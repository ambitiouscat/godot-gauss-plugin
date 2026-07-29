@tool
extends RefCounted
class_name GaussianProjectionCapacity

const WORKSPACE_LAYOUT_VERSION := 2
const TILE_SIZE := 16
const RADIX := 256
const RADIX_PASSES := 8
const PARTITION_SIZE := 4096
const UINT32_MAX := 0xffff_ffff
const MAX_PAIR_CAPACITY := 0x7fff_ffff

const DEFAULT_WORKSPACE_BUDGET_BYTES := 256 * 1024 * 1024
const MAX_WORKSPACE_BUDGET_BYTES := 2 * 1024 * 1024 * 1024
const SUPPORTED_ULTRAWIDE_SIZE := Vector2i(11_520, 2160)
const MAX_SUPPORTED_VIEWPORT_SIZE := Vector2i(16_384, 16_384)

const PROJECTION_RANGE_BYTES_PER_SPLAT := 12 * 4
const PREFIX_BLOCK_SUM_BYTES_PER_BLOCK := 4
const KEY_BYTES_PER_PAIR := 2 * 4 * 2
const VALUE_BYTES_PER_PAIR := 4 * 2
const PAIR_BYTES := KEY_BYTES_PER_PAIR + VALUE_BYTES_PER_PAIR
const TELEMETRY_BYTES := 16 * 4
const INDIRECT_DISPATCH_BYTES := 6 * 4
const TILE_BOUNDS_BYTES_PER_BIN := 2 * 4
const HISTOGRAM_FIXED_BYTES := 4 + RADIX_PASSES * RADIX * 4
const HISTOGRAM_BYTES_PER_PARTITION := RADIX * 4

static func checked_bin_grid(viewport_size: Vector2i) -> Dictionary:
	if viewport_size.x <= 0 or viewport_size.y <= 0:
		return _invalid("GDGS_INVALID_VIEWPORT", "Viewport dimensions must be positive")
	if viewport_size.x > MAX_SUPPORTED_VIEWPORT_SIZE.x or viewport_size.y > MAX_SUPPORTED_VIEWPORT_SIZE.y:
		return _invalid("GDGS_UNSUPPORTED_VIEWPORT", "Viewport dimensions exceed the supported profile")

	var grid := Vector2i(
		(viewport_size.x + TILE_SIZE - 1) / TILE_SIZE,
		(viewport_size.y + TILE_SIZE - 1) / TILE_SIZE
	)
	var bin_count := int(grid.x) * int(grid.y)
	if bin_count <= 0 or bin_count > UINT32_MAX:
		return _invalid("GDGS_BIN_GRID_OVERFLOW", "Screen-bin grid cannot be represented by a 32-bit ID")
	return {
		"valid": true,
		"grid": grid,
		"bin_count": bin_count,
		"last_bin_id": bin_count - 1
	}

static func checked_rect_count(image_position: Vector2, radius: float, viewport_size: Vector2i) -> Dictionary:
	var grid_result := checked_bin_grid(viewport_size)
	if not grid_result.get("valid", false):
		return grid_result
	if not is_finite(image_position.x) or not is_finite(image_position.y) or not is_finite(radius):
		return _invalid("GDGS_NON_FINITE_PROJECTION", "Projected position or radius is non-finite")
	if radius < 0.0:
		return _invalid("GDGS_INVALID_PROJECTION_RADIUS", "Projected radius must not be negative")

	var grid: Vector2i = grid_result["grid"]
	var lower := (image_position - Vector2(radius, radius)) / float(TILE_SIZE)
	var upper := (image_position + Vector2(radius, radius)) / float(TILE_SIZE)
	if not is_finite(lower.x) or not is_finite(lower.y) or not is_finite(upper.x) or not is_finite(upper.y):
		return _invalid("GDGS_PROJECTION_EXTENT_OVERFLOW", "Projected rectangle extent is non-finite")

	var minimum := Vector2i(
		int(floor(clampf(lower.x, 0.0, float(grid.x)))),
		int(floor(clampf(lower.y, 0.0, float(grid.y))))
	)
	var maximum := Vector2i(
		int(ceil(clampf(upper.x, 0.0, float(grid.x)))),
		int(ceil(clampf(upper.y, 0.0, float(grid.y))))
	)
	var width := maxi(maximum.x - minimum.x, 0)
	var height := maxi(maximum.y - minimum.y, 0)
	var pair_count := int(width) * int(height)
	if pair_count > UINT32_MAX:
		return _invalid("GDGS_PROJECTION_COUNT_OVERFLOW", "Projected screen-bin count exceeds the counter range")
	return {
		"valid": true,
		"minimum": minimum,
		"maximum": maximum,
		"pair_count": pair_count
	}

static func legacy_packed_key(bin_id: int, ordered_depth: int) -> int:
	return ((bin_id << 16) | (ordered_depth & 0xffff)) & UINT32_MAX

static func logical_key(bin_id: int, ordered_depth: int) -> Vector2i:
	return Vector2i(bin_id, ordered_depth)

static func logical_key_less(left: Vector2i, right: Vector2i) -> bool:
	return left.x < right.x or (left.x == right.x and left.y < right.y)

static func admit_whole_splats(requested_counts: PackedInt32Array, pair_capacity: int) -> Dictionary:
	var capacity := clampi(pair_capacity, 0, MAX_PAIR_CAPACITY)
	var offsets := PackedInt64Array()
	offsets.resize(requested_counts.size())
	offsets.fill(-1)
	var requested := 0
	var admitted := 0
	var dropped := 0
	var saturated := false
	var prefix_open := true

	for index in requested_counts.size():
		var count := int(requested_counts[index])
		if count < 0:
			saturated = true
			continue
		if requested > UINT32_MAX - count:
			requested = UINT32_MAX
			saturated = true
		else:
			requested += count
		if prefix_open and count <= capacity - admitted:
			offsets[index] = admitted
			admitted += count
		else:
			prefix_open = false
			dropped += count

	return {
		"offsets": offsets,
		"requested": requested,
		"admitted": admitted,
		"emitted": admitted,
		"dropped": dropped,
		"capacity": capacity,
		"high_water": admitted,
		"overflow": dropped > 0,
		"counter_saturated": saturated
	}

static func compute_workspace_layout(point_count: int, viewport_size: Vector2i, budget_bytes: int) -> Dictionary:
	if point_count < 0:
		return _invalid("GDGS_INVALID_POINT_COUNT", "Point count must not be negative")
	if budget_bytes <= 0 or budget_bytes > MAX_WORKSPACE_BUDGET_BYTES:
		return _invalid("GDGS_INVALID_WORKSPACE_BUDGET", "Workspace budget is outside the supported range")
	var grid_result := checked_bin_grid(viewport_size)
	if not grid_result.get("valid", false):
		return grid_result

	var projection_range_bytes := point_count * PROJECTION_RANGE_BYTES_PER_SPLAT
	var prefix_block_count := int((point_count + 255) / 256) if point_count > 0 else 0
	var prefix_block_sum_bytes := prefix_block_count * PREFIX_BLOCK_SUM_BYTES_PER_BLOCK
	var tile_bounds_bytes := int(grid_result["bin_count"]) * TILE_BOUNDS_BYTES_PER_BIN
	var fixed_bytes := projection_range_bytes + prefix_block_sum_bytes + tile_bounds_bytes + TELEMETRY_BYTES + INDIRECT_DISPATCH_BYTES
	if fixed_bytes > budget_bytes:
		return _invalid("GDGS_WORKSPACE_BUDGET_EXHAUSTED", "Fixed projection workspace exceeds its byte ceiling")

	var low := 0
	var high := mini(int((budget_bytes - fixed_bytes) / PAIR_BYTES), MAX_PAIR_CAPACITY)
	while low < high:
		var candidate := low + int((high - low + 1) / 2)
		if _workspace_bytes(candidate, fixed_bytes) <= budget_bytes:
			low = candidate
		else:
			high = candidate - 1

	var pair_capacity := low
	var partition_count := int((pair_capacity + PARTITION_SIZE - 1) / PARTITION_SIZE) if pair_capacity > 0 else 0
	var histogram_bytes := HISTOGRAM_FIXED_BYTES + partition_count * HISTOGRAM_BYTES_PER_PARTITION
	var pair_bytes := pair_capacity * PAIR_BYTES
	var total_bytes := fixed_bytes + pair_bytes + histogram_bytes
	if total_bytes > budget_bytes:
		return _invalid("GDGS_WORKSPACE_ARITHMETIC_ERROR", "Checked workspace layout exceeded its byte ceiling")

	return {
		"valid": true,
		"layout_version": WORKSPACE_LAYOUT_VERSION,
		"budget_bytes": budget_bytes,
		"total_bytes": total_bytes,
		"pair_capacity": pair_capacity,
		"pair_bytes": pair_bytes,
		"partition_count": partition_count,
		"prefix_block_count": prefix_block_count,
		"grid": grid_result["grid"],
		"bin_count": grid_result["bin_count"],
		"allocations": {
			"projection_ranges": projection_range_bytes,
			"prefix_block_sums": prefix_block_sum_bytes,
			"key_records": pair_capacity * KEY_BYTES_PER_PAIR,
			"values": pair_capacity * VALUE_BYTES_PER_PAIR,
			"histogram": histogram_bytes,
			"telemetry": TELEMETRY_BYTES,
			"indirect_dispatch": INDIRECT_DISPATCH_BYTES,
			"tile_bounds": tile_bounds_bytes
		}
	}

static func _workspace_bytes(pair_capacity: int, fixed_bytes: int) -> int:
	var partition_count := int((pair_capacity + PARTITION_SIZE - 1) / PARTITION_SIZE) if pair_capacity > 0 else 0
	return (
		fixed_bytes
		+ pair_capacity * PAIR_BYTES
		+ HISTOGRAM_FIXED_BYTES
		+ partition_count * HISTOGRAM_BYTES_PER_PARTITION
	)

static func _invalid(error_id: String, message: String) -> Dictionary:
	return {
		"valid": false,
		"error_id": error_id,
		"message": message
	}
