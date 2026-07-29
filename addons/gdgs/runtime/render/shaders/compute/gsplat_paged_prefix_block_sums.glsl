#[compute]
#version 460

#define FLAG_OVERFLOW (1u)
#define FLAG_COUNTER_SATURATED (2u)

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) restrict buffer BlockSumsBuffer {
	uint block_sums[];
};

layout(std430, set = 0, binding = 1) restrict buffer TelemetryBuffer {
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

layout(std140, set = 0, binding = 2) restrict uniform PrefixConstants {
	uint point_count;
	uint block_count;
	uint capacity;
	uint frame_generation;
	uint grid_width;
	uint grid_height;
	uint allocated_workspace_bytes;
	uint workspace_layout_version;
};

void main() {
	uint running_total = 0u;
	uint telemetry_flags = 0u;
	for (uint block_index = 0u; block_index < block_count; ++block_index) {
		uint block_total = block_sums[block_index];
		block_sums[block_index] = running_total;
		if (running_total > 0xffffffffu - block_total) {
			running_total = 0xffffffffu;
			telemetry_flags |= FLAG_COUNTER_SATURATED;
		} else {
			running_total += block_total;
		}
	}

	bool group_fits = running_total <= capacity &&
		(telemetry_flags & FLAG_COUNTER_SATURATED) == 0u;
	telemetry.layout_version = workspace_layout_version;
	telemetry.generation = frame_generation;
	telemetry.resident_splats = point_count;
	telemetry.visible_splats = 0u;
	telemetry.requested_pairs = running_total;
	telemetry.admitted_pairs = 0u;
	telemetry.emitted_pairs = 0u;
	telemetry.dropped_pairs = group_fits ? 0u : running_total;
	telemetry.pair_capacity = capacity;
	telemetry.workspace_bytes = allocated_workspace_bytes;
	telemetry.high_water = 0u;
	telemetry.invalid_projection_splats = 0u;
	telemetry.flags = telemetry_flags |
		(group_fits ? 0u : FLAG_OVERFLOW);
	telemetry.grid_x = grid_width;
	telemetry.grid_y = grid_height;
	telemetry.first_dropped_splat =
		group_fits ? 0xffffffffu : 0u;
}
