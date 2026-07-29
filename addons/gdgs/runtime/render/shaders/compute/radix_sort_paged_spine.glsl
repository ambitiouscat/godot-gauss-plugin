#[compute]
#version 460 core

#extension GL_KHR_shader_subgroup_basic: enable
#extension GL_KHR_shader_subgroup_arithmetic: enable
#extension GL_KHR_shader_subgroup_ballot: enable

/**
 * vulkan_radix_sort, modified under the MIT license.
 * Source: https://github.com/jaesung-cs/vulkan_radix_sort/tree/master
 */
#define RADIX              (256)
#define SUBGROUP_SIZE      (32)
#define WORKGROUP_SIZE     (512)
#define PARTITION_DIVISION (8)
#define PARTITION_SIZE     (PARTITION_DIVISION * WORKGROUP_SIZE)
#define RADIX_PASSES       (16)

layout(local_size_x = WORKGROUP_SIZE) in;

layout(std430, set = 0, binding = 0) restrict buffer Histogram {
	uint element_count;
	uint global_histogram[RADIX_PASSES * RADIX];
	uint partition_histogram[PARTITION_SIZE * RADIX];
};

layout(push_constant) uniform PushConstant {
	int pass;
	float _pad0;
	float _pad1;
	float _pad2;
};

shared uint reduction;
shared uint intermediate[SUBGROUP_SIZE];

void main() {
	uint thread_index = gl_SubgroupInvocationID;
	uint subgroup_index = gl_SubgroupID;
	uint index = subgroup_index * gl_SubgroupSize + thread_index;
	uint radix = gl_WorkGroupID.x;
	uint count = element_count;
	uint partition_count =
		(count + PARTITION_SIZE - 1u) / PARTITION_SIZE;

	// The optimized scan below stores one value per subgroup in
	// intermediate[SUBGROUP_SIZE]. Devices with subgroups smaller than 32
	// can expose more than 32 subgroups for this 512-thread workgroup, so
	// that path would write past shared memory. Keep the fast path for
	// subgroup-32 hardware and use a stable scalar scan everywhere else.
	if (gl_SubgroupSize < SUBGROUP_SIZE) {
		if (gl_LocalInvocationIndex == 0u) {
			uint running = 0u;
			for (
				uint partition_index = 0u;
				partition_index < partition_count;
				++partition_index
			) {
				uint histogram_index =
					RADIX * partition_index + radix;
				uint value = partition_histogram[histogram_index];
				partition_histogram[histogram_index] = running;
				running += value;
			}
			if (radix == 0u) {
				running = 0u;
				for (uint digit = 0u; digit < RADIX; ++digit) {
					uint histogram_index =
						RADIX * uint(pass) + digit;
					uint value = global_histogram[histogram_index];
					global_histogram[histogram_index] = running;
					running += value;
				}
			}
		}
		return;
	}

	if (index == 0u) reduction = 0u;
	barrier();
	for (uint i = 0u; WORKGROUP_SIZE * i < partition_count; ++i) {
		uint partition_index = WORKGROUP_SIZE * i + index;
		uint value = partition_index < partition_count
			? partition_histogram[RADIX * partition_index + radix]
			: 0u;
		uint exclusive_value = subgroupExclusiveAdd(value) + reduction;
		uint sum = subgroupAdd(value);
		if (subgroupElect()) intermediate[subgroup_index] = sum;
		barrier();
		if (index < gl_NumSubgroups) {
			uint intermediate_exclusive =
				subgroupExclusiveAdd(intermediate[index]);
			uint intermediate_sum = subgroupAdd(intermediate[index]);
			intermediate[index] = intermediate_exclusive;
			if (index == 0u) reduction += intermediate_sum;
		}
		barrier();
		if (partition_index < partition_count) {
			exclusive_value += intermediate[subgroup_index];
			partition_histogram[
				RADIX * partition_index + radix
			] = exclusive_value;
		}
		barrier();
	}

	if (gl_WorkGroupID.x == 0u && index < RADIX) {
		uint value = global_histogram[RADIX * uint(pass) + index];
		uint exclusive_value = subgroupExclusiveAdd(value);
		uint sum = subgroupAdd(value);
		if (subgroupElect()) intermediate[subgroup_index] = sum;
		barrier();
		if (index < RADIX / gl_SubgroupSize) {
			intermediate[index] =
				subgroupExclusiveAdd(intermediate[index]);
		}
		barrier();
		exclusive_value += intermediate[subgroup_index];
		global_histogram[
			RADIX * uint(pass) + index
		] = exclusive_value;
	}
}
