#[compute]
#version 460 core

#extension GL_KHR_shader_subgroup_basic: enable

/**
 * vulkan_radix_sort, modified under the MIT license.
 * Source: https://github.com/jaesung-cs/vulkan_radix_sort/tree/master
 */
#define RADIX              (256)
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

layout(std430, set = 0, binding = 1) restrict readonly buffer KeysBuffer {
	uvec4 keys[];
};

layout(push_constant) uniform PushConstant {
	int pass;
	uint in_offset;
	float _pad0;
	float _pad1;
};

shared uint local_histogram[RADIX];

uint selected_word(in uvec4 key) {
	uint word_index = 3u - uint(pass >> 2);
	return key[word_index];
}

void main() {
	uint thread_index = gl_SubgroupInvocationID;
	uint subgroup_index = gl_SubgroupID;
	uint index = subgroup_index * gl_SubgroupSize + thread_index;
	uint count = element_count;
	uint partition_index = gl_WorkGroupID.x;
	uint partition_start = partition_index * PARTITION_SIZE;
	if (partition_start >= count) return;

	if (index < RADIX) local_histogram[index] = 0u;
	barrier();
	for (int i = 0; i < PARTITION_DIVISION; ++i) {
		uint key_index = partition_start + WORKGROUP_SIZE * uint(i) + index;
		uvec4 key = key_index < count
			? keys[key_index + in_offset]
			: uvec4(0xffffffffu);
		uint radix = bitfieldExtract(
			selected_word(key),
			8 * (pass & 3),
			8
		);
		atomicAdd(local_histogram[radix], 1u);
	}
	barrier();
	if (index < RADIX) {
		partition_histogram[RADIX * partition_index + index] =
			local_histogram[index];
		atomicAdd(
			global_histogram[RADIX * uint(pass) + index],
			local_histogram[index]
		);
	}
}
