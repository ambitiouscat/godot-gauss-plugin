#[compute]
#version 460

#define BLOCK_SIZE (256)
#define RANGE_VALID (1u)

layout(local_size_x = BLOCK_SIZE, local_size_y = 1, local_size_z = 1) in;

struct ProjectionRange {
	uvec4 bounds;
	uint requested;
	uint prefix_offset;
	uint admitted_offset;
	uint ordered_depth;
	uint status;
	uint _pad0;
	uint _pad1;
	uint _pad2;
};

layout(std430, set = 0, binding = 0) restrict buffer ProjectionRangesBuffer {
	ProjectionRange projection_ranges[];
};

layout(std430, set = 0, binding = 1) restrict writeonly buffer BlockSumsBuffer {
	uint block_sums[];
};

layout(std140, set = 0, binding = 2) restrict uniform Uniforms {
	vec3 camera_pos;
	float time;
	ivec2 dims;
	int point_count;
	int _uniform_pad0;
};

shared uint scan_values[BLOCK_SIZE];

uint saturating_add(in uint lhs, in uint rhs) {
	return lhs > 0xffffffffu - rhs ? 0xffffffffu : lhs + rhs;
}

void main() {
	uint id = gl_GlobalInvocationID.x;
	uint local_id = gl_LocalInvocationID.x;
	uint requested = 0u;
	if (id < uint(point_count) && (projection_ranges[id].status & RANGE_VALID) != 0u) {
		requested = projection_ranges[id].requested;
	}
	scan_values[local_id] = requested;
	barrier();

	for (uint offset = 1u; offset < BLOCK_SIZE; offset <<= 1u) {
		uint addend = local_id >= offset ? scan_values[local_id - offset] : 0u;
		barrier();
		if (local_id >= offset) {
			scan_values[local_id] = saturating_add(scan_values[local_id], addend);
		}
		barrier();
	}

	if (id < uint(point_count)) {
		projection_ranges[id].prefix_offset = scan_values[local_id] - requested;
	}
	if (local_id == BLOCK_SIZE - 1u) {
		block_sums[gl_WorkGroupID.x] = scan_values[local_id];
	}
}
