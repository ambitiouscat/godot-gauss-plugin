#[compute]
#version 460

#define BLOCK_SIZE (256)
#define RANGE_VALID (1u)
#define RANGE_INVALID_PROJECTION (2u)
#define RANGE_ADMITTED (4u)
#define FLAG_OVERFLOW (1u)
#define FLAG_COUNTER_SATURATED (2u)

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

layout(std430, set = 0, binding = 1) restrict readonly buffer BlockSumsBuffer {
	uint block_sums[];
};

layout(std430, set = 0, binding = 2) restrict buffer TelemetryBuffer {
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

layout(std430, set = 0, binding = 3) restrict buffer Histograms {
	uint sort_buffer_size;
	uint histogram[];
};

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
	if ((range_data.status & RANGE_INVALID_PROJECTION) != 0u) {
		atomicAdd(telemetry.invalid_projection_splats, 1u);
	}
	if ((range_data.status & RANGE_VALID) == 0u ||
		range_data.requested == 0u) return;
	atomicAdd(telemetry.visible_splats, 1u);

	// Prefix-block-sums decides the complete candidate group once. On
	// rejection every range remains unadmitted, so emit has no legal writer.
	if (
		(telemetry.flags & FLAG_OVERFLOW) != 0u ||
		telemetry.requested_pairs > telemetry.pair_capacity
	) {
		range_data.admitted_offset = 0xffffffffu;
		projection_ranges[id] = range_data;
		return;
	}

	uint block_offset = block_sums[gl_WorkGroupID.x];
	uint local_offset = range_data.prefix_offset;
	uint prefix_offset = block_offset + local_offset;
	if (prefix_offset < block_offset || prefix_offset < local_offset) {
		prefix_offset = 0xffffffffu;
		atomicOr(telemetry.flags, FLAG_COUNTER_SATURATED);
	}
	range_data.prefix_offset = prefix_offset;

	bool fits = prefix_offset <= telemetry.pair_capacity &&
		range_data.requested <=
			telemetry.pair_capacity - prefix_offset;
	if (!fits) {
		range_data.admitted_offset = 0xffffffffu;
		atomicMin(telemetry.first_dropped_splat, id);
		atomicOr(telemetry.flags, FLAG_OVERFLOW);
		projection_ranges[id] = range_data;
		return;
	}

	range_data.admitted_offset = prefix_offset;
	range_data.status |= RANGE_ADMITTED;
	projection_ranges[id] = range_data;
	atomicAdd(telemetry.admitted_pairs, range_data.requested);
	atomicAdd(sort_buffer_size, range_data.requested);
}
