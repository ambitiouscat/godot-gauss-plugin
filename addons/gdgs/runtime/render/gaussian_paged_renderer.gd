@tool
extends RefCounted
class_name GaussianPagedRenderer

const RenderingDeviceContext := preload("res://addons/gdgs/runtime/render/gaussian_rendering_device_context.gd")
const Capacity := preload("res://addons/gdgs/runtime/render/gaussian_paged_projection_capacity.gd")
const PagedCacheScript := preload("res://addons/gdgs/runtime/render/gaussian_paged_gpu_state_cache.gd")

func render_for_compositor(
	state_cache: RefCounted,
	world_registry: RefCounted,
	texture_size: Vector2i,
	camera_transform: Transform3D,
	camera_projection: Projection,
	camera_world_position: Vector3,
	view_identity: String,
	view_generation: int,
	depth_capture_alpha: float = 0.5
) -> Dictionary:
	var candidates: Array = (
		world_registry.call(&"get_resident_page_candidates")
	)
	if candidates.is_empty():
		state_cache.call(&"commit_empty_view", view_identity)
		state_cache.call(&"commit_resident_pages", candidates)
		return {}
	var active_list: Dictionary = world_registry.call(
		&"build_active_reference_list",
		view_identity,
		view_generation
	)
	if (
		not bool(active_list.get("accepted", false))
		or int(active_list.get("logical_splat_count", 0)) <= 0
	):
		return _render_committed_or_retain(
			state_cache,
			view_identity,
			texture_size,
			camera_transform,
			camera_projection,
			camera_world_position,
			depth_capture_alpha,
			active_list
		)
	var preparation: Dictionary = state_cache.call(
		&"prepare_selected_set_transition",
		active_list,
		candidates,
		texture_size
	)
	if not bool(preparation.get("accepted", false)):
		return _render_committed_or_retain(
			state_cache,
			view_identity,
			texture_size,
			camera_transform,
			camera_projection,
			camera_world_position,
			depth_capture_alpha,
			preparation
		)
	var selected_candidates: Array = preparation.get(
		"candidates",
		[]
	)
	var residency_error: Error = state_cache.call(
		&"ensure_resident_pages",
		selected_candidates
	)
	if residency_error != OK:
		if residency_error != ERR_BUSY:
			var residency_failure: Dictionary = state_cache.call(
				&"get_last_error"
			)
			var transition_snapshot: Dictionary = state_cache.call(
				&"get_transition_snapshot"
			)
			if bool(transition_snapshot.get("active", false)):
				state_cache.call(
					&"fail_selected_set_transition",
					"page_residency_failed",
					residency_failure
				)
		return _render_committed_or_retain(
			state_cache,
			view_identity,
			texture_size,
			camera_transform,
			camera_projection,
			camera_world_position,
			depth_capture_alpha,
			state_cache.call(&"get_last_error")
		)
	var state = state_cache.call(
		&"get_or_create_view_state",
		active_list,
		texture_size
	)
	if state == null or state.context == null:
		state_cache.call(
			&"cancel_selected_set_transition",
			"candidate_view_allocation_failed"
		)
		return _render_committed_or_retain(
			state_cache,
			view_identity,
			texture_size,
			camera_transform,
			camera_projection,
			camera_world_position,
			depth_capture_alpha,
			state_cache.call(&"get_last_error")
		)
	if (
		state_cache.call(
			&"commit_selected_set_transition_pre_switch",
			state
		) != OK
	):
		return _reject_candidate_and_retain(
			state_cache,
			state,
			texture_size,
			camera_transform,
			camera_projection,
			camera_world_position,
			depth_capture_alpha,
			{
				"accepted": false,
				"error_id": "GDGS_TRANSITION_PRE_SWITCH_FAILED",
				"detail": state_cache.call(&"get_last_error")
			}
		)
	_update_camera_from_transform(
		state,
		camera_transform,
		camera_projection
	)
	if state.camera_matrices.is_empty():
		return _reject_candidate_and_retain(
			state_cache,
			state,
			texture_size,
			camera_transform,
			camera_projection,
			camera_world_position,
			depth_capture_alpha,
			{
				"accepted": false,
				"error_id": "GDGS_CAMERA_STATE_INVALID"
			}
		)
	state.camera_world_position = camera_world_position
	state.depth_capture_alpha = clampf(
		depth_capture_alpha,
		0.0,
		1.0
	)
	var admission := _prepare_candidate_count(
		state_cache,
		state
	)
	if not bool(admission.get("accepted", false)):
		return _reject_candidate_and_retain(
			state_cache,
			state,
			texture_size,
			camera_transform,
			camera_projection,
			camera_world_position,
			depth_capture_alpha,
			admission
		)

	_scatter_sort_and_render(state)
	var complete_admission := _complete_admission_snapshot(
		state,
		state_cache.call(&"collect_stream", state, 0)
	)
	state_cache.call(
		&"record_admission_snapshot",
		state,
		complete_admission
	)
	if not bool(complete_admission.get("accepted", false)):
		return _reject_candidate_and_retain(
			state_cache,
			state,
			texture_size,
			camera_transform,
			camera_projection,
			camera_world_position,
			depth_capture_alpha,
			complete_admission
		)
	if state_cache.call(&"commit_view_state", state) != OK:
		return _reject_candidate_and_retain(
			state_cache,
			state,
			texture_size,
			camera_transform,
			camera_projection,
			camera_world_position,
			depth_capture_alpha,
			{
				"accepted": false,
				"error_id": "GDGS_VIEW_COMMIT_FAILED"
			}
		)
	state_cache.call(&"commit_resident_pages", candidates)
	return _state_result(state, complete_admission, false)

func _prepare_candidate_count(
	state_cache: RefCounted,
	state
) -> Dictionary:
	var uniforms := RenderingDeviceContext.create_push_constant([
		state.camera_world_position.x,
		state.camera_world_position.y,
		state.camera_world_position.z,
		Time.get_ticks_msec() * 1e-3,
		state.texture_size.x,
		state.texture_size.y,
		state.logical_point_count,
		0
	])
	uniforms.append_array(state.camera_matrices)
	assert(
		uniforms.size()
			== PagedCacheScript.PROJECTION_UNIFORM_BYTES
	)
	state.context.device.buffer_update(
		state.descriptors["uniforms"].rid,
		0,
		uniforms.size(),
		uniforms
	)
	state.context.device.buffer_clear(
		state.descriptors["histogram"].rid,
		0,
		4 + Capacity.RADIX_PASSES * Capacity.RADIX * 4
	)
	state.context.device.buffer_clear(
		state.descriptors["tile_bounds"].rid,
		0,
		state.tile_dims.x * state.tile_dims.y * 2 * 4
	)
	var pair_capacity := int(
		state.workspace_layout["pair_capacity"]
	)
	var prefix_constants := (
		RenderingDeviceContext.create_push_constant([
			state.logical_point_count,
			int(state.workspace_layout["prefix_block_count"]),
			pair_capacity,
			state.view_generation,
			state.tile_dims.x,
			state.tile_dims.y,
			int(state.workspace_layout["total_bytes"]),
			Capacity.WORKSPACE_LAYOUT_VERSION
		])
	)
	assert(
		prefix_constants.size()
			== PagedCacheScript.PREFIX_CONSTANTS_BYTES
	)
	state.context.device.buffer_update(
		state.descriptors["prefix_constants"].rid,
		0,
		prefix_constants.size(),
		prefix_constants
	)

	var compute_list: int = state.context.compute_list_begin()
	for instance_index in state.active_references.size():
		var reference: Dictionary = (
			state.active_references[instance_index]
		)
		var point_count := int(reference["point_count"])
		var page_id := int(reference["page_id"])
		if instance_index >= state.projection_pipelines.size():
			continue
		var push_constants := (
			RenderingDeviceContext.create_push_constant([
				point_count,
				int(reference["output_base"]),
				instance_index,
				page_id
			])
		)
		state.projection_pipelines[instance_index].call(
			state.context,
			compute_list,
			push_constants
		)
	state.context.compute_list_end()

	compute_list = state.context.compute_list_begin()
	state.pipelines["prefix_blocks"].call(
		state.context,
		compute_list,
		PackedByteArray()
	)
	state.pipelines["prefix_block_sums"].call(
		state.context,
		compute_list,
		PackedByteArray()
	)
	state.context.compute_list_end()
	var admission: Dictionary = state_cache.call(
		&"collect_admission",
		state
	)
	state_cache.call(
		&"record_admission_snapshot",
		state,
		admission
	)
	return admission

func _scatter_sort_and_render(state) -> void:
	var pair_capacity := int(
		state.workspace_layout["pair_capacity"]
	)
	var compute_list: int = state.context.compute_list_begin()
	state.pipelines["admission"].call(
		state.context,
		compute_list,
		PackedByteArray()
	)
	state.pipelines["emit"].call(
		state.context,
		compute_list,
		PackedByteArray()
	)
	state.context.compute_list_end()

	compute_list = state.context.compute_list_begin()
	for radix_pass in Capacity.RADIX_PASSES:
		var sort_push_constant := (
			RenderingDeviceContext.create_push_constant([
				radix_pass,
				pair_capacity * (radix_pass % 2),
				pair_capacity * (1 - (radix_pass % 2)),
				0
			])
		)
		state.pipelines["radix_upsweep"].call(
			state.context,
			compute_list,
			sort_push_constant,
			[],
			state.descriptors["grid_dimensions"].rid,
			0
		)
		state.pipelines["radix_spine"].call(
			state.context,
			compute_list,
			sort_push_constant
		)
		state.pipelines["radix_downsweep"].call(
			state.context,
			compute_list,
			sort_push_constant,
			[],
			state.descriptors["grid_dimensions"].rid,
			0
		)
	state.context.compute_list_end()

	compute_list = state.context.compute_list_begin()
	state.pipelines["boundaries"].call(
		state.context,
		compute_list,
		PackedByteArray(),
		[],
		state.descriptors["grid_dimensions"].rid,
		3 * 4
	)
	state.context.compute_list_end()

	compute_list = state.context.compute_list_begin()
	state.pipelines["render"].call(
		state.context,
		compute_list,
		RenderingDeviceContext.create_push_constant([
			0.0,
			-1,
			state.depth_capture_alpha,
			0.0
		])
	)
	state.context.compute_list_end()

func _reject_candidate_and_retain(
	state_cache: RefCounted,
	state,
	texture_size: Vector2i,
	camera_transform: Transform3D,
	camera_projection: Projection,
	camera_world_position: Vector3,
	depth_capture_alpha: float,
	rejection: Dictionary
) -> Dictionary:
	var was_committed := bool(
		state_cache.call(&"is_committed_view_state", state)
	)
	if not was_committed:
		state_cache.call(
			&"discard_candidate_view_state",
			state
		)
	if was_committed and state.has_complete_submission:
		var retained := rejection.duplicate(true)
		retained["retained_previous_submission"] = true
		retained["retained_render_refreshed"] = false
		state_cache.call(&"note_retained_submission")
		state_cache.call(
			&"record_admission_snapshot",
			state,
			retained
		)
		return _state_result(state, retained, true)
	return _render_committed_or_retain(
		state_cache,
		state.view_identity,
		texture_size,
		camera_transform,
		camera_projection,
		camera_world_position,
		depth_capture_alpha,
		rejection
	)

func _render_committed_or_retain(
	state_cache: RefCounted,
	view_identity: String,
	texture_size: Vector2i,
	camera_transform: Transform3D,
	camera_projection: Projection,
	camera_world_position: Vector3,
	depth_capture_alpha: float,
	rejection: Dictionary
) -> Dictionary:
	var committed = state_cache.call(
		&"get_committed_view_state",
		view_identity
	)
	if (
		committed == null
		or committed.context == null
		or not committed.has_complete_submission
		or committed.texture_size != texture_size
	):
		return {}
	_update_camera_from_transform(
		committed,
		camera_transform,
		camera_projection
	)
	committed.camera_world_position = camera_world_position
	committed.depth_capture_alpha = clampf(
		depth_capture_alpha,
		0.0,
		1.0
	)
	var fallback_admission := _prepare_candidate_count(
		state_cache,
		committed
	)
	if bool(fallback_admission.get("accepted", false)):
		_scatter_sort_and_render(committed)
		var complete_admission := _complete_admission_snapshot(
			committed,
			state_cache.call(
				&"collect_stream",
				committed,
				0
			)
		)
		if bool(complete_admission.get("accepted", false)):
			var retained_fresh := rejection.duplicate(true)
			retained_fresh["retained_previous_submission"] = true
			retained_fresh["retained_render_refreshed"] = true
			retained_fresh["retained_requested_pairs"] = int(
				complete_admission.get("requested_pairs", 0)
			)
			state_cache.call(&"note_retained_submission")
			state_cache.call(
				&"record_admission_snapshot",
				committed,
				retained_fresh
			)
			return _state_result(
				committed,
				retained_fresh,
				true
			)
	var retained := rejection.duplicate(true)
	retained["retained_previous_submission"] = true
	retained["retained_render_refreshed"] = false
	state_cache.call(&"note_retained_submission")
	state_cache.call(
		&"record_admission_snapshot",
		committed,
		retained
	)
	return _state_result(committed, retained, true)

func _complete_admission_snapshot(
	state,
	stream: Dictionary
) -> Dictionary:
	var requested := int(stream.get("requested_pairs", 0))
	var admitted := int(stream.get("admitted_pairs", 0))
	var emitted := int(stream.get("emitted_pairs", 0))
	var dropped := int(stream.get("dropped_pairs", 0))
	var flags := int(stream.get("flags", 0))
	var accepted := (
		not stream.is_empty()
		and flags == 0
		and dropped == 0
		and admitted == requested
		and emitted == admitted
	)
	return {
		"schema": "gdgs-paged-atomic-admission-v1",
		"accepted": accepted,
		"error_id": (
			""
			if accepted
			else "GDGS_ATOMIC_SCATTER_INVARIANT"
		),
		"view_identity": state.view_identity,
		"view_generation": state.view_generation,
		"registry_revision": state.registry_revision,
		"requested_pairs": requested,
		"admitted_pairs": admitted,
		"emitted_pairs": emitted,
		"rejected_pairs": dropped,
		"pair_capacity": int(stream.get("pair_capacity", 0)),
		"flags": flags,
		"retained_previous_submission": false
	}

func _state_result(
	state,
	admission: Dictionary,
	retained_previous: bool
) -> Dictionary:
	return {
		"color_alpha_texture":
			state.descriptors["render_texture"].rid,
		"color_alpha_format":
			RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		"depth_texture":
			state.descriptors["depth_texture"].rid,
		"view_identity": state.view_identity,
		"view_generation": state.view_generation,
		"workspace_layout_version":
			Capacity.WORKSPACE_LAYOUT_VERSION,
		"retained_previous_submission": retained_previous,
		"admission": admission.duplicate(true)
	}

func _update_camera_from_transform(
	state,
	camera_transform: Transform3D,
	camera_projection: Projection
) -> void:
	var view := Projection(camera_transform.affine_inverse())
	if (
		view != state.camera_view
		or camera_projection != state.camera_projection
	):
		state.camera_view = view
		state.camera_projection = camera_projection
		state.camera_matrices = (
			RenderingDeviceContext.create_push_constant(
				_projection_to_column_major_floats(view)
				+ _projection_to_column_major_floats(
					camera_projection
				)
			)
		)

func _projection_to_column_major_floats(
	matrix: Projection
) -> Array:
	return [
		matrix.x[0], matrix.x[1], matrix.x[2], matrix.x[3],
		matrix.y[0], matrix.y[1], matrix.y[2], matrix.y[3],
		matrix.z[0], matrix.z[1], matrix.z[2], matrix.z[3],
		matrix.w[0], matrix.w[1], matrix.w[2], matrix.w[3]
	]
