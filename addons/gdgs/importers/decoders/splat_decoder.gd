@tool
extends RefCounted

const GaussianResourceBuilder = preload("res://addons/gdgs/importers/builders/gaussian_resource_builder.gd")
const DecodeControl = preload("res://addons/gdgs/importers/decoders/gaussian_decode_control.gd")

const SH_C0 := 0.28209479177387814
const SH_COEFF_COUNT := 48
const RECORD_SIZE := 32

static func decode(
	path: String,
	progress_callback := Callable(),
	cancellation_callback := Callable(),
	limits: Dictionary = {}
) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _error(FileAccess.get_open_error(), "Unable to open splat file: %s" % path)

	var size := file.get_length()
	var max_source_bytes := DecodeControl.limit(limits, "max_source_bytes", DecodeControl.DEFAULT_MAX_SOURCE_BYTES)
	if size > max_source_bytes:
		return DecodeControl.error(ERR_OUT_OF_MEMORY, "SPLAT source exceeds the configured byte limit", "GDGS_SOURCE_TOO_LARGE")
	if size % RECORD_SIZE != 0:
		return _error(ERR_INVALID_DATA, "Legacy splat file size must be a multiple of 32 bytes")

	var count := int(size / RECORD_SIZE)
	var max_point_count := DecodeControl.limit(limits, "max_point_count", DecodeControl.DEFAULT_MAX_POINT_COUNT)
	if count > max_point_count:
		return DecodeControl.error(ERR_OUT_OF_MEMORY, "SPLAT record count exceeds the configured limit", "GDGS_DECODE_LIMIT")

	var data := PackedByteArray()
	var remaining := size
	var io_chunk_bytes := maxi(DecodeControl.limit(limits, "io_chunk_bytes", DecodeControl.DEFAULT_IO_CHUNK_BYTES), 1)
	while remaining > 0:
		if DecodeControl.is_cancelled(cancellation_callback):
			return DecodeControl.cancellation_error()
		var requested := mini(remaining, io_chunk_bytes)
		var chunk := file.get_buffer(requested)
		if chunk.size() != requested:
			return DecodeControl.error(ERR_FILE_CORRUPT, "Unable to read the entire splat file", "GDGS_TRUNCATED")
		data.append_array(chunk)
		remaining -= requested
		DecodeControl.report(progress_callback, 0.2 * float(size - remaining) / float(maxi(size, 1)))

	var canonical := GaussianResourceBuilder.create_canonical(count)
	var positions: PackedVector3Array = canonical["positions"]
	var scales_linear: PackedVector3Array = canonical["scales_linear"]
	var rotations: Array = canonical["rotations"]
	var opacities: PackedFloat32Array = canonical["opacities"]
	var sh_coeffs: PackedFloat32Array = canonical["sh_coeffs"]

	var check_interval := maxi(DecodeControl.limit(limits, "check_interval", DecodeControl.DEFAULT_CHECK_INTERVAL), 1)
	for i in count:
		if i % check_interval == 0:
			if DecodeControl.is_cancelled(cancellation_callback):
				return DecodeControl.cancellation_error()
			DecodeControl.report(progress_callback, 0.2 + 0.8 * float(i) / float(maxi(count, 1)))
		var base := i * RECORD_SIZE
		var position := Vector3(
			data.decode_float(base + 0),
			data.decode_float(base + 4),
			data.decode_float(base + 8)
		)
		if not DecodeControl.finite_vector3(position):
			return DecodeControl.error(ERR_INVALID_DATA, "SPLAT contains a non-finite position", "GDGS_NON_FINITE")
		positions[i] = position
		var scale := Vector3(
			maxf(data.decode_float(base + 12), 1e-6),
			maxf(data.decode_float(base + 16), 1e-6),
			maxf(data.decode_float(base + 20), 1e-6)
		)
		if not DecodeControl.finite_vector3(scale):
			return DecodeControl.error(ERR_INVALID_DATA, "SPLAT contains a non-finite scale", "GDGS_NON_FINITE")
		scales_linear[i] = scale

		var w := _decode_signed_byte(int(data[base + 28]))
		var x := _decode_signed_byte(int(data[base + 29]))
		var y := _decode_signed_byte(int(data[base + 30]))
		var z := _decode_signed_byte(int(data[base + 31]))
		var rotation := Quaternion(x, y, z, w)
		var magnitude_sq := x * x + y * y + z * z + w * w
		if magnitude_sq <= 0.0:
			rotation = Quaternion(0.0, 0.0, 0.0, 1.0)
		else:
			rotation = rotation.normalized()
		rotations[i] = rotation

		var sh_offset := i * SH_COEFF_COUNT
		sh_coeffs[sh_offset + 0] = (float(data[base + 24]) / 255.0 - 0.5) / SH_C0
		sh_coeffs[sh_offset + 1] = (float(data[base + 25]) / 255.0 - 0.5) / SH_C0
		sh_coeffs[sh_offset + 2] = (float(data[base + 26]) / 255.0 - 0.5) / SH_C0
		opacities[i] = float(data[base + 27]) / 255.0

	DecodeControl.report(progress_callback, 1.0)

	return {
		"ok": true,
		"canonical": canonical
	}

static func _decode_signed_byte(value: int) -> float:
	return (float(value) - 128.0) / 128.0

static func _error(code: Error, message: String) -> Dictionary:
	return DecodeControl.error(code, message)
