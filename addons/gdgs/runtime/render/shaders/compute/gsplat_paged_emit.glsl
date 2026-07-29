#[compute]
#version 460

#define TILE_SIZE (16)
#define RANGE_ADMITTED (4u)
#define FLAG_WRITER_INVARIANT (4u)
#define FLAG_KEY_RANGE (8u)

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

struct ProjectionRange {
	uvec4 bounds;
	uint requested;
	uint prefix_offset;
	uint admitted_offset;
	uint ordered_depth;
	uint status;
	uint page_id;
	uint point_index;
	uint _pad0;
};

layout(std430, set = 0, binding = 0) restrict readonly buffer ProjectionRangesBuffer {
	ProjectionRange projection_ranges[];
};

layout(std430, set = 0, binding = 1) restrict writeonly buffer SortKeysBuffer {
	uvec4 sort_keys[];
};

layout(std430, set = 0, binding = 2) restrict writeonly buffer SortValuesBuffer {
	uint sort_values[];
};

layout(std430, set = 0, binding = 3) restrict buffer TelemetryBuffer {
	uint layout_version;
	uint generation;
	uint resident_splats;
	uint visible_splats;
	uint requested_pairs;
	uint admitted_pairs;
	uint emitted_pairs;
	uint dropped_pairs;
	uint pair_capacity;
	uint workspace_bytes;
	uint high_water;
	uint invalid_projection_splats;
	uint flags;
	uint grid_x;
	uint grid_y;
	uint first_dropped_splat;
} telemetry;

layout(std140, set = 0, binding = 4) restrict uniform Uniforms {
	vec3 camera_pos;
	float time;
	ivec2 dims;
	int point_count;
	int _uniform_pad0;
};

void main() {
	uint id = gl_GlobalInvocationID.x;
	if (id >= uint(point_count)) return;
	ProjectionRange range_data = projection_ranges[id];
	if ((range_data.status & RANGE_ADMITTED) == 0u || range_data.requested == 0u) return;

	uvec2 grid_size = uvec2((dims + TILE_SIZE - 1) / TILE_SIZE);
	uint local_index = 0u;
	uint emitted = 0u;
	for (uint y = range_data.bounds.y; y < range_data.bounds.w; ++y) {
		for (uint x = range_data.bounds.x; x < range_data.bounds.z; ++x) {
			if (local_index >= range_data.requested || range_data.admitted_offset > telemetry.pair_capacity || local_index >= telemetry.pair_capacity - range_data.admitted_offset) {
				atomicOr(telemetry.flags, FLAG_WRITER_INVARIANT);
				local_index += 1u;
				continue;
			}
			uint tile_id = y * grid_size.x + x;
			if (tile_id >= telemetry.grid_x * telemetry.grid_y) {
				atomicOr(telemetry.flags, FLAG_KEY_RANGE);
				local_index += 1u;
				continue;
			}
			uint write_index = range_data.admitted_offset + local_index;
			sort_keys[write_index] = uvec4(
				tile_id,
				range_data.ordered_depth,
				range_data.page_id,
				range_data.point_index
			);
			sort_values[write_index] = id;
			atomicMax(telemetry.high_water, write_index + 1u);
			emitted += 1u;
			local_index += 1u;
		}
	}
	if (local_index != range_data.requested) {
		atomicOr(telemetry.flags, FLAG_WRITER_INVARIANT);
	}
	atomicAdd(telemetry.emitted_pairs, emitted);
}
