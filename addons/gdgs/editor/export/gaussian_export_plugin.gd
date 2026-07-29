@tool
extends EditorExportPlugin

const ProjectFiles = preload("res://addons/gdgs/editor/workflows/gaussian_project_files.gd")

func _get_name() -> String:
	return "GDGS Gaussian Raw Sources"

func _supports_platform(_platform: EditorExportPlatform) -> bool:
	return true

func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	var platform := get_export_platform()
	var external_references := ProjectFiles.find_external_scene_references()
	if not external_references.is_empty():
		for issue in external_references:
			var message := String(issue["message"])
			push_error("[gdgs] %s" % message)
			if platform != null:
				platform.add_message(EditorExportPlatform.EXPORT_MESSAGE_ERROR, "Gaussian sources", message)
		return

	for source_path in ProjectFiles.list_project_sources():
		var file := FileAccess.open(source_path, FileAccess.READ)
		if file == null:
			var message := "Unable to package Gaussian source '%s' (error %d)." % [source_path, FileAccess.get_open_error()]
			push_error("[gdgs] %s" % message)
			if platform != null:
				platform.add_message(EditorExportPlatform.EXPORT_MESSAGE_ERROR, "Gaussian sources", message)
			continue
		var source_size := file.get_length()
		var bytes := file.get_buffer(source_size)
		if bytes.size() != source_size:
			var message := "Gaussian source '%s' could not be read completely for export." % source_path
			push_error("[gdgs] %s" % message)
			if platform != null:
				platform.add_message(EditorExportPlatform.EXPORT_MESSAGE_ERROR, "Gaussian sources", message)
			continue
		add_file(source_path, bytes, false)
