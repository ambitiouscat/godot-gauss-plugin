@tool
extends RefCounted

const ProjectFiles = preload("res://addons/gdgs/editor/workflows/gaussian_project_files.gd")

static func plan(selected_nodes: Array[Node]) -> Dictionary:
	var import_map := _build_import_map()
	var candidates: Array[Node] = []
	var seen := {}
	for selected in selected_nodes:
		_collect_gaussian_nodes(selected, candidates, seen)

	var changes: Array[Dictionary] = []
	var unresolved: Array[Dictionary] = []
	var skipped := 0
	for node in candidates:
		var current_source := String(node.get("source_path"))
		var legacy: Variant = node.get("gaussian")
		if legacy == null or not current_source.is_empty():
			skipped += 1
			continue
		var source_path := _resolve_source(legacy, import_map)
		if source_path.is_empty():
			unresolved.push_back({
				"node": node,
				"node_path": String(node.get_path()) if node.is_inside_tree() else String(node.name),
				"resource_path": String(legacy.resource_path if legacy is Resource else "")
			})
			continue
		changes.push_back({
			"node": node,
			"source_path": source_path,
			"legacy": legacy
		})
	return {
		"changes": changes,
		"unresolved": unresolved,
		"skipped": skipped,
		"candidates": candidates.size()
	}

static func _collect_gaussian_nodes(node: Node, result: Array[Node], seen: Dictionary) -> void:
	if node == null or seen.has(node.get_instance_id()):
		return
	seen[node.get_instance_id()] = true
	if _has_property(node, &"source_path") and _has_property(node, &"gaussian"):
		result.push_back(node)
	for child in node.get_children():
		_collect_gaussian_nodes(child, result, seen)

static func _resolve_source(legacy: Variant, import_map: Dictionary) -> String:
	if not legacy is Resource:
		return ""
	var resource_path := String((legacy as Resource).resource_path)
	if ProjectFiles.is_supported_source(resource_path) and FileAccess.file_exists(resource_path):
		return resource_path
	return String(import_map.get(resource_path, ""))

static func _build_import_map() -> Dictionary:
	var result := {}
	for source_path in ProjectFiles.list_project_sources():
		var import_path := source_path + ".import"
		if not FileAccess.file_exists(import_path):
			continue
		var config := ConfigFile.new()
		if config.load(import_path) != OK:
			continue
		var remapped := String(config.get_value("remap", "path", ""))
		if not remapped.is_empty():
			result[remapped] = source_path
		var destinations: Variant = config.get_value("deps", "dest_files", [])
		if destinations is Array or destinations is PackedStringArray:
			for destination in destinations:
				result[String(destination)] = source_path
	return result

static func _has_property(object: Object, property_name: StringName) -> bool:
	for property in object.get_property_list():
		if StringName(property.get("name", &"")) == property_name:
			return true
	return false
