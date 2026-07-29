@tool
extends RefCounted

const GaussianAssetLoader = preload("res://addons/gdgs/runtime/loading/gaussian_asset_loader.gd")
const GaussianSourceDecoder = preload("res://addons/gdgs/importers/gaussian_source_decoder.gd")
const GaussianResourceBuilder = preload("res://addons/gdgs/importers/builders/gaussian_resource_builder.gd")

static func build(source_path: String, destination_path: String) -> Dictionary:
	if not Thread.is_main_thread():
		return _error(ERR_BUSY, "Legacy GaussianResource builds must be started on the main thread")
	var source_result: Dictionary = GaussianAssetLoader.inspect_source(source_path)
	if not source_result.get("ok", false):
		return source_result
	var destination_result: Dictionary = GaussianAssetLoader.canonicalize_project_path(destination_path)
	if not destination_result.get("ok", false):
		return destination_result
	var destination: String = destination_result["source_path"]
	var extension := destination.get_extension().to_lower()
	if extension != "res" and extension != "tres":
		return _error(ERR_INVALID_PARAMETER, "Legacy GaussianResource destination must end in .res or .tres")

	var decode_result: Dictionary = GaussianSourceDecoder.decode(source_result["source_path"])
	if not decode_result.get("ok", false):
		return decode_result
	var build_result: Dictionary = GaussianResourceBuilder.build(decode_result["canonical"])
	if not build_result.get("ok", false):
		return build_result
	var save_error := ResourceSaver.save(build_result["resource"], destination)
	if save_error != OK:
		return _error(save_error, "Unable to save legacy GaussianResource to %s" % destination)
	return {
		"ok": true,
		"source_path": source_result["source_path"],
		"destination_path": destination,
		"resource": build_result["resource"],
		"point_count": int(build_result["resource"].point_count)
	}

static func _error(code: Error, message: String) -> Dictionary:
	return {"ok": false, "error": code, "message": message}
