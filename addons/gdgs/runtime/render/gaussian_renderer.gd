@tool
extends RefCounted
class_name GaussianRenderer

const RenderingDeviceContext := preload("res://addons/gdgs/runtime/render/gaussian_rendering_device_context.gd")
const ProjectionCapacity := preload("res://addons/gdgs/runtime/render/gaussian_projection_capacity.gd")
const GpuTiming := preload("res://addons/gdgs/runtime/render/gaussian_gpu_timing.gd")
const RADIX := 256

func render_for_compositor(
	state_cache: GaussianGpuStateCache,
	scene_registry,
	texture_size: Vector2i,
	camera_transform: Transform3D,
	camera_projection: Projection,
	camera_world_position: Vector3,
	depth_capture_alpha: float = 0.5
) -> Dictionary:
	state_cache.flush_pending_cleanup()

	if not scene_registry.has_gpu_data():
		state_cache.cleanup_all(true)
		return {}

	var point_count: int = scene_registry.get_point_count()
	var point_data_byte: PackedByteArray = scene_registry.get_point_data_byte()
	var resident_page: Dictionary = scene_registry.get_resident_page_descriptor()
	var residency_error := state_cache.ensure_resident_page(
		resident_page,
		point_data_byte
	)
	if residency_error != OK:
		return {}
	var safe_size := Vector2i(maxi(texture_size.x, 1), maxi(texture_size.y, 1))
	var state = state_cache.get_or_create_render_state(safe_size)
	_update_camera_from_transform(state, camera_transform, camera_projection)
	state.camera_world_position = camera_world_position
	state.depth_capture_alpha = clampf(depth_capture_alpha, 0.0, 1.0)

	var unique_data_size: int = point_data_byte.size()

	if state.needs_gpu_rebuild:
		state_cache.rebuild_gpu_state(state, point_count, unique_data_size, scene_registry.get_instance_count())
	if state.context == null:
		return {}

	if state.needs_splat_upload:
		state_cache.upload_splats(state, point_data_byte, scene_registry.get_splat_instance_ids_byte())
	if state.needs_instance_upload:
		state_cache.upload_instance_transforms(state, scene_registry.get_instance_transforms_byte())

	if state.camera_matrices.is_empty():
		return {}

	state_cache.poll_gpu_timing_results(state.context.device)
	var gpu_timing_token := state_cache.consume_gpu_timing_request(state.texture_size, state.generation)
	_rasterize_state(state, point_count, gpu_timing_token)
	if state.descriptors.has("render_texture") and state.descriptors.has("depth_texture"):
		var result := {
			"color_alpha_texture": state.descriptors["render_texture"].rid,
			"color_alpha_format":
				RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
			"depth_texture": state.descriptors["depth_texture"].rid
		}
		if gpu_timing_token > 0:
			result["gpu_timing_token"] = gpu_timing_token
		return result
	return {}

func _rasterize_state(state, point_count: int, gpu_timing_token: int = 0) -> void:
	if state.context == null:
		return

	var uniforms := RenderingDeviceContext.create_push_constant([
		state.camera_world_position.x,
		state.camera_world_position.y,
		state.camera_world_position.z,
		Time.get_ticks_msec() * 1e-3,
		state.texture_size.x,
		state.texture_size.y,
		point_count,
		0
	])
	uniforms.append_array(state.camera_matrices)
	assert(uniforms.size() == GaussianGpuStateCache.PROJECTION_UNIFORM_BYTES)
	state.context.device.buffer_update(state.descriptors["uniforms"].rid, 0, uniforms.size(), uniforms)
	state.context.device.buffer_clear(state.descriptors["histogram"].rid, 0, 4 + ProjectionCapacity.RADIX_PASSES * RADIX * 4)
	state.context.device.buffer_clear(state.descriptors["tile_bounds"].rid, 0, state.tile_dims.x * state.tile_dims.y * 2 * 4)

	var pair_capacity := int(state.workspace_layout["pair_capacity"])
	var prefix_constants := RenderingDeviceContext.create_push_constant([
		point_count,
		int(state.workspace_layout["prefix_block_count"]),
		pair_capacity,
		state.generation,
		state.tile_dims.x,
		state.tile_dims.y,
		int(state.workspace_layout["total_bytes"]),
		ProjectionCapacity.WORKSPACE_LAYOUT_VERSION
	])
	assert(prefix_constants.size() == GaussianGpuStateCache.PREFIX_CONSTANTS_BYTES)
	state.context.device.buffer_update(
		state.descriptors["prefix_constants"].rid,
		0,
		prefix_constants.size(),
		prefix_constants
	)
	if gpu_timing_token > 0:
		state.context.device.capture_timestamp(GpuTiming.marker(gpu_timing_token, "begin"))
	var compute_list: int = state.context.compute_list_begin()
	state.pipelines["gsplat_projection"].call(state.context, compute_list)
	state.pipelines["gsplat_prefix_blocks"].call(state.context, compute_list)
	state.pipelines["gsplat_prefix_block_sums"].call(state.context, compute_list)
	state.pipelines["gsplat_admission"].call(state.context, compute_list)
	state.pipelines["gsplat_emit"].call(state.context, compute_list)
	state.context.compute_list_end()
	if gpu_timing_token > 0:
		state.context.device.capture_timestamp(GpuTiming.marker(gpu_timing_token, "projection_end"))

	compute_list = state.context.compute_list_begin()
	for radix_shift_pass in range(ProjectionCapacity.RADIX_PASSES):
		var sort_push_constant := RenderingDeviceContext.create_push_constant([
			radix_shift_pass,
			pair_capacity * (radix_shift_pass % 2),
			pair_capacity * (1 - (radix_shift_pass % 2)),
			0
		])
		state.pipelines["radix_sort_upsweep"].call(state.context, compute_list, sort_push_constant, [], state.descriptors["grid_dimensions"].rid, 0)
		state.pipelines["radix_sort_spine"].call(state.context, compute_list, sort_push_constant)
		state.pipelines["radix_sort_downsweep"].call(state.context, compute_list, sort_push_constant, [], state.descriptors["grid_dimensions"].rid, 0)
	state.context.compute_list_end()
	if gpu_timing_token > 0:
		state.context.device.capture_timestamp(GpuTiming.marker(gpu_timing_token, "sort_end"))

	compute_list = state.context.compute_list_begin()
	state.pipelines["gsplat_boundaries"].call(state.context, compute_list, PackedByteArray(), [], state.descriptors["grid_dimensions"].rid, 3 * 4)
	state.context.compute_list_end()
	if gpu_timing_token > 0:
		state.context.device.capture_timestamp(GpuTiming.marker(gpu_timing_token, "boundaries_end"))

	compute_list = state.context.compute_list_begin()
	state.pipelines["gsplat_render"].call(
		state.context,
		compute_list,
		RenderingDeviceContext.create_push_constant([0.0, -1, state.depth_capture_alpha, 0.0])
	)
	state.context.compute_list_end()
	if gpu_timing_token > 0:
		state.context.device.capture_timestamp(GpuTiming.marker(gpu_timing_token, "raster_end"))

func _update_camera_from_transform(state, camera_transform: Transform3D, camera_projection: Projection) -> void:
	var view := Projection(camera_transform.affine_inverse())
	if view != state.camera_view or camera_projection != state.camera_projection:
		state.camera_view = view
		state.camera_projection = camera_projection
		state.camera_matrices = RenderingDeviceContext.create_push_constant(
			_projection_to_column_major_floats(view) + _projection_to_column_major_floats(camera_projection)
		)

func _projection_to_column_major_floats(matrix: Projection) -> Array:
	return [
		matrix.x[0], matrix.x[1], matrix.x[2], matrix.x[3],
		matrix.y[0], matrix.y[1], matrix.y[2], matrix.y[3],
		matrix.z[0], matrix.z[1], matrix.z[2], matrix.z[3],
		matrix.w[0], matrix.w[1], matrix.w[2], matrix.w[3]
	]
