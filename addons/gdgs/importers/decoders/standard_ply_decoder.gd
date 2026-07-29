@tool
extends RefCounted

const BinaryPlyReader = preload("res://addons/gdgs/importers/parsers/binary_ply_reader.gd")
const GaussianResourceBuilder = preload("res://addons/gdgs/importers/builders/gaussian_resource_builder.gd")
const DecodeControl = preload("res://addons/gdgs/importers/decoders/gaussian_decode_control.gd")

const SH_COEFF_COUNT := 48

static func decode(
	path: String,
	progress_callback := Callable(),
	cancellation_callback := Callable(),
	limits: Dictionary = {}
) -> Dictionary:
	var read_progress := func(value: float) -> void:
		DecodeControl.report(progress_callback, value * 0.2)
	var ply := BinaryPlyReader.read(path, true, read_progress, cancellation_callback, limits)
	if not ply.get("ok", false):
		return ply
	if DecodeControl.is_cancelled(cancellation_callback):
		return DecodeControl.cancellation_error()

	var vertex := BinaryPlyReader.get_element(ply, "vertex")
	if vertex.is_empty():
		return _error(ERR_INVALID_DATA, "PLY file does not contain a vertex element")

	var property_map: Dictionary = vertex.get("property_map", {})
	var required := [
		"x", "y", "z",
		"f_dc_0", "f_dc_1", "f_dc_2",
		"opacity",
		"scale_0", "scale_1",
		"rot_0", "rot_1", "rot_2", "rot_3"
	]
	for name in required:
		if not property_map.has(name):
			return _error(ERR_INVALID_DATA, "PLY file is missing required property '%s'" % name)

	var count := int(vertex.get("count", 0))
	var stride := int(vertex.get("stride", 0))
	var data: PackedByteArray = vertex.get("data", PackedByteArray())
	var max_point_count := DecodeControl.limit(limits, "max_point_count", DecodeControl.DEFAULT_MAX_POINT_COUNT)
	if count > max_point_count:
		return DecodeControl.error(ERR_OUT_OF_MEMORY, "PLY vertex count exceeds the configured limit", "GDGS_DECODE_LIMIT")

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
		var base := i * stride

		var position := Vector3(
			float(_read_property(data, base, property_map, "x", 0.0)),
			float(_read_property(data, base, property_map, "y", 0.0)),
			float(_read_property(data, base, property_map, "z", 0.0))
		)
		if not DecodeControl.finite_vector3(position):
			return DecodeControl.error(ERR_INVALID_DATA, "PLY contains a non-finite position", "GDGS_NON_FINITE")
		positions[i] = position

		var scale_2 := float(_read_property(data, base, property_map, "scale_2", log(1e-6)))
		var scale := Vector3(
			exp(float(_read_property(data, base, property_map, "scale_0", 0.0))),
			exp(float(_read_property(data, base, property_map, "scale_1", 0.0))),
			exp(scale_2)
		)
		if not DecodeControl.finite_vector3(scale):
			return DecodeControl.error(ERR_INVALID_DATA, "PLY contains a non-finite scale", "GDGS_NON_FINITE")
		scales_linear[i] = scale

		var rotation := Quaternion(
			float(_read_property(data, base, property_map, "rot_1", 0.0)),
			float(_read_property(data, base, property_map, "rot_2", 0.0)),
			float(_read_property(data, base, property_map, "rot_3", 0.0)),
			float(_read_property(data, base, property_map, "rot_0", 1.0))
		)
		if not DecodeControl.finite_quaternion(rotation):
			return DecodeControl.error(ERR_INVALID_DATA, "PLY contains a non-finite rotation", "GDGS_NON_FINITE")
		rotations[i] = rotation.normalized() if rotation.length_squared() > 1e-12 else Quaternion.IDENTITY

		var opacity_value := float(_read_property(data, base, property_map, "opacity", 0.0))
		if not is_finite(opacity_value):
			return DecodeControl.error(ERR_INVALID_DATA, "PLY contains a non-finite opacity", "GDGS_NON_FINITE")
		opacities[i] = _sigmoid(opacity_value)

		var sh_offset := i * SH_COEFF_COUNT
		sh_coeffs[sh_offset + 0] = float(_read_property(data, base, property_map, "f_dc_0", 0.0))
		sh_coeffs[sh_offset + 1] = float(_read_property(data, base, property_map, "f_dc_1", 0.0))
		sh_coeffs[sh_offset + 2] = float(_read_property(data, base, property_map, "f_dc_2", 0.0))

		for coeff_idx in range(15):
			var coeff_offset := sh_offset + 3 + coeff_idx * 3
			sh_coeffs[coeff_offset + 0] = float(_read_property(data, base, property_map, "f_rest_%d" % coeff_idx, 0.0))
			sh_coeffs[coeff_offset + 1] = float(_read_property(data, base, property_map, "f_rest_%d" % (coeff_idx + 15), 0.0))
			sh_coeffs[coeff_offset + 2] = float(_read_property(data, base, property_map, "f_rest_%d" % (coeff_idx + 30), 0.0))
		for coeff_idx in SH_COEFF_COUNT:
			if not is_finite(sh_coeffs[sh_offset + coeff_idx]):
				return DecodeControl.error(ERR_INVALID_DATA, "PLY contains a non-finite SH coefficient", "GDGS_NON_FINITE")

	DecodeControl.report(progress_callback, 1.0)

	return {
		"ok": true,
		"canonical": canonical
	}

static func _read_property(data: PackedByteArray, base: int, property_map: Dictionary, property_name: String, default_value: Variant) -> Variant:
	var prop: Dictionary = property_map.get(property_name, {})
	if prop.is_empty():
		return default_value
	return BinaryPlyReader.decode_scalar(data, base + int(prop["offset"]), String(prop["type"]))

static func _sigmoid(value: float) -> float:
	return 1.0 / (1.0 + exp(-value))

static func _error(code: Error, message: String) -> Dictionary:
	return DecodeControl.error(code, message)
