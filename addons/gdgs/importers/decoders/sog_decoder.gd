@tool
extends RefCounted

const GaussianResourceBuilder = preload("res://addons/gdgs/importers/builders/gaussian_resource_builder.gd")
const DecodeControl = preload("res://addons/gdgs/importers/decoders/gaussian_decode_control.gd")

const SH_COEFF_COUNT := 48
const SH_COEFFS_PER_BAND := {
	1: 3,
	2: 8,
	3: 15
}
const SQRT2 := 1.4142135623730951

static func decode(
	path: String,
	progress_callback := Callable(),
	cancellation_callback := Callable(),
	limits: Dictionary = {}
) -> Dictionary:
	var source_size := 0
	var source_file := FileAccess.open(path, FileAccess.READ)
	if source_file == null:
		return _error(FileAccess.get_open_error(), "Unable to open SOG archive: %s" % path)
	source_size = source_file.get_length()
	source_file = null
	var max_source_bytes := DecodeControl.limit(limits, "max_source_bytes", DecodeControl.DEFAULT_MAX_SOURCE_BYTES)
	if source_size > max_source_bytes:
		return DecodeControl.error(ERR_OUT_OF_MEMORY, "SOG source exceeds the configured byte limit", "GDGS_SOURCE_TOO_LARGE")
	if DecodeControl.is_cancelled(cancellation_callback):
		return DecodeControl.cancellation_error()
	DecodeControl.report(progress_callback, 0.0)

	var zip_reader := ZIPReader.new()
	var open_error := zip_reader.open(path)
	if open_error != OK:
		return _error(open_error, "Unable to open SOG archive: %s" % path)

	var meta_bytes := zip_reader.read_file("meta.json")
	if meta_bytes.is_empty():
		zip_reader.close()
		return _error(ERR_FILE_NOT_FOUND, "Bundled SOG archive is missing meta.json")

	var meta = JSON.parse_string(meta_bytes.get_string_from_utf8())
	if typeof(meta) != TYPE_DICTIONARY:
		zip_reader.close()
		return _error(ERR_INVALID_DATA, "SOG metadata is not valid JSON")

	if int(meta.get("version", -1)) != 2:
		zip_reader.close()
		return _error(ERR_UNAVAILABLE, "Only SOG version 2 is supported")

	var count := int(meta.get("count", 0))
	if count <= 0:
		zip_reader.close()
		return _error(ERR_INVALID_DATA, "SOG metadata does not contain a valid gaussian count")
	var max_point_count := DecodeControl.limit(limits, "max_point_count", DecodeControl.DEFAULT_MAX_POINT_COUNT)
	if count > max_point_count:
		zip_reader.close()
		return DecodeControl.error(ERR_OUT_OF_MEMORY, "SOG gaussian count exceeds the configured limit", "GDGS_DECODE_LIMIT")
	if DecodeControl.is_cancelled(cancellation_callback):
		zip_reader.close()
		return DecodeControl.cancellation_error()
	DecodeControl.report(progress_callback, 0.05)

	var means_meta: Dictionary = meta.get("means", {})
	var means_files: Array = means_meta.get("files", [])
	if means_files.size() < 2:
		zip_reader.close()
		return _error(ERR_INVALID_DATA, "SOG means metadata is incomplete")

	var means_l := _load_image(zip_reader, String(means_files[0]), Image.FORMAT_RGB8, cancellation_callback, limits)
	if not means_l.get("ok", false):
		zip_reader.close()
		return means_l
	DecodeControl.report(progress_callback, 0.09)
	var means_u := _load_image(zip_reader, String(means_files[1]), Image.FORMAT_RGB8, cancellation_callback, limits)
	if not means_u.get("ok", false):
		zip_reader.close()
		return means_u

	var scales_meta: Dictionary = meta.get("scales", {})
	var scales_files: Array = scales_meta.get("files", [])
	if scales_files.is_empty():
		zip_reader.close()
		return _error(ERR_INVALID_DATA, "SOG scales metadata is incomplete")
	DecodeControl.report(progress_callback, 0.13)
	var scales_image := _load_image(zip_reader, String(scales_files[0]), Image.FORMAT_RGB8, cancellation_callback, limits)
	if not scales_image.get("ok", false):
		zip_reader.close()
		return scales_image

	var quats_meta: Dictionary = meta.get("quats", {})
	var quats_files: Array = quats_meta.get("files", [])
	if quats_files.is_empty():
		zip_reader.close()
		return _error(ERR_INVALID_DATA, "SOG quaternion metadata is incomplete")
	DecodeControl.report(progress_callback, 0.17)
	var quats_image := _load_image(zip_reader, String(quats_files[0]), Image.FORMAT_RGBA8, cancellation_callback, limits)
	if not quats_image.get("ok", false):
		zip_reader.close()
		return quats_image

	var sh0_meta: Dictionary = meta.get("sh0", {})
	var sh0_files: Array = sh0_meta.get("files", [])
	if sh0_files.is_empty():
		zip_reader.close()
		return _error(ERR_INVALID_DATA, "SOG sh0 metadata is incomplete")
	DecodeControl.report(progress_callback, 0.21)
	var sh0_image := _load_image(zip_reader, String(sh0_files[0]), Image.FORMAT_RGBA8, cancellation_callback, limits)
	if not sh0_image.get("ok", false):
		zip_reader.close()
		return sh0_image

	var dims := Vector2i(int(means_l["width"]), int(means_l["height"]))
	if not _image_matches(means_u, dims) or not _image_matches(scales_image, dims) or not _image_matches(quats_image, dims) or not _image_matches(sh0_image, dims):
		zip_reader.close()
		return _error(ERR_INVALID_DATA, "SOG textures must share the same dimensions")
	if count > dims.x * dims.y:
		zip_reader.close()
		return _error(ERR_INVALID_DATA, "SOG texture atlas is too small for the gaussian count")

	var means_mins := _array_to_vector3(means_meta.get("mins", []))
	var means_maxs := _array_to_vector3(means_meta.get("maxs", []))
	var scales_codebook_values: Array = scales_meta.get("codebook", [])
	var sh0_codebook_values: Array = sh0_meta.get("codebook", [])
	if scales_codebook_values.size() != 256 or sh0_codebook_values.size() != 256:
		zip_reader.close()
		return _error(ERR_INVALID_DATA, "SOG codebooks must contain 256 entries")
	var scales_codebook := _array_to_float_array(scales_codebook_values)
	var sh0_codebook := _array_to_float_array(sh0_codebook_values)
	if not DecodeControl.finite_vector3(means_mins) or not DecodeControl.finite_vector3(means_maxs) or not _all_finite(scales_codebook) or not _all_finite(sh0_codebook):
		zip_reader.close()
		return DecodeControl.error(ERR_INVALID_DATA, "SOG metadata contains non-finite values", "GDGS_NON_FINITE")

	var shn_centroids := {}
	var shn_labels := {}
	var shn_bands := 0
	var shn_coeffs_per_channel := 0
	var shn_palette_count := 0
	var shn_codebook := PackedFloat32Array()

	if meta.has("shN"):
		var shn_meta: Dictionary = meta["shN"]
		shn_bands = int(shn_meta.get("bands", 0))
		if not SH_COEFFS_PER_BAND.has(shn_bands):
			zip_reader.close()
			return _error(ERR_INVALID_DATA, "SOG shN metadata contains an unsupported band count")
		var shn_files: Array = shn_meta.get("files", [])
		if shn_files.size() < 2:
			zip_reader.close()
			return _error(ERR_INVALID_DATA, "SOG shN metadata is incomplete")
		shn_palette_count = int(shn_meta.get("count", 0))
		var shn_codebook_values: Array = shn_meta.get("codebook", [])
		if shn_palette_count <= 0 or shn_codebook_values.size() != 256:
			zip_reader.close()
			return _error(ERR_INVALID_DATA, "SOG shN metadata is invalid")
		shn_codebook = _array_to_float_array(shn_codebook_values)

		DecodeControl.report(progress_callback, 0.25)
		shn_centroids = _load_image(zip_reader, String(shn_files[0]), Image.FORMAT_RGB8, cancellation_callback, limits)
		if not shn_centroids.get("ok", false):
			zip_reader.close()
			return shn_centroids
		shn_labels = _load_image(zip_reader, String(shn_files[1]), Image.FORMAT_RGBA8, cancellation_callback, limits)
		if not shn_labels.get("ok", false):
			zip_reader.close()
			return shn_labels
		if not _image_matches(shn_labels, dims):
			zip_reader.close()
			return _error(ERR_INVALID_DATA, "SOG shN label texture dimensions do not match the main atlas")

		shn_coeffs_per_channel = SH_COEFFS_PER_BAND[shn_bands]
		if not _all_finite(shn_codebook):
			zip_reader.close()
			return DecodeControl.error(ERR_INVALID_DATA, "SOG shN codebook contains non-finite values", "GDGS_NON_FINITE")

	var canonical := GaussianResourceBuilder.create_canonical(count)
	var positions: PackedVector3Array = canonical["positions"]
	var scales_linear: PackedVector3Array = canonical["scales_linear"]
	var rotations: Array = canonical["rotations"]
	var opacities: PackedFloat32Array = canonical["opacities"]
	var sh_coeffs: PackedFloat32Array = canonical["sh_coeffs"]

	var means_l_data: PackedByteArray = means_l["data"]
	var means_u_data: PackedByteArray = means_u["data"]
	var scales_data: PackedByteArray = scales_image["data"]
	var quats_data: PackedByteArray = quats_image["data"]
	var sh0_data: PackedByteArray = sh0_image["data"]
	var shn_centroids_data := PackedByteArray()
	var shn_labels_data := PackedByteArray()
	if meta.has("shN"):
		shn_centroids_data = shn_centroids["data"]
		shn_labels_data = shn_labels["data"]

	var check_interval := maxi(DecodeControl.limit(limits, "check_interval", DecodeControl.DEFAULT_CHECK_INTERVAL), 1)
	for i in count:
		if i % check_interval == 0:
			if DecodeControl.is_cancelled(cancellation_callback):
				zip_reader.close()
				return DecodeControl.cancellation_error()
			DecodeControl.report(progress_callback, 0.3 + 0.7 * float(i) / float(maxi(count, 1)))
		var means_rgb_offset := i * 3
		var quats_rgba_offset := i * 4
		var sh0_rgba_offset := i * 4

		var qx := (int(means_u_data[means_rgb_offset + 0]) << 8) | int(means_l_data[means_rgb_offset + 0])
		var qy := (int(means_u_data[means_rgb_offset + 1]) << 8) | int(means_l_data[means_rgb_offset + 1])
		var qz := (int(means_u_data[means_rgb_offset + 2]) << 8) | int(means_l_data[means_rgb_offset + 2])
		var position := Vector3(
			_unlog(_lerp_range(means_mins.x, means_maxs.x, float(qx) / 65535.0)),
			_unlog(_lerp_range(means_mins.y, means_maxs.y, float(qy) / 65535.0)),
			_unlog(_lerp_range(means_mins.z, means_maxs.z, float(qz) / 65535.0))
		)
		if not DecodeControl.finite_vector3(position):
			zip_reader.close()
			return DecodeControl.error(ERR_INVALID_DATA, "SOG contains a non-finite position", "GDGS_NON_FINITE")
		positions[i] = position

		var scale := Vector3(
			maxf(exp(scales_codebook[int(scales_data[means_rgb_offset + 0])]), 1e-6),
			maxf(exp(scales_codebook[int(scales_data[means_rgb_offset + 1])]), 1e-6),
			maxf(exp(scales_codebook[int(scales_data[means_rgb_offset + 2])]), 1e-6)
		)
		if not DecodeControl.finite_vector3(scale):
			zip_reader.close()
			return DecodeControl.error(ERR_INVALID_DATA, "SOG contains a non-finite scale", "GDGS_NON_FINITE")
		scales_linear[i] = scale

		var mode := int(quats_data[quats_rgba_offset + 3]) - 252
		if mode < 0 or mode > 3:
			zip_reader.close()
			return _error(ERR_INVALID_DATA, "SOG quaternion packing mode is invalid")
		rotations[i] = _decode_sog_quaternion(
			int(quats_data[quats_rgba_offset + 0]),
			int(quats_data[quats_rgba_offset + 1]),
			int(quats_data[quats_rgba_offset + 2]),
			mode
		)

		var sh_offset := i * SH_COEFF_COUNT
		sh_coeffs[sh_offset + 0] = sh0_codebook[int(sh0_data[sh0_rgba_offset + 0])]
		sh_coeffs[sh_offset + 1] = sh0_codebook[int(sh0_data[sh0_rgba_offset + 1])]
		sh_coeffs[sh_offset + 2] = sh0_codebook[int(sh0_data[sh0_rgba_offset + 2])]
		opacities[i] = float(sh0_data[sh0_rgba_offset + 3]) / 255.0

		if meta.has("shN"):
			var labels_offset := i * 4
			var label := int(shn_labels_data[labels_offset + 0]) | (int(shn_labels_data[labels_offset + 1]) << 8)
			if label >= shn_palette_count:
				zip_reader.close()
				return _error(ERR_INVALID_DATA, "SOG shN label index is out of range")

			for coeff_idx in range(shn_coeffs_per_channel):
				var centroid_x := (label % 64) * shn_coeffs_per_channel + coeff_idx
				var centroid_y := int(label / 64)
				var centroid_offset := (centroid_y * int(shn_centroids["width"]) + centroid_x) * 3
				if centroid_offset + 2 >= shn_centroids_data.size():
					zip_reader.close()
					return _error(ERR_INVALID_DATA, "SOG shN centroid texture layout is invalid")

				var dst := sh_offset + 3 + coeff_idx * 3
				sh_coeffs[dst + 0] = shn_codebook[int(shn_centroids_data[centroid_offset + 0])]
				sh_coeffs[dst + 1] = shn_codebook[int(shn_centroids_data[centroid_offset + 1])]
				sh_coeffs[dst + 2] = shn_codebook[int(shn_centroids_data[centroid_offset + 2])]

	zip_reader.close()
	DecodeControl.report(progress_callback, 1.0)
	return {
		"ok": true,
		"canonical": canonical
	}

static func _load_image(
	zip_reader: ZIPReader,
	filename: String,
	target_format: int,
	cancellation_callback: Callable,
	limits: Dictionary
) -> Dictionary:
	if DecodeControl.is_cancelled(cancellation_callback):
		return DecodeControl.cancellation_error()
	var bytes := zip_reader.read_file(filename)
	if bytes.is_empty():
		return _error(ERR_FILE_NOT_FOUND, "SOG archive entry '%s' is missing" % filename)
	var dimensions := _webp_dimensions(bytes)
	if dimensions.x <= 0 or dimensions.y <= 0:
		return _error(ERR_INVALID_DATA, "SOG archive entry '%s' has an invalid WebP header" % filename)
	var max_decoded_bytes := DecodeControl.limit(limits, "max_decoded_bytes", DecodeControl.DEFAULT_MAX_DECODED_BYTES)
	var pixel_count := DecodeControl.checked_product(dimensions.x, dimensions.y, max_decoded_bytes)
	var channel_count := 3 if target_format == Image.FORMAT_RGB8 else 4
	if pixel_count < 0 or DecodeControl.checked_product(pixel_count, channel_count, max_decoded_bytes) < 0:
		return DecodeControl.error(ERR_OUT_OF_MEMORY, "Decoded SOG image exceeds the configured byte limit", "GDGS_DECODE_LIMIT")

	var image := Image.new()
	var load_error := image.load_webp_from_buffer(bytes)
	if load_error != OK:
		return _error(load_error, "Unable to decode WebP image '%s'" % filename)

	if image.get_format() != target_format:
		image.convert(target_format)
	var image_data := image.get_data()
	if image.get_width() != dimensions.x or image.get_height() != dimensions.y or image_data.size() > max_decoded_bytes:
		return DecodeControl.error(ERR_OUT_OF_MEMORY, "Decoded SOG image exceeds the configured byte limit", "GDGS_DECODE_LIMIT")

	return {
		"ok": true,
		"width": image.get_width(),
		"height": image.get_height(),
		"data": image_data
	}

static func _webp_dimensions(bytes: PackedByteArray) -> Vector2i:
	if bytes.size() < 30:
		return Vector2i.ZERO
	if bytes.slice(0, 4).get_string_from_ascii() != "RIFF" or bytes.slice(8, 12).get_string_from_ascii() != "WEBP":
		return Vector2i.ZERO
	var chunk_type := bytes.slice(12, 16).get_string_from_ascii()
	match chunk_type:
		"VP8X":
			var width := 1 + int(bytes[24]) + (int(bytes[25]) << 8) + (int(bytes[26]) << 16)
			var height := 1 + int(bytes[27]) + (int(bytes[28]) << 8) + (int(bytes[29]) << 16)
			return Vector2i(width, height)
		"VP8L":
			if bytes[20] != 0x2F:
				return Vector2i.ZERO
			var bits := int(bytes[21]) | (int(bytes[22]) << 8) | (int(bytes[23]) << 16) | (int(bytes[24]) << 24)
			return Vector2i(1 + (bits & 0x3FFF), 1 + ((bits >> 14) & 0x3FFF))
		"VP8 ":
			if bytes[23] != 0x9D or bytes[24] != 0x01 or bytes[25] != 0x2A:
				return Vector2i.ZERO
			return Vector2i(bytes.decode_u16(26) & 0x3FFF, bytes.decode_u16(28) & 0x3FFF)
	return Vector2i.ZERO

static func _image_matches(image_info: Dictionary, dims: Vector2i) -> bool:
	return int(image_info.get("width", -1)) == dims.x and int(image_info.get("height", -1)) == dims.y

static func _array_to_vector3(values: Array) -> Vector3:
	return Vector3(
		float(values[0]) if values.size() > 0 else 0.0,
		float(values[1]) if values.size() > 1 else 0.0,
		float(values[2]) if values.size() > 2 else 0.0
	)

static func _array_to_float_array(values: Array) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(values.size())
	for i in values.size():
		result[i] = float(values[i])
	return result

static func _all_finite(values: PackedFloat32Array) -> bool:
	for value in values:
		if not is_finite(value):
			return false
	return true

static func _decode_sog_quaternion(a: int, b: int, c: int, mode: int) -> Quaternion:
	var comps := [0.0, 0.0, 0.0, 0.0]
	var decoded := [
		(float(a) / 255.0 - 0.5) * SQRT2,
		(float(b) / 255.0 - 0.5) * SQRT2,
		(float(c) / 255.0 - 0.5) * SQRT2
	]
	var decoded_idx := 0
	var sum_sq := 0.0

	for component_idx in 4:
		if component_idx == mode:
			continue
		comps[component_idx] = decoded[decoded_idx]
		sum_sq += decoded[decoded_idx] * decoded[decoded_idx]
		decoded_idx += 1

	comps[mode] = sqrt(maxf(0.0, 1.0 - sum_sq))
	return Quaternion(comps[1], comps[2], comps[3], comps[0]).normalized()

static func _unlog(value: float) -> float:
	var sign_value := -1.0 if value < 0.0 else 1.0
	return sign_value * (exp(abs(value)) - 1.0)

static func _lerp_range(min_value: float, max_value: float, normalized: float) -> float:
	return min_value + (max_value - min_value) * normalized

static func _error(code: Error, message: String) -> Dictionary:
	return DecodeControl.error(code, message)
