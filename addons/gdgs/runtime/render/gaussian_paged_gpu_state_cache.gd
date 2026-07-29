@tool
extends RefCounted
class_name GaussianPagedGpuStateCache

const RenderingDeviceContext := preload("res://addons/gdgs/runtime/render/gaussian_rendering_device_context.gd")
const Capacity := preload("res://addons/gdgs/runtime/render/gaussian_paged_projection_capacity.gd")

const FLOATS_PER_SPLAT := 60
const FLOATS_PER_CULLED_SPLAT := 16
const BYTES_PER_FLOAT := 4
const PROJECTION_UNIFORM_BYTES := 40 * BYTES_PER_FLOAT
const PREFIX_CONSTANTS_BYTES := 8 * BYTES_PER_FLOAT
const INSTANCE_TRANSFORM_BYTES := 16 * BYTES_PER_FLOAT
const CULLED_SPLAT_BYTES := FLOATS_PER_CULLED_SPLAT * BYTES_PER_FLOAT
const TILE_SPLAT_POSITION_BYTES := 4 * BYTES_PER_FLOAT
# The paged path uses an RGBA16F colour/alpha target plus an R32F depth
# target. The legacy renderer deliberately keeps its existing RGBA32F target.
# Keeping the formats distinct avoids changing standalone output while making
# the frozen 512 MiB per-view contract compatible with its required 8K row.
const COLOR_TARGET_BYTES_PER_PIXEL := 4 * 2
const DEPTH_TARGET_BYTES_PER_PIXEL := BYTES_PER_FLOAT
const RENDER_TARGET_BYTES_PER_PIXEL := (
	COLOR_TARGET_BYTES_PER_PIXEL + DEPTH_TARGET_BYTES_PER_PIXEL
)
const TRANSITION_METADATA_BYTES := 32
# The active-view ceiling is deliberately NOT a constant here. It is derived
# from the approved native budget (`configured_maximum_active_views`) so the
# contract stays the single authority; re-declaring it locally is what let the
# gate drift to 4 while the approved value was 2.
const NATIVE_RUNTIME_SINGLETON := &"GDSpatialGaussianRuntimeInternal"
const NATIVE_DEVICE_IDENTITY := "GodotRenderingServer.main"
const PAGE_EMPTY := "empty"
const PAGE_UPLOADING := "uploading"
const PAGE_READY := "ready"

const SHADER_PROJECTION := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_paged_projection.glsl"
const SHADER_PREFIX_BLOCKS := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_prefix_blocks.glsl"
const SHADER_PREFIX_BLOCK_SUMS := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_paged_prefix_block_sums.glsl"
const SHADER_ADMISSION := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_paged_admission.glsl"
const SHADER_EMIT := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_paged_emit.glsl"
const SHADER_RADIX_UPSWEEP := "res://addons/gdgs/runtime/render/shaders/compute/radix_sort_paged_upsweep.glsl"
const SHADER_RADIX_SPINE := "res://addons/gdgs/runtime/render/shaders/compute/radix_sort_paged_spine.glsl"
const SHADER_RADIX_DOWNSWEEP := "res://addons/gdgs/runtime/render/shaders/compute/radix_sort_paged_downsweep.glsl"
const SHADER_BOUNDARIES := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_paged_boundaries.glsl"
const SHADER_RENDER := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_paged_render.glsl"

class PageState:
	extends RefCounted

	var page_id := 0
	var content_identity := ""
	var content_hash := ""
	var point_count := 0
	var unaligned_bytes := 0
	var class_bytes := 0
	var payload := PackedByteArray()
	var descriptor
	var generation := 0
	var state := PAGE_EMPTY
	var upload_id := ""
	var uploaded_bytes := 0
	var final_submission_id := 0
	var readiness_recorded := false
	var proof_scheduled := false

class ViewState:
	extends RefCounted

	var view_identity := ""
	var view_generation := 0
	var registry_revision := 0
	var selection_generation := 0
	var selection_signature := ""
	var texture_size := Vector2i.ONE
	var tile_dims := Vector2i.ONE
	var logical_point_count := 0
	var active_references: Array[Dictionary] = []
	var context
	var shaders: Dictionary = {}
	var pipelines: Dictionary = {}
	var descriptors: Dictionary = {}
	var projection_sets: Dictionary = {}
	var projection_pipelines: Array[Callable] = []
	var workspace_layout: Dictionary = {}
	var accounted_workspace_bytes := 0
	var workspace_accounting: Dictionary = {}
	var camera_projection: Projection
	var camera_view: Projection
	var camera_matrices := PackedByteArray()
	var camera_world_position := Vector3.ZERO
	var depth_capture_alpha := 0.5
	var committed := false
	var has_complete_submission := false
	var last_admission: Dictionary = {}
	var last_error: Dictionary = {}

class TransitionState:
	extends RefCounted

	var identity := ""
	var view_identity := ""
	var registry_revision := 0
	var view_generation := 0
	var texture_size := Vector2i.ONE
	var selection_generation := 0
	var selection_signature := ""
	var stage := ""
	var outgoing_page_ids: Dictionary = {}
	var incoming_page_ids: Dictionary = {}
	var newly_admitted_page_ids: Dictionary = {}
	var retirement_keys: Dictionary = {}
	var measurement: Dictionary = {}
	var reservation: Dictionary = {}
	var reservation_native_before: Dictionary = {}
	var reservation_native_after: Dictionary = {}
	var pre_switch: Dictionary = {}
	var frame_boundary: Dictionary = {}
	var retirement: Dictionary = {}
	var cancellation: Dictionary = {}

var _native_runtime: Object
var _native_configured := false
var _page_descriptor_context
var _pages: Dictionary = {}
var _retiring_pages: Dictionary = {}
var _views: Dictionary = {}
var _candidate_views: Dictionary = {}
var _workspace_budget_bytes := Capacity.DEFAULT_WORKSPACE_BUDGET_BYTES
# Per-view admission ceilings derived from the approved native budget rather
# than re-declared here. Zero means "not yet derived"; every gate that uses
# them fails closed in that state.
var _configured_maximum_active_views := 0
var _configured_sort_workspace_bytes_per_view := 0
var _configured_overlap_pairs_per_view := 0
var _native_last_upload_frame := -1
var _latest_telemetry: Dictionary = {}
var _atomic_group_rejection_count := 0
var _retained_submission_count := 0
var _transition: TransitionState
var _last_transition_snapshot: Dictionary = {}
var _transition_reservation_count := 0
var _transition_commit_count := 0
var _transition_completion_count := 0
var _transition_cancellation_count := 0
var _transition_failure_count := 0
var _failed_selections: Dictionary = {}
var _last_error: Dictionary = {}

func ensure_resident_pages(candidates: Array) -> Error:
	var validated := _validate_candidates(candidates)
	if not bool(validated.get("valid", false)):
		return _record_error(
			String(validated.get("error_id", "GDGS_PAGED_PAGE_INVALID")),
			"validate_candidates",
			validated
		)
	if candidates.is_empty():
		_poll_native_runtime()
		return OK
	var candidate_by_id: Dictionary = validated["candidate_by_id"]
	var runtime_error := _ensure_native_runtime()
	if runtime_error != OK:
		return runtime_error
	_poll_native_runtime()

	var incoming_candidates: Array[Dictionary] = []
	for candidate_value: Variant in candidates:
		var candidate: Dictionary = candidate_value
		var page_id := int(candidate["page_id"])
		var existing: PageState = _pages.get(page_id, null)
		if (
			existing != null
			and existing.content_hash
				== String(candidate["content_hash"])
		):
			continue
		if existing != null:
			return _record_error(
				"GDGS_PAGE_IDENTITY_CONFLICT",
				"ensure_resident_pages",
				candidate
			)
		incoming_candidates.push_back(candidate)
	if not incoming_candidates.is_empty():
		var preflight_definitions: Array[Dictionary] = []
		for candidate: Dictionary in incoming_candidates:
			preflight_definitions.push_back({
				"content_identity": candidate["content_identity"],
				"content_hash": candidate["content_hash"],
				"layout_version": candidate["layout_version"],
				"shader_version": candidate["shader_version"],
				"unaligned_bytes": candidate["unaligned_bytes"]
			})
		var preflight: Dictionary = _native_runtime.call(
			&"preflight_page_group",
			preflight_definitions
		)
		if not bool(preflight.get("accepted", false)):
			return _record_error(
				String(
					preflight.get(
						"status",
						"GDGS_PAGE_GROUP_PREFLIGHT_FAILED"
					)
				),
				"preflight_page_group",
				preflight
			)

	# The native staging pool is a bounded transient resource. Keep at most
	# one page upload live in this cache so a selected set is accumulated
	# progressively while the previous committed set remains visible. The
	# transition reservation therefore charges the largest selected page as
	# the physical staging peak, rather than the sum of pages that never need
	# to occupy staging simultaneously.
	var upload_in_flight := false
	for page_value: Variant in _pages.values():
		var resident_page: PageState = page_value
		if resident_page.state == PAGE_UPLOADING:
			upload_in_flight = true
			break
	var newly_admitted: Array[PageState] = []
	if not upload_in_flight and not incoming_candidates.is_empty():
		var candidate: Dictionary = incoming_candidates[0]
		var admission_error := _admit_page(candidate)
		if admission_error != OK:
			_rollback_unsubmitted_pages(newly_admitted)
			return admission_error
		var admitted_page: PageState = _pages.get(
			int(candidate["page_id"]),
			null
		)
		if admitted_page != null:
			newly_admitted.push_back(admitted_page)

	var upload_error := _pump_uploads()
	if upload_error != OK and upload_error != ERR_BUSY:
		return upload_error
	_poll_native_runtime()
	for page_id: Variant in candidate_by_id:
		var page: PageState = _pages.get(page_id, null)
		if page == null or page.state != PAGE_READY:
			return ERR_BUSY
	return OK

func prepare_selected_set_transition(
	active_list: Dictionary,
	candidates: Array,
	texture_size: Vector2i
) -> Dictionary:
	if not bool(active_list.get("accepted", false)):
		return _transition_rejection(
			"GDGS_TRANSITION_ACTIVE_SET_INVALID",
			active_list
		)
	if texture_size.x <= 0 or texture_size.y <= 0:
		return _transition_rejection(
			"GDGS_PAGED_VIEW_INVALID",
			{
				"view_identity": String(
					active_list.get("view_identity", "")
				),
				"texture_size": texture_size
			}
		)
	var validated := _validate_candidates(candidates)
	if not bool(validated.get("valid", false)):
		return _transition_rejection(
			String(validated.get("error_id", "GDGS_PAGED_PAGE_INVALID")),
			validated
		)
	var selected := _selected_candidates(
		active_list,
		validated["candidate_by_id"]
	)
	if not bool(selected.get("accepted", false)):
		return selected
	var selected_candidates: Array = selected["candidates"]
	var view_identity := String(active_list.get("view_identity", ""))
	var selection_generation := _active_selection_generation(active_list)
	var selection_signature := _active_selection_signature(active_list)
	var committed: ViewState = _views.get(view_identity, null)
	if _native_runtime != null and is_instance_valid(_native_runtime):
		_poll_native_runtime()
	var stable_failure: Dictionary = _failed_selections.get(
		view_identity,
		{}
	)
	if not stable_failure.is_empty():
		if (
			String(stable_failure.get("selection_signature", ""))
				== selection_signature
			and int(stable_failure.get("selection_generation", 0))
				== selection_generation
			and int(stable_failure.get("view_generation", 0))
				== int(active_list.get("view_generation", 0))
			and stable_failure.get("texture_size", Vector2i.ZERO)
				== texture_size
		):
			_last_error = (
				stable_failure.get("error", {}) as Dictionary
			).duplicate(true)
			return {
				"accepted": false,
				"error_id": String(
					_last_error.get(
						"error_id",
						"GDGS_TRANSITION_MEMBER_FAILED"
					)
				),
				"detail": _last_error.duplicate(true),
				"stable_failure": true
			}
		_failed_selections.erase(view_identity)

	if (
		_transition != null
		and _transition.view_identity == view_identity
		and _transition.selection_signature == selection_signature
		and _transition.registry_revision
			== int(active_list.get("registry_revision", 0))
		and _transition.view_generation
			== int(active_list.get("view_generation", 0))
		and _transition.texture_size == texture_size
	):
		return {
			"accepted": true,
			"candidates": selected_candidates,
			"transition_identity": _transition.identity,
			"transition_stage": _transition.stage
		}
	if _transition != null:
		if _transition.stage == "post_switch":
			return _transition_rejection(
				"GDGS_TRANSITION_RETIREMENT_PENDING",
				_transition_snapshot(_transition)
			)
		var cancel_error := _cancel_active_transition(
			"selection_superseded"
		)
		if cancel_error != OK:
			return _transition_rejection(
				"GDGS_TRANSITION_CANCEL_FAILED",
				get_transition_snapshot()
			)

	if (
		committed == null
		or selection_generation <= 0
		or (
			committed.selection_signature == selection_signature
			and committed.selection_generation == selection_generation
			and committed.view_generation
				== int(active_list.get("view_generation", 0))
			and committed.texture_size == texture_size
			and committed.logical_point_count
				== int(active_list.get("logical_splat_count", 0))
		)
	):
		return {
			"accepted": true,
			"candidates": selected_candidates,
			"transition_identity": "",
			"transition_stage": "none"
		}

	var runtime_error := _ensure_native_runtime()
	if runtime_error != OK:
		return _transition_rejection(
			"GDGS_NATIVE_RUNTIME_REQUIRED",
			_last_error
		)
	_poll_native_runtime()
	var reserved := _reserve_selected_set_transition(
		active_list,
		selected_candidates,
		texture_size,
		committed,
		selection_generation,
		selection_signature
	)
	if not bool(reserved.get("accepted", false)):
		return reserved
	return {
		"accepted": true,
		"candidates": selected_candidates,
		"transition_identity": _transition.identity,
		"transition_stage": _transition.stage
	}

func commit_selected_set_transition_pre_switch(
	state: ViewState
) -> Error:
	if (
		_transition == null
		or state == null
		or _transition.view_identity != state.view_identity
		or _transition.selection_signature != state.selection_signature
		or _transition.view_generation != state.view_generation
		or _transition.texture_size != state.texture_size
	):
		return OK
	if _transition.stage == "pre_switch":
		return OK
	if _transition.stage != "reserved":
		return _record_error(
			"GDGS_TRANSITION_STAGE_INVALID",
			"commit_transition_pre_switch",
			_transition_snapshot(_transition)
		)
	var committed: Dictionary = _native_runtime.call(
		&"commit_transition_pre_switch",
		_transition.identity
	)
	if (
		not bool(committed.get("accepted", false))
		or String(committed.get("status", "")) != "COMMITTED"
	):
		return _record_error(
			String(
				committed.get(
					"status",
					"GDGS_TRANSITION_PRE_SWITCH_FAILED"
				)
			),
			"commit_transition_pre_switch",
			committed
		)
	_transition.pre_switch = committed.duplicate(true)
	_transition.stage = "pre_switch"
	_transition_commit_count += 1
	return OK

func get_transition_snapshot() -> Dictionary:
	return {
		"schema": "gdgs-selected-set-transition-snapshot-v1",
		"active": _transition != null,
		"current": (
			{}
			if _transition == null
			else _transition_snapshot(_transition)
		),
		"last": _last_transition_snapshot.duplicate(true),
		"reservation_count": _transition_reservation_count,
		"commit_count": _transition_commit_count,
		"completion_count": _transition_completion_count,
		"cancellation_count": _transition_cancellation_count,
		"failure_count": _transition_failure_count,
		"failed_selections": _failed_selections.duplicate(true)
	}

func cancel_selected_set_transition(reason: String) -> Error:
	return _cancel_active_transition(reason)

func fail_selected_set_transition(
	reason: String,
	detail: Dictionary
) -> Error:
	if _transition == null or _transition.stage == "post_switch":
		return _record_error(
			"GDGS_TRANSITION_FAILURE_STATE_INVALID",
			"fail_selected_set_transition",
			{
				"reason": reason,
				"detail": detail.duplicate(true),
				"transition": get_transition_snapshot()
			}
		)
	var failed_transition := _transition
	var cleanup_errors: Array[Dictionary] = []
	for page_id_value: Variant in (
		failed_transition.newly_admitted_page_ids.keys()
	):
		var page_id := int(page_id_value)
		if _page_used_by_other_committed_view(
			page_id,
			failed_transition.view_identity
		):
			continue
		var page: PageState = _pages.get(page_id, null)
		if page == null:
			continue
		var cleanup_error := _retire_page(page)
		if cleanup_error != OK:
			cleanup_errors.push_back({
				"page_id": page_id,
				"error": _last_error.duplicate(true)
			})
	var cancel_error := _cancel_active_transition(
		"member_failed:%s" % reason
	)
	var error := {
		"schema": "gdgs-selected-set-stable-failure-v1",
		"error_id": "GDGS_TRANSITION_MEMBER_FAILED",
		"operation": "selected_set_transition",
		"reason": reason,
		"detail": detail.duplicate(true),
		"cleanup_errors": cleanup_errors,
		"cancel_error": cancel_error,
		"view_identity": failed_transition.view_identity,
		"view_generation": failed_transition.view_generation,
		"selection_generation":
			failed_transition.selection_generation,
		"selection_signature":
			failed_transition.selection_signature,
		"texture_size": failed_transition.texture_size
	}
	_failed_selections[failed_transition.view_identity] = {
		"selection_generation":
			failed_transition.selection_generation,
		"selection_signature":
			failed_transition.selection_signature,
		"view_generation": failed_transition.view_generation,
		"texture_size": failed_transition.texture_size,
		"error": error.duplicate(true)
	}
	_transition_failure_count += 1
	_last_error = error.duplicate(true)
	if cancel_error != OK or not cleanup_errors.is_empty():
		return ERR_CANT_CREATE
	return OK

func get_or_create_view_state(
	active_list: Dictionary,
	texture_size: Vector2i
):
	var view_identity := String(
		active_list.get("view_identity", "")
	)
	var view_generation := int(
		active_list.get("view_generation", 0)
	)
	var registry_revision := int(
		active_list.get("registry_revision", 0)
	)
	var selection_signature := _active_selection_signature(active_list)
	var logical_point_count := int(
		active_list.get("logical_splat_count", 0)
	)
	var active_references: Array = active_list.get(
		"active_references",
		[]
	)
	if (
		not bool(active_list.get("accepted", false))
		or view_identity.is_empty()
		or view_generation <= 0
		or logical_point_count <= 0
		or active_references.is_empty()
		or texture_size.x <= 0
		or texture_size.y <= 0
	):
		_record_error(
			"GDGS_PAGED_VIEW_INVALID",
			"get_or_create_view_state",
			active_list
		)
		return null

	var committed: ViewState = _views.get(view_identity, null)
	if _state_matches(
		committed,
		view_generation,
		selection_signature,
		texture_size,
		logical_point_count
	):
		return committed
	var state: ViewState = _candidate_views.get(
		view_identity,
		null
	)
	if _state_matches(
		state,
		view_generation,
		selection_signature,
		texture_size,
		logical_point_count
	):
		return state
	if state != null:
		cleanup_view_state(state)
		_candidate_views.erase(view_identity)
	if _configured_maximum_active_views <= 0:
		_record_error(
			"GDGS_CONFIGURED_VIEW_LIMITS_UNAVAILABLE",
			"get_or_create_view_state",
			{"view_identity": view_identity}
		)
		return null
	if (
		not _views.has(view_identity)
		and not _candidate_views.has(view_identity)
		and _views.size() + _candidate_views.size()
			>= _configured_maximum_active_views
	):
		_record_error(
			"GDGS_ACTIVE_VIEW_LIMIT",
			"get_or_create_view_state",
			{
				"view_identity": view_identity,
				"active_view_count": (
					_views.size() + _candidate_views.size()
				),
				"approved_maximum_active_views":
					_configured_maximum_active_views
			}
		)
		return null
	state = ViewState.new()
	_candidate_views[view_identity] = state
	state.view_identity = view_identity
	state.view_generation = view_generation
	state.registry_revision = registry_revision
	state.selection_generation = _active_selection_generation(active_list)
	state.selection_signature = selection_signature
	state.texture_size = texture_size
	state.tile_dims = (
		texture_size
		+ Vector2i(Capacity.TILE_SIZE - 1, Capacity.TILE_SIZE - 1)
	) / Capacity.TILE_SIZE
	state.logical_point_count = logical_point_count
	state.active_references.assign(active_references)
	if _rebuild_view_state(state) != OK:
		_candidate_views.erase(view_identity)
		return null
	return state

func is_committed_view_state(state: ViewState) -> bool:
	return (
		state != null
		and state.committed
		and _views.get(state.view_identity, null) == state
	)

func get_committed_view_state(view_identity: String) -> ViewState:
	return _views.get(view_identity, null)

func commit_view_state(state: ViewState) -> Error:
	if state == null or state.context == null:
		return ERR_INVALID_PARAMETER
	if is_committed_view_state(state):
		state.has_complete_submission = true
		return OK
	if _candidate_views.get(state.view_identity, null) != state:
		return ERR_INVALID_DATA
	var owns_transition := (
		_transition != null
		and _transition.view_identity == state.view_identity
		and _transition.selection_signature == state.selection_signature
		and _transition.view_generation == state.view_generation
		and _transition.texture_size == state.texture_size
	)
	if owns_transition:
		if _transition.stage != "pre_switch":
			return _record_error(
				"GDGS_TRANSITION_PRE_SWITCH_REQUIRED",
				"commit_view_state",
				_transition_snapshot(_transition)
			)
		var boundary: Dictionary = _native_runtime.call(
			&"commit_transition_frame_boundary",
			_transition.identity
		)
		if (
			not bool(boundary.get("accepted", false))
			or String(boundary.get("status", ""))
				!= "RETIREMENT_STARTED"
		):
			return _record_error(
				String(
					boundary.get(
						"status",
						"GDGS_TRANSITION_FRAME_BOUNDARY_FAILED"
					)
				),
				"commit_transition_frame_boundary",
				boundary
			)
		_transition.frame_boundary = boundary.duplicate(true)
	var previous: ViewState = _views.get(state.view_identity, null)
	_candidate_views.erase(state.view_identity)
	_views[state.view_identity] = state
	_failed_selections.erase(state.view_identity)
	state.committed = true
	state.has_complete_submission = true
	if previous != null and previous != state:
		cleanup_view_state(previous)
	if owns_transition:
		_transition.stage = "post_switch"
		for page_id_value: Variant in _transition.outgoing_page_ids.keys():
			var page: PageState = _pages.get(
				int(page_id_value),
				null
			)
			if page == null:
				continue
			var retirement_error := _retire_page(page, true)
			if retirement_error != OK:
				return retirement_error
		_try_finish_transition_retirement()
	return OK

func discard_candidate_view_state(state: ViewState) -> void:
	if state == null or is_committed_view_state(state):
		return
	if _candidate_views.get(state.view_identity, null) == state:
		_candidate_views.erase(state.view_identity)
	cleanup_view_state(state)
	if (
		_transition != null
		and _transition.view_identity == state.view_identity
		and _transition.selection_signature == state.selection_signature
		and _transition.view_generation == state.view_generation
		and _transition.texture_size == state.texture_size
		and _transition.stage != "post_switch"
	):
		_cancel_active_transition("candidate_discarded")

func commit_empty_view(view_identity: String) -> void:
	if (
		_transition != null
		and _transition.view_identity == view_identity
		and _transition.stage != "post_switch"
	):
		_cancel_active_transition("empty_view")
	var candidate: ViewState = _candidate_views.get(
		view_identity,
		null
	)
	if candidate != null:
		_candidate_views.erase(view_identity)
		cleanup_view_state(candidate)
	var committed: ViewState = _views.get(view_identity, null)
	if committed != null:
		_views.erase(view_identity)
		cleanup_view_state(committed)
	_failed_selections.erase(view_identity)

func set_workspace_budget_bytes(budget_bytes: int) -> Error:
	if (
		budget_bytes <= 0
		or budget_bytes > Capacity.MAX_WORKSPACE_BUDGET_BYTES
	):
		return ERR_INVALID_PARAMETER
	if budget_bytes == _workspace_budget_bytes:
		return OK
	_workspace_budget_bytes = budget_bytes
	cleanup_all_views()
	return OK

func get_workspace_budget_bytes() -> int:
	return _workspace_budget_bytes

func get_last_error() -> Dictionary:
	return _last_error.duplicate(true)

func get_latest_telemetry() -> Dictionary:
	return _latest_telemetry.duplicate(true)

func record_admission_snapshot(
	state: ViewState,
	snapshot: Dictionary
) -> void:
	if state != null:
		state.last_admission = snapshot.duplicate(true)
	_latest_telemetry = snapshot.duplicate(true)
	if (
		not bool(snapshot.get("accepted", false))
		and String(snapshot.get("error_id", ""))
			== "GDGS_PAIR_CAPACITY_EXCEEDED"
	):
		_atomic_group_rejection_count += 1

func note_retained_submission() -> void:
	_retained_submission_count += 1

func poll_native_runtime() -> void:
	_poll_native_runtime()

func commit_resident_pages(candidates: Array) -> Error:
	var keep_page_ids: Dictionary = {}
	for candidate_value: Variant in candidates:
		if candidate_value is Dictionary:
			keep_page_ids[int(candidate_value.get("page_id", 0))] = true
	for page_id: Variant in _pages.keys():
		if keep_page_ids.has(page_id):
			continue
		var page: PageState = _pages.get(page_id, null)
		if page == null:
			continue
		var retirement_error := _retire_page(page)
		if retirement_error != OK:
			return retirement_error
	return OK

func get_residency_snapshot() -> Dictionary:
	var ready_pages := 0
	var uploading_pages := 0
	var resident_bytes := 0
	var resident_class_bytes := 0
	var page_table: Array[Dictionary] = []
	var page_ids: Array = _pages.keys()
	page_ids.sort()
	for page_id: Variant in page_ids:
		var page: PageState = _pages[page_id]
		if page.state == PAGE_READY:
			ready_pages += 1
		elif page.state == PAGE_UPLOADING:
			uploading_pages += 1
		resident_bytes += page.unaligned_bytes
		resident_class_bytes += page.class_bytes
		page_table.push_back({
			"page_id": page.page_id,
			"content_identity": page.content_identity,
			"content_hash": page.content_hash,
			"point_count": page.point_count,
			"generation": page.generation,
			"state": page.state,
			"resident_bytes": page.unaligned_bytes,
			"class_bytes": page.class_bytes,
			"buffer_valid": (
				page.descriptor != null
				and page.descriptor.rid.is_valid()
			)
		})
	var retiring_pages: Array[Dictionary] = []
	var retirement_keys: Array = _retiring_pages.keys()
	retirement_keys.sort()
	for retirement_key: Variant in retirement_keys:
		var retirement: Dictionary = (
			_retiring_pages[retirement_key] as Dictionary
		).duplicate(true)
		retirement["retirement_key"] = String(retirement_key)
		retiring_pages.push_back(retirement)
	var snapshot := {
		"schema": "gdgs-paged-residency-snapshot-v1",
		"page_count": _pages.size(),
		"ready_page_count": ready_pages,
		"uploading_page_count": uploading_pages,
		"retiring_page_count": _retiring_pages.size(),
		"resident_bytes": resident_bytes,
		"resident_class_bytes": resident_class_bytes,
		"view_count": _views.size(),
		"candidate_view_count": _candidate_views.size(),
		"atomic_group_rejection_count":
			_atomic_group_rejection_count,
		"retained_submission_count": _retained_submission_count,
		"page_table": page_table,
		"retiring_pages": retiring_pages,
		"configured_view_limits": get_configured_view_limits(),
		"workspace_budget_bytes": _workspace_budget_bytes,
		"latest_telemetry": _latest_telemetry.duplicate(true),
		"transition": get_transition_snapshot(),
		"last_error": _last_error.duplicate(true)
	}
	if _native_runtime != null and is_instance_valid(_native_runtime):
		snapshot["native_snapshot"] = _native_runtime.call(&"snapshot")
	return snapshot

func collect_admission(state: ViewState) -> Dictionary:
	if (
		state == null
		or state.context == null
		or not state.descriptors.has("telemetry")
	):
		return {
			"accepted": false,
			"error_id": "GDGS_ADMISSION_STATE_INVALID"
		}
	var telemetry_bytes: PackedByteArray = (
		state.context.device.buffer_get_data(
			state.descriptors["telemetry"].rid
		)
	)
	if telemetry_bytes.size() < Capacity.TELEMETRY_BYTES:
		return {
			"accepted": false,
			"error_id": "GDGS_ADMISSION_READBACK_INVALID"
		}
	var requested_pairs := int(telemetry_bytes.decode_u32(16))
	var admitted_pairs := int(telemetry_bytes.decode_u32(20))
	var emitted_pairs := int(telemetry_bytes.decode_u32(24))
	var rejected_pairs := int(telemetry_bytes.decode_u32(28))
	var pair_capacity := int(telemetry_bytes.decode_u32(32))
	var flags := int(telemetry_bytes.decode_u32(48))
	var accepted := (
		requested_pairs <= pair_capacity
		and (flags & 1) == 0
	)
	return {
		"schema": "gdgs-paged-atomic-admission-v1",
		"accepted": accepted,
		"error_id": (
			""
			if accepted
			else "GDGS_PAIR_CAPACITY_EXCEEDED"
		),
		"view_identity": state.view_identity,
		"view_generation": state.view_generation,
		"registry_revision": state.registry_revision,
		"requested_pairs": requested_pairs,
		"admitted_pairs": admitted_pairs,
		"emitted_pairs": emitted_pairs,
		"rejected_pairs": rejected_pairs,
		"pair_capacity": pair_capacity,
		"flags": flags,
		"retained_previous_submission": false
	}

func collect_projection_ranges(
	state: ViewState,
	maximum_ranges: int = -1
) -> Dictionary:
	# Synchronous validation/diagnostic readback. The production frame path
	# never calls this method.
	if (
		state == null
		or state.context == null
		or not state.descriptors.has("projection_ranges")
	):
		return {}
	var range_count := state.logical_point_count
	if maximum_ranges >= 0:
		range_count = mini(range_count, maximum_ranges)
	if range_count == 0:
		return {
			"schema": "gdgs-paged-projection-ranges-v1",
			"range_count": 0,
			"valid_count": 0,
			"invalid_count": 0,
			"empty_count": 0,
			"maximum_requested_pairs_per_splat": 0,
			"requested_histogram": {},
			"ranges": []
		}
	var range_bytes_required := (
		range_count
		* Capacity.PROJECTION_RANGE_BYTES_PER_SPLAT
	)
	var range_bytes: PackedByteArray = (
		state.context.device.buffer_get_data(
			state.descriptors["projection_ranges"].rid,
			0,
			range_bytes_required
		)
	)
	if range_bytes.size() < range_bytes_required:
		return {}
	var ranges: Array[Dictionary] = []
	var requested_histogram: Dictionary = {}
	var valid_count := 0
	var invalid_count := 0
	var empty_count := 0
	var maximum_requested := 0
	for index in range_count:
		var offset := (
			index
			* Capacity.PROJECTION_RANGE_BYTES_PER_SPLAT
		)
		var status := int(range_bytes.decode_u32(offset + 32))
		var requested := int(
			range_bytes.decode_u32(offset + 16)
		)
		if (status & 1) != 0:
			valid_count += 1
		elif (status & 2) != 0:
			invalid_count += 1
		else:
			empty_count += 1
		requested_histogram[requested] = int(
			requested_histogram.get(requested, 0)
		) + 1
		maximum_requested = maxi(maximum_requested, requested)
		ranges.push_back({
			"logical_splat_id": index,
			"bounds": PackedInt64Array([
				int(range_bytes.decode_u32(offset)),
				int(range_bytes.decode_u32(offset + 4)),
				int(range_bytes.decode_u32(offset + 8)),
				int(range_bytes.decode_u32(offset + 12))
			]),
			"requested_pairs": requested,
			"prefix_offset": int(
				range_bytes.decode_u32(offset + 20)
			),
			"admitted_offset": int(
				range_bytes.decode_u32(offset + 24)
			),
			"ordered_depth": int(
				range_bytes.decode_u32(offset + 28)
			),
			"status": status,
			"page_id": int(
				range_bytes.decode_u32(offset + 36)
			),
			"point_index": int(
				range_bytes.decode_u32(offset + 40)
			)
		})
	return {
		"schema": "gdgs-paged-projection-ranges-v1",
		"range_count": range_count,
		"valid_count": valid_count,
		"invalid_count": invalid_count,
		"empty_count": empty_count,
		"maximum_requested_pairs_per_splat": maximum_requested,
		"requested_histogram": requested_histogram,
		"ranges": ranges
	}

func collect_stream(state: ViewState, maximum_entries: int = -1) -> Dictionary:
	if (
		state == null
		or state.context == null
		or not state.descriptors.has("telemetry")
	):
		return {}
	var telemetry_bytes: PackedByteArray = (
		state.context.device.buffer_get_data(
			state.descriptors["telemetry"].rid
		)
	)
	if telemetry_bytes.size() < Capacity.TELEMETRY_BYTES:
		return {}
	var emitted := int(telemetry_bytes.decode_u32(6 * 4))
	var pair_capacity := int(telemetry_bytes.decode_u32(8 * 4))
	var entry_count := mini(emitted, pair_capacity)
	if maximum_entries >= 0:
		entry_count = mini(entry_count, maximum_entries)
	var key_bytes_required := entry_count * 4 * 4
	var value_bytes_required := entry_count * 4
	var key_bytes: PackedByteArray = (
		state.context.device.buffer_get_data(
			state.descriptors["sort_keys"].rid,
			0,
			key_bytes_required
		)
	)
	var value_bytes: PackedByteArray = (
		state.context.device.buffer_get_data(
			state.descriptors["sort_values"].rid,
			0,
			value_bytes_required
		)
	)
	var entries: Array[Dictionary] = []
	if (
		key_bytes.size() >= key_bytes_required
		and value_bytes.size() >= value_bytes_required
	):
		for index in entry_count:
			var key_offset := index * 16
			entries.push_back({
				"screen_bin_id": int(key_bytes.decode_u32(key_offset)),
				"ordered_depth": int(
					key_bytes.decode_u32(key_offset + 4)
				),
				"page_id": int(
					key_bytes.decode_u32(key_offset + 8)
				),
				"point_index": int(
					key_bytes.decode_u32(key_offset + 12)
				),
				"logical_splat_id": int(
					value_bytes.decode_u32(index * 4)
				)
			})
	return {
		"schema": "gdgs-paged-overlap-stream-v1",
		"layout_version": int(telemetry_bytes.decode_u32(0)),
		"generation": int(telemetry_bytes.decode_u32(4)),
		"resident_splats": int(telemetry_bytes.decode_u32(8)),
		"visible_splats": int(telemetry_bytes.decode_u32(12)),
		"requested_pairs": int(telemetry_bytes.decode_u32(16)),
		"admitted_pairs": int(telemetry_bytes.decode_u32(20)),
		"emitted_pairs": emitted,
		"dropped_pairs": int(telemetry_bytes.decode_u32(28)),
		"pair_capacity": pair_capacity,
		"flags": int(telemetry_bytes.decode_u32(48)),
		"entries": entries
	}

func cleanup_view_state(state: ViewState) -> void:
	if state == null:
		return
	if state.context != null:
		state.context.free()
		state.context = null
	state.shaders.clear()
	state.pipelines.clear()
	state.descriptors.clear()
	state.projection_sets.clear()
	state.projection_pipelines.clear()
	state.workspace_layout = {}
	state.camera_matrices = PackedByteArray()

func cleanup_all_views() -> void:
	for state_value: Variant in _views.values():
		cleanup_view_state(state_value)
	for state_value: Variant in _candidate_views.values():
		cleanup_view_state(state_value)
	_views.clear()
	_candidate_views.clear()
	_failed_selections.clear()

func shutdown() -> void:
	if _transition != null:
		if _transition.stage == "post_switch":
			_record_error(
				"GDGS_TRANSITION_RETIREMENT_PENDING",
				"shutdown",
				_transition_snapshot(_transition)
			)
			return
		_cancel_active_transition("shutdown")
	cleanup_all_views()
	if _native_runtime != null and is_instance_valid(_native_runtime):
		for page_value: Variant in _pages.values():
			_retire_page(page_value)
		var shutdown_result: Dictionary = _native_runtime.call(
			&"begin_shutdown"
		)
		if not bool(shutdown_result.get("accepted", false)):
			_record_error(
				String(
					shutdown_result.get(
						"status",
						"GDGS_PAGED_SHUTDOWN_FAILED"
					)
				),
				"begin_shutdown",
				shutdown_result
			)
	_pages.clear()
	if _page_descriptor_context != null:
		_page_descriptor_context.free()
		_page_descriptor_context = null
	_native_configured = false

func has_live_state() -> bool:
	return (
		not _pages.is_empty()
		or not _retiring_pages.is_empty()
		or not _views.is_empty()
		or not _candidate_views.is_empty()
		or _transition != null
	)

func _selected_candidates(
	active_list: Dictionary,
	candidate_by_id: Dictionary
) -> Dictionary:
	var selected: Array[Dictionary] = []
	var selected_page_ids: Dictionary = {}
	for reference_value: Variant in active_list.get(
		"active_references",
		[]
	):
		if not reference_value is Dictionary:
			return _transition_rejection(
				"GDGS_TRANSITION_ACTIVE_SET_INVALID",
				active_list
			)
		var reference: Dictionary = reference_value
		var page_id := int(reference.get("page_id", 0))
		if page_id <= 0 or not candidate_by_id.has(page_id):
			return _transition_rejection(
				"GDGS_TRANSITION_SELECTED_PAGE_MISSING",
				{"page_id": page_id}
			)
		if selected_page_ids.has(page_id):
			continue
		selected_page_ids[page_id] = true
		selected.push_back(candidate_by_id[page_id])
	return {
		"accepted": true,
		"candidates": selected
	}

func _active_selection_generation(active_list: Dictionary) -> int:
	var generation := 0
	for reference_value: Variant in active_list.get(
		"active_references",
		[]
	):
		if reference_value is Dictionary:
			generation = maxi(
				generation,
				int(reference_value.get("selection_generation", 0))
			)
	return generation

func _active_selection_signature(active_list: Dictionary) -> String:
	var tokens := PackedStringArray()
	for reference_value: Variant in active_list.get(
		"active_references",
		[]
	):
		if not reference_value is Dictionary:
			continue
		var reference: Dictionary = reference_value
		tokens.push_back("%s|%s|%d|%d|%d|%d|%s" % [
			String(reference.get("source_kind", "")),
			String(reference.get("owner_identity", "")),
			int(reference.get("reference_id", 0)),
			int(reference.get("page_id", 0)),
			int(reference.get("point_count", 0)),
			int(reference.get("selection_generation", 0)),
			str(
				reference.get(
					"model_transform",
					Transform3D.IDENTITY
				)
			)
		])
	return "\n".join(tokens).sha256_text()

func _page_ids_from_references(references: Array) -> Dictionary:
	var page_ids: Dictionary = {}
	for reference_value: Variant in references:
		if reference_value is Dictionary:
			page_ids[int(reference_value.get("page_id", 0))] = true
	return page_ids

func _page_used_by_other_committed_view(
	page_id: int,
	excluded_view_identity: String
) -> bool:
	for state_value: Variant in _views.values():
		var state: ViewState = state_value
		if state.view_identity == excluded_view_identity:
			continue
		for reference: Dictionary in state.active_references:
			if int(reference.get("page_id", 0)) == page_id:
				return true
	return false

func _reserve_selected_set_transition(
	active_list: Dictionary,
	selected_candidates: Array,
	texture_size: Vector2i,
	committed: ViewState,
	selection_generation: int,
	selection_signature: String
) -> Dictionary:
	if not _retiring_pages.is_empty():
		return _transition_rejection(
			"GDGS_TRANSITION_RETIREMENT_PENDING",
			{"retiring_page_count": _retiring_pages.size()}
		)
	var candidate_workspace := _compute_view_workspace_accounting(
		int(active_list.get("logical_splat_count", 0)),
		int(active_list.get("active_reference_count", 0)),
		texture_size
	)
	if not bool(candidate_workspace.get("valid", false)):
		return _transition_rejection(
			String(
				candidate_workspace.get(
					"error_id",
					"GDGS_PAGED_WORKSPACE_EXHAUSTED"
				)
			),
			candidate_workspace
		)

	var next_page_ids := _page_ids_from_references(
		active_list.get("active_references", [])
	)
	var old_page_ids := _page_ids_from_references(
		committed.active_references
	)
	var outgoing_page_ids: Dictionary = {}
	var retained_bytes := 0
	var retained_members: Array[Dictionary] = []
	for page_id_value: Variant in old_page_ids.keys():
		var page_id := int(page_id_value)
		if (
			next_page_ids.has(page_id)
			or _page_used_by_other_committed_view(
				page_id,
				committed.view_identity
			)
		):
			continue
		var outgoing_page: PageState = _pages.get(page_id, null)
		if outgoing_page == null or outgoing_page.class_bytes <= 0:
			return _transition_rejection(
				"GDGS_TRANSITION_RETAINED_PAGE_MISSING",
				{"page_id": page_id}
			)
		outgoing_page_ids[page_id] = true
		retained_bytes += outgoing_page.class_bytes
		retained_members.push_back({
			"identity": outgoing_page.content_identity,
			"page_id": page_id,
			"bytes": outgoing_page.class_bytes
		})

	var other_resident: Array[Dictionary] = []
	for page_id_value: Variant in _pages.keys():
		var page_id := int(page_id_value)
		if outgoing_page_ids.has(page_id):
			continue
		var resident_page: PageState = _pages[page_id]
		other_resident.push_back({
			"identity": "resident-page-%d-g%d" % [
				page_id,
				resident_page.generation
			],
			"bytes": resident_page.class_bytes
		})

	var stable_view_workspaces: Array[Dictionary] = []
	for state_value: Variant in _views.values():
		var existing_view: ViewState = state_value
		if existing_view.view_identity == committed.view_identity:
			continue
		if existing_view.accounted_workspace_bytes <= 0:
			return _transition_rejection(
				"GDGS_TRANSITION_VIEW_ACCOUNTING_MISSING",
				{"view_identity": existing_view.view_identity}
			)
		stable_view_workspaces.push_back({
			"identity": "steady-view-%s-g%d" % [
				existing_view.view_identity.sha256_text(),
				existing_view.view_generation
			],
			"bytes": existing_view.accounted_workspace_bytes
		})

	var incoming_definitions: Array[Dictionary] = []
	var newly_admitted_page_ids: Dictionary = {}
	var incoming_payload_bytes := 0
	for candidate_value: Variant in selected_candidates:
		var candidate: Dictionary = candidate_value
		var page_id := int(candidate["page_id"])
		if _pages.has(page_id):
			continue
		newly_admitted_page_ids[page_id] = true
		incoming_payload_bytes += int(candidate["unaligned_bytes"])
		incoming_definitions.push_back({
			"content_identity": candidate["content_identity"],
			"content_hash": candidate["content_hash"],
			"layout_version": candidate["layout_version"],
			"shader_version": candidate["shader_version"],
			"unaligned_bytes": candidate["unaligned_bytes"]
		})

	var native_before: Dictionary = _native_runtime.call(&"snapshot")
	var alignment_bytes := int(
		native_before.get("allocation_alignment_bytes", 0)
	)
	if alignment_bytes <= 0:
		return _transition_rejection(
			"GDGS_TRANSITION_ALIGNMENT_UNAVAILABLE",
			native_before
		)
	var incoming_aligned_bytes := 0
	var staging_bytes := 0
	if not incoming_definitions.is_empty():
		var preflight: Dictionary = _native_runtime.call(
			&"preflight_page_group",
			incoming_definitions
		)
		if not bool(preflight.get("accepted", false)):
			return _transition_rejection(
				String(
					preflight.get(
						"status",
						"GDGS_PAGE_GROUP_PREFLIGHT_FAILED"
					)
				),
				preflight
			)
		incoming_aligned_bytes = int(
			preflight.get("incoming_class_bytes", 0)
		)
		for definition: Dictionary in incoming_definitions:
			staging_bytes = maxi(
				staging_bytes,
				_align_up(
					int(definition["unaligned_bytes"]),
					alignment_bytes
				)
			)

	var transition_identity := "gdgs-transition-%s-g%d-r%d" % [
		committed.view_identity.sha256_text(),
		selection_generation,
		int(active_list.get("registry_revision", 0))
	]
	var measurement := {
		"retained_active_page": {
			"identity": "%s.outgoing-pages" % transition_identity,
			"bytes": retained_bytes
		},
		"other_non_transition_resident_pages": other_resident,
		"outgoing_per_view_workspace": {
			"identity": "%s.outgoing-view" % transition_identity,
			"bytes": committed.accounted_workspace_bytes
		},
		"existing_per_view_workspaces": stable_view_workspaces,
		"replacement_per_view_workspaces": [{
			"identity": "%s.replacement-view" % transition_identity,
			"bytes": int(
				candidate_workspace["accounted_workspace_bytes"]
			)
		}],
		"incoming_replacement_page": {
			"identity": "%s.incoming-pages" % transition_identity,
			"bytes": incoming_payload_bytes
		},
		"incoming_replacement_aligned_bytes":
			incoming_aligned_bytes,
		"upload_staging": {
			"identity": "%s.upload-staging" % transition_identity,
			"bytes": staging_bytes
		},
		"incremental_per_view_transition_workspaces": [],
		"transition_metadata": {
			"identity": "%s.metadata" % transition_identity,
			"bytes": TRANSITION_METADATA_BYTES
		},
		"category_membership": {
			"retained_active_pages": retained_members,
			"other_non_transition_resident_pages":
				other_resident.duplicate(true),
			"existing_per_view_workspace":
				stable_view_workspaces.duplicate(true),
			"incoming_replacement_pages":
				incoming_definitions.duplicate(true),
			"replacement_per_view_workspace":
				candidate_workspace.duplicate(true)
		}
	}
	var reservation: Dictionary = _native_runtime.call(
		&"reserve_transition_budget",
		transition_identity,
		measurement
	)
	var native_after: Dictionary = _native_runtime.call(&"snapshot")
	if (
		int(native_before.get("page_count", -1))
			!= int(native_after.get("page_count", -2))
		or int(native_before.get("allocation_count", -1))
			!= int(native_after.get("allocation_count", -2))
	):
		if bool(reservation.get("accepted", false)):
			_native_runtime.call(
				&"cancel_transition_budget",
				transition_identity
			)
		return _transition_rejection(
			"GDGS_TRANSITION_RESERVED_AFTER_ALLOCATION",
			{
				"before": native_before,
				"after": native_after,
				"reservation": reservation
			}
		)
	if not bool(reservation.get("accepted", false)):
		return _transition_rejection(
			String(
				reservation.get(
					"status",
					"GDGS_TRANSITION_BUDGET_REJECTED"
				)
			),
			{
				"measurement": measurement,
				"reservation": reservation,
				"native_before": native_before,
				"native_after": native_after
			}
		)

	var transition := TransitionState.new()
	transition.identity = transition_identity
	transition.view_identity = committed.view_identity
	transition.registry_revision = int(
		active_list.get("registry_revision", 0)
	)
	transition.view_generation = int(
		active_list.get("view_generation", 0)
	)
	transition.texture_size = texture_size
	transition.selection_generation = selection_generation
	transition.selection_signature = selection_signature
	transition.stage = "reserved"
	transition.outgoing_page_ids = outgoing_page_ids.duplicate()
	transition.incoming_page_ids = (
		next_page_ids.duplicate()
	)
	transition.newly_admitted_page_ids = (
		newly_admitted_page_ids.duplicate()
	)
	transition.measurement = measurement.duplicate(true)
	transition.reservation = reservation.duplicate(true)
	transition.reservation_native_before = native_before.duplicate(true)
	transition.reservation_native_after = native_after.duplicate(true)
	_transition = transition
	_transition_reservation_count += 1
	return {
		"accepted": true,
		"transition_identity": transition_identity,
		"reservation": reservation
	}

func _try_finish_transition_retirement() -> void:
	if (
		_transition == null
		or _transition.stage != "post_switch"
		or not _transition.retirement_keys.is_empty()
	):
		return
	for page_id_value: Variant in _transition.outgoing_page_ids.keys():
		if _pages.has(int(page_id_value)):
			return
	var finished: Dictionary = _native_runtime.call(
		&"finish_transition_retirement",
		_transition.identity
	)
	if (
		not bool(finished.get("accepted", false))
		or String(finished.get("status", "")) != "RELEASED"
	):
		_record_error(
			String(
				finished.get(
					"status",
					"GDGS_TRANSITION_RETIREMENT_FINISH_FAILED"
				)
			),
			"finish_transition_retirement",
			finished
		)
		return
	_transition.retirement = finished.duplicate(true)
	_transition.stage = "settled"
	_last_transition_snapshot = _transition_snapshot(_transition)
	_transition = null
	_transition_completion_count += 1

func _cancel_active_transition(reason: String) -> Error:
	if _transition == null:
		return OK
	if _transition.stage == "post_switch":
		return ERR_BUSY
	var cancelled: Dictionary = _native_runtime.call(
		&"cancel_transition_budget",
		_transition.identity
	)
	if (
		not bool(cancelled.get("accepted", false))
		or String(cancelled.get("status", "")) != "RELEASED"
	):
		return _record_error(
			String(
				cancelled.get(
					"status",
					"GDGS_TRANSITION_CANCEL_FAILED"
				)
			),
			"cancel_transition_budget",
			cancelled
		)
	_transition.cancellation = cancelled.duplicate(true)
	_transition.cancellation["reason"] = reason
	_transition.stage = "cancelled"
	_last_transition_snapshot = _transition_snapshot(_transition)
	_transition = null
	_transition_cancellation_count += 1
	return OK

func _transition_snapshot(transition: TransitionState) -> Dictionary:
	if transition == null:
		return {}
	return {
		"identity": transition.identity,
		"view_identity": transition.view_identity,
		"registry_revision": transition.registry_revision,
		"view_generation": transition.view_generation,
		"texture_size": transition.texture_size,
		"selection_generation": transition.selection_generation,
		"selection_signature": transition.selection_signature,
		"stage": transition.stage,
		"outgoing_page_ids":
			transition.outgoing_page_ids.duplicate(true),
		"incoming_page_ids":
			transition.incoming_page_ids.duplicate(true),
		"newly_admitted_page_ids":
			transition.newly_admitted_page_ids.duplicate(true),
		"retirement_keys":
			transition.retirement_keys.duplicate(true),
		"measurement": transition.measurement.duplicate(true),
		"reservation": transition.reservation.duplicate(true),
		"reservation_native_before":
			transition.reservation_native_before.duplicate(true),
		"reservation_native_after":
			transition.reservation_native_after.duplicate(true),
		"pre_switch": transition.pre_switch.duplicate(true),
		"frame_boundary": transition.frame_boundary.duplicate(true),
		"retirement": transition.retirement.duplicate(true),
		"cancellation": transition.cancellation.duplicate(true)
	}

func _transition_rejection(
	error_id: String,
	detail: Dictionary
) -> Dictionary:
	_record_error(error_id, "selected_set_transition", detail)
	return {
		"accepted": false,
		"error_id": error_id,
		"detail": detail.duplicate(true)
	}

func _align_up(value: int, alignment: int) -> int:
	if value <= 0 or alignment <= 0:
		return 0
	return int((value + alignment - 1) / alignment) * alignment

func _validate_candidates(candidates: Array) -> Dictionary:
	var candidate_by_id: Dictionary = {}
	for candidate_value: Variant in candidates:
		if not candidate_value is Dictionary:
			return _invalid("GDGS_PAGED_PAGE_INVALID")
		var candidate: Dictionary = candidate_value
		var page_id := int(candidate.get("page_id", 0))
		var point_count := int(candidate.get("point_count", 0))
		var payload_value: Variant = candidate.get(
			"point_data_byte",
			null
		)
		var expected_bytes := int(
			candidate.get("unaligned_bytes", 0)
		)
		if (
			page_id <= 0
			or page_id > Capacity.UINT32_MAX
			or candidate_by_id.has(page_id)
			or String(candidate.get("content_identity", "")).is_empty()
			or String(candidate.get("content_hash", "")).is_empty()
			or point_count <= 0
			or typeof(payload_value) != TYPE_PACKED_BYTE_ARRAY
			or expected_bytes <= 0
			or expected_bytes != payload_value.size()
			or expected_bytes
				!= point_count * FLOATS_PER_SPLAT * BYTES_PER_FLOAT
			or int(candidate.get("schema_version", 0)) != 1
			or int(candidate.get("layout_version", 0)) != 1
			or int(candidate.get("shader_version", 0)) != 1
			or typeof(candidate.get("aabb_min", null))
				!= TYPE_VECTOR3
			or typeof(candidate.get("aabb_max", null))
				!= TYPE_VECTOR3
			or String(
				candidate.get("coordinate_space", "")
			).is_empty()
		):
			return _invalid("GDGS_PAGED_PAGE_INVALID")
		candidate_by_id[page_id] = candidate
	return {
		"valid": true,
		"candidate_by_id": candidate_by_id
	}

func _ensure_native_runtime() -> Error:
	if _native_runtime == null or not is_instance_valid(_native_runtime):
		_native_runtime = null
		if Engine.has_singleton(NATIVE_RUNTIME_SINGLETON):
			_native_runtime = Engine.get_singleton(
				NATIVE_RUNTIME_SINGLETON
			)
	if _native_runtime == null:
		return _record_error(
			"GDGS_NATIVE_RUNTIME_REQUIRED",
			"resolve_native_runtime",
			{}
		)
	if _native_configured:
		return OK
	var configured: Dictionary = _native_runtime.call(
		&"configure_reference_high",
		NATIVE_DEVICE_IDENTITY
	)
	if not bool(configured.get("accepted", false)):
		return _record_error(
			String(configured.get("status", "CONFIGURE_FAILED")),
			"configure_reference_high",
			configured
		)
	# `_native_configured` is set only after every step below succeeds.
	# Setting it earlier would let a later failure leave the cache
	# half-initialised: the next call would short-circuit to OK with a null
	# page-descriptor context and crash on first use.
	# `configure_reference_high` is idempotent for the same device identity,
	# so retrying costs nothing.
	var limits_error := _derive_configured_limits()
	if limits_error != OK:
		return limits_error
	if _page_descriptor_context == null:
		_page_descriptor_context = RenderingDeviceContext.create(
			RenderingServer.get_rendering_device()
		)
	if _page_descriptor_context == null:
		return _record_error(
			"GDGS_PAGE_DESCRIPTOR_CONTEXT_UNAVAILABLE",
			"ensure_native_runtime",
			{}
		)
	_native_configured = true
	return OK

# The approved budget is the single authority for the per-view ceilings. They
# are read once, right after `configure_reference_high` succeeds, and the cache
# refuses to admit views at all if the runtime does not publish them.
func _derive_configured_limits() -> Error:
	var snapshot: Dictionary = _native_runtime.call(&"snapshot")
	var maximum_active_views := int(
		snapshot.get("configured_maximum_active_views", 0)
	)
	var sort_workspace_bytes := int(
		snapshot.get("configured_sort_workspace_bytes_per_view", 0)
	)
	var overlap_pairs := int(
		snapshot.get("configured_overlap_pairs_per_view", 0)
	)
	if (
		maximum_active_views <= 0
		or sort_workspace_bytes <= 0
		or overlap_pairs <= 0
	):
		return _record_error(
			"GDGS_CONFIGURED_VIEW_LIMITS_UNAVAILABLE",
			"derive_configured_limits",
			{
				"configured_maximum_active_views":
					maximum_active_views,
				"configured_sort_workspace_bytes_per_view":
					sort_workspace_bytes,
				"configured_overlap_pairs_per_view": overlap_pairs
			}
		)
	_configured_maximum_active_views = maximum_active_views
	_configured_sort_workspace_bytes_per_view = sort_workspace_bytes
	_configured_overlap_pairs_per_view = overlap_pairs
	# The configured budget is only a ceiling for the capacity search, not an
	# allocation, so it is deliberately NOT compared against the approved
	# per-view limit here. What the contract bounds is the workspace a view
	# actually accounts for, which is enforced in
	# `_compute_view_workspace_accounting`.
	return OK

func get_configured_view_limits() -> Dictionary:
	return {
		"maximum_active_views": _configured_maximum_active_views,
		"sort_workspace_bytes_per_view":
			_configured_sort_workspace_bytes_per_view,
		"overlap_pairs_per_view": _configured_overlap_pairs_per_view,
		"derived": (
			_configured_maximum_active_views > 0
			and _configured_sort_workspace_bytes_per_view > 0
			and _configured_overlap_pairs_per_view > 0
		)
	}

func _admit_page(candidate: Dictionary) -> Error:
	var page_id := int(candidate["page_id"])
	var identity := String(candidate["content_identity"])
	var payload: PackedByteArray = candidate["point_data_byte"]
	var admitted: Dictionary = _native_runtime.call(
		&"admit_page",
		identity,
		String(candidate["content_hash"]),
		int(candidate["schema_version"]),
		int(candidate["layout_version"]),
		int(candidate["shader_version"]),
		int(candidate["point_count"]),
		candidate["aabb_min"],
		candidate["aabb_max"],
		String(candidate["coordinate_space"]),
		payload
	)
	if not bool(admitted.get("accepted", false)):
		return _record_error(
			String(admitted.get("status", "ADMIT_FAILED")),
			"admit_page",
			admitted
		)
	var generation := int(admitted.get("generation", 0))
	var class_bytes := int(admitted.get("class_bytes", 0))
	var buffer_rid: RID = admitted.get("buffer_rid", RID())
	if (
		generation <= 0
		or class_bytes < payload.size()
		or not buffer_rid.is_valid()
		or int(admitted.get("buffer_offset_bytes", -1)) != 0
		or int(admitted.get("physical_bytes", 0)) != payload.size()
	):
		if generation > 0:
			_native_runtime.call(
				&"abandon_unsubmitted_page",
				identity,
				generation
			)
		return _record_error(
			"GDGS_NATIVE_PAGE_ALLOCATION_INVALID",
			"admit_page",
			admitted
		)
	var page := PageState.new()
	page.page_id = page_id
	page.content_identity = identity
	page.content_hash = String(candidate["content_hash"])
	page.point_count = int(candidate["point_count"])
	page.unaligned_bytes = payload.size()
	page.class_bytes = class_bytes
	page.payload = payload
	page.generation = generation
	page.state = PAGE_UPLOADING
	page.descriptor = (
		_page_descriptor_context.wrap_borrowed_storage_buffer(buffer_rid)
	)
	page.upload_id = "gdgs-paged-%d-%d" % [
		page_id,
		generation
	]
	var enqueued: Dictionary = _native_runtime.call(
		&"enqueue_upload",
		page.upload_id,
		page.content_identity,
		page.generation,
		page.payload.size()
	)
	if not bool(enqueued.get("accepted", false)):
		_native_runtime.call(
			&"abandon_unsubmitted_page",
			page.content_identity,
			page.generation
		)
		return _record_error(
			String(enqueued.get("status", "ENQUEUE_FAILED")),
			"enqueue_upload",
			enqueued
		)
	_pages[page_id] = page
	return OK

func _pump_uploads() -> Error:
	var needs_upload := false
	for page_value: Variant in _pages.values():
		var page: PageState = page_value
		if (
			page.state == PAGE_UPLOADING
			and page.final_submission_id == 0
		):
			needs_upload = true
			break
	if not needs_upload:
		return OK
	var physical_frame := int(Engine.get_frames_drawn())
	if physical_frame == _native_last_upload_frame:
		return ERR_BUSY
	_native_last_upload_frame = physical_frame
	var frame: Dictionary = _native_runtime.call(
		&"begin_upload_frame"
	)
	if not bool(frame.get("accepted", false)):
		return _record_error(
			String(frame.get("status", "UPLOAD_FRAME_FAILED")),
			"begin_upload_frame",
			frame
		)
	var submission_id := int(frame.get("submission_id", 0))
	for slice_value: Variant in frame.get("slices", []):
		var slice: Dictionary = slice_value
		var upload_id := String(slice.get("upload_id", ""))
		var page: PageState = _find_page_by_upload_id(upload_id)
		if page == null:
			return _record_error(
				"GDGS_UNKNOWN_UPLOAD_SLICE",
				"begin_upload_frame",
				slice
			)
		var source_offset := int(
			slice.get("source_offset_bytes", -1)
		)
		var slice_bytes := int(slice.get("slice_bytes", 0))
		if (
			submission_id <= 0
			or source_offset < 0
			or slice_bytes <= 0
			or source_offset != page.uploaded_bytes
			or source_offset + slice_bytes > page.payload.size()
		):
			return _record_error(
				"GDGS_UPLOAD_SLICE_RANGE_INVALID",
				"begin_upload_frame",
				slice
			)
		var data: PackedByteArray = page.payload.slice(
			source_offset,
			source_offset + slice_bytes
		)
		var written: Dictionary = _native_runtime.call(
			&"write_upload_slice",
			upload_id,
			submission_id,
			source_offset,
			data
		)
		if not bool(written.get("accepted", false)):
			return _record_error(
				String(written.get("status", "UPLOAD_WRITE_FAILED")),
				"write_upload_slice",
				written
			)
		page.uploaded_bytes += slice_bytes
		if bool(slice.get("final_slice", false)):
			if page.uploaded_bytes != page.payload.size():
				return _record_error(
					"GDGS_FINAL_UPLOAD_SIZE_MISMATCH",
					"write_upload_slice",
					slice
				)
			page.final_submission_id = submission_id
			var readiness: Dictionary = _native_runtime.call(
				&"record_readiness",
				page.upload_id,
				page.generation,
				1,
				submission_id
			)
			if not bool(readiness.get("accepted", false)):
				return _record_error(
					String(
						readiness.get(
							"status",
							"READINESS_FAILED"
						)
					),
					"record_readiness",
					readiness
				)
			page.readiness_recorded = true
			var proof: Dictionary = _native_runtime.call(
				&"submit_completion_proof",
				page.content_identity,
				page.generation,
				submission_id,
				0,
				mini(4, page.payload.size())
			)
			if not bool(proof.get("accepted", false)):
				return _record_error(
					String(proof.get("status", "PROOF_FAILED")),
					"submit_completion_proof",
					proof
				)
			page.proof_scheduled = true
	return ERR_BUSY

func _poll_native_runtime() -> void:
	if _native_runtime == null or not is_instance_valid(_native_runtime):
		return
	for publication_value: Variant in _native_runtime.call(
		&"poll_publications"
	):
		var publication: Dictionary = publication_value
		var page: PageState = _find_page_by_identity(
			String(publication.get("content_identity", ""))
		)
		if (
			page != null
			and page.generation
				== int(publication.get("owner_generation", 0))
			and page.final_submission_id
				== int(publication.get("submission_id", 0))
		):
			page.state = PAGE_READY
			# PackedByteArray is copy-on-write, so upload did not duplicate the
			# backing allocation. Release even that shared CPU reference once
			# the matching generation is ready; world/resource ownership stays
			# authoritative and no renderer-side decoded cache remains.
			page.payload = PackedByteArray()
	for retirement_value: Variant in _native_runtime.call(
		&"poll_retirements"
	):
		var retirement: Dictionary = retirement_value
		var retirement_key := "%s#%d" % [
			String(retirement.get("content_identity", "")),
			int(retirement.get("generation", 0))
		]
		_retiring_pages.erase(retirement_key)
		if (
			_transition != null
			and _transition.retirement_keys.has(retirement_key)
		):
			_transition.retirement_keys.erase(retirement_key)
	_try_finish_transition_retirement()

func _retire_page(
	page: PageState,
	track_transition: bool = false
) -> Error:
	if page == null or not _pages.has(page.page_id):
		return OK
	var retired: Dictionary = _native_runtime.call(
		&"request_page_retirement",
		page.content_identity,
		page.generation,
		0,
		mini(4, page.unaligned_bytes)
	)
	if not bool(retired.get("accepted", false)):
		return _record_error(
			String(retired.get("status", "RETIREMENT_FAILED")),
			"request_page_retirement",
			retired
		)
	var retirement_key := "%s#%d" % [
		page.content_identity,
		page.generation
	]
	_retiring_pages[retirement_key] = {
		"submission_id": int(retired.get("submission_id", 0)),
		"class_bytes": page.class_bytes,
		"content_identity": page.content_identity,
		"generation": page.generation
	}
	if track_transition and _transition != null:
		_transition.retirement_keys[retirement_key] = true
	_pages.erase(page.page_id)
	return OK

func _rebuild_view_state(state: ViewState) -> Error:
	var accounting := _compute_view_workspace_accounting(
		state.logical_point_count,
		state.active_references.size(),
		state.texture_size
	)
	var layout: Dictionary = accounting.get("layout", {})
	if not bool(accounting.get("valid", false)):
		return _fail_view(
			state,
			String(
				accounting.get(
					"error_id",
					"GDGS_PAGED_WORKSPACE_EXHAUSTED"
				)
			),
			accounting
		)
	state.accounted_workspace_bytes = int(
		accounting["accounted_workspace_bytes"]
	)
	state.workspace_accounting = accounting.duplicate(true)
	if (
		not bool(layout.get("valid", false))
		or int(layout.get("pair_capacity", 0)) <= 0
	):
		return _fail_view(
			state,
			String(
				layout.get(
					"error_id",
					"GDGS_PAGED_WORKSPACE_EXHAUSTED"
				)
			),
			layout
		)
	state.workspace_layout = layout
	state.context = RenderingDeviceContext.create(
		RenderingServer.get_rendering_device()
	)
	var shader_paths := {
		"projection": SHADER_PROJECTION,
		"prefix_blocks": SHADER_PREFIX_BLOCKS,
		"prefix_block_sums": SHADER_PREFIX_BLOCK_SUMS,
		"admission": SHADER_ADMISSION,
		"emit": SHADER_EMIT,
		"radix_upsweep": SHADER_RADIX_UPSWEEP,
		"radix_spine": SHADER_RADIX_SPINE,
		"radix_downsweep": SHADER_RADIX_DOWNSWEEP,
		"boundaries": SHADER_BOUNDARIES,
		"render": SHADER_RENDER
	}
	for shader_name: String in shader_paths:
		var shader: RID = state.context.load_shader(
			shader_paths[shader_name]
		)
		if not shader.is_valid():
			return _fail_view(
				state,
				"GDGS_PAGED_SHADER_CREATE_FAILED",
				{"shader": shader_paths[shader_name]}
			)
		state.shaders[shader_name] = shader

	var pair_capacity := int(layout["pair_capacity"])
	var allocations: Dictionary = layout["allocations"]
	var block_dims := PackedInt32Array()
	block_dims.resize(6)
	block_dims.fill(1)
	block_dims[0] = int(layout["partition_count"])
	block_dims[3] = ceili(pair_capacity / 256.0)

	state.descriptors["culled_splats"] = (
		state.context.create_empty_storage_buffer(
			state.logical_point_count
				* FLOATS_PER_CULLED_SPLAT
				* BYTES_PER_FLOAT
		)
	)
	state.descriptors["projection_ranges"] = (
		state.context.create_empty_storage_buffer(
			int(allocations["projection_ranges"])
		)
	)
	state.descriptors["prefix_block_sums"] = (
		state.context.create_empty_storage_buffer(
			int(allocations["prefix_block_sums"])
		)
	)
	state.descriptors["telemetry"] = (
		state.context.create_empty_storage_buffer(
			Capacity.TELEMETRY_BYTES
		)
	)
	state.descriptors["grid_dimensions"] = (
		state.context.create_storage_buffer(
			6 * 4,
			block_dims.to_byte_array(),
			RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT
		)
	)
	state.descriptors["histogram"] = (
		state.context.create_empty_storage_buffer(
			int(allocations["histogram"])
		)
	)
	state.descriptors["sort_keys"] = (
		state.context.create_empty_storage_buffer(
			int(allocations["key_records"])
		)
	)
	state.descriptors["sort_values"] = (
		state.context.create_empty_storage_buffer(
			int(allocations["values"])
		)
	)
	var transform_bytes := _build_transform_bytes(
		state.active_references
	)
	state.descriptors["instance_transforms"] = (
		state.context.create_storage_buffer(
			transform_bytes.size(),
			transform_bytes
		)
	)
	state.descriptors["uniforms"] = (
		state.context.create_uniform_buffer(
			PROJECTION_UNIFORM_BYTES
		)
	)
	state.descriptors["prefix_constants"] = (
		state.context.create_uniform_buffer(
			PREFIX_CONSTANTS_BYTES
		)
	)
	state.descriptors["tile_bounds"] = (
		state.context.create_empty_storage_buffer(
			int(allocations["tile_bounds"])
		)
	)
	state.descriptors["tile_splat_pos"] = (
		state.context.create_empty_storage_buffer(4 * 4)
	)
	state.descriptors["render_texture"] = state.context.create_texture(
		state.texture_size,
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	)
	state.descriptors["depth_texture"] = state.context.create_texture(
		state.texture_size,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT
	)
	for descriptor_name: String in state.descriptors:
		var descriptor = state.descriptors[descriptor_name]
		if descriptor == null or not descriptor.rid.is_valid():
			return _fail_view(
				state,
				"GDGS_PAGED_GPU_ALLOCATION_FAILED",
				{"descriptor": descriptor_name}
			)

	var page_ids: Dictionary = {}
	for reference: Dictionary in state.active_references:
		page_ids[int(reference["page_id"])] = true
	for page_id: Variant in page_ids:
		var page: PageState = _pages.get(page_id, null)
		if (
			page == null
			or page.state != PAGE_READY
			or page.descriptor == null
			or not page.descriptor.rid.is_valid()
		):
			return _fail_view(
				state,
				"GDGS_PAGED_RESIDENT_PAGE_MISSING",
				{"page_id": page_id}
			)
		var borrowed = state.context.wrap_borrowed_storage_buffer(
			page.descriptor.rid
		)
		state.projection_sets[page_id] = (
			state.context.create_descriptor_set([
				borrowed,
				state.descriptors["culled_splats"],
				state.descriptors["projection_ranges"],
				state.descriptors["instance_transforms"],
				state.descriptors["uniforms"]
			], state.shaders["projection"], 0)
		)

	var prefix_blocks_set: RID = state.context.create_descriptor_set([
		state.descriptors["projection_ranges"],
		state.descriptors["prefix_block_sums"],
		state.descriptors["uniforms"]
	], state.shaders["prefix_blocks"], 0)
	var prefix_block_sums_set: RID = state.context.create_descriptor_set([
		state.descriptors["prefix_block_sums"],
		state.descriptors["telemetry"],
		state.descriptors["prefix_constants"]
	], state.shaders["prefix_block_sums"], 0)
	var admission_set: RID = state.context.create_descriptor_set([
		state.descriptors["projection_ranges"],
		state.descriptors["prefix_block_sums"],
		state.descriptors["telemetry"],
		state.descriptors["histogram"],
		state.descriptors["uniforms"]
	], state.shaders["admission"], 0)
	var emit_set: RID = state.context.create_descriptor_set([
		state.descriptors["projection_ranges"],
		state.descriptors["sort_keys"],
		state.descriptors["sort_values"],
		state.descriptors["telemetry"],
		state.descriptors["uniforms"]
	], state.shaders["emit"], 0)
	var radix_upsweep_set: RID = state.context.create_descriptor_set([
		state.descriptors["histogram"],
		state.descriptors["sort_keys"]
	], state.shaders["radix_upsweep"], 0)
	var radix_spine_set: RID = state.context.create_descriptor_set([
		state.descriptors["histogram"]
	], state.shaders["radix_spine"], 0)
	var radix_downsweep_set: RID = state.context.create_descriptor_set([
		state.descriptors["histogram"],
		state.descriptors["sort_keys"],
		state.descriptors["sort_values"]
	], state.shaders["radix_downsweep"], 0)
	var boundaries_set: RID = state.context.create_descriptor_set([
		state.descriptors["histogram"],
		state.descriptors["sort_keys"],
		state.descriptors["tile_bounds"]
	], state.shaders["boundaries"], 0)
	var render_set: RID = state.context.create_descriptor_set([
		state.descriptors["culled_splats"],
		state.descriptors["sort_values"],
		state.descriptors["tile_bounds"],
		state.descriptors["tile_splat_pos"],
		state.descriptors["render_texture"],
		state.descriptors["depth_texture"]
	], state.shaders["render"], 0)
	var uniform_sets := [
		prefix_blocks_set,
		prefix_block_sums_set,
		admission_set,
		emit_set,
		radix_upsweep_set,
		radix_spine_set,
		radix_downsweep_set,
		boundaries_set,
		render_set
	]
	for uniform_set: RID in uniform_sets:
		if not uniform_set.is_valid():
			return _fail_view(
				state,
				"GDGS_PAGED_DESCRIPTOR_SET_FAILED",
				{}
			)
	for page_set: RID in state.projection_sets.values():
		if not page_set.is_valid():
			return _fail_view(
				state,
				"GDGS_PAGED_PROJECTION_SET_FAILED",
				{}
			)

	for reference: Dictionary in state.active_references:
		var reference_projection_set: RID = (
			state.projection_sets[int(reference["page_id"])]
		)
		state.projection_pipelines.push_back(
			state.context.create_pipeline(
				[ceili(int(reference["point_count"]) / 256.0), 1, 1],
				[reference_projection_set],
				state.shaders["projection"]
			)
		)
	state.pipelines["prefix_blocks"] = state.context.create_pipeline(
		[int(layout["prefix_block_count"]), 1, 1],
		[prefix_blocks_set],
		state.shaders["prefix_blocks"]
	)
	state.pipelines["prefix_block_sums"] = (
		state.context.create_pipeline(
			[1, 1, 1],
			[prefix_block_sums_set],
			state.shaders["prefix_block_sums"]
		)
	)
	state.pipelines["admission"] = state.context.create_pipeline(
		[ceili(state.logical_point_count / 256.0), 1, 1],
		[admission_set],
		state.shaders["admission"]
	)
	state.pipelines["emit"] = state.context.create_pipeline(
		[ceili(state.logical_point_count / 256.0), 1, 1],
		[emit_set],
		state.shaders["emit"]
	)
	state.pipelines["radix_upsweep"] = state.context.create_pipeline(
		[],
		[radix_upsweep_set],
		state.shaders["radix_upsweep"]
	)
	state.pipelines["radix_spine"] = state.context.create_pipeline(
		[Capacity.RADIX, 1, 1],
		[radix_spine_set],
		state.shaders["radix_spine"]
	)
	state.pipelines["radix_downsweep"] = state.context.create_pipeline(
		[],
		[radix_downsweep_set],
		state.shaders["radix_downsweep"]
	)
	state.pipelines["boundaries"] = state.context.create_pipeline(
		[],
		[boundaries_set],
		state.shaders["boundaries"]
	)
	state.pipelines["render"] = state.context.create_pipeline(
		[state.tile_dims.x, state.tile_dims.y, 1],
		[render_set],
		state.shaders["render"]
	)
	return OK

func _compute_view_workspace_accounting(
	logical_point_count: int,
	reference_count: int,
	texture_size: Vector2i
) -> Dictionary:
	if (
		_configured_overlap_pairs_per_view <= 0
		or _configured_sort_workspace_bytes_per_view <= 0
	):
		return {
			"valid": false,
			"error_id": "GDGS_CONFIGURED_VIEW_LIMITS_UNAVAILABLE",
			"reason": "Approved per-view workspace limits are unknown"
		}
	var culled_splat_bytes := (
		logical_point_count * CULLED_SPLAT_BYTES
	)
	var instance_transform_bytes := (
		reference_count * INSTANCE_TRANSFORM_BYTES
	)
	for fixed_storage: Dictionary in [
		{
			"name": "culled_splats",
			"bytes": culled_splat_bytes
		},
		{
			"name": "instance_transforms",
			"bytes": instance_transform_bytes
		}
	]:
		if (
			int(fixed_storage["bytes"])
			> Capacity.PORTABLE_STORAGE_BUFFER_RANGE_BYTES
		):
			return {
				"valid": false,
				"error_id": "GDGS_STORAGE_BUFFER_RANGE_EXCEEDED",
				"reason": (
					"Fixed view storage buffer exceeds the portable "
					+ "Vulkan range"
				),
				"allocation": fixed_storage["name"],
				"allocation_bytes": fixed_storage["bytes"],
				"storage_buffer_range_bytes":
					Capacity.PORTABLE_STORAGE_BUFFER_RANGE_BYTES
			}
	var render_target_bytes := (
		int(texture_size.x)
		* int(texture_size.y)
		* RENDER_TARGET_BYTES_PER_PIXEL
	)
	var accounted_overhead_bytes := (
		culled_splat_bytes
		+ instance_transform_bytes
		+ PROJECTION_UNIFORM_BYTES
		+ PREFIX_CONSTANTS_BYTES
		+ TILE_SPLAT_POSITION_BYTES
		+ render_target_bytes
	)
	var available_layout_bytes := (
		_configured_sort_workspace_bytes_per_view
		- accounted_overhead_bytes
	)
	if available_layout_bytes <= 0:
		return {
			"valid": false,
			"error_id": "GDGS_VIEW_WORKSPACE_EXCEEDS_APPROVED_LIMIT",
			"reason": (
				"Fixed per-view workspace exceeds the approved ceiling"
			),
			"accounted_workspace_overhead_bytes":
				accounted_overhead_bytes,
			"available_layout_bytes": available_layout_bytes,
			"approved_sort_workspace_bytes_per_view":
				_configured_sort_workspace_bytes_per_view
		}
	# `_workspace_budget_bytes` remains the caller's independent projection/
	# sort ceiling. The approved per-view ceiling is a second, stricter bound
	# over every view-owned allocation, including composite targets. Search
	# only the intersection; never allocate first and reject afterwards.
	var effective_layout_budget_bytes := mini(
		_workspace_budget_bytes,
		available_layout_bytes
	)
	var layout: Dictionary = Capacity.compute_workspace_layout(
		logical_point_count,
		texture_size,
		effective_layout_budget_bytes,
		_configured_overlap_pairs_per_view
	)
	if not bool(layout.get("valid", false)):
		var failed := layout.duplicate(true)
		failed["requested_layout_budget_bytes"] = (
			_workspace_budget_bytes
		)
		failed["effective_layout_budget_bytes"] = (
			effective_layout_budget_bytes
		)
		failed["accounted_workspace_overhead_bytes"] = (
			accounted_overhead_bytes
		)
		failed["available_layout_bytes"] = available_layout_bytes
		failed["approved_sort_workspace_bytes_per_view"] = (
			_configured_sort_workspace_bytes_per_view
		)
		return failed
	var layout_bytes := int(layout.get("total_bytes", 0))
	var accounted_bytes := layout_bytes + accounted_overhead_bytes
	# This is the quantity the frozen contract bounds: the workspace a single
	# view actually accounts for, not the ceiling handed to the capacity
	# search.
	if accounted_bytes > _configured_sort_workspace_bytes_per_view:
		return {
			"valid": false,
			"error_id": "GDGS_VIEW_WORKSPACE_EXCEEDS_APPROVED_LIMIT",
			"reason": "Per-view workspace exceeds the approved ceiling",
			"accounted_workspace_bytes": accounted_bytes,
			"approved_sort_workspace_bytes_per_view":
				_configured_sort_workspace_bytes_per_view
		}
	return {
		"valid": true,
		"schema": "gdgs-view-workspace-accounting-v1",
		"layout": layout,
		"requested_layout_budget_bytes": _workspace_budget_bytes,
		"effective_layout_budget_bytes": effective_layout_budget_bytes,
		"available_layout_bytes": available_layout_bytes,
		"layout_bytes": layout_bytes,
		"culled_splat_bytes": culled_splat_bytes,
		"instance_transform_bytes": instance_transform_bytes,
		"projection_uniform_bytes": PROJECTION_UNIFORM_BYTES,
		"prefix_constants_bytes": PREFIX_CONSTANTS_BYTES,
		"tile_splat_position_bytes": TILE_SPLAT_POSITION_BYTES,
		"render_target_bytes": render_target_bytes,
		"render_target_format": "rgba16f+r32f",
		"storage_buffer_range_bytes":
			Capacity.PORTABLE_STORAGE_BUFFER_RANGE_BYTES,
		"accounted_workspace_overhead_bytes":
			accounted_overhead_bytes,
		"accounted_workspace_bytes": accounted_bytes
	}

func _build_transform_bytes(
	references: Array[Dictionary]
) -> PackedByteArray:
	var transforms := PackedFloat32Array()
	for reference: Dictionary in references:
		var transform: Transform3D = reference.get(
			"model_transform",
			Transform3D.IDENTITY
		)
		transforms.append_array(PackedFloat32Array([
			transform.basis.x[0],
			transform.basis.x[1],
			transform.basis.x[2],
			1.0,
			transform.basis.y[0],
			transform.basis.y[1],
			transform.basis.y[2],
			0.0,
			transform.basis.z[0],
			transform.basis.z[1],
			transform.basis.z[2],
			0.0,
			transform.origin.x,
			transform.origin.y,
			transform.origin.z,
			1.0
		]))
	return transforms.to_byte_array()

func _find_page_by_upload_id(upload_id: String):
	for page_value: Variant in _pages.values():
		var page: PageState = page_value
		if page.upload_id == upload_id:
			return page
	return null

func _find_page_by_identity(identity: String):
	for page_value: Variant in _pages.values():
		var page: PageState = page_value
		if page.content_identity == identity:
			return page
	return null

func _rollback_unsubmitted_pages(
	pages: Array[PageState]
) -> void:
	for index in range(pages.size() - 1, -1, -1):
		var page: PageState = pages[index]
		if page == null or not _pages.has(page.page_id):
			continue
		var abandoned: Dictionary = _native_runtime.call(
			&"abandon_unsubmitted_page",
			page.content_identity,
			page.generation
		)
		if bool(abandoned.get("accepted", false)):
			_pages.erase(page.page_id)
		else:
			_record_error(
				String(
					abandoned.get(
						"status",
						"GDGS_GROUP_ROLLBACK_FAILED"
					)
				),
				"abandon_unsubmitted_page",
				abandoned
			)

func _state_matches(
	state: ViewState,
	view_generation: int,
	selection_signature: String,
	texture_size: Vector2i,
	logical_point_count: int
) -> bool:
	return (
		state != null
		and state.context != null
		and state.view_generation == view_generation
		and state.selection_signature == selection_signature
		and state.texture_size == texture_size
		and state.logical_point_count == logical_point_count
	)

func _fail_view(
	state: ViewState,
	error_id: String,
	detail: Dictionary
) -> Error:
	state.last_error = {
		"schema": "gdgs-paged-view-error-v1",
		"error_id": error_id,
		"detail": detail.duplicate(true)
	}
	_last_error = state.last_error.duplicate(true)
	cleanup_view_state(state)
	return ERR_CANT_CREATE

func _record_error(
	error_id: String,
	operation: String,
	detail: Dictionary
) -> Error:
	_last_error = {
		"schema": "gdgs-paged-renderer-error-v1",
		"error_id": error_id,
		"operation": operation,
		"detail": detail.duplicate(true),
		"captured_usec": Time.get_ticks_usec()
	}
	return ERR_CANT_CREATE

func _invalid(error_id: String) -> Dictionary:
	return {
		"valid": false,
		"error_id": error_id
	}
