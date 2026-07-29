@tool
@icon("res://addons/gdgs/editor/icons/gaussian_splat_node.svg")
extends VisualInstance3D
class_name GaussianSplatNode

const MANAGER_SCRIPT := preload("res://addons/gdgs/runtime/render/gaussian_render_manager.gd")
const ASSET_LOADER_SCRIPT := preload("res://addons/gdgs/runtime/loading/gaussian_asset_loader.gd")
const LOAD_CONTRACT := preload("res://addons/gdgs/runtime/loading/gaussian_load_contract.gd")
const MANAGER_NODE_NAME := "_GdgsGaussianRenderManager"
const MANAGER_PENDING_META := "_gdgs_manager_pending"
const MAX_MANAGER_READY_ATTEMPTS := 16

enum LoadState {
	UNLOADED = 0,
	QUEUED = 1,
	LOADING = 2,
	LOADED = 3,
	FAILED = 4
}

signal load_state_changed(state: int)
signal load_progress(value: float)
signal load_completed(resource: GaussianResource)
signal load_failed(error: int, error_id: String, message: String)
signal unloaded

## The lazy source workflow. Assignment only canonicalizes the path; it never
## opens or decodes the source. Call request_load() explicitly when wanted.
@export_file("*.ply", "*.compressed.ply", "*.splat", "*.sog") var source_path: String:
	set(value):
		_set_source_path(value)
	get:
		return _source_path

## Legacy eager compatibility. Godot resolves this Resource dependency while
## loading the scene, so use source_path for new lazy-loading scenes.
@export var gaussian: GaussianResource:
	set(value):
		_set_legacy_gaussian(value)
	get:
		return _legacy_gaussian

var load_state: int:
	get:
		return _load_state

var progress: float:
	get:
		return _progress

var last_error_code: int:
	get:
		return _last_error_code

var last_error_id: String:
	get:
		return _last_error_id

var last_error: String:
	get:
		return _last_error

var loaded_gaussian: GaussianResource:
	get:
		return _runtime_gaussian

var _source_path := ""
var _source_path_validation := ""
var _legacy_gaussian: GaussianResource
var _runtime_gaussian: GaussianResource
var _connected_gaussian: GaussianResource
var _local_aabb := AABB()
var _aabb_valid := false

var _load_state := LoadState.UNLOADED
var _progress := 0.0
var _last_error_code := OK
var _last_error_id := ""
var _last_error := ""
var _request_generation := 0
var _request_id := 0
var _lease: Variant = null
var _asset_loader: Node

var _registered_with_manager := false
var _registered_manager: Node

static func get_model_orientation_correction() -> Transform3D:
	return Transform3D(Basis.from_euler(Vector3(0.0, 0.0, -PI)), Vector3.ZERO)

func _enter_tree() -> void:
	_apply_default_orientation_if_needed()
	set_notify_transform(true)
	_refresh_active_resource()
	if _source_path.is_empty() and _legacy_gaussian != null:
		call_deferred("_register_with_manager")

func _ready() -> void:
	_refresh_active_resource()

func _exit_tree() -> void:
	if not _source_path.is_empty():
		_release_source_lifecycle(false)
	else:
		_unregister_from_manager()
	_disconnect_active_gaussian()
	_disconnect_loader()

func _get_aabb() -> AABB:
	return _local_aabb if _aabb_valid else AABB()

func get_active_gaussian() -> GaussianResource:
	if not _source_path.is_empty():
		return _runtime_gaussian
	return _legacy_gaussian

func request_load() -> Error:
	if _source_path.is_empty():
		return _reject_request(ERR_UNCONFIGURED, "GDGS_SOURCE_NOT_SET", "Set source_path before requesting a Gaussian load")
	if not is_inside_tree():
		return _reject_request(ERR_UNCONFIGURED, "GDGS_NODE_OUTSIDE_TREE", "GaussianSplatNode must be inside the scene tree before loading")
	if _load_state == LoadState.LOADED and _lease != null:
		return OK
	if _request_id > 0 and (_load_state == LoadState.QUEUED or _load_state == LoadState.LOADING):
		return OK

	_request_generation += 1
	_request_id = 0
	_clear_error()
	_set_progress(0.0, true)
	_set_load_state(LoadState.QUEUED)

	var manager := _ensure_manager()
	if manager == null:
		call_deferred("_submit_when_manager_ready", _request_generation, 0)
		return OK
	return _submit_load(manager, _request_generation)

func cancel_load() -> void:
	if _request_id <= 0 and _load_state != LoadState.QUEUED and _load_state != LoadState.LOADING:
		return
	var request_to_cancel := _request_id
	_request_id = 0
	_request_generation += 1
	if request_to_cancel > 0 and _asset_loader != null and is_instance_valid(_asset_loader):
		_asset_loader.cancel_request(request_to_cancel)
	_set_progress(0.0, true)
	_set_load_state(LoadState.UNLOADED)

func unload() -> void:
	if _source_path.is_empty():
		return
	_release_source_lifecycle(true)

func _set_source_path(value: String) -> void:
	var requested := value.strip_edges().replace("\\", "/")
	var canonical := requested
	var validation_message := ""
	if not requested.is_empty():
		var path_result: Dictionary = ASSET_LOADER_SCRIPT.canonicalize_project_path(requested)
		if path_result.get("ok", false):
			canonical = String(path_result["source_path"])
		else:
			validation_message = String(path_result.get("message", "Invalid Gaussian source path"))
	if _source_path == canonical and _source_path_validation == validation_message:
		return

	if not _source_path.is_empty():
		_release_source_lifecycle(true)
	else:
		_unregister_from_manager()
	_source_path = canonical
	_source_path_validation = validation_message
	_runtime_gaussian = null
	_refresh_active_resource()
	_clear_error()
	_set_progress(0.0, true)
	_set_load_state(LoadState.UNLOADED)
	if _source_path.is_empty() and _legacy_gaussian != null and is_inside_tree():
		call_deferred("_register_with_manager")
	_update_editor_state()

func _set_legacy_gaussian(value: GaussianResource) -> void:
	if _legacy_gaussian == value:
		return
	var legacy_is_active := _source_path.is_empty()
	if legacy_is_active:
		_unregister_from_manager()
	_legacy_gaussian = value
	_refresh_active_resource()
	if legacy_is_active and _legacy_gaussian != null and is_inside_tree():
		call_deferred("_register_with_manager")
	_update_editor_state()

func _submit_when_manager_ready(generation: int, attempt: int) -> void:
	if generation != _request_generation or _load_state != LoadState.QUEUED or not is_inside_tree():
		return
	var manager := _ensure_manager()
	if manager == null:
		if attempt < MAX_MANAGER_READY_ATTEMPTS:
			call_deferred("_submit_when_manager_ready", generation, attempt + 1)
		else:
			_apply_failure(ERR_TIMEOUT, "GDGS_MANAGER_TIMEOUT", "Gaussian render manager did not become ready")
		return
	_submit_load(manager, generation)

func _submit_load(manager: Node, generation: int) -> Error:
	if generation != _request_generation:
		return ERR_SKIP
	if not manager.has_method("get_asset_loader"):
		return _reject_request(ERR_UNAVAILABLE, "GDGS_LOADER_UNAVAILABLE", "Gaussian asset loader is unavailable")
	var loader: Node = manager.get_asset_loader()
	if loader == null:
		return _reject_request(ERR_UNAVAILABLE, "GDGS_LOADER_UNAVAILABLE", "Gaussian asset loader is unavailable")
	_connect_loader(loader)
	var result: Dictionary = loader.request_load(_source_path, get_instance_id(), generation)
	if not result.get("ok", false):
		var error := int(result.get("error", FAILED))
		_apply_failure(error, String(result.get("error_id", "GDGS_LOAD_REJECTED")), String(result.get("message", "Gaussian load request was rejected")))
		return error
	_request_id = int(result["request_id"])
	_set_load_state(int(result.get("state", LoadState.QUEUED)))
	return OK

func _connect_loader(loader: Node) -> void:
	if _asset_loader == loader:
		return
	_disconnect_loader()
	_asset_loader = loader
	loader.request_state_changed.connect(_on_loader_state_changed)
	loader.request_progress.connect(_on_loader_progress)
	loader.request_completed.connect(_on_loader_completed)
	loader.request_failed.connect(_on_loader_failed)
	loader.request_cancelled.connect(_on_loader_cancelled)
	loader.shutting_down.connect(_on_loader_shutting_down)

func _disconnect_loader() -> void:
	if _asset_loader == null or not is_instance_valid(_asset_loader):
		_asset_loader = null
		return
	for signal_name in [
		&"request_state_changed",
		&"request_progress",
		&"request_completed",
		&"request_failed",
		&"request_cancelled",
		&"shutting_down"
	]:
		var callback := Callable(self, "_on_loader_%s" % String(signal_name).trim_prefix("request_").replace("shutting_down", "shutting_down"))
		if _asset_loader.is_connected(signal_name, callback):
			_asset_loader.disconnect(signal_name, callback)
	_asset_loader = null

func _on_loader_state_changed(request_id: int, generation: int, state: int) -> void:
	if not _matches_request(request_id, generation):
		return
	_set_load_state(state)

func _on_loader_progress(request_id: int, generation: int, value: float) -> void:
	if not _matches_request(request_id, generation):
		return
	_set_progress(value)

func _on_loader_completed(request_id: int, generation: int, lease: Variant) -> void:
	if not _matches_request(request_id, generation):
		return
	if not is_inside_tree() or _source_path.is_empty():
		if _asset_loader != null and is_instance_valid(_asset_loader):
			_asset_loader.release_lease(lease)
		return
	var resource: Variant = lease.resource
	if not resource is GaussianResource:
		_asset_loader.release_lease(lease)
		_apply_failure(ERR_INVALID_DATA, "GDGS_INVALID_RESOURCE", "Gaussian loader published an invalid resource")
		return
	_request_id = 0
	_lease = lease
	_runtime_gaussian = resource
	_refresh_active_resource()
	_set_progress(1.0)
	_set_load_state(LoadState.LOADED)
	_register_with_manager()
	load_completed.emit(_runtime_gaussian)

func _on_loader_failed(request_id: int, generation: int, error: int, error_id: String, message: String) -> void:
	if not _matches_request(request_id, generation):
		return
	_request_id = 0
	_apply_failure(error, error_id, message)

func _on_loader_cancelled(request_id: int, generation: int) -> void:
	if not _matches_request(request_id, generation):
		return
	_request_id = 0
	_set_progress(0.0, true)
	_set_load_state(LoadState.UNLOADED)

func _on_loader_shutting_down(loader: Node) -> void:
	if loader != _asset_loader:
		return
	_release_source_lifecycle(false)
	_disconnect_loader()

func _matches_request(request_id: int, generation: int) -> bool:
	return request_id == _request_id and generation == _request_generation

func _release_source_lifecycle(emit_signal: bool) -> void:
	var had_activity := _request_id > 0 or _lease != null or _runtime_gaussian != null or _load_state != LoadState.UNLOADED
	var request_to_cancel := _request_id
	_request_id = 0
	_request_generation += 1
	if request_to_cancel > 0 and _asset_loader != null and is_instance_valid(_asset_loader):
		_asset_loader.cancel_request(request_to_cancel)
	_unregister_from_manager()
	if _lease != null and _asset_loader != null and is_instance_valid(_asset_loader):
		_asset_loader.release_lease(_lease)
	_lease = null
	_runtime_gaussian = null
	_refresh_active_resource()
	_clear_error()
	_set_progress(0.0, true)
	_set_load_state(LoadState.UNLOADED)
	if emit_signal and had_activity:
		unloaded.emit()

func _reject_request(error: int, error_id: String, message: String) -> Error:
	_apply_failure(error, error_id, message)
	return error

func _apply_failure(error: int, error_id: String, message: String) -> void:
	_last_error_code = error
	_last_error_id = error_id
	_last_error = message
	_set_load_state(LoadState.FAILED)
	load_failed.emit(error, error_id, message)
	_update_editor_state()

func _clear_error() -> void:
	_last_error_code = OK
	_last_error_id = ""
	_last_error = ""

func _set_load_state(value: int) -> void:
	var clamped := clampi(value, LoadState.UNLOADED, LoadState.FAILED)
	if _load_state == clamped:
		return
	_load_state = clamped
	load_state_changed.emit(_load_state)
	_update_editor_state()

func _set_progress(value: float, allow_reset: bool = false) -> void:
	var normalized := clampf(value, 0.0, 1.0)
	if not allow_reset:
		normalized = maxf(normalized, _progress)
	if is_equal_approx(_progress, normalized):
		return
	_progress = normalized
	load_progress.emit(_progress)

func _refresh_active_resource() -> void:
	var active := get_active_gaussian()
	if _connected_gaussian != active:
		_disconnect_active_gaussian()
		_connected_gaussian = active
		if _connected_gaussian != null:
			_connected_gaussian.changed.connect(_on_active_gaussian_changed)
	_rebuild_aabb()
	if Engine.is_editor_hint():
		update_gizmos()

func _disconnect_active_gaussian() -> void:
	if _connected_gaussian != null:
		var callback := Callable(self, "_on_active_gaussian_changed")
		if _connected_gaussian.changed.is_connected(callback):
			_connected_gaussian.changed.disconnect(callback)
	_connected_gaussian = null

func _on_active_gaussian_changed() -> void:
	_rebuild_aabb()
	if _registered_with_manager:
		_mark_manager_dirty()
	if Engine.is_editor_hint():
		update_gizmos()

func _rebuild_aabb() -> void:
	_aabb_valid = false
	var active := get_active_gaussian()
	if active == null:
		_local_aabb = AABB()
		return
	_local_aabb = active.aabb
	_aabb_valid = true

func _apply_default_orientation_if_needed() -> void:
	if not transform.basis.orthonormalized().is_equal_approx(Basis.IDENTITY):
		return
	transform = transform * get_model_orientation_correction()

func _register_with_manager() -> void:
	if _registered_with_manager or not is_inside_tree() or is_queued_for_deletion() or get_active_gaussian() == null:
		return
	var manager := _ensure_manager()
	if manager != null and manager.has_method("register_splat_node"):
		manager.register_splat_node(self)
		_registered_manager = manager
		_registered_with_manager = true
	elif manager == null:
		call_deferred("_register_with_manager")

func _unregister_from_manager() -> void:
	if not _registered_with_manager:
		return
	var manager := _registered_manager
	if manager != null and is_instance_valid(manager) and manager.has_method("unregister_splat_node"):
		manager.unregister_splat_node(self)
	_registered_manager = null
	_registered_with_manager = false

func _mark_manager_dirty() -> void:
	if _registered_manager != null and is_instance_valid(_registered_manager) and _registered_manager.has_method("mark_resource_dirty"):
		_registered_manager.mark_resource_dirty(self)

func _mark_manager_transform_dirty() -> void:
	if _registered_manager != null and is_instance_valid(_registered_manager) and _registered_manager.has_method("mark_transform_dirty"):
		_registered_manager.mark_transform_dirty(self)

func _ensure_manager() -> Node:
	if not is_inside_tree():
		return null
	var tree := get_tree()
	if tree == null or tree.root == null:
		return null
	var root_node: Node = tree.root
	var manager := root_node.get_node_or_null(MANAGER_NODE_NAME)
	if manager != null:
		return manager
	if root_node.has_meta(MANAGER_PENDING_META):
		return null
	root_node.set_meta(MANAGER_PENDING_META, true)
	manager = MANAGER_SCRIPT.new()
	manager.name = MANAGER_NODE_NAME
	root_node.call_deferred("add_child", manager)
	root_node.call_deferred("remove_meta", MANAGER_PENDING_META)
	return null

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if not _source_path_validation.is_empty():
		warnings.push_back(_source_path_validation)
	if not _source_path.is_empty() and _legacy_gaussian != null:
		warnings.push_back("source_path is authoritative; the legacy GaussianResource assignment is ignored until source_path is cleared.")
	elif _source_path.is_empty() and _legacy_gaussian != null:
		warnings.push_back("Legacy GaussianResource mode loads eagerly with the scene. Assign source_path to use explicit lazy loading.")
	return warnings

func _update_editor_state() -> void:
	if Engine.is_editor_hint():
		update_configuration_warnings()
		notify_property_list_changed()

func _notification(what: int) -> void:
	if (what == NOTIFICATION_TRANSFORM_CHANGED or what == NOTIFICATION_VISIBILITY_CHANGED) and _registered_with_manager and is_inside_tree():
		_mark_manager_transform_dirty()
