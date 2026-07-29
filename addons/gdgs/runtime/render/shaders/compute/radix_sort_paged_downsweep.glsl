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
#define WORKGROUP_SIZE     (512)
#define PARTITION_DIVISION (8)
#define PARTITION_SIZE     (PARTITION_DIVISION * WORKGROUP_SIZE)
#define RADIX_PASSES       (16)

layout(local_size_x = WORKGROUP_SIZE) in;

layout(std430, set = 0, binding = 0) restrict readonly buffer Histogram {
	uint element_count;
	uint global_histogram[RADIX_PASSES * RADIX];
	uint partition_histogram[PARTITION_SIZE * RADIX];
};

layout(std430, set = 0, binding = 1) restrict buffer KeysBuffer {
	uvec4 keys[];
};

layout(std430, set = 0, binding = 2) restrict buffer ValuesBuffer {
	uint values[];
};

layout(push_constant) uniform PushConstant {
	int pass;
	uint in_offset;
	uint out_offset;
	float _pad;
};

shared uint local_histogram[PARTITION_SIZE];
shared uint local_histogram_sum[RADIX];

uint selected_word(in uvec4 key) {
	uint word_index = 3u - uint(pass >> 2);
	return key[word_index];
}

void main() {
	uint thread_index = gl_SubgroupInvocationID;
	uint subgroup_index = gl_SubgroupID;
	uint index = subgroup_index * gl_SubgroupSize + thread_index;
	uint partition_index = gl_WorkGroupID.x;
	uint partition_start = partition_index * PARTITION_SIZE;
	uint count = element_count;
	if (partition_start >= count) return;

	// The optimized path lays out shared-memory histograms using the runtime
	// subgroup count. A 512-thread workgroup with subgroups smaller than 32
	// requires more entries than the fixed arrays provide. Use a stable
	// scalar scatter on those devices; subgroup-32 hardware retains the
	// original parallel path.
	if (gl_SubgroupSize < 32u) {
		if (gl_LocalInvocationIndex == 0u) {
			for (uint digit = 0u; digit < RADIX; ++digit) {
				local_histogram_sum[digit] =
					global_histogram[RADIX * uint(pass) + digit]
					+ partition_histogram[
						RADIX * partition_index + digit
					];
			}
			uint partition_end = min(
				count,
				partition_start + PARTITION_SIZE
			);
			for (
				uint key_index = partition_start;
				key_index < partition_end;
				++key_index
			) {
				uvec4 key = keys[key_index + in_offset];
				uint radix = bitfieldExtract(
					selected_word(key),
					(pass & 3) * 8,
					8
				);
				uint destination = local_histogram_sum[radix]++;
				if (destination < count) {
					keys[destination + out_offset] = key;
					values[destination + out_offset] =
						values[key_index + in_offset];
				}
			}
		}
		return;
	}

	if (index < RADIX) {
		for (int i = 0; i < int(gl_NumSubgroups); ++i) {
			local_histogram[gl_NumSubgroups * index + uint(i)] = 0u;
		}
	}
	barrier();

	uvec4 local_keys[PARTITION_DIVISION];
	uint local_radix[PARTITION_DIVISION];
	uint local_offsets[PARTITION_DIVISION];
	uint subgroup_histogram[PARTITION_DIVISION];
	uint local_values[PARTITION_DIVISION];

	for (int i = 0; i < PARTITION_DIVISION; ++i) {
		uint key_index =
			partition_start
			+ (PARTITION_DIVISION * gl_SubgroupSize) * subgroup_index
			+ uint(i) * gl_SubgroupSize
			+ thread_index;
		uvec4 key = key_index < count
			? keys[key_index + in_offset]
			: uvec4(0xffffffffu);
		local_keys[i] = key;
		local_values[i] = key_index < count
			? values[key_index + in_offset]
			: 0u;

		uint radix = bitfieldExtract(
			selected_word(key),
			(pass & 3) * 8,
			8
		);
		local_radix[i] = radix;
		uvec4 mask = subgroupBallot(true);
		#pragma unroll
		for (int bit = 0; bit < 8; ++bit) {
			uint digit = (radix >> uint(bit)) & 1u;
			uvec4 ballot = subgroupBallot(digit == 1u);
			mask &= uvec4(digit - 1u) ^ ballot;
		}
		uint subgroup_offset = subgroupBallotExclusiveBitCount(mask);
		uint radix_count = subgroupBallotBitCount(mask);
		if (subgroup_offset == 0u) {
			atomicAdd(
				local_histogram[
					gl_NumSubgroups * radix + subgroup_index
				],
				radix_count
			);
			subgroup_histogram[i] = radix_count;
		} else {
			subgroup_histogram[i] = 0u;
		}
		local_offsets[i] = subgroup_offset;
	}
	barrier();

	for (
		uint histogram_index = index;
		histogram_index < RADIX * gl_NumSubgroups;
		histogram_index += WORKGROUP_SIZE
	) {
		uint value = local_histogram[histogram_index];
		uint sum = subgroupAdd(value);
		uint exclusive_value = subgroupExclusiveAdd(value);
		local_histogram[histogram_index] = exclusive_value;
		if (thread_index == 0u) {
			local_histogram_sum[
				histogram_index / gl_SubgroupSize
			] = sum;
		}
	}
	barrier();

	uint intermediate_offset =
		RADIX * gl_NumSubgroups / gl_SubgroupSize;
	if (index < intermediate_offset) {
		uint value = local_histogram_sum[index];
		uint sum = subgroupAdd(value);
		local_histogram_sum[index] = subgroupExclusiveAdd(value);
		if (thread_index == 0u) {
			local_histogram_sum[
				intermediate_offset + index / gl_SubgroupSize
			] = sum;
		}
	}
	barrier();

	uint intermediate_size = max(
		RADIX
			* gl_NumSubgroups
			/ gl_SubgroupSize
			/ gl_SubgroupSize,
		1u
	);
	if (index < intermediate_size) {
		uint value =
			local_histogram_sum[intermediate_offset + index];
		local_histogram_sum[
			intermediate_offset + index
		] = subgroupExclusiveAdd(value);
	}
	barrier();

	if (index < intermediate_offset) {
		local_histogram_sum[index] += local_histogram_sum[
			intermediate_offset + index / gl_SubgroupSize
		];
	}
	barrier();
	for (
		uint histogram_index = index;
		histogram_index < RADIX * gl_NumSubgroups;
		histogram_index += WORKGROUP_SIZE
	) {
		local_histogram[histogram_index] +=
			local_histogram_sum[
				histogram_index / gl_SubgroupSize
			];
	}
	barrier();

	for (int i = 0; i < PARTITION_DIVISION; ++i) {
		uint radix = local_radix[i];
		local_offsets[i] += local_histogram[
			gl_NumSubgroups * radix + subgroup_index
		];
		barrier();
		if (subgroup_histogram[i] > 0u) {
			atomicAdd(
				local_histogram[
					gl_NumSubgroups * radix + subgroup_index
				],
				subgroup_histogram[i]
			);
		}
		barrier();
	}

	if (index < RADIX) {
		uint previous = index == 0u
			? 0u
			: local_histogram[gl_NumSubgroups * index - 1u];
		local_histogram_sum[index] =
			global_histogram[RADIX * uint(pass) + index]
			+ partition_histogram[RADIX * partition_index + index]
			- previous;
	}
	barrier();

	uint destination_offsets[PARTITION_DIVISION];
	for (int i = 0; i < PARTITION_DIVISION; ++i) {
		local_histogram[local_offsets[i]] = selected_word(local_keys[i]);
	}
	barrier();
	for (
		uint local_index = index;
		local_index < PARTITION_SIZE;
		local_index += WORKGROUP_SIZE
	) {
		uint key_word = local_histogram[local_index];
		uint radix = bitfieldExtract(
			key_word,
			(pass & 3) * 8,
			8
		);
		destination_offsets[
			local_index / WORKGROUP_SIZE
		] = local_histogram_sum[radix] + local_index;
	}
	barrier();

	for (uint word_index = 0u; word_index < 4u; ++word_index) {
		for (int i = 0; i < PARTITION_DIVISION; ++i) {
			local_histogram[local_offsets[i]] =
				local_keys[i][word_index];
		}
		barrier();
		for (
			uint local_index = index;
			local_index < PARTITION_SIZE;
			local_index += WORKGROUP_SIZE
		) {
			uint destination = destination_offsets[
				local_index / WORKGROUP_SIZE
			];
			if (destination < count) {
				keys[destination + out_offset][word_index] =
					local_histogram[local_index];
			}
		}
		barrier();
	}

	for (int i = 0; i < PARTITION_DIVISION; ++i) {
		local_histogram[local_offsets[i]] = local_values[i];
	}
	barrier();
	for (
		uint local_index = index;
		local_index < PARTITION_SIZE;
		local_index += WORKGROUP_SIZE
	) {
		uint destination = destination_offsets[
			local_index / WORKGROUP_SIZE
		];
		if (destination < count) {
			values[destination + out_offset] =
				local_histogram[local_index];
		}
	}
}
