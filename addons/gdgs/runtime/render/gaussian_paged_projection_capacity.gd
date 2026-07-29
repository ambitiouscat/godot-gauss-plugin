@tool
extends RefCounted
class_name GaussianPagedProjectionCapacity

# Section 4 paged workspace. The existing layout-v2/single-page path remains
# unchanged for rollback. A paged key is four uint32 words and is radix-sorted
# least-significant word first: point, page, depth, then screen bin.

const WORKSPACE_LAYOUT_VERSION := 3
const TILE_SIZE := 16
const RADIX := 256
const RADIX_PASSES := 16
const PARTITION_SIZE := 4096
const UINT32_MAX := 0xffff_ffff
const MAX_PAIR_CAPACITY := 0x7fff_ffff

const DEFAULT_WORKSPACE_BUDGET_BYTES := 256 * 1024 * 1024
const MAX_WORKSPACE_BUDGET_BYTES := 2 * 1024 * 1024 * 1024
const MAX_SUPPORTED_VIEWPORT_SIZE := Vector2i(16_384, 16_384)
# Godot 4.7 does not expose VkPhysicalDeviceLimits::maxStorageBufferRange
# through RenderingDevice.limit_get(). Vulkan guarantees at least 128 MiB, so
# every individually bound storage buffer stays below that portable floor.
# This prevents a layout that fits the aggregate workspace budget from still
# violating a smaller device's descriptor range limit.
const PORTABLE_STORAGE_BUFFER_RANGE_BYTES := 128 * 1024 * 1024

const PROJECTION_RANGE_BYTES_PER_SPLAT := 12 * 4
const PREFIX_BLOCK_SUM_BYTES_PER_BLOCK := 4
const KEY_WORDS_PER_PAIR := 4
const KEY_BYTES_PER_PAIR := KEY_WORDS_PER_PAIR * 4 * 2
const VALUE_BYTES_PER_PAIR := 4 * 2
const PAIR_BYTES := KEY_BYTES_PER_PAIR + VALUE_BYTES_PER_PAIR
const TELEMETRY_BYTES := 16 * 4
const INDIRECT_DISPATCH_BYTES := 6 * 4
const TILE_BOUNDS_BYTES_PER_BIN := 2 * 4
const HISTOGRAM_FIXED_BYTES := 4 + RADIX_PASSES * RADIX * 4
const HISTOGRAM_BYTES_PER_PARTITION := RADIX * 4

static func checked_bin_grid(viewport_size: Vector2i) -> Dictionary:
	if viewport_size.x <= 0 or viewport_size.y <= 0:
		return _invalid(
			"GDGS_INVALID_VIEWPORT",
			"Viewport dimensions must be positive"
		)
	if (
		viewport_size.x > MAX_SUPPORTED_VIEWPORT_SIZE.x
		or viewport_size.y > MAX_SUPPORTED_VIEWPORT_SIZE.y
	):
		return _invalid(
			"GDGS_UNSUPPORTED_VIEWPORT",
			"Viewport dimensions exceed the supported profile"
		)
	var grid := Vector2i(
		(viewport_size.x + TILE_SIZE - 1) / TILE_SIZE,
		(viewport_size.y + TILE_SIZE - 1) / TILE_SIZE
	)
	var bin_count := int(grid.x) * int(grid.y)
	if bin_count <= 0 or bin_count > UINT32_MAX:
		return _invalid(
			"GDGS_BIN_GRID_OVERFLOW",
			"Screen-bin grid cannot be represented by a uint32 ID"
		)
	return {
		"valid": true,
		"grid": grid,
		"bin_count": bin_count,
		"last_bin_id": bin_count - 1
	}

static func logical_key(
	bin_id: int,
	ordered_depth: int,
	page_id: int,
	point_index: int
) -> PackedInt64Array:
	return PackedInt64Array([
		bin_id & UINT32_MAX,
		ordered_depth & UINT32_MAX,
		page_id & UINT32_MAX,
		point_index & UINT32_MAX
	])

static func logical_key_less(
	left: PackedInt64Array,
	right: PackedInt64Array
) -> bool:
	if left.size() != KEY_WORDS_PER_PAIR or right.size() != KEY_WORDS_PER_PAIR:
		return false
	for word in KEY_WORDS_PER_PAIR:
		if left[word] != right[word]:
			return left[word] < right[word]
	return false

static func radix_word_for_pass(pass_index: int) -> int:
	if pass_index < 0 or pass_index >= RADIX_PASSES:
		return -1
	# uvec4 storage order is bin, depth, page, point. LSD radix order is
	# point, page, depth, bin so the final ordering is tuple-lexicographic.
	return 3 - int(pass_index / 4)

static func compute_workspace_layout(
	point_count: int,
	viewport_size: Vector2i,
	budget_bytes: int,
	maximum_pair_capacity: int = MAX_PAIR_CAPACITY
) -> Dictionary:
	if point_count < 0 or point_count > MAX_PAIR_CAPACITY:
		return _invalid(
			"GDGS_INVALID_POINT_COUNT",
			"Logical point count is outside the paged uint32 profile"
		)
	if (
		budget_bytes <= 0
		or budget_bytes > MAX_WORKSPACE_BUDGET_BYTES
	):
		return _invalid(
			"GDGS_INVALID_WORKSPACE_BUDGET",
			"Workspace budget is outside the supported range"
		)
	var grid_result := checked_bin_grid(viewport_size)
	if not bool(grid_result.get("valid", false)):
		return grid_result

	var projection_range_bytes := (
		point_count * PROJECTION_RANGE_BYTES_PER_SPLAT
	)
	if projection_range_bytes > PORTABLE_STORAGE_BUFFER_RANGE_BYTES:
		return _storage_buffer_limit_exceeded(
			"projection_ranges",
			projection_range_bytes
		)
	var prefix_block_count := (
		int((point_count + 255) / 256) if point_count > 0 else 0
	)
	var prefix_block_sum_bytes := (
		prefix_block_count * PREFIX_BLOCK_SUM_BYTES_PER_BLOCK
	)
	var tile_bounds_bytes := (
		int(grid_result["bin_count"]) * TILE_BOUNDS_BYTES_PER_BIN
	)
	var fixed_bytes := (
		projection_range_bytes
		+ prefix_block_sum_bytes
		+ tile_bounds_bytes
		+ TELEMETRY_BYTES
		+ INDIRECT_DISPATCH_BYTES
	)
	if fixed_bytes > budget_bytes:
		return _invalid(
			"GDGS_WORKSPACE_BUDGET_EXHAUSTED",
			"Fixed paged projection workspace exceeds its byte ceiling"
		)

	# The approved per-view overlap-pair ceiling bounds the search directly. A
	# budget large enough to afford more pairs must yield the approved cap, not
	# a rejection, so this is a clamp rather than a post-hoc check.
	var pair_capacity_ceiling := mini(
		mini(MAX_PAIR_CAPACITY, maximum_pair_capacity),
		mini(
			int(
				PORTABLE_STORAGE_BUFFER_RANGE_BYTES
					/ KEY_BYTES_PER_PAIR
			),
			int(
				PORTABLE_STORAGE_BUFFER_RANGE_BYTES
					/ VALUE_BYTES_PER_PAIR
			)
		)
	)
	if pair_capacity_ceiling < 0:
		return _invalid(
			"GDGS_INVALID_PAIR_CAPACITY_CEILING",
			"Maximum pair capacity ceiling is negative"
		)
	var low := 0
	var high := mini(
		int((budget_bytes - fixed_bytes) / PAIR_BYTES),
		pair_capacity_ceiling
	)
	while low < high:
		var candidate := low + int((high - low + 1) / 2)
		if _workspace_bytes(candidate, fixed_bytes) <= budget_bytes:
			low = candidate
		else:
			high = candidate - 1

	var pair_capacity := low
	var partition_count := (
		int((pair_capacity + PARTITION_SIZE - 1) / PARTITION_SIZE)
		if pair_capacity > 0
		else 0
	)
	var histogram_bytes := (
		HISTOGRAM_FIXED_BYTES
		+ partition_count * HISTOGRAM_BYTES_PER_PARTITION
	)
	if histogram_bytes > PORTABLE_STORAGE_BUFFER_RANGE_BYTES:
		return _storage_buffer_limit_exceeded(
			"histogram",
			histogram_bytes
		)
	var pair_bytes := pair_capacity * PAIR_BYTES
	var total_bytes := fixed_bytes + pair_bytes + histogram_bytes
	if total_bytes > budget_bytes:
		return _invalid(
			"GDGS_WORKSPACE_ARITHMETIC_ERROR",
			"Checked paged workspace exceeded its byte ceiling"
		)
	return {
		"valid": true,
		"layout_version": WORKSPACE_LAYOUT_VERSION,
		"budget_bytes": budget_bytes,
		"total_bytes": total_bytes,
		"pair_capacity": pair_capacity,
		"pair_capacity_ceiling": pair_capacity_ceiling,
		"configured_pair_capacity_ceiling": maximum_pair_capacity,
		"storage_buffer_range_bytes":
			PORTABLE_STORAGE_BUFFER_RANGE_BYTES,
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
	var partition_count := (
		int((pair_capacity + PARTITION_SIZE - 1) / PARTITION_SIZE)
		if pair_capacity > 0
		else 0
	)
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

static func _storage_buffer_limit_exceeded(
	allocation: String,
	allocation_bytes: int
) -> Dictionary:
	return {
		"valid": false,
		"error_id": "GDGS_STORAGE_BUFFER_RANGE_EXCEEDED",
		"message": (
			"Paged storage buffer exceeds the portable Vulkan range"
		),
		"allocation": allocation,
		"allocation_bytes": allocation_bytes,
		"storage_buffer_range_bytes":
			PORTABLE_STORAGE_BUFFER_RANGE_BYTES
	}
