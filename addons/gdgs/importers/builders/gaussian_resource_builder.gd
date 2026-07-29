@tool
extends RefCounted

const GaussianResourceScript = preload("res://addons/gdgs/runtime/resources/gaussian_resource.gd")
const GaussianDiagnostics = preload("res://addons/gdgs/runtime/diagnostics/gaussian_diagnostics.gd")
const DecodeControl = preload("res://addons/gdgs/importers/decoders/gaussian_decode_control.gd")

const STRUCT_SIZE := 60
const SH_FLOAT_COUNT := 48

static func create_canonical(count: int) -> Dictionary:
	var positions := PackedVector3Array()
	positions.resize(count)

	var scales_linear := PackedVector3Array()
	scales_linear.resize(count)

	var rotations: Array = []
	rotations.resize(count)

	var opacities := PackedFloat32Array()
	opacities.resize(count)

	var sh_coeffs := PackedFloat32Array()
	sh_coeffs.resize(count * SH_FLOAT_COUNT)

	return {
		"count": count,
		"positions": positions,
		"scales_linear": scales_linear,
		"rotations": rotations,
		"opacities": opacities,
		"sh_coeffs": sh_coeffs
	}

static func build(
	canonical: Dictionary,
	progress_callback := Callable(),
	cancellation_callback := Callable(),
	limits: Dictionary = {}
) -> Dictionary:
	var payload_result := build_payload(canonical, progress_callback, cancellation_callback, limits)
	if not payload_result.get("ok", false):
		return payload_result
	return publish(payload_result["payload"])

static func build_payload(
	canonical: Dictionary,
	progress_callback := Callable(),
	cancellation_callback := Callable(),
	limits: Dictionary = {}
) -> Dictionary:
	var count := int(canonical.get("count", 0))
	var builder_started_usec := GaussianDiagnostics.begin_builder(count)
	DecodeControl.report(progress_callback, 0.0)
	var positions: PackedVector3Array = canonical.get("positions", PackedVector3Array())
	var scales_linear: PackedVector3Array = canonical.get("scales_linear", PackedVector3Array())
	var rotations: Array = canonical.get("rotations", [])
	var opacities: PackedFloat32Array = canonical.get("opacities", PackedFloat32Array())
	var sh_coeffs: PackedFloat32Array = canonical.get("sh_coeffs", PackedFloat32Array())

	if count < 0:
		return _instrumented_error(builder_started_usec, count, ERR_INVALID_DATA, "Canonical gaussian count is invalid")
	var max_point_count := DecodeControl.limit(limits, "max_point_count", DecodeControl.DEFAULT_MAX_POINT_COUNT)
	var max_decoded_bytes := DecodeControl.limit(limits, "max_decoded_bytes", DecodeControl.DEFAULT_MAX_DECODED_BYTES)
	var payload_bytes := DecodeControl.checked_product(count, STRUCT_SIZE * 4, max_decoded_bytes)
	if count > max_point_count or payload_bytes < 0:
		return _instrumented_error(builder_started_usec, count, ERR_OUT_OF_MEMORY, "Gaussian payload exceeds the configured decoded-byte limit", "GDGS_DECODE_LIMIT")
	if positions.size() != count or scales_linear.size() != count or rotations.size() != count or opacities.size() != count:
		return _instrumented_error(builder_started_usec, count, ERR_INVALID_DATA, "Canonical gaussian arrays are inconsistent")
	var sh_value_count := DecodeControl.checked_product(count, SH_FLOAT_COUNT, int(max_decoded_bytes / 4))
	if sh_value_count < 0 or sh_coeffs.size() != sh_value_count:
		return _instrumented_error(builder_started_usec, count, ERR_INVALID_DATA, "Canonical SH coefficient buffer has an unexpected size")

	var check_interval := maxi(DecodeControl.limit(limits, "check_interval", DecodeControl.DEFAULT_CHECK_INTERVAL), 1)
	var center := Vector3.ZERO
	if count > 0:
		for i in count:
			if i % check_interval == 0:
				if DecodeControl.is_cancelled(cancellation_callback):
					return _instrumented_error(builder_started_usec, count, ERR_BUSY, "Gaussian payload construction was cancelled", "GDGS_CANCELLED", true)
				DecodeControl.report(progress_callback, 0.15 * float(i) / float(count))
			if not DecodeControl.finite_vector3(positions[i]):
				return _instrumented_error(builder_started_usec, count, ERR_INVALID_DATA, "Canonical gaussian positions contain a non-finite value", "GDGS_NON_FINITE")
			center += positions[i]
		center /= float(count)
		if not DecodeControl.finite_vector3(center):
			return _instrumented_error(builder_started_usec, count, ERR_INVALID_DATA, "Canonical gaussian center is non-finite", "GDGS_NON_FINITE")

	var points := PackedFloat32Array()
	points.resize(count * STRUCT_SIZE)

	var aabb_min_v := Vector3(INF, INF, INF)
	var aabb_max_v := Vector3(-INF, -INF, -INF)

	for i in count:
		if i % check_interval == 0:
			if DecodeControl.is_cancelled(cancellation_callback):
				return _instrumented_error(builder_started_usec, count, ERR_BUSY, "Gaussian payload construction was cancelled", "GDGS_CANCELLED", true)
			DecodeControl.report(progress_callback, 0.15 + 0.85 * float(i) / float(maxi(count, 1)))
		var pos: Vector3 = positions[i] - center
		var scale_linear: Vector3 = scales_linear[i]
		var rotation_value = rotations[i]
		var rotation := Quaternion(0.0, 0.0, 0.0, 1.0)
		if rotation_value is Quaternion:
			rotation = rotation_value.normalized()
		if not DecodeControl.finite_vector3(pos) or not DecodeControl.finite_vector3(scale_linear) or not DecodeControl.finite_quaternion(rotation) or not is_finite(opacities[i]):
			return _instrumented_error(builder_started_usec, count, ERR_INVALID_DATA, "Canonical gaussian data contains a non-finite value", "GDGS_NON_FINITE")

		scale_linear = Vector3(
			maxf(scale_linear.x, 1e-6),
			maxf(scale_linear.y, 1e-6),
			maxf(scale_linear.z, 1e-6)
		)

		aabb_min_v = aabb_min_v.min(pos)
		aabb_max_v = aabb_max_v.max(pos)

		var base := i * STRUCT_SIZE
		points[base + 0] = pos.x
		points[base + 1] = pos.y
		points[base + 2] = pos.z
		points[base + 3] = 0.0

		var scale_mat := Basis.from_scale(scale_linear)
		var rot_mat := Basis(rotation).transposed()
		var cov_3d := (scale_mat * rot_mat).transposed() * (scale_mat * rot_mat)
		if not DecodeControl.finite_vector3(cov_3d.x) or not DecodeControl.finite_vector3(cov_3d.y) or not DecodeControl.finite_vector3(cov_3d.z):
			return _instrumented_error(builder_started_usec, count, ERR_INVALID_DATA, "Canonical gaussian covariance is non-finite", "GDGS_NON_FINITE")

		points[base + 4] = cov_3d.x[0]
		points[base + 5] = cov_3d.y[0]
		points[base + 6] = cov_3d.z[0]
		points[base + 7] = cov_3d.y[1]
		points[base + 8] = cov_3d.z[1]
		points[base + 9] = cov_3d.z[2]

		points[base + 10] = clampf(opacities[i], 0.0, 1.0)
		points[base + 11] = 0.0

		var sh_offset := i * SH_FLOAT_COUNT
		for j in SH_FLOAT_COUNT:
			var coefficient := sh_coeffs[sh_offset + j]
			if not is_finite(coefficient):
				return _instrumented_error(builder_started_usec, count, ERR_INVALID_DATA, "Canonical gaussian SH data contains a non-finite value", "GDGS_NON_FINITE")
			points[base + 12 + j] = coefficient

	var point_data_byte := points.to_byte_array()
	points = PackedFloat32Array()
	var payload := {
		"schema": "gdgs-v1-payload",
		"point_count": count,
		"point_data_byte": point_data_byte,
		"aabb": AABB(aabb_min_v, aabb_max_v - aabb_min_v) if count > 0 else AABB()
	}
	payload_bytes = point_data_byte.size()
	GaussianDiagnostics.finish_builder(builder_started_usec, true, count, payload_bytes)
	DecodeControl.report(progress_callback, 1.0)

	return {
		"ok": true,
		"payload": payload
	}

static func publish(payload: Dictionary) -> Dictionary:
	if not Thread.is_main_thread():
		return _error(ERR_BUSY, "GaussianResource publication must run on the main thread")

	var count_value: Variant = payload.get("point_count", null)
	var point_data_value: Variant = payload.get("point_data_byte", null)
	var aabb_value: Variant = payload.get("aabb", null)
	if typeof(count_value) != TYPE_INT or typeof(point_data_value) != TYPE_PACKED_BYTE_ARRAY or typeof(aabb_value) != TYPE_AABB:
		return _error(ERR_INVALID_DATA, "Gaussian payload has an invalid type contract")

	var count: int = count_value
	var point_data_byte: PackedByteArray = point_data_value
	var expected_bytes := DecodeControl.checked_product(count, STRUCT_SIZE * 4, DecodeControl.DEFAULT_MAX_DECODED_BYTES)
	if expected_bytes < 0 or point_data_byte.size() != expected_bytes:
		return _error(ERR_INVALID_DATA, "Gaussian payload byte length does not match point_count")

	var resource = GaussianResourceScript.new()
	resource.point_count = count
	resource.point_data_byte = point_data_byte
	resource.point_data_float = PackedFloat32Array()
	resource.xyz = PackedVector3Array()
	resource.aabb = aabb_value
	return {
		"ok": true,
		"resource": resource
	}

static func _error(code: Error, message: String) -> Dictionary:
	return {
		"ok": false,
		"error": code,
		"message": message
	}

static func _instrumented_error(
	started_usec: int,
	point_count: int,
	code: Error,
	message: String,
	error_id: String = "",
	cancelled: bool = false
) -> Dictionary:
	GaussianDiagnostics.finish_builder(started_usec, false, point_count, 0, code)
	return DecodeControl.error(code, message, error_id, cancelled)
