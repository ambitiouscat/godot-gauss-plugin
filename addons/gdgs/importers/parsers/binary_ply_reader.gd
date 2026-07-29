@tool
extends RefCounted

const DecodeControl = preload("res://addons/gdgs/importers/decoders/gaussian_decode_control.gd")

const TYPE_SIZES := {
	"char": 1,
	"uchar": 1,
	"short": 2,
	"ushort": 2,
	"int": 4,
	"uint": 4,
	"float": 4,
	"double": 8
}

const TYPE_ALIASES := {
	"int8": "char",
	"uint8": "uchar",
	"int16": "short",
	"uint16": "ushort",
	"int32": "int",
	"uint32": "uint",
	"float32": "float",
	"float64": "double"
}

const MAX_HEADER_BYTES := 1024 * 1024
const MAX_ELEMENTS := 64
const MAX_PROPERTIES_PER_ELEMENT := 512
const MAX_RECORD_STRIDE := 1024 * 1024

static func read(
	path: String,
	include_data := true,
	progress_callback := Callable(),
	cancellation_callback := Callable(),
	limits: Dictionary = {}
) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _error(FileAccess.get_open_error(), "Unable to open PLY file: %s" % path)

	file.big_endian = false
	var source_size := file.get_length()
	var max_source_bytes := DecodeControl.limit(limits, "max_source_bytes", DecodeControl.DEFAULT_MAX_SOURCE_BYTES)
	if source_size > max_source_bytes:
		return DecodeControl.error(ERR_OUT_OF_MEMORY, "PLY source exceeds the configured byte limit", "GDGS_SOURCE_TOO_LARGE")
	if DecodeControl.is_cancelled(cancellation_callback):
		return DecodeControl.cancellation_error()
	DecodeControl.report(progress_callback, 0.0)

	var magic := file.get_line().strip_edges()
	if magic != "ply":
		return _error(ERR_FILE_UNRECOGNIZED, "Missing PLY magic header")

	var format := ""
	var elements: Array = []
	var current_element: Dictionary = {}
	var saw_end_header := false

	while not file.eof_reached():
		if file.get_position() > MAX_HEADER_BYTES:
			return _error(ERR_INVALID_DATA, "PLY header exceeds the configured byte limit")
		if DecodeControl.is_cancelled(cancellation_callback):
			return DecodeControl.cancellation_error()
		var raw_line := file.get_line()
		var line := raw_line.strip_edges()
		if line.is_empty():
			continue
		if line == "end_header":
			saw_end_header = true
			break

		var parts := line.split(" ", false)
		if parts.is_empty():
			continue

		match parts[0]:
			"comment", "obj_info":
				continue
			"format":
				if parts.size() < 3:
					return _error(ERR_INVALID_DATA, "Malformed PLY format declaration")
				format = parts[1]
			"element":
				if parts.size() < 3:
					return _error(ERR_INVALID_DATA, "Malformed PLY element declaration")
				if elements.size() >= MAX_ELEMENTS:
					return _error(ERR_INVALID_DATA, "PLY contains too many elements")
				var count_text: String = parts[2]
				if not count_text.is_valid_int():
					return _error(ERR_INVALID_DATA, "PLY element count is not an integer")
				var element_count := int(count_text)
				if element_count < 0:
					return _error(ERR_INVALID_DATA, "PLY element count cannot be negative")
				current_element = {
					"name": parts[1],
					"count": element_count,
					"stride": 0,
					"properties": [],
					"property_map": {}
				}
				elements.push_back(current_element)
			"property":
				if current_element.is_empty():
					return _error(ERR_INVALID_DATA, "PLY property declared before any element")
				if parts.size() < 3:
					return _error(ERR_INVALID_DATA, "Malformed PLY property declaration")
				if parts[1] == "list":
					return _error(ERR_UNAVAILABLE, "PLY list properties are not supported")
				if current_element["properties"].size() >= MAX_PROPERTIES_PER_ELEMENT:
					return _error(ERR_INVALID_DATA, "PLY element contains too many properties")

				var raw_type: String = parts[1]
				var prop_type: String = TYPE_ALIASES.get(raw_type, raw_type)
				if not TYPE_SIZES.has(prop_type):
					return _error(ERR_UNAVAILABLE, "Unsupported PLY property type: %s" % raw_type)
				if int(current_element["stride"]) > MAX_RECORD_STRIDE - int(TYPE_SIZES[prop_type]):
					return _error(ERR_INVALID_DATA, "PLY record stride exceeds the configured limit")

				var prop := {
					"name": parts[2],
					"type": prop_type,
					"offset": current_element["stride"],
					"size": TYPE_SIZES[prop_type]
				}
				current_element["properties"].push_back(prop)
				current_element["property_map"][prop["name"]] = prop
				current_element["stride"] += prop["size"]
			_:
				return _error(ERR_INVALID_DATA, "Unsupported PLY header token: %s" % parts[0])

	if not saw_end_header:
		return _error(ERR_FILE_CORRUPT, "PLY header is missing end_header")

	if format != "binary_little_endian":
		return _error(ERR_UNAVAILABLE, "Only binary_little_endian PLY is supported")

	if elements.is_empty():
		return _error(ERR_INVALID_DATA, "PLY file does not contain any elements")

	var max_decoded_bytes := DecodeControl.limit(limits, "max_decoded_bytes", DecodeControl.DEFAULT_MAX_DECODED_BYTES)
	var total_declared_bytes := 0
	for element in elements:
		var element_bytes := DecodeControl.checked_product(int(element["count"]), int(element["stride"]), max_decoded_bytes)
		if element_bytes < 0 or total_declared_bytes > max_decoded_bytes - element_bytes:
			return DecodeControl.error(ERR_OUT_OF_MEMORY, "PLY declared data exceeds the configured decoded-byte limit", "GDGS_DECODE_LIMIT")
		total_declared_bytes += element_bytes
	if file.get_position() > source_size or total_declared_bytes > source_size - file.get_position():
		return DecodeControl.error(ERR_FILE_CORRUPT, "Unexpected end of PLY data", "GDGS_TRUNCATED")

	if include_data:
		var io_chunk_bytes := maxi(DecodeControl.limit(limits, "io_chunk_bytes", DecodeControl.DEFAULT_IO_CHUNK_BYTES), 1)
		var total_read := 0
		for element in elements:
			var byte_size := int(element["count"]) * int(element["stride"])
			var element_data := PackedByteArray()
			var remaining := byte_size
			while remaining > 0:
				if DecodeControl.is_cancelled(cancellation_callback):
					return DecodeControl.cancellation_error()
				var requested := mini(remaining, io_chunk_bytes)
				var chunk := file.get_buffer(requested)
				if chunk.size() != requested:
					return DecodeControl.error(ERR_FILE_CORRUPT, "Unexpected end of PLY data while reading '%s'" % element["name"], "GDGS_TRUNCATED")
				element_data.append_array(chunk)
				remaining -= requested
				total_read += requested
				DecodeControl.report(progress_callback, float(total_read) / float(maxi(total_declared_bytes, 1)))
			element["data"] = element_data

	DecodeControl.report(progress_callback, 1.0)

	return {
		"ok": true,
		"format": format,
		"elements": elements
	}

static func get_element(ply: Dictionary, name: String) -> Dictionary:
	var elements: Array = ply.get("elements", [])
	for element in elements:
		if element.get("name", "") == name:
			return element
	return {}

static func decode_scalar(data: PackedByteArray, byte_offset: int, data_type: String) -> Variant:
	match data_type:
		"char":
			var value := int(data[byte_offset])
			return value if value < 128 else value - 256
		"uchar":
			return int(data[byte_offset])
		"short":
			return data.decode_s16(byte_offset)
		"ushort":
			return data.decode_u16(byte_offset)
		"int":
			return data.decode_s32(byte_offset)
		"uint":
			return data.decode_u32(byte_offset)
		"float":
			return data.decode_float(byte_offset)
		"double":
			return data.decode_double(byte_offset)
		_:
			return null

static func _error(code: Error, message: String) -> Dictionary:
	return DecodeControl.error(code, message)
