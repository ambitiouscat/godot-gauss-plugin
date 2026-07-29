@tool
extends RefCounted
class_name GaussianWorldRegistry

# Main-thread world ownership for the DG-5B paged renderer. Immutable
# resources are represented once as physical page candidates, while every
# standalone or tileset instance remains an independent per-view reference.
# This registry never concatenates attribute payloads and never owns GPU RIDs.

const FLOATS_PER_SPLAT := 60
const BYTES_PER_FLOAT := 4
const UINT32_MAX := 0xffff_ffff

const SOURCE_STANDALONE := "standalone"
const SOURCE_TILESET := "tileset"
const ERROR_PAGE_ID_EXHAUSTED := "GDGS_PAGE_ID_EXHAUSTED"
const ERROR_INVALID_VIEW := "GDGS_INVALID_VIEW_REFERENCE_REQUEST"
const ERROR_ACTIVE_RANGE_OVERFLOW := "GDGS_ACTIVE_REFERENCE_RANGE_OVERFLOW"

class PageEntry:
	extends RefCounted

	var resource: Resource
	var page_id := 0
	var point_count := 0
	var point_data_byte := PackedByteArray()
	var aabb := AABB()
	var content_identity := ""
	var content_hash := ""
	var nodes: Array[Node] = []

var _reference_nodes: Array[Node] = []
var _pages: Dictionary = {}
var _resource_pages: Dictionary = {}
var _page_ids: Dictionary = {}
var _next_page_id := 1
var _revision := 0
var _last_error: Dictionary = {}

func register_reference(node: Node) -> Dictionary:
	if node == null or _reference_nodes.has(node):
		return _change_result(false, false, false)
	_reference_nodes.push_back(node)
	return _sync_pages(null, true)

func unregister_reference(node: Node) -> Dictionary:
	if node == null or not _reference_nodes.has(node):
		return _change_result(false, false, false)
	_reference_nodes.erase(node)
	return _sync_pages(null, true)

func mark_resource_dirty(node: Node) -> Dictionary:
	if node == null or not _reference_nodes.has(node):
		return _change_result(false, false, false)
	return _sync_pages(_get_node_gaussian(node), false)

func mark_transform_dirty(node: Node) -> Dictionary:
	if node == null or not _reference_nodes.has(node):
		return _change_result(false, false, false)
	_revision += 1
	return _change_result(true, false, false)

func mark_selection_dirty(node: Node) -> Dictionary:
	# Selection remains owned by the external spatial/Cesium bridge. The
	# registry only invalidates its per-view active-reference snapshot.
	if node == null or not _reference_nodes.has(node):
		return _change_result(false, false, false)
	_revision += 1
	return _change_result(true, false, false)

func get_revision() -> int:
	return _revision

func get_page_count() -> int:
	return _pages.size()

func get_active_reference_count() -> int:
	_prune_reference_nodes()
	return _reference_nodes.size()

func get_registered_nodes() -> Array:
	_prune_reference_nodes()
	return _reference_nodes.duplicate()

func get_last_error() -> Dictionary:
	return _last_error.duplicate(true)

func get_resident_page_candidates() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var pages: Array = _pages.values()
	pages.sort_custom(func(left: PageEntry, right: PageEntry) -> bool:
		return left.page_id < right.page_id
	)
	for page: PageEntry in pages:
		result.push_back({
			"page_id": page.page_id,
			"content_identity": page.content_identity,
			"content_hash": page.content_hash,
			"schema_version": 1,
			"layout_version": 1,
			"shader_version": 1,
			"point_count": page.point_count,
			"aabb_min": page.aabb.position,
			"aabb_max": page.aabb.end,
			"coordinate_space": "model_local_meters",
			"unaligned_bytes": page.point_data_byte.size(),
			"point_data_byte": page.point_data_byte
		})
	return result

func build_active_reference_list(
	view_identity: String,
	view_generation: int
) -> Dictionary:
	if view_identity.is_empty() or view_generation <= 0:
		return {
			"accepted": false,
			"error_id": ERROR_INVALID_VIEW,
			"active_references": []
		}

	_prune_reference_nodes()
	var references: Array[Dictionary] = []
	for page_value: Variant in _pages.values():
		var page: PageEntry = page_value
		for node: Node in page.nodes:
			if (
				not is_instance_valid(node)
				or not _get_node_visibility(node)
				or not _is_selected_for_view(node, view_identity)
			):
				continue
			var source_kind := _get_reference_source(node)
			if (
				source_kind != SOURCE_STANDALONE
				and source_kind != SOURCE_TILESET
			):
				continue
			references.push_back({
				"view_identity": view_identity,
				"view_generation": view_generation,
				"source_kind": source_kind,
				"owner_identity": _get_owner_identity(node),
				"selection_generation":
					_get_selection_generation(
						node,
						view_identity
					),
				"reference_id": int(node.get_instance_id()),
				"page_id": page.page_id,
				"content_identity": page.content_identity,
				"content_hash": page.content_hash,
				"layout_version": 1,
				"shader_version": 1,
				"point_count": page.point_count,
				"model_transform": _get_node_transform(node)
			})

	references.sort_custom(_active_reference_less)
	var output_base := 0
	var source_counts := {
		SOURCE_STANDALONE: 0,
		SOURCE_TILESET: 0
	}
	var referenced_pages: Dictionary = {}
	for reference: Dictionary in references:
		reference["output_base"] = output_base
		var point_count := int(reference["point_count"])
		if output_base > UINT32_MAX - point_count:
			return {
				"accepted": false,
				"error_id": ERROR_ACTIVE_RANGE_OVERFLOW,
				"active_references": []
			}
		output_base += point_count
		var source_kind := String(reference["source_kind"])
		source_counts[source_kind] = int(source_counts[source_kind]) + 1
		referenced_pages[int(reference["page_id"])] = true

	return {
		"accepted": true,
		"schema": "gdgs-gaussian-active-reference-list-v1",
		"view_identity": view_identity,
		"view_generation": view_generation,
		"registry_revision": _revision,
		"active_references": references,
		"active_reference_count": references.size(),
		"active_page_count": referenced_pages.size(),
		"logical_splat_count": output_base,
		"standalone_reference_count": int(
			source_counts[SOURCE_STANDALONE]
		),
		"tileset_reference_count": int(source_counts[SOURCE_TILESET])
	}

func snapshot() -> Dictionary:
	var resident_payload_bytes := 0
	var physical_splats := 0
	var logical_reference_splats := 0
	for page_value: Variant in _pages.values():
		var page: PageEntry = page_value
		resident_payload_bytes += page.point_data_byte.size()
		physical_splats += page.point_count
		logical_reference_splats += page.point_count * page.nodes.size()
	return {
		"schema": "gdgs-gaussian-world-registry-v1",
		"revision": _revision,
		"physical_page_count": _pages.size(),
		"reference_count": get_active_reference_count(),
		"physical_splat_count": physical_splats,
		"logical_reference_splat_count": logical_reference_splats,
		"resident_payload_bytes": resident_payload_bytes,
		"last_error": _last_error.duplicate(true)
	}

func clear() -> Dictionary:
	var changed := not _reference_nodes.is_empty() or not _pages.is_empty()
	_reference_nodes.clear()
	_pages.clear()
	_resource_pages.clear()
	_page_ids.clear()
	_next_page_id = 1
	_last_error = {}
	if changed:
		_revision += 1
	return _change_result(changed, changed, changed)

func _sync_pages(
	force_rebuild_resource: Resource,
	reference_set_changed: bool
) -> Dictionary:
	reference_set_changed = _prune_reference_nodes() or reference_set_changed
	_last_error = {}
	var previous_page_count := _pages.size()
	var next_pages: Dictionary = {}
	var next_resource_pages: Dictionary = {}
	var payload_changed := false

	for node: Node in _reference_nodes:
		if not is_instance_valid(node):
			continue
		var gaussian := _get_node_gaussian(node)
		if gaussian == null:
			continue
		var candidate: PageEntry = (
			null
			if gaussian == force_rebuild_resource
			else _resource_pages.get(gaussian, null)
		)
		if candidate == null:
			candidate = _build_page(gaussian)
			payload_changed = true
		if candidate == null:
			continue
		var page: PageEntry = next_pages.get(
			candidate.content_identity,
			null
		)
		if page == null:
			page = candidate
			next_pages[page.content_identity] = page
			page.nodes.clear()
		page.nodes.push_back(node)
		next_resource_pages[gaussian] = page

	var page_set_changed := (
		previous_page_count != next_pages.size()
		or not _same_resource_set(_pages, next_pages)
	)
	_pages = next_pages
	_resource_pages = next_resource_pages
	var changed := (
		reference_set_changed
		or page_set_changed
		or payload_changed
	)
	if changed:
		_revision += 1
	return _change_result(changed, page_set_changed, payload_changed)

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
		or point_data.size()
			!= point_count * FLOATS_PER_SPLAT * BYTES_PER_FLOAT
	):
		return null

	var content_hash := _sha256_bytes(point_data)
	if content_hash.is_empty():
		return null
	var resource_path := String(gaussian.resource_path)
	var source_identity := (
		String(gaussian.get_meta(&"gdgs_content_identity"))
		if gaussian.has_meta(&"gdgs_content_identity")
		else (
			"resource-%s" % resource_path.sha256_text()
			if not resource_path.is_empty()
			else "memory-%d" % gaussian.get_instance_id()
		)
	)
	# The native arena indexes live pages by content identity. Bind immutable
	# bytes into that identity so a changed source generation can coexist with
	# its still-renderable predecessor during an atomic replacement.
	var content_identity := (
		"%s-%s" % [source_identity, content_hash]
	)
	var page_id := int(_page_ids.get(content_identity, 0))
	if page_id <= 0:
		if _next_page_id <= 0 or _next_page_id > UINT32_MAX:
			_last_error = {
				"error_id": ERROR_PAGE_ID_EXHAUSTED,
				"message": "Gaussian page IDs exhausted the uint32 key field"
			}
			return null
		page_id = _next_page_id
		_next_page_id += 1
		_page_ids[content_identity] = page_id

	var page := PageEntry.new()
	page.resource = gaussian
	page.page_id = page_id
	page.point_count = point_count
	page.point_data_byte = point_data
	page.aabb = aabb_value
	page.content_identity = content_identity
	page.content_hash = content_hash
	return page

func _active_reference_less(left: Dictionary, right: Dictionary) -> bool:
	var left_source := (
		0 if String(left["source_kind"]) == SOURCE_STANDALONE else 1
	)
	var right_source := (
		0 if String(right["source_kind"]) == SOURCE_STANDALONE else 1
	)
	if left_source != right_source:
		return left_source < right_source
	var left_owner := String(left["owner_identity"])
	var right_owner := String(right["owner_identity"])
	if left_owner != right_owner:
		return left_owner < right_owner
	var left_page := int(left["page_id"])
	var right_page := int(right["page_id"])
	if left_page != right_page:
		return left_page < right_page
	return int(left["reference_id"]) < int(right["reference_id"])

func _same_resource_set(left: Dictionary, right: Dictionary) -> bool:
	if left.size() != right.size():
		return false
	for resource: Variant in left:
		if not right.has(resource):
			return false
	return true

func _get_node_gaussian(node: Node) -> Resource:
	if node.has_method("get_active_gaussian"):
		var active: Variant = node.call("get_active_gaussian")
		return active if active is Resource else null
	var value: Variant = node.get("gaussian")
	return value if value is Resource else null

func _get_node_transform(node: Node) -> Transform3D:
	return (node as Node3D).global_transform if node is Node3D else Transform3D.IDENTITY

func _get_node_visibility(node: Node) -> bool:
	return (node as Node3D).is_visible_in_tree() if node is Node3D else true

func _get_reference_source(node: Node) -> String:
	if node.has_method("get_gaussian_reference_source"):
		return String(node.call("get_gaussian_reference_source"))
	return SOURCE_STANDALONE

func _get_owner_identity(node: Node) -> String:
	if node.has_method("get_gaussian_owner_identity"):
		var identity := String(node.call("get_gaussian_owner_identity"))
		if not identity.is_empty():
			return identity
	return "node-%d" % node.get_instance_id()

func _is_selected_for_view(node: Node, view_identity: String) -> bool:
	if node.has_method("is_gaussian_selected_for_view"):
		return bool(node.call(
			"is_gaussian_selected_for_view",
			view_identity
		))
	return true

func _get_selection_generation(
	node: Node,
	view_identity: String
) -> int:
	if node.has_method("get_gaussian_selection_generation"):
		return maxi(
			0,
			int(node.call(
				"get_gaussian_selection_generation",
				view_identity
			))
		)
	return 0

func _prune_reference_nodes() -> bool:
	var changed := false
	for index in range(_reference_nodes.size() - 1, -1, -1):
		if not is_instance_valid(_reference_nodes[index]):
			_reference_nodes.remove_at(index)
			changed = true
	return changed

func _sha256_bytes(bytes: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	if hashing.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if hashing.update(bytes) != OK:
		return ""
	return hashing.finish().hex_encode()

func _change_result(
	changed: bool,
	page_set_changed: bool,
	payload_changed: bool
) -> Dictionary:
	return {
		"changed": changed,
		"page_set_changed": page_set_changed,
		"payload_changed": payload_changed,
		"revision": _revision
	}
