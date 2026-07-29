@tool
extends Node
class_name GaussianRenderManager

const SceneRegistryScript := preload("res://addons/gdgs/runtime/render/gaussian_scene_registry.gd")
const PageRegistryScript := preload("res://addons/gdgs/runtime/render/gaussian_page_registry.gd")
const WorldRegistryScript := preload("res://addons/gdgs/runtime/render/gaussian_world_registry.gd")
const GpuStateCacheScript := preload("res://addons/gdgs/runtime/render/gaussian_gpu_state_cache.gd")
const RendererScript := preload("res://addons/gdgs/runtime/render/gaussian_renderer.gd")
const PagedGpuStateCacheScript := preload("res://addons/gdgs/runtime/render/gaussian_paged_gpu_state_cache.gd")
const PagedRendererScript := preload("res://addons/gdgs/runtime/render/gaussian_paged_renderer.gd")
const AssetLoaderScript := preload("res://addons/gdgs/runtime/loading/gaussian_asset_loader.gd")

const RENDERER_MODE_LEGACY_MERGE := "legacy_merge"
const RENDERER_MODE_SINGLE_PAGE := "single_page"
const RENDERER_MODE_PAGED := "paged"
const MANAGER_GROUP := &"_gdspatial_gaussian_render_manager"

static var _instance

var _scene_registry: GaussianSceneRegistry = SceneRegistryScript.new()
var _page_registry: GaussianPageRegistry = PageRegistryScript.new()
var _world_registry: RefCounted = WorldRegistryScript.new()
var _gpu_state_cache: GaussianGpuStateCache = GpuStateCacheScript.new()
var _renderer: GaussianRenderer = RendererScript.new()
var _paged_gpu_state_cache: RefCounted = PagedGpuStateCacheScript.new()
var _paged_renderer: RefCounted = PagedRendererScript.new()
var _asset_loader: Node
var _renderer_mode := RENDERER_MODE_LEGACY_MERGE
var _shutdown_started := false

static func get_instance():
	if _instance != null and is_instance_valid(_instance):
		return _instance
	return null

func _enter_tree() -> void:
	_instance = self
	add_to_group(MANAGER_GROUP)

func _ready() -> void:
	_ensure_asset_loader()

func _exit_tree() -> void:
	if is_in_group(MANAGER_GROUP):
		remove_from_group(MANAGER_GROUP)
	shutdown()
	if _instance == self:
		_instance = null

func get_asset_loader() -> Node:
	return _ensure_asset_loader()

func get_scene_registry() -> GaussianSceneRegistry:
	return _scene_registry

func get_page_registry() -> GaussianPageRegistry:
	return _page_registry

func get_world_registry() -> RefCounted:
	return _world_registry

func get_renderer_mode() -> String:
	return _renderer_mode

# Mutually exclusive renderer switch (DG-5B Task 2.3): exactly one registry
# feeds the compositor. Switching migrates the registered nodes, tears down
# every GPU render state and rebuilds from the new registry, so the legacy
# merge path and the single-page path can never submit in the same frame.
func set_renderer_mode(mode: String) -> Error:
	if (
		mode != RENDERER_MODE_LEGACY_MERGE
		and mode != RENDERER_MODE_SINGLE_PAGE
		and mode != RENDERER_MODE_PAGED
	):
		return ERR_INVALID_PARAMETER
	if mode == _renderer_mode:
		return OK
	# The native runtime is process/device-owned. Do not let a hot switch poll
	# or consume completion messages belonging to another live backend.
	if (
		(
			mode == RENDERER_MODE_PAGED
			or _renderer_mode == RENDERER_MODE_PAGED
		)
		and (
			_gpu_state_cache.has_render_states()
			or bool(_paged_gpu_state_cache.call(&"has_live_state"))
		)
	):
		return ERR_BUSY
	var nodes: Array = _world_registry.call(&"get_registered_nodes")
	_apply_registry_result(_scene_registry.clear())
	_apply_registry_result(_page_registry.clear())
	_renderer_mode = mode
	if mode == RENDERER_MODE_PAGED:
		return OK
	var target_registry = (
		_page_registry
		if mode == RENDERER_MODE_SINGLE_PAGE
		else _scene_registry
	)
	_apply_registry_result(target_registry.clear())
	for node in nodes:
		if is_instance_valid(node):
			_apply_registry_result(target_registry.register_splat_node(node))
	_gpu_state_cache.request_cleanup()
	return OK

func get_renderer_mode_error() -> Dictionary:
	if _renderer_mode == RENDERER_MODE_SINGLE_PAGE:
		return _page_registry.get_mode_error()
	return {}

func request_projection_telemetry_sample(
	texture_size: Vector2i = Vector2i.ZERO,
	include_projection_ranges: bool = false,
	include_sort_validation: bool = false
) -> void:
	_gpu_state_cache.request_telemetry_sample(texture_size, include_projection_ranges, include_sort_validation)

func get_latest_projection_telemetry() -> Dictionary:
	if _renderer_mode == RENDERER_MODE_PAGED:
		return _paged_gpu_state_cache.call(
			&"get_latest_telemetry"
		)
	return _gpu_state_cache.get_latest_telemetry()

func get_residency_snapshot() -> Dictionary:
	if _renderer_mode == RENDERER_MODE_PAGED:
		return _paged_gpu_state_cache.call(&"get_residency_snapshot")
	return _gpu_state_cache.get_residency_snapshot()

func set_projection_workspace_budget_bytes(budget_bytes: int) -> Error:
	if _renderer_mode == RENDERER_MODE_PAGED:
		return _paged_gpu_state_cache.call(
			&"set_workspace_budget_bytes",
			budget_bytes
		)
	return _gpu_state_cache.set_workspace_budget_bytes(budget_bytes)

func get_projection_workspace_budget_bytes() -> int:
	if _renderer_mode == RENDERER_MODE_PAGED:
		return int(_paged_gpu_state_cache.call(
			&"get_workspace_budget_bytes"
		))
	return _gpu_state_cache.get_workspace_budget_bytes()

func request_projection_gpu_timing_sample(texture_size: Vector2i = Vector2i.ZERO) -> Error:
	return _gpu_state_cache.request_gpu_timing_sample(texture_size)

func get_latest_projection_gpu_timing() -> Dictionary:
	return _gpu_state_cache.get_latest_gpu_timing()

func register_splat_node(node: Node) -> void:
	_world_registry.register_reference(node)
	if _renderer_mode == RENDERER_MODE_PAGED:
		return
	_apply_registry_result(_active_registry().register_splat_node(node))

func unregister_splat_node(node: Node) -> void:
	_world_registry.unregister_reference(node)
	if _renderer_mode == RENDERER_MODE_PAGED:
		return
	_apply_registry_result(_active_registry().unregister_splat_node(node))

func mark_resource_dirty(node: Node) -> void:
	_world_registry.mark_resource_dirty(node)
	if _renderer_mode == RENDERER_MODE_PAGED:
		return
	_apply_registry_result(_active_registry().mark_resource_dirty(node))

func mark_transform_dirty(node: Node) -> void:
	_world_registry.mark_transform_dirty(node)
	if _renderer_mode == RENDERER_MODE_PAGED:
		return
	_apply_registry_result(_active_registry().mark_transform_dirty(node))

func mark_selection_dirty(node: Node) -> void:
	_world_registry.mark_selection_dirty(node)
	if _renderer_mode == RENDERER_MODE_PAGED:
		return
	# Legacy rollback registries have no selection authority of their own;
	# invalidating their transform snapshot is the existing rebuild signal.
	_apply_registry_result(_active_registry().mark_transform_dirty(node))

func shutdown() -> void:
	if _shutdown_started:
		return
	_shutdown_started = true
	if _asset_loader != null and is_instance_valid(_asset_loader):
		_asset_loader.shutdown()
	_apply_registry_result(_scene_registry.clear())
	_apply_registry_result(_page_registry.clear())
	_world_registry.clear()
	if (
		_gpu_state_cache.has_render_states()
		or bool(_paged_gpu_state_cache.call(&"has_live_state"))
	):
		RenderingServer.call_on_render_thread(_shutdown_on_render_thread)

func render_for_compositor(
	texture_size: Vector2i,
	camera_transform: Transform3D,
	camera_projection: Projection,
	camera_world_position: Vector3,
	depth_capture_alpha: float = 0.5,
	view_identity: String = "default-view",
	view_generation: int = 1
) -> Dictionary:
	if _renderer_mode == RENDERER_MODE_PAGED:
		return _paged_renderer.call(
			&"render_for_compositor",
			_paged_gpu_state_cache,
			_world_registry,
			texture_size,
			camera_transform,
			camera_projection,
			camera_world_position,
			view_identity,
			view_generation,
			depth_capture_alpha
		)
	var registry = _active_registry()
	if _renderer_mode == RENDERER_MODE_SINGLE_PAGE:
		var mode_error: Dictionary = registry.get_mode_error()
		if not mode_error.is_empty():
			return {"error": mode_error.duplicate(true)}
	return _renderer.render_for_compositor(
		_gpu_state_cache,
		registry,
		texture_size,
		camera_transform,
		camera_projection,
		camera_world_position,
		depth_capture_alpha
	)

func _active_registry():
	return _page_registry if _renderer_mode == RENDERER_MODE_SINGLE_PAGE else _scene_registry

func _cleanup_on_render_thread() -> void:
	_gpu_state_cache.cleanup_all()

func _shutdown_on_render_thread() -> void:
	_gpu_state_cache.shutdown()
	_paged_gpu_state_cache.call(&"shutdown")

func _ensure_asset_loader() -> Node:
	if _asset_loader != null and is_instance_valid(_asset_loader):
		return _asset_loader
	if not is_inside_tree():
		return null
	_asset_loader = AssetLoaderScript.new()
	_asset_loader.name = "_GaussianAssetLoader"
	add_child(_asset_loader)
	return _asset_loader

func _apply_registry_result(result: Dictionary) -> void:
	if result.is_empty():
		return
	if result.get("request_cleanup", false):
		_gpu_state_cache.request_cleanup()
	if result.has("require_gpu_rebuild") and bool(result["require_gpu_rebuild"]):
		_gpu_state_cache.mark_all_render_states_needs_gpu_rebuild()
	if result.has("require_splat_upload") and bool(result["require_splat_upload"]):
		_gpu_state_cache.mark_all_render_states_needs_splat_upload(true)
	if result.has("require_instance_upload") and bool(result["require_instance_upload"]):
		_gpu_state_cache.mark_all_render_states_needs_instance_upload(true)

func _notification(what: int) -> void:
	if (
		what == NOTIFICATION_PREDELETE
		and (
			_gpu_state_cache.has_render_states()
			or bool(_paged_gpu_state_cache.call(&"has_live_state"))
		)
	):
		RenderingServer.call_on_render_thread(_shutdown_on_render_thread)
