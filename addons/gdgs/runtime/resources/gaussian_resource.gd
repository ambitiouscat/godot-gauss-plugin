@tool
@icon("res://addons/gdgs/editor/icons/gaussian_resource.svg")
extends Resource
class_name GaussianResource

# GPU-ready std430 layout.
# Each splat occupies 60 float32 values (240 bytes).
const FLOATS_PER_SPLAT := 60
const BYTES_PER_FLOAT := 4
const BYTES_PER_SPLAT := FLOATS_PER_SPLAT * BYTES_PER_FLOAT

@export var point_count: int = 0

# Legacy compatibility fields. New builders leave both arrays empty; existing
# serialized resources remain readable through the fallback helpers below.
@export var point_data_float: PackedFloat32Array
@export var point_data_byte: PackedByteArray
@export var xyz: PackedVector3Array
@export var aabb: AABB = AABB()

func has_valid_canonical_payload() -> bool:
	return point_count >= 0 and point_data_byte.size() == point_count * BYTES_PER_SPLAT

func has_valid_legacy_float_payload() -> bool:
	return point_count >= 0 and point_data_float.size() == point_count * FLOATS_PER_SPLAT

func get_canonical_point_bytes() -> PackedByteArray:
	if has_valid_canonical_payload():
		return point_data_byte
	if has_valid_legacy_float_payload():
		return point_data_float.to_byte_array()
	return PackedByteArray()

func extract_positions(max_positions: int = -1) -> PackedVector3Array:
	var result := PackedVector3Array()
	if point_count <= 0:
		return result
	var available := has_valid_canonical_payload() or has_valid_legacy_float_payload() or xyz.size() == point_count
	if not available:
		return result

	var output_count := point_count if max_positions <= 0 else mini(point_count, max_positions)
	result.resize(output_count)
	var sample_step := float(point_count) / float(output_count)
	for output_index in output_count:
		var point_index := mini(int(floor(float(output_index) * sample_step)), point_count - 1)
		result[output_index] = _read_position(point_index)
	return result

func _read_position(point_index: int) -> Vector3:
	if point_index < 0 or point_index >= point_count:
		return Vector3.ZERO
	if has_valid_canonical_payload():
		var byte_offset := point_index * BYTES_PER_SPLAT
		return Vector3(
			point_data_byte.decode_float(byte_offset),
			point_data_byte.decode_float(byte_offset + BYTES_PER_FLOAT),
			point_data_byte.decode_float(byte_offset + BYTES_PER_FLOAT * 2)
		)
	if has_valid_legacy_float_payload():
		var float_offset := point_index * FLOATS_PER_SPLAT
		return Vector3(
			point_data_float[float_offset],
			point_data_float[float_offset + 1],
			point_data_float[float_offset + 2]
		)
	if xyz.size() == point_count:
		return xyz[point_index]
	return Vector3.ZERO
