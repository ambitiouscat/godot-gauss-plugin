@tool
extends RefCounted
class_name GaussianGpuStateCache

const RenderingDeviceContext := preload("res://addons/gdgs/runtime/render/gaussian_rendering_device_context.gd")
const ProjectionCapacity := preload("res://addons/gdgs/runtime/render/gaussian_projection_capacity.gd")
const GpuTiming := preload("res://addons/gdgs/runtime/render/gaussian_gpu_timing.gd")

const TILE_SIZE := 16
const WORKGROUP_SIZE := 512
const RADIX := 256
const PARTITION_DIVISION := 8
const PARTITION_SIZE := PARTITION_DIVISION * WORKGROUP_SIZE
const MAX_RENDER_STATES := 4
const FLOATS_PER_SPLAT := 60
const FLOATS_PER_CULLED_SPLAT := 16
const BYTES_PER_FLOAT := 4
const PROJECTION_UNIFORM_BYTES := 40 * BYTES_PER_FLOAT
const PREFIX_CONSTANTS_BYTES := 8 * BYTES_PER_FLOAT
const NATIVE_RUNTIME_SINGLETON := &"GDSpatialGaussianRuntimeInternal"
const NATIVE_DEVICE_IDENTITY := "GodotRenderingServer.main"
const PAGE_STATE_EMPTY := "empty"
const PAGE_STATE_UPLOADING := "uploading"
const PAGE_STATE_READY := "ready"

const SHADER_PATH_PROJECTION := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_projection.glsl"
const SHADER_PATH_PREFIX_BLOCKS := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_prefix_blocks.glsl"
const SHADER_PATH_PREFIX_BLOCK_SUMS := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_prefix_block_sums.glsl"
const SHADER_PATH_ADMISSION := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_admission.glsl"
const SHADER_PATH_EMIT := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_emit.glsl"
const SHADER_PATH_RADIX_UPSWEEP := "res://addons/gdgs/runtime/render/shaders/compute/radix_sort_upsweep.glsl"
const SHADER_PATH_RADIX_SPINE := "res://addons/gdgs/runtime/render/shaders/compute/radix_sort_spine.glsl"
const SHADER_PATH_RADIX_DOWNSWEEP := "res://addons/gdgs/runtime/render/shaders/compute/radix_sort_downsweep.glsl"
const SHADER_PATH_BOUNDARIES := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_boundaries.glsl"
const SHADER_PATH_RENDER := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_render.glsl"

class RenderState:
	extends RefCounted

	var texture_size := Vector2i.ONE
	var tile_dims := Vector2i.ONE
	var camera_projection: Projection
	var camera_view: Projection
	var camera_matrices := PackedByteArray()
	var camera_world_position := Vector3.ZERO
	var depth_capture_alpha := 0.5
	var needs_gpu_rebuild := true
	var needs_splat_upload := false
	var needs_instance_upload := false
	var context: GdgsRenderingDeviceContext
	var shaders: Dictionary = {}
	var pipelines: Dictionary = {}
	var descriptors: Dictionary = {}
	var workspace_layout: Dictionary = {}
	var last_error: Dictionary = {}
	var generation := 0

var _render_states: Dictionary = {}
var _render_state_lru: Array = []
var _pending_gpu_cleanup := false
var _pending_resident_cleanup := false
var _resident_page_context: GdgsRenderingDeviceContext
var _resident_page_descriptor
var _resident_page_identity := ""
var _resident_page_hash := ""
var _resident_page_bytes := 0
var _resident_page_upload_total_count := 0
var _resident_page_state := PAGE_STATE_EMPTY
var _resident_page_generation := 0
var _resident_page_virtual_offset := 0
var _resident_page_buffer_offset := 0
var _resident_upload_id := ""
var _resident_uploaded_bytes := 0
var _resident_final_submission_id := 0
var _resident_readiness_recorded := false
var _resident_completion_proof_scheduled := false
var _native_runtime: Object
var _native_last_upload_frame := -1
var _native_last_error: Dictionary = {}
var _retiring_pages: Dictionary = {}
var _next_generation := 1
var _workspace_budget_bytes := ProjectionCapacity.DEFAULT_WORKSPACE_BUDGET_BYTES
var _telemetry_mutex := Mutex.new()
var _latest_telemetry: Dictionary = {}
var _last_overflow_warning_msec := -10_000
var _gpu_timing_mutex := Mutex.new()
var _next_gpu_timing_token := 1
var _gpu_timing_request: Dictionary = {}
var _pending_gpu_timing: Dictionary = {}
var _latest_gpu_timing: Dictionary = {}

func has_render_states() -> bool:
	return (
		not _render_states.is_empty()
		or _resident_page_context != null
		or not _retiring_pages.is_empty()
		or _native_runtime != null
	)

func request_cleanup(clear_resident_page: bool = true) -> void:
	_pending_gpu_cleanup = true
	_pending_resident_cleanup = _pending_resident_cleanup or clear_resident_page

func flush_pending_cleanup() -> void:
	_poll_native_runtime()
	if _pending_gpu_cleanup:
		cleanup_all(_pending_resident_cleanup)

func ensure_resident_page(page: Dictionary, point_data_byte: PackedByteArray) -> Error:
	var content_identity := String(page.get("content_identity", ""))
	var content_hash := String(page.get("content_hash", ""))
	var expected_bytes := int(page.get("unaligned_bytes", 0))
	var point_count := int(page.get("point_count", 0))
	var aabb_min: Variant = page.get("aabb_min", null)
	var aabb_max: Variant = page.get("aabb_max", null)
	if (
		content_identity.is_empty()
		or content_hash.is_empty()
		or expected_bytes <= 0
		or expected_bytes != point_data_byte.size()
		or point_count <= 0
		or point_count * FLOATS_PER_SPLAT * BYTES_PER_FLOAT != expected_bytes
		or typeof(aabb_min) != TYPE_VECTOR3
		or typeof(aabb_max) != TYPE_VECTOR3
		or int(page.get("schema_version", 0)) != 1
		or int(page.get("layout_version", 0)) != 1
		or int(page.get("shader_version", 0)) != 1
		or String(page.get("coordinate_space", "")).is_empty()
	):
		return ERR_INVALID_DATA
	_resolve_native_runtime()
	_poll_native_runtime()
	if (
		_resident_page_context != null
		and _resident_page_descriptor != null
		and _resident_page_descriptor.rid.is_valid()
		and _resident_page_identity == content_identity
		and _resident_page_hash == content_hash
		and _resident_page_bytes == expected_bytes
	):
		if _native_runtime == null or _resident_page_state == PAGE_STATE_READY:
			return OK
		if _resident_page_state == PAGE_STATE_UPLOADING:
			var pump_error := _pump_native_upload(point_data_byte)
			_poll_native_runtime()
			if pump_error != OK and pump_error != ERR_BUSY:
				return pump_error
			return OK if _resident_page_state == PAGE_STATE_READY else ERR_BUSY
		return ERR_BUSY

	# Descriptor sets in every render state reference the resident page RID,
	# so they must drain before that page is replaced. View/workspace rebuilds
	# do not destroy an unchanged resident page.
	if _resident_page_context != null:
		cleanup_all(false)
		var retirement_error := _begin_resident_page_retirement()
		if retirement_error != OK:
			return retirement_error
	_poll_native_runtime()
	if not _retiring_pages.is_empty():
		return ERR_BUSY

	return _begin_resident_page(page, point_data_byte)

func _begin_resident_page(page: Dictionary, point_data_byte: PackedByteArray) -> Error:
	var content_identity := String(page["content_identity"])
	var content_hash := String(page["content_hash"])
	var expected_bytes := int(page["unaligned_bytes"])
	var schema_version := int(page["schema_version"])
	var layout_version := int(page["layout_version"])
	var shader_version := int(page["shader_version"])
	var point_count := int(page["point_count"])
	var aabb_min: Vector3 = page["aabb_min"]
	var aabb_max: Vector3 = page["aabb_max"]
	var coordinate_space := String(page["coordinate_space"])
	var generation := 0
	var native_buffer_rid := RID()
	var virtual_offset := 0
	var buffer_offset := 0
	if _native_runtime != null:
		var configured: Dictionary = _native_runtime.call(
			&"configure_reference_high",
			NATIVE_DEVICE_IDENTITY
		)
		if not bool(configured.get("accepted", false)):
			return _record_native_error("configure_reference_high", configured)
		var admitted: Dictionary = _native_runtime.call(
			&"admit_page",
			content_identity,
			content_hash,
			schema_version,
			layout_version,
			shader_version,
			point_count,
			aabb_min,
			aabb_max,
			coordinate_space,
			point_data_byte
		)
		if not bool(admitted.get("accepted", false)):
			return _record_native_error("admit_page", admitted)
		generation = int(admitted.get("generation", 0))
		native_buffer_rid = admitted.get("buffer_rid", RID())
		virtual_offset = int(admitted.get("byte_offset", -1))
		buffer_offset = int(admitted.get("buffer_offset_bytes", -1))
		if (
			generation <= 0
			or not native_buffer_rid.is_valid()
			or virtual_offset < 0
			or buffer_offset != 0
			or int(admitted.get("physical_bytes", 0)) != expected_bytes
		):
			if generation > 0:
				_native_runtime.call(
					&"abandon_unsubmitted_page",
					content_identity,
					generation
				)
			return _record_native_error(
				"admit_page",
				{"status": "INVALID_NATIVE_PAGE_ALLOCATION"}
			)

	_resident_page_context = RenderingDeviceContext.create(
		RenderingServer.get_rendering_device()
	)
	_resident_page_descriptor = (
		_resident_page_context.create_storage_buffer(expected_bytes, point_data_byte)
		if _native_runtime == null
		else _resident_page_context.wrap_borrowed_storage_buffer(native_buffer_rid)
	)
	if (
		_resident_page_descriptor == null
		or not _resident_page_descriptor.rid.is_valid()
	):
		if _native_runtime != null and generation > 0:
			_native_runtime.call(
				&"abandon_unsubmitted_page",
				content_identity,
				generation
			)
		_cleanup_resident_page()
		return ERR_CANT_CREATE
	_resident_page_identity = content_identity
	_resident_page_hash = content_hash
	_resident_page_bytes = expected_bytes
	_resident_page_generation = generation
	_resident_page_virtual_offset = virtual_offset
	_resident_page_buffer_offset = buffer_offset
	_resident_uploaded_bytes = expected_bytes if _native_runtime == null else 0
	_resident_page_upload_total_count += 1
	_resident_page_state = (
		PAGE_STATE_READY
		if _native_runtime == null
		else PAGE_STATE_UPLOADING
	)
	if _native_runtime == null:
		return OK
	_resident_upload_id = "gdgs-upload:%s:%d" % [
		content_hash,
		generation
	]
	var enqueued: Dictionary = _native_runtime.call(
		&"enqueue_upload",
		_resident_upload_id,
		content_identity,
		generation,
		expected_bytes
	)
	if not bool(enqueued.get("accepted", false)):
		_native_runtime.call(
			&"abandon_unsubmitted_page",
			content_identity,
			generation
		)
		_cleanup_resident_page()
		return _record_native_error("enqueue_upload", enqueued)
	var pump_error := _pump_native_upload(point_data_byte)
	return ERR_BUSY if pump_error == OK else pump_error

func _pump_native_upload(point_data_byte: PackedByteArray) -> Error:
	if _native_runtime == null or _resident_page_state != PAGE_STATE_UPLOADING:
		return OK
	if _resident_final_submission_id > 0:
		return _schedule_native_completion_proof()
	var physical_frame := int(Engine.get_frames_drawn())
	if physical_frame == _native_last_upload_frame:
		return ERR_BUSY
	_native_last_upload_frame = physical_frame
	var frame: Dictionary = _native_runtime.call(&"begin_upload_frame")
	if not bool(frame.get("accepted", false)):
		return _record_native_error("begin_upload_frame", frame)
	var submission_id := int(frame.get("submission_id", 0))
	var slices: Array = frame.get("slices", [])
	if slices.is_empty():
		return ERR_BUSY
	for value in slices:
		var slice: Dictionary = value
		if String(slice.get("upload_id", "")) != _resident_upload_id:
			return _record_native_error(
				"begin_upload_frame",
				{"status": "UPLOAD_ID_MISMATCH"}
			)
		var source_offset := int(slice.get("source_offset_bytes", -1))
		var slice_bytes := int(slice.get("slice_bytes", 0))
		if (
			source_offset < 0
			or slice_bytes <= 0
			or source_offset != _resident_uploaded_bytes
			or source_offset + slice_bytes > point_data_byte.size()
		):
			return _record_native_error(
				"begin_upload_frame",
				{"status": "UPLOAD_SLICE_RANGE_INVALID"}
			)
		var data := point_data_byte.slice(
			source_offset,
			source_offset + slice_bytes
		)
		var upload_result: Dictionary = _native_runtime.call(
			&"write_upload_slice",
			_resident_upload_id,
			submission_id,
			source_offset,
			data
		)
		if not bool(upload_result.get("accepted", false)):
			return _record_native_error(
				"write_upload_slice",
				upload_result
			)
		_resident_uploaded_bytes += slice_bytes
		if bool(slice.get("final_slice", false)):
			if (
				submission_id <= 0
				or _resident_uploaded_bytes != _resident_page_bytes
			):
				return _record_native_error(
					"begin_upload_frame",
					{"status": "FINAL_UPLOAD_SIZE_MISMATCH"}
				)
			_resident_final_submission_id = submission_id
			var readiness: Dictionary = _native_runtime.call(
				&"record_readiness",
				_resident_upload_id,
				_resident_page_generation,
				1,
				submission_id
			)
			if not bool(readiness.get("accepted", false)):
				return _record_native_error("record_readiness", readiness)
			_resident_readiness_recorded = true
			return _schedule_native_completion_proof()
	return ERR_BUSY

func _schedule_native_completion_proof() -> Error:
	if _resident_completion_proof_scheduled:
		return ERR_BUSY
	if (
		_native_runtime == null
		or not _resident_readiness_recorded
		or _resident_final_submission_id <= 0
		or _resident_page_descriptor == null
	):
		return ERR_INVALID_DATA
	var proof: Dictionary = _native_runtime.call(
		&"submit_completion_proof",
		_resident_page_identity,
		_resident_page_generation,
		_resident_final_submission_id,
		0,
		mini(4, _resident_page_bytes)
	)
	if not bool(proof.get("accepted", false)):
		return _record_native_error("submit_completion_proof", proof)
	_resident_completion_proof_scheduled = true
	return ERR_BUSY

func _begin_resident_page_retirement() -> Error:
	if _resident_page_context == null:
		return OK
	if _native_runtime == null:
		_cleanup_resident_page()
		return OK
	if (
		_resident_page_descriptor == null
		or not _resident_page_descriptor.rid.is_valid()
		or _resident_page_generation <= 0
	):
		return ERR_INVALID_DATA
	var retired: Dictionary = _native_runtime.call(
		&"request_page_retirement",
		_resident_page_identity,
		_resident_page_generation,
		0,
		mini(4, _resident_page_bytes)
	)
	if not bool(retired.get("accepted", false)):
		return _record_native_error("request_page_retirement", retired)
	var retirement_key := "%s#%d" % [
		_resident_page_identity,
		_resident_page_generation
	]
	# The native device arena owned the RID from admission. The script context
	# only borrowed it for descriptor-set construction, so it can be released
	# immediately while native retirement quarantine keeps the buffer alive.
	_resident_page_context.free()
	_retiring_pages[retirement_key] = int(
		retired.get("submission_id", 0)
	)
	_clear_resident_page_fields()
	return OK

func _resolve_native_runtime() -> void:
	if _native_runtime != null and is_instance_valid(_native_runtime):
		return
	_native_runtime = null
	if Engine.has_singleton(NATIVE_RUNTIME_SINGLETON):
		_native_runtime = Engine.get_singleton(NATIVE_RUNTIME_SINGLETON)

func _poll_native_runtime() -> void:
	if _native_runtime == null or not is_instance_valid(_native_runtime):
		return
	var publications: Array = _native_runtime.call(&"poll_publications")
	for value in publications:
		var publication: Dictionary = value
		if (
			String(publication.get("content_identity", "")) == _resident_page_identity
			and int(publication.get("owner_generation", 0)) == _resident_page_generation
			and int(publication.get("submission_id", 0)) == _resident_final_submission_id
		):
			_resident_page_state = PAGE_STATE_READY
	var retirements: Array = _native_runtime.call(&"poll_retirements")
	for value in retirements:
		var retirement: Dictionary = value
		var retirement_key := "%s#%d" % [
			String(retirement.get("content_identity", "")),
			int(retirement.get("generation", 0))
		]
		if _retiring_pages.has(retirement_key):
			_retiring_pages.erase(retirement_key)

func _record_native_error(operation: String, outcome: Dictionary) -> Error:
	_native_last_error = {
		"schema": "gdgs-native-gaussian-error-v1",
		"operation": operation,
		"status": String(outcome.get("status", "UNKNOWN")),
		"outcome": outcome.duplicate(true),
		"captured_usec": Time.get_ticks_usec()
	}
	return ERR_CANT_CREATE

func get_residency_snapshot() -> Dictionary:
	var snapshot := {
		"schema": "gdgs-resident-page-snapshot-v1",
		"resident": (
			_resident_page_context != null
			and _resident_page_descriptor != null
			and _resident_page_descriptor.rid.is_valid()
		),
		"content_identity": _resident_page_identity,
		"content_hash": _resident_page_hash,
		"resident_bytes": _resident_page_bytes,
		"attribute_upload_total_count": _resident_page_upload_total_count,
		"render_state_count": _render_states.size(),
		"residency_state": _resident_page_state,
		"generation": _resident_page_generation,
		"virtual_offset_bytes": _resident_page_virtual_offset,
		"buffer_offset_bytes": _resident_page_buffer_offset,
		"uploaded_bytes": _resident_uploaded_bytes,
		"native_runtime": _native_runtime != null,
		"retiring_page_count": _retiring_pages.size(),
		"last_native_error": _native_last_error.duplicate(true)
	}
	if _native_runtime != null and is_instance_valid(_native_runtime):
		snapshot["native_snapshot"] = _native_runtime.call(&"snapshot")
	return snapshot

func get_or_create_render_state(texture_size: Vector2i):
	var state: RenderState = _render_states.get(texture_size, null)
	if state == null:
		state = RenderState.new()
		state.texture_size = texture_size
		state.tile_dims = (texture_size + Vector2i(TILE_SIZE - 1, TILE_SIZE - 1)) / TILE_SIZE
		_render_states[texture_size] = state
	_touch_render_state(texture_size)
	_enforce_render_state_cache_limit()
	return state

func mark_all_render_states_needs_gpu_rebuild() -> void:
	for state in _render_states.values():
		state.needs_gpu_rebuild = true

func mark_all_render_states_needs_splat_upload(value: bool) -> void:
	for state in _render_states.values():
		state.needs_splat_upload = value

func mark_all_render_states_needs_instance_upload(value: bool) -> void:
	for state in _render_states.values():
		state.needs_instance_upload = value

func set_workspace_budget_bytes(budget_bytes: int) -> Error:
	if budget_bytes <= 0 or budget_bytes > ProjectionCapacity.MAX_WORKSPACE_BUDGET_BYTES:
		return ERR_INVALID_PARAMETER
	if budget_bytes == _workspace_budget_bytes:
		return OK
	_workspace_budget_bytes = budget_bytes
	mark_all_render_states_needs_gpu_rebuild()
	_telemetry_mutex.lock()
	_latest_telemetry = {}
	_telemetry_mutex.unlock()
	return OK

func get_workspace_budget_bytes() -> int:
	return _workspace_budget_bytes

func request_gpu_timing_sample(texture_size: Vector2i = Vector2i.ZERO) -> Error:
	_gpu_timing_mutex.lock()
	if not _gpu_timing_request.is_empty() or not _pending_gpu_timing.is_empty():
		_gpu_timing_mutex.unlock()
		return ERR_BUSY
	var token := _next_gpu_timing_token
	_next_gpu_timing_token += 1
	_gpu_timing_request = {
		"token": token,
		"texture_size": texture_size,
		"requested_usec": Time.get_ticks_usec()
	}
	_latest_gpu_timing = {}
	_gpu_timing_mutex.unlock()
	return OK

func get_latest_gpu_timing() -> Dictionary:
	_gpu_timing_mutex.lock()
	var result := _latest_gpu_timing.duplicate(true)
	_gpu_timing_mutex.unlock()
	return result

func consume_gpu_timing_request(texture_size: Vector2i, generation: int) -> int:
	_gpu_timing_mutex.lock()
	if _gpu_timing_request.is_empty():
		_gpu_timing_mutex.unlock()
		return 0
	var requested_size: Vector2i = _gpu_timing_request.get("texture_size", Vector2i.ZERO)
	if requested_size != Vector2i.ZERO and requested_size != texture_size:
		_gpu_timing_mutex.unlock()
		return 0
	var token := int(_gpu_timing_request["token"])
	_pending_gpu_timing = _gpu_timing_request.duplicate(true)
	_pending_gpu_timing["texture_size"] = texture_size
	_pending_gpu_timing["generation"] = generation
	_pending_gpu_timing["capture_started_usec"] = Time.get_ticks_usec()
	_gpu_timing_request = {}
	_gpu_timing_mutex.unlock()
	return token

func poll_gpu_timing_results(device: RenderingDevice) -> void:
	if device == null:
		return
	_gpu_timing_mutex.lock()
	var pending := _pending_gpu_timing.duplicate(true)
	_gpu_timing_mutex.unlock()
	if pending.is_empty():
		return

	var names: Array = []
	var gpu_times_usec: Array = []
	var timestamp_count := device.get_captured_timestamps_count()
	for index in timestamp_count:
		names.push_back(device.get_captured_timestamp_name(index))
		gpu_times_usec.push_back(device.get_captured_timestamp_gpu_time(index))
	var sample := GpuTiming.build_sample(
		pending,
		device.get_captured_timestamps_frame(),
		names,
		gpu_times_usec
	)
	if sample.is_empty():
		if Time.get_ticks_usec() - int(pending.get("capture_started_usec", 0)) < GpuTiming.RESULT_TIMEOUT_USEC:
			return
		sample = GpuTiming.timeout_sample(pending)

	_gpu_timing_mutex.lock()
	if int(_pending_gpu_timing.get("token", 0)) == int(pending.get("token", 0)):
		_latest_gpu_timing = sample
		_pending_gpu_timing = {}
	_gpu_timing_mutex.unlock()

func rebuild_gpu_state(state, point_count: int, unique_data_size: int, instance_count: int) -> void:
	cleanup_state(state)
	state.last_error = {}
	if point_count <= 0:
		return
	if (
		_resident_page_context == null
		or _resident_page_descriptor == null
		or not _resident_page_descriptor.rid.is_valid()
		or unique_data_size != _resident_page_bytes
	):
		_fail_rebuild(
			state,
			"GDGS_RESIDENT_PAGE_MISSING",
			"A validated resident Gaussian page must exist before view workspace allocation"
		)
		return

	var layout: Dictionary = ProjectionCapacity.compute_workspace_layout(
		point_count,
		state.texture_size,
		_workspace_budget_bytes
	)
	if not layout.get("valid", false) or int(layout.get("pair_capacity", 0)) <= 0:
		_fail_rebuild(
			state,
			String(layout.get("error_id", "GDGS_WORKSPACE_BUDGET_EXHAUSTED")),
			String(layout.get("message", "Projection workspace has no usable pair capacity"))
		)
		return

	state.workspace_layout = layout
	state.generation = _next_generation
	_next_generation += 1
	state.context = RenderingDeviceContext.create(RenderingServer.get_rendering_device())

	state.shaders["projection"] = state.context.load_shader(SHADER_PATH_PROJECTION)
	state.shaders["prefix_blocks"] = state.context.load_shader(SHADER_PATH_PREFIX_BLOCKS)
	state.shaders["prefix_block_sums"] = state.context.load_shader(SHADER_PATH_PREFIX_BLOCK_SUMS)
	state.shaders["admission"] = state.context.load_shader(SHADER_PATH_ADMISSION)
	state.shaders["emit"] = state.context.load_shader(SHADER_PATH_EMIT)
	state.shaders["radix_upsweep"] = state.context.load_shader(SHADER_PATH_RADIX_UPSWEEP)
	state.shaders["radix_spine"] = state.context.load_shader(SHADER_PATH_RADIX_SPINE)
	state.shaders["radix_downsweep"] = state.context.load_shader(SHADER_PATH_RADIX_DOWNSWEEP)
	state.shaders["boundaries"] = state.context.load_shader(SHADER_PATH_BOUNDARIES)
	state.shaders["render"] = state.context.load_shader(SHADER_PATH_RENDER)

	var pair_capacity := int(layout["pair_capacity"])
	var num_partitions := int(layout["partition_count"])
	var prefix_block_count := int(layout["prefix_block_count"])
	var allocations: Dictionary = layout["allocations"]
	var block_dims := PackedInt32Array()
	block_dims.resize(6)
	block_dims.fill(1)
	# Pre-size indirect dispatch dimensions on the CPU. On macOS/Metal, updating this
	# buffer from the projection pass can cause the entire GS pipeline to go blank.
	block_dims[0] = num_partitions
	block_dims[3] = ceili(pair_capacity / 256.0)

	# Immutable Gaussian attributes are device-owned and shared by every
	# render state/view. This descriptor is not owned by state.context.
	state.descriptors["splats"] = _resident_page_descriptor
	state.descriptors["culled_splats"] = state.context.create_storage_buffer(point_count * FLOATS_PER_CULLED_SPLAT * BYTES_PER_FLOAT)
	state.descriptors["projection_ranges"] = state.context.create_storage_buffer(int(allocations["projection_ranges"]))
	state.descriptors["prefix_block_sums"] = state.context.create_storage_buffer(int(allocations["prefix_block_sums"]))
	state.descriptors["telemetry"] = state.context.create_storage_buffer(ProjectionCapacity.TELEMETRY_BYTES)
	state.descriptors["grid_dimensions"] = state.context.create_storage_buffer(6 * 4, block_dims.to_byte_array(), RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	state.descriptors["histogram"] = state.context.create_storage_buffer(int(allocations["histogram"]))
	state.descriptors["sort_keys"] = state.context.create_storage_buffer(int(allocations["key_records"]))
	state.descriptors["sort_values"] = state.context.create_storage_buffer(int(allocations["values"]))
	state.descriptors["splat_instance_ids"] = state.context.create_storage_buffer(point_count * 4 * 2)
	state.descriptors["instance_transforms"] = state.context.create_storage_buffer(instance_count * 16 * BYTES_PER_FLOAT)
	state.descriptors["uniforms"] = state.context.create_uniform_buffer(PROJECTION_UNIFORM_BYTES)
	state.descriptors["prefix_constants"] = state.context.create_uniform_buffer(PREFIX_CONSTANTS_BYTES)
	state.descriptors["tile_bounds"] = state.context.create_storage_buffer(int(allocations["tile_bounds"]))
	state.descriptors["tile_splat_pos"] = state.context.create_storage_buffer(4 * 4)
	state.descriptors["render_texture"] = state.context.create_texture(state.texture_size, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	state.descriptors["depth_texture"] = state.context.create_texture(state.texture_size, RenderingDevice.DATA_FORMAT_R32_SFLOAT)
	var failed_descriptor_name := ""
	for descriptor_name: String in state.descriptors:
		var descriptor = state.descriptors[descriptor_name]
		if descriptor == null or not descriptor.rid.is_valid():
			failed_descriptor_name = descriptor_name
			break
	if not failed_descriptor_name.is_empty():
		_fail_rebuild(
			state,
			"GDGS_GPU_ALLOCATION_FAILED",
			"RenderingDevice allocation failed for '%s' within the %d-byte projection workspace" % [failed_descriptor_name, _workspace_budget_bytes]
		)
		return

	var projection_set: RID = state.context.create_descriptor_set([
		state.descriptors["splats"],
		state.descriptors["culled_splats"],
		state.descriptors["projection_ranges"],
		state.descriptors["splat_instance_ids"],
		state.descriptors["instance_transforms"],
		state.descriptors["uniforms"]
	], state.shaders["projection"], 0)

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

	state.pipelines["gsplat_projection"] = state.context.create_pipeline([ceili(point_count / 256.0), 1, 1], [projection_set], state.shaders["projection"])
	state.pipelines["gsplat_prefix_blocks"] = state.context.create_pipeline([prefix_block_count, 1, 1], [prefix_blocks_set], state.shaders["prefix_blocks"])
	state.pipelines["gsplat_prefix_block_sums"] = state.context.create_pipeline([1, 1, 1], [prefix_block_sums_set], state.shaders["prefix_block_sums"])
	state.pipelines["gsplat_admission"] = state.context.create_pipeline([ceili(point_count / 256.0), 1, 1], [admission_set], state.shaders["admission"])
	state.pipelines["gsplat_emit"] = state.context.create_pipeline([ceili(point_count / 256.0), 1, 1], [emit_set], state.shaders["emit"])
	state.pipelines["radix_sort_upsweep"] = state.context.create_pipeline([], [radix_upsweep_set], state.shaders["radix_upsweep"])
	state.pipelines["radix_sort_spine"] = state.context.create_pipeline([RADIX, 1, 1], [radix_spine_set], state.shaders["radix_spine"])
	state.pipelines["radix_sort_downsweep"] = state.context.create_pipeline([], [radix_downsweep_set], state.shaders["radix_downsweep"])
	state.pipelines["gsplat_boundaries"] = state.context.create_pipeline([], [boundaries_set], state.shaders["boundaries"])
	state.pipelines["gsplat_render"] = state.context.create_pipeline([state.tile_dims.x, state.tile_dims.y, 1], [render_set], state.shaders["render"])

	state.needs_gpu_rebuild = false
	state.needs_splat_upload = true
	state.needs_instance_upload = true

func upload_splats(state, point_data_byte: PackedByteArray, splat_instance_ids_byte: PackedByteArray) -> void:
	if state.context == null or point_data_byte.is_empty() or splat_instance_ids_byte.is_empty():
		return
	if (
		_resident_page_descriptor == null
		or state.descriptors.get("splats", null) != _resident_page_descriptor
		or point_data_byte.size() != _resident_page_bytes
	):
		return
	# Only per-view/instance indirection changes here. Immutable splat
	# attributes were uploaded once when the resident page was created.
	state.context.device.buffer_update(state.descriptors["splat_instance_ids"].rid, 0, splat_instance_ids_byte.size(), splat_instance_ids_byte)
	state.needs_splat_upload = false

func upload_instance_transforms(state, instance_transforms_byte: PackedByteArray) -> void:
	if state.context == null or instance_transforms_byte.is_empty():
		return
	state.context.device.buffer_update(state.descriptors["instance_transforms"].rid, 0, instance_transforms_byte.size(), instance_transforms_byte)
	state.needs_instance_upload = false

func request_telemetry_sample(
	texture_size: Vector2i = Vector2i.ZERO,
	include_projection_ranges: bool = false,
	include_sort_validation: bool = false
) -> void:
	RenderingServer.call_on_render_thread(
		_collect_telemetry_on_render_thread.bind(texture_size, include_projection_ranges, include_sort_validation)
	)

func get_latest_telemetry() -> Dictionary:
	_telemetry_mutex.lock()
	var result := _latest_telemetry.duplicate(true)
	_telemetry_mutex.unlock()
	return result

func _collect_telemetry_on_render_thread(
	texture_size: Vector2i,
	include_projection_ranges: bool,
	include_sort_validation: bool
) -> void:
	var selected_size := texture_size
	if selected_size == Vector2i.ZERO:
		if _render_state_lru.is_empty():
			return
		selected_size = _render_state_lru.back()
	var state: RenderState = _render_states.get(selected_size, null)
	if state == null or state.context == null or not state.descriptors.has("telemetry"):
		return
	var expected_generation := state.generation
	var bytes: PackedByteArray = state.context.device.buffer_get_data(state.descriptors["telemetry"].rid)
	if bytes.size() < ProjectionCapacity.TELEMETRY_BYTES:
		return
	if state.context == null or state.generation != expected_generation:
		return

	var flags := int(bytes.decode_u32(12 * 4))
	var sample := {
		"schema": "gdgs-projection-telemetry-v2",
		"layout_version": int(bytes.decode_u32(0 * 4)),
		"generation": int(bytes.decode_u32(1 * 4)),
		"resident_splats": int(bytes.decode_u32(2 * 4)),
		"visible_splats": int(bytes.decode_u32(3 * 4)),
		"requested_pairs": int(bytes.decode_u32(4 * 4)),
		"admitted_pairs": int(bytes.decode_u32(5 * 4)),
		"emitted_pairs": int(bytes.decode_u32(6 * 4)),
		"dropped_pairs": int(bytes.decode_u32(7 * 4)),
		"pair_capacity": int(bytes.decode_u32(8 * 4)),
		"workspace_bytes": int(bytes.decode_u32(9 * 4)),
		"high_water": int(bytes.decode_u32(10 * 4)),
		"invalid_projection_splats": int(bytes.decode_u32(11 * 4)),
		"flags": flags,
		"grid": Vector2i(int(bytes.decode_u32(13 * 4)), int(bytes.decode_u32(14 * 4))),
		"first_dropped_splat": int(bytes.decode_u32(15 * 4)),
		"overflow": (flags & 1) != 0,
		"counter_saturated": (flags & 2) != 0,
		"writer_invariant_failed": (flags & 4) != 0,
		"key_range_failed": (flags & 8) != 0,
		"captured_usec": Time.get_ticks_usec()
	}
	sample["bounds_valid"] = (
		int(sample["emitted_pairs"]) <= int(sample["admitted_pairs"])
		and int(sample["admitted_pairs"]) <= int(sample["pair_capacity"])
		and int(sample["high_water"]) <= int(sample["pair_capacity"])
	)
	sample["accounting_valid"] = bool(sample["counter_saturated"]) or (
		int(sample["requested_pairs"]) == int(sample["admitted_pairs"]) + int(sample["dropped_pairs"])
	)
	if include_projection_ranges:
		var range_bytes: PackedByteArray = state.context.device.buffer_get_data(state.descriptors["projection_ranges"].rid)
		var range_stride := ProjectionCapacity.PROJECTION_RANGE_BYTES_PER_SPLAT
		var resident_count := mini(int(sample["resident_splats"]), int(range_bytes.size() / range_stride))
		var max_requested := 0
		var max_requested_splat := -1
		var minimum_view_depth := INF
		var maximum_view_depth := 0.0
		var fullscreen_third_count := 0
		var sample_grid: Vector2i = sample["grid"]
		var fullscreen_third_threshold := sample_grid.x * sample_grid.y / 3
		for splat_index in resident_count:
			var range_offset := splat_index * range_stride
			var requested := int(range_bytes.decode_u32(range_offset + 4 * 4))
			var status := int(range_bytes.decode_u32(range_offset + 8 * 4))
			if (status & 1) == 0:
				continue
			var view_depth := range_bytes.decode_float(range_offset + 7 * 4)
			minimum_view_depth = minf(minimum_view_depth, view_depth)
			maximum_view_depth = maxf(maximum_view_depth, view_depth)
			if requested > max_requested:
				max_requested = requested
				max_requested_splat = splat_index
			if requested > fullscreen_third_threshold:
				fullscreen_third_count += 1
		sample["range_diagnostics"] = {
			"max_requested_pairs_per_splat": max_requested,
			"max_requested_splat": max_requested_splat,
			"minimum_view_depth": minimum_view_depth if minimum_view_depth != INF else -1.0,
			"maximum_view_depth": maximum_view_depth,
			"splats_covering_more_than_one_third_screen": fullscreen_third_count
		}
	if include_sort_validation:
		_append_sort_validation(state, sample)

	_telemetry_mutex.lock()
	_latest_telemetry = sample
	_telemetry_mutex.unlock()
	if bool(sample["overflow"]) and Time.get_ticks_msec() - _last_overflow_warning_msec >= 5000:
		_last_overflow_warning_msec = Time.get_ticks_msec()
		push_warning("[gdgs] Gaussian pair workspace exhausted: requested=%d admitted=%d capacity=%d dropped=%d" % [
			sample["requested_pairs"],
			sample["admitted_pairs"],
			sample["pair_capacity"],
			sample["dropped_pairs"]
		])

func _append_sort_validation(state, sample: Dictionary) -> void:
	var element_count := mini(int(sample["emitted_pairs"]), int(sample["pair_capacity"]))
	var key_bytes_required := element_count * 2 * 4
	var value_bytes_required := element_count * 4
	var key_bytes: PackedByteArray = state.context.device.buffer_get_data(
		state.descriptors["sort_keys"].rid,
		0,
		key_bytes_required
	)
	var value_bytes: PackedByteArray = state.context.device.buffer_get_data(
		state.descriptors["sort_values"].rid,
		0,
		value_bytes_required
	)
	if key_bytes.size() < key_bytes_required or value_bytes.size() < value_bytes_required:
		sample["sort_validation"] = {
			"valid": false,
			"error_id": "GDGS_SORT_READBACK_TRUNCATED",
			"element_count": element_count,
			"key_bytes": key_bytes.size(),
			"value_bytes": value_bytes.size()
		}
		return

	var grid: Vector2i = sample["grid"]
	var bin_count := int(grid.x) * int(grid.y)
	var sorted := true
	var key_range_valid := true
	var value_range_valid := true
	var first_error_index := -1
	var first_bin := -1
	var last_bin := -1
	var first_depth := 0
	var last_depth := 0
	var previous_bin := -1
	var previous_depth := 0
	var unique_bins := 0
	for pair_index in element_count:
		var key_offset := pair_index * 8
		var bin_id := int(key_bytes.decode_u32(key_offset))
		var ordered_depth := int(key_bytes.decode_u32(key_offset + 4))
		var splat_id := int(value_bytes.decode_u32(pair_index * 4))
		if pair_index == 0:
			first_bin = bin_id
			first_depth = ordered_depth
		if bin_id < 0 or bin_id >= bin_count:
			key_range_valid = false
			if first_error_index == -1:
				first_error_index = pair_index
		if splat_id < 0 or splat_id >= int(sample["resident_splats"]):
			value_range_valid = false
			if first_error_index == -1:
				first_error_index = pair_index
		if pair_index == 0 or bin_id != previous_bin:
			unique_bins += 1
		elif ordered_depth < previous_depth:
			sorted = false
			if first_error_index == -1:
				first_error_index = pair_index
		if pair_index > 0 and bin_id < previous_bin:
			sorted = false
			if first_error_index == -1:
				first_error_index = pair_index
		previous_bin = bin_id
		previous_depth = ordered_depth
		last_bin = bin_id
		last_depth = ordered_depth

	var boundary_bytes_required := bin_count * ProjectionCapacity.TILE_BOUNDS_BYTES_PER_BIN
	var boundary_bytes: PackedByteArray = state.context.device.buffer_get_data(
		state.descriptors["tile_bounds"].rid,
		0,
		boundary_bytes_required
	)
	var boundary_valid := boundary_bytes.size() >= boundary_bytes_required
	var first_boundary_error_bin := -1
	if boundary_valid:
		for bin_id in bin_count:
			var boundary_offset := bin_id * ProjectionCapacity.TILE_BOUNDS_BYTES_PER_BIN
			var range_start := int(boundary_bytes.decode_u32(boundary_offset))
			var range_end := int(boundary_bytes.decode_u32(boundary_offset + 4))
			if range_end < range_start or range_end > element_count:
				boundary_valid = false
				first_boundary_error_bin = bin_id
				break
			if range_start < range_end:
				var start_bin := int(key_bytes.decode_u32(range_start * 8))
				var end_bin := int(key_bytes.decode_u32((range_end - 1) * 8))
				if start_bin != bin_id or end_bin != bin_id:
					boundary_valid = false
					first_boundary_error_bin = bin_id
					break

	sample["sort_validation"] = {
		"valid": sorted and key_range_valid and value_range_valid and boundary_valid,
		"element_count": element_count,
		"sorted_lexicographically": sorted,
		"key_range_valid": key_range_valid,
		"value_range_valid": value_range_valid,
		"boundary_ranges_valid": boundary_valid,
		"unique_bins": unique_bins,
		"first_bin": first_bin,
		"last_bin": last_bin,
		"first_ordered_depth": first_depth,
		"last_ordered_depth": last_depth,
		"first_error_index": first_error_index,
		"first_boundary_error_bin": first_boundary_error_bin
	}

func _fail_rebuild(state, error_id: String, message: String) -> void:
	cleanup_state(state)
	state.last_error = {
		"schema": "gdgs-renderer-error-v1",
		"error_id": error_id,
		"message": message,
		"workspace_budget_bytes": _workspace_budget_bytes,
		"captured_usec": Time.get_ticks_usec()
	}
	# Keep the failed state quiescent. A configuration or registry change explicitly
	# marks it for rebuild; rendering an unchanged frame must not retry allocation.
	state.needs_gpu_rebuild = false
	_telemetry_mutex.lock()
	_latest_telemetry = state.last_error.duplicate(true)
	_telemetry_mutex.unlock()
	push_error("[gdgs] %s: %s" % [error_id, message])

func cleanup_state(state) -> void:
	if state == null:
		return
	if state.context != null:
		state.context.free()
		state.context = null
	state.shaders.clear()
	state.pipelines.clear()
	state.descriptors.clear()
	state.workspace_layout = {}
	state.generation = 0
	state.needs_gpu_rebuild = true
	state.needs_splat_upload = true
	state.needs_instance_upload = true

func cleanup_all(clear_resident_page: bool = true) -> void:
	for state in _render_states.values():
		cleanup_state(state)
	_render_states.clear()
	_render_state_lru.clear()
	_telemetry_mutex.lock()
	_latest_telemetry = {}
	_telemetry_mutex.unlock()
	_gpu_timing_mutex.lock()
	_gpu_timing_request = {}
	_pending_gpu_timing = {}
	_latest_gpu_timing = {}
	_gpu_timing_mutex.unlock()
	_pending_gpu_cleanup = false
	_pending_resident_cleanup = false
	if clear_resident_page:
		if _native_runtime != null and _resident_page_context != null:
			_begin_resident_page_retirement()
		else:
			_cleanup_resident_page()

func shutdown() -> void:
	cleanup_all(true)
	if _native_runtime == null or not is_instance_valid(_native_runtime):
		return
	var shutdown_result: Dictionary = _native_runtime.call(&"begin_shutdown")
	if not bool(shutdown_result.get("accepted", false)):
		_record_native_error("begin_shutdown", shutdown_result)

func _cleanup_resident_page() -> void:
	if _resident_page_context != null:
		_resident_page_context.free()
	_clear_resident_page_fields()

func _clear_resident_page_fields() -> void:
	_resident_page_context = null
	_resident_page_descriptor = null
	_resident_page_identity = ""
	_resident_page_hash = ""
	_resident_page_bytes = 0
	_resident_page_state = PAGE_STATE_EMPTY
	_resident_page_generation = 0
	_resident_page_virtual_offset = 0
	_resident_page_buffer_offset = 0
	_resident_upload_id = ""
	_resident_uploaded_bytes = 0
	_resident_final_submission_id = 0
	_resident_readiness_recorded = false
	_resident_completion_proof_scheduled = false
	_native_last_upload_frame = -1

func _touch_render_state(texture_size: Vector2i) -> void:
	var existing_index := _render_state_lru.find(texture_size)
	if existing_index != -1:
		_render_state_lru.remove_at(existing_index)
	_render_state_lru.push_back(texture_size)

func _enforce_render_state_cache_limit() -> void:
	while _render_state_lru.size() > MAX_RENDER_STATES:
		var stale_size = _render_state_lru[0]
		_render_state_lru.remove_at(0)
		var stale_state = _render_states.get(stale_size, null)
		if stale_state != null:
			cleanup_state(stale_state)
			_render_states.erase(stale_size)
