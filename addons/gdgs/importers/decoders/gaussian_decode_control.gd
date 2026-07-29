@tool
extends RefCounted

const DEFAULT_IO_CHUNK_BYTES := 4 * 1024 * 1024
const DEFAULT_CHECK_INTERVAL := 1024
const DEFAULT_MAX_SOURCE_BYTES := 2 * 1024 * 1024 * 1024
const DEFAULT_MAX_DECODED_BYTES := 8 * 1024 * 1024 * 1024
const DEFAULT_MAX_POINT_COUNT := int(DEFAULT_MAX_DECODED_BYTES / 240)

static func report(callback: Callable, value: float) -> void:
	if callback.is_valid():
		callback.call(clampf(value, 0.0, 1.0))

static func is_cancelled(callback: Callable) -> bool:
	return callback.is_valid() and bool(callback.call())

static func cancellation_error() -> Dictionary:
	return error(ERR_BUSY, "Gaussian source decoding was cancelled", "GDGS_CANCELLED", true)

static func error(code: Error, message: String, error_id: String = "", cancelled: bool = false) -> Dictionary:
	var result := {
		"ok": false,
		"error": code,
		"message": message
	}
	if not error_id.is_empty():
		result["error_id"] = error_id
	if cancelled:
		result["cancelled"] = true
	return result

static func limit(limits: Dictionary, name: String, fallback: int) -> int:
	return maxi(int(limits.get(name, fallback)), 0)

static func checked_product(left: int, right: int, ceiling: int) -> int:
	if left < 0 or right < 0 or ceiling < 0:
		return -1
	if left == 0 or right == 0:
		return 0
	if left > int(ceiling / right):
		return -1
	return left * right

static func finite_vector3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

static func finite_quaternion(value: Quaternion) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z) and is_finite(value.w)
