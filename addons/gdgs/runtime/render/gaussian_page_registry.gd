@tool
extends RefCounted
class_name GaussianPageRegistry

# Single-page residency registry (DG-5B Task 2.3). Each standalone
# GaussianResource owns exactly one immutable page; nodes referencing the
# same resource share that page through per-instance transforms. More than
# one distinct resource is a stable, explicit failure: the multi-page
# unified overlap stream arrives with Section 4 and must not be simulated
# by silently merging pages here.

const FLOATS_PER_SPLAT := 60
const BYTES_PER_FLOAT := 4
const MODE_ERROR_MULTI_RESOURCE := "GDGS_SINGLE_PAGE_MULTI_RESOURCE"
const GaussianDiagnostics = preload("res://addons/gdgs/runtime/diagnostics/gaussian_diagnostics.gd")

class PageEntry:
	extends RefCounted

	var resource: Resource
	var point_count := 0
	var point_data_byte := PackedByteArray()
	var aabb := AABB()
	var content_identity := ""
	var content_hash := ""
	var nodes: Array[Node] = []

var _splat_nodes: Array[Node] = []
var _pages: Dictionary = {}
var _mode_error: Dictionary = {}

var _point_count := 0
var _point_data_byte := PackedByteArray()
var _splat_instance_ids_byte := PackedByteArray()
var _instance_count := 0
var _instance_transforms_byte := PackedByteArray()

func register_splat_node(node: Node) -> Dictionary:
	if node == null or _splat_nodes.has(node):
		return {}
	_splat_nodes.push_back(node)
	return _sync_pages()

func unregister_splat_node(node: Node) -> Dictionary:
	_splat_nodes.erase(node)
	return _sync_pages()

func mark_resource_dirty(node: Node) -> Dictionary:
	if node == null:
		return {}
	return _sync_pages()

func mark_transform_dirty(node: Node) -> Dictionary:
	if node == null:
		return {}
	return _sync_instance_transforms()

func has_gpu_data() -> bool:
	return _mode_error.is_empty() and _point_count > 0 and not _point_data_byte.is_empty()

func get_mode_error() -> Dictionary:
	return _mode_error.duplicate(true)

func get_point_count() -> int:
	return _point_count

func get_point_data_byte() -> PackedByteArray:
	return _point_data_byte

func get_splat_instance_ids_byte() -> PackedByteArray:
	return _splat_instance_ids_byte

func get_instance_count() -> int:
	return _instance_count

func get_instance_transforms_byte() -> PackedByteArray:
	return _instance_transforms_byte

func get_page_count() -> int:
	return _pages.size()

func get_resident_page_descriptor() -> Dictionary:
	if _pages.size() != 1 or not _mode_error.is_empty():
		return {}
	var page: PageEntry = _pages.values()[0]
	return {
		"content_identity": page.content_identity,
		"content_hash": page.content_hash,
		"schema_version": 1,
		"layout_version": 1,
		"shader_version": 1,
		"point_count": page.point_count,
		"aabb_min": page.aabb.position,
		"aabb_max": page.aabb.end,
		"coordinate_space": "model_local_meters",
		"unaligned_bytes": page.point_data_byte.size()
	}

func is_registered(node: Node) -> bool:
	return node != null and _splat_nodes.has(node)

func get_registered_node_count() -> int:
	_prune_splat_nodes()
	return _splat_nodes.size()

func get_registered_nodes() -> Array[Node]:
	_prune_splat_nodes()
	return _splat_nodes.duplicate()

func clear() -> Dictionary:
	_splat_nodes.clear()
	_pages.clear()
	_mode_error = {}
	_reset_merged_state()
	GaussianDiagnostics.set_registry_metrics(0, 0)
	return _change_result(true, true, true, true)

func _sync_pages() -> Dictionary:
	_prune_splat_nodes()

	var next_pages: Dictionary = {}
	for node in _splat_nodes:
		if not is_instance_valid(node):
			continue
		var gaussian: Resource = _get_node_gaussian(node)
		if gaussian == null:
			continue
		var page: PageEntry = next_pages.get(gaussian, null)
		if page == null:
			page = _pages.get(gaussian, null)
			if page == null:
				page = _build_page(gaussian)
			if page == null:
				continue
			next_pages[gaussian] = page
			page.nodes.clear()
		page.nodes.push_back(node)
	_pages = next_pages

	if _pages.size() > 1:
		_reset_merged_state()
		_mode_error = {
			"schema": "gdgs-single-page-mode-error-v1",
			"error_id": MODE_ERROR_MULTI_RESOURCE,
			"message": "Single-page renderer admits exactly one distinct GaussianResource page; %d were registered. The multi-page unified overlap stream arrives with DG-5B Section 4." % _pages.size(),
			"registered_pages": _pages.size(),
			"captured_usec": Time.get_ticks_usec()
		}
		GaussianDiagnostics.set_registry_metrics(_splat_nodes.size(), 0)
		return _change_result(true, true, false, false)
	_mode_error = {}

	if _pages.is_empty():
		_reset_merged_state()
		GaussianDiagnostics.set_registry_metrics(_splat_nodes.size(), 0)
		return _change_result(true, false, false, false)

	var page: PageEntry = _pages.values()[0]
	var merged_instance_ids := PackedInt32Array()
	var merged_instance_transforms := PackedFloat32Array()
	var total_point_count := 0
	var next_instance_index := 0
	for node in page.nodes:
		if not is_instance_valid(node):
			continue
		var node_instance_ids := PackedInt32Array()
		node_instance_ids.resize(page.point_count * 2)
		for index in range(page.point_count):
			node_instance_ids[index * 2] = next_instance_index
			node_instance_ids[index * 2 + 1] = index
		merged_instance_ids.append_array(node_instance_ids)
		merged_instance_transforms.append_array(_transform_to_column_major_packed_floats(
			_get_node_transform(node),
			_get_node_visibility(node)
		))
		total_point_count += page.point_count
		next_instance_index += 1

	var merged_instance_ids_byte := merged_instance_ids.to_byte_array()
	var merged_instance_transforms_byte := merged_instance_transforms.to_byte_array()
	if total_point_count <= 0:
		_reset_merged_state()
		GaussianDiagnostics.set_registry_metrics(_splat_nodes.size(), 0)
		return _change_result(true, false, false, false)

	var count_changed := total_point_count != _point_count
	var payload_changed := page.point_data_byte != _point_data_byte
	var ids_changed := merged_instance_ids_byte != _splat_instance_ids_byte
	var transforms_changed := merged_instance_transforms_byte != _instance_transforms_byte

	_point_count = total_point_count
	_point_data_byte = page.point_data_byte
	_splat_instance_ids_byte = merged_instance_ids_byte
	_instance_count = next_instance_index
	_instance_transforms_byte = merged_instance_transforms_byte
	GaussianDiagnostics.set_registry_metrics(_splat_nodes.size(), _point_data_byte.size())

	return _change_result(
		false,
		count_changed or payload_changed or ids_changed,
		payload_changed or ids_changed,
		transforms_changed
	)

func _build_page(gaussian: Resource) -> PageEntry:
	var point_count := int(gaussian.get("point_count"))
	var aabb_value: Variant = gaussian.get("aabb")
	var point_data := PackedByteArray()
	if gaussian.has_method("get_canonical_point_bytes"):
		point_data = gaussian.call("get_canonical_point_bytes")
	else:
		var point_data_value: Variant = gaussian.get("point_data_byte")
		if typeof(point_data_value) == TYPE_PACKED_BYTE_ARRAY:
			point_data = point_data_value
	if (
		point_count <= 0
		or point_data.is_empty()
		or typeof(aabb_value) != TYPE_AABB
	):
		return null
	var expected_size := point_count * FLOATS_PER_SPLAT * BYTES_PER_FLOAT
	if point_data.size() != expected_size:
		push_warning("[gdgs] GaussianResource data size mismatch. Expected %d, got %d bytes." % [expected_size, point_data.size()])
		return null
	var page := PageEntry.new()
	page.resource = gaussian
	page.point_count = point_count
	page.point_data_byte = point_data
	page.aabb = aabb_value
	var resource_path := String(gaussian.resource_path)
	page.content_identity = (
		"resource-%s" % resource_path.sha256_text()
		if not resource_path.is_empty()
		else "memory-%d" % gaussian.get_instance_id()
	)
	page.content_hash = _sha256_bytes(point_data)
	return page

func _sync_instance_transforms() -> Dictionary:
	if _pages.size() != 1 or not _mode_error.is_empty():
		return {}
	var page: PageEntry = _pages.values()[0]
	var transforms := PackedFloat32Array()
	for node in page.nodes:
		if not is_instance_valid(node):
			continue
		transforms.append_array(_transform_to_column_major_packed_floats(
			_get_node_transform(node),
			_get_node_visibility(node)
		))
	var next_bytes := transforms.to_byte_array()
	if next_bytes == _instance_transforms_byte:
		return {}
	var size_changed := next_bytes.size() != _instance_transforms_byte.size()
	_instance_transforms_byte = next_bytes
	return _change_result(false, size_changed, false, true)

func _reset_merged_state() -> void:
	_point_count = 0
	_point_data_byte = PackedByteArray()
	_splat_instance_ids_byte = PackedByteArray()
	_instance_count = 0
	_instance_transforms_byte = PackedByteArray()

func _get_node_gaussian(node: Node) -> Resource:
	if node.has_method("get_active_gaussian"):
		var active: Variant = node.call("get_active_gaussian")
		return active if active is Resource else null
	var value: Variant = node.get("gaussian")
	return value if value is Resource else null

func _get_node_transform(node: Node) -> Transform3D:
	if node is Node3D:
		return (node as Node3D).global_transform
	return Transform3D.IDENTITY

func _get_node_visibility(node: Node) -> bool:
	if node is Node3D:
		return (node as Node3D).is_visible_in_tree()
	return true

func _transform_to_column_major_packed_floats(transform: Transform3D, visibility: bool) -> PackedFloat32Array:
	return PackedFloat32Array([
		transform.basis.x[0], transform.basis.x[1], transform.basis.x[2], 1.0 if visibility else 0.0,
		transform.basis.y[0], transform.basis.y[1], transform.basis.y[2], 0.0,
		transform.basis.z[0], transform.basis.z[1], transform.basis.z[2], 0.0,
		transform.origin.x, transform.origin.y, transform.origin.z, 1.0
	])

func _prune_splat_nodes() -> void:
	for index in range(_splat_nodes.size() - 1, -1, -1):
		if not is_instance_valid(_splat_nodes[index]):
			_splat_nodes.remove_at(index)

func _sha256_bytes(bytes: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	if hashing.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if hashing.update(bytes) != OK:
		return ""
	return hashing.finish().hex_encode()

func _change_result(
	request_cleanup: bool,
	require_gpu_rebuild: bool,
	require_splat_upload: bool,
	require_instance_upload: bool
) -> Dictionary:
	return {
		"request_cleanup": request_cleanup,
		"require_gpu_rebuild": require_gpu_rebuild,
		"require_splat_upload": require_splat_upload,
		"require_instance_upload": require_instance_upload
	}
