@tool
extends RefCounted
class_name GdgsGaussianSourceDecoder

const BinaryPlyReader = preload("res://addons/gdgs/importers/parsers/binary_ply_reader.gd")
const StandardPlyDecoder = preload("res://addons/gdgs/importers/decoders/standard_ply_decoder.gd")
const CompressedPlyDecoder = preload("res://addons/gdgs/importers/decoders/compressed_ply_decoder.gd")
const SplatDecoder = preload("res://addons/gdgs/importers/decoders/splat_decoder.gd")
const SogDecoder = preload("res://addons/gdgs/importers/decoders/sog_decoder.gd")
const DecodeControl = preload("res://addons/gdgs/importers/decoders/gaussian_decode_control.gd")
const GaussianDiagnostics = preload("res://addons/gdgs/runtime/diagnostics/gaussian_diagnostics.gd")

static func decode(
	source_file: String,
	progress_callback := Callable(),
	cancellation_callback := Callable(),
	limits: Dictionary = {}
) -> Dictionary:
	var format_name := source_format(source_file)
	var decoder_started_usec := GaussianDiagnostics.begin_decoder(format_name, source_file)
	var result := _decode_uninstrumented(source_file, progress_callback, cancellation_callback, limits)
	GaussianDiagnostics.finish_decoder(
		decoder_started_usec,
		format_name,
		bool(result.get("ok", false)),
		int(result.get("error", OK))
	)
	return result

static func source_format(source_file: String) -> String:
	var lower_source := source_file.to_lower()
	if lower_source.ends_with(".compressed.ply"):
		return "compressed_ply"
	if lower_source.ends_with(".ply"):
		return "ply"
	if lower_source.ends_with(".splat"):
		return "splat"
	if lower_source.ends_with(".sog"):
		return "sog"
	return "unsupported"

static func _decode_uninstrumented(
	source_file: String,
	progress_callback: Callable,
	cancellation_callback: Callable,
	limits: Dictionary
) -> Dictionary:
	if DecodeControl.is_cancelled(cancellation_callback):
		return DecodeControl.cancellation_error()
	DecodeControl.report(progress_callback, 0.0)
	var lower_source := source_file.to_lower()
	if lower_source.ends_with(".splat"):
		return SplatDecoder.decode(source_file, progress_callback, cancellation_callback, limits)
	if lower_source.ends_with(".sog"):
		return SogDecoder.decode(source_file, progress_callback, cancellation_callback, limits)
	if lower_source.ends_with(".ply"):
		var header_progress := func(value: float) -> void:
			DecodeControl.report(progress_callback, value * 0.02)
		var header := BinaryPlyReader.read(source_file, false, header_progress, cancellation_callback, limits)
		if not header.get("ok", false):
			return header
		if _is_compressed_ply(source_file, header):
			return CompressedPlyDecoder.decode(source_file, progress_callback, cancellation_callback, limits)
		return StandardPlyDecoder.decode(source_file, progress_callback, cancellation_callback, limits)
	return DecodeControl.error(
		ERR_FILE_UNRECOGNIZED,
		"Unsupported gaussian splat extension: %s" % source_file.get_extension(),
		"GDGS_UNSUPPORTED_FORMAT"
	)

static func _is_compressed_ply(source_file: String, header: Dictionary) -> bool:
	if source_file.to_lower().ends_with(".compressed.ply"):
		return true

	var chunk_element := BinaryPlyReader.get_element(header, "chunk")
	var vertex_element := BinaryPlyReader.get_element(header, "vertex")
	if chunk_element.is_empty() or vertex_element.is_empty():
		return false

	var property_map: Dictionary = vertex_element.get("property_map", {})
	return property_map.has("packed_position") and property_map.has("packed_rotation") and property_map.has("packed_scale") and property_map.has("packed_color")
