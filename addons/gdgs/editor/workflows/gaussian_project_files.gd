@tool
extends RefCounted

static func is_supported_source(path: String) -> bool:
	var lower := path.to_lower()
	return lower.ends_with(".ply") or lower.ends_with(".splat") or lower.ends_with(".sog")

static func list_project_sources() -> PackedStringArray:
	var result := PackedStringArray()
	_walk("res://", result, true)
	result.sort()
	return result

static func find_external_scene_references() -> Array[Dictionary]:
	var scene_paths := PackedStringArray()
	_walk("res://", scene_paths, false, ".tscn")
	var issues: Array[Dictionary] = []
	for scene_path in scene_paths:
		var text := FileAccess.get_file_as_string(scene_path)
		for raw_line in text.split("\n"):
			var line := String(raw_line).strip_edges()
			if not line.begins_with("source_path") or line.find("=") < 0:
				continue
			var first_quote := line.find("\"")
			var last_quote := line.rfind("\"")
			if first_quote < 0 or last_quote <= first_quote:
				continue
			var source_path := line.substr(first_quote + 1, last_quote - first_quote - 1).replace("\\\\", "\\")
			if source_path.is_empty() or source_path.begins_with("res://"):
				continue
			issues.push_back({
				"scene": scene_path,
				"source_path": source_path,
				"message": "%s references external Gaussian source '%s'; copy it into the project and assign a res:// path before export." % [scene_path, source_path]
			})
	return issues

static func _walk(
	directory_path: String,
	result: PackedStringArray,
	sources_only: bool,
	required_suffix: String = ""
) -> void:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		return
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		var child_path := directory_path.path_join(entry)
		if directory.current_is_dir():
			if not entry.begins_with("."):
				_walk(child_path, result, sources_only, required_suffix)
		elif sources_only:
			if is_supported_source(child_path):
				result.push_back(child_path)
		elif required_suffix.is_empty() or child_path.to_lower().ends_with(required_suffix):
			result.push_back(child_path)
		entry = directory.get_next()
	directory.list_dir_end()
