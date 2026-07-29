#[compute]
#version 460

#define SH_C0 0.28209479177387814
#define SH_C1 0.4886025119029199
#define SH_C2_0 1.0925484305920792
#define SH_C2_1 1.0925484305920792
#define SH_C2_2 0.31539156525252005
#define SH_C2_3 1.0925484305920792
#define SH_C2_4 0.5462742152960396
#define SH_C3_0 0.5900435899266435
#define SH_C3_1 2.890611442640554
#define SH_C3_2 0.4570457994644658
#define SH_C3_3 0.3731763325901154
#define SH_C3_4 0.4570457994644658
#define SH_C3_5 1.445305721320277
#define SH_C3_6 0.5900435899266435

#define TILE_SIZE (16)
#define RANGE_VALID (1u)
#define RANGE_INVALID_PROJECTION (2u)
#define DECODE_COVARIANCE(c) (mat3(c[0], c[1], c[2], c[1], c[3], c[4], c[2], c[4], c[5]))

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

struct Splat {
	vec3 position;
	float time;
	float covariance[6];
	float opacity;
	float _pad;
	float sh_coefficients[16 * 3];
};

struct RasterizeData {
	vec2 image_pos;
	vec2 pos_xy;
	vec3 conic;
	float pos_z;
	vec4 color;
	vec4 depth_data;
};

// std430 stride is 48 bytes. The final three words carry the stable
// page/index tie break while retaining the approved range layout.
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

layout(std430, set = 0, binding = 0) restrict readonly buffer SplatsBuffer {
	Splat splat_buffer[];
};

layout(std430, set = 0, binding = 1) restrict writeonly buffer CulledBuffer {
	RasterizeData culled_buffer[];
};

layout(std430, set = 0, binding = 2) restrict writeonly buffer ProjectionRangesBuffer {
	ProjectionRange projection_ranges[];
};

layout(std430, set = 0, binding = 3) restrict readonly buffer InstanceTransformsBuffer {
	mat4 instance_model_matrices[];
};

layout(std140, set = 0, binding = 4) restrict uniform Uniforms {
	vec3 camera_pos;
	float time;
	ivec2 dims;
	int point_count;
	int _uniform_pad0;
	mat4 view_matrix;
	mat4 projection_matrix;
};

layout(push_constant) uniform PushConstants {
	uint local_point_count;
	uint output_base;
	uint instance_index;
	uint physical_page_id;
};

float ease_out_cubic(in float x) {
	float a = 1.0 - x;
	return 1.0 - a * a * a;
}

bool finite_float(in float value) {
	return !isnan(value) && !isinf(value);
}

bool finite_vec2(in vec2 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

bool finite_vec3(in vec3 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

bool finite_vec4(in vec4 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

ProjectionRange empty_range(in uint status, in uint page_id, in uint point_index) {
	ProjectionRange result;
	result.bounds = uvec4(0u);
	result.requested = 0u;
	result.prefix_offset = 0u;
	result.admitted_offset = 0xffffffffu;
	result.ordered_depth = 0u;
	result.status = status;
	result.page_id = page_id;
	result.point_index = point_index;
	result._pad0 = 0u;
	return result;
}

#define SH_COEFFICIENTS(x) (vec3(sh_coefficients[x * 3], sh_coefficients[x * 3 + 1], sh_coefficients[x * 3 + 2]))
vec3 get_color(in vec3 view_dir, in float sh_coefficients[16 * 3]) {
	const float x = view_dir.x;
	const float y = view_dir.y;
	const float z = view_dir.z;
	const float xx = x * x;
	const float yy = y * y;
	const float zz = z * z;
	const float xy = x * y;
	const float yz = y * z;
	const float xz = x * z;
	return max(vec3(0.0), 0.5
		+ SH_COEFFICIENTS(0) * SH_C0
		- SH_COEFFICIENTS(1) * SH_C1 * y
		+ SH_COEFFICIENTS(2) * SH_C1 * z
		- SH_COEFFICIENTS(3) * SH_C1 * x
		+ SH_COEFFICIENTS(4) * SH_C2_0 * xy
		- SH_COEFFICIENTS(5) * SH_C2_1 * yz
		+ SH_COEFFICIENTS(6) * SH_C2_2 * (2.0 * zz - xx - yy)
		- SH_COEFFICIENTS(7) * SH_C2_3 * xz
		+ SH_COEFFICIENTS(8) * SH_C2_4 * (xx - yy)
		- SH_COEFFICIENTS(9) * SH_C3_0 * y * (3.0 * xx - yy)
		+ SH_COEFFICIENTS(10) * SH_C3_1 * x * yz
		- SH_COEFFICIENTS(11) * SH_C3_2 * y * (4.0 * zz - xx - yy)
		+ SH_COEFFICIENTS(12) * SH_C3_3 * z * (2.0 * zz - 3.0 * xx - 3.0 * yy)
		- SH_COEFFICIENTS(13) * SH_C3_4 * x * (4.0 * zz - xx - yy)
		+ SH_COEFFICIENTS(14) * SH_C3_5 * z * (xx - yy)
		- SH_COEFFICIENTS(15) * SH_C3_6 * x * (xx - 3.0 * yy));
}

vec3 project_covariance(in mat3 covariance_3d, in float scale_modifier, in vec3 mean, in ivec2 image_dims) {
	const mat3 cov_3d = covariance_3d * scale_modifier * scale_modifier;
	vec2 tan_fov_inv = vec2(projection_matrix[0][0], projection_matrix[1][1]);
	vec2 focal = vec2(image_dims - 1) * 0.5 * tan_fov_inv;
	vec2 tan_fov = 1.0 / abs(tan_fov_inv);
	float stable_view_z = min(mean.z, -0.001);
	float depth_inv = -1.0 / stable_view_z;
	focal *= depth_inv;
	mean.xy = clamp(mean.xy * depth_inv, -tan_fov * 1.3, tan_fov * 1.3);
	mat3 jacobian = mat3(
		focal.x, 0.0, 0.0,
		0.0, focal.y, 0.0,
		focal.x * mean.x, focal.y * mean.y, 0.0);
	mat3 screen_transform = jacobian * mat3(view_matrix);
	mat3 cov_2d = screen_transform * cov_3d * transpose(screen_transform);
	return vec3(cov_2d[0][0] + 0.3, cov_2d[0][1], cov_2d[1][1] + 0.3);
}

uvec4 get_rect(in vec2 image_pos, in vec2 radius, in uvec2 grid_size) {
	vec2 lower = clamp((image_pos - radius) / float(TILE_SIZE), vec2(0.0), vec2(grid_size));
	vec2 upper = clamp(ceil((image_pos + radius) / float(TILE_SIZE)), vec2(0.0), vec2(grid_size));
	return uvec4(floor(lower), upper);
}

void store_invalid(in uint output_id, in uint point_id) {
	projection_ranges[output_id] = empty_range(
		RANGE_INVALID_PROJECTION,
		physical_page_id,
		point_id
	);
}

void main() {
	const uint local_id = gl_GlobalInvocationID.x;
	if (local_id >= local_point_count) return;
	const uint output_id = output_base + local_id;
	if (output_id >= uint(point_count) || output_id < output_base) return;
	projection_ranges[output_id] = empty_range(
		0u,
		physical_page_id,
		local_id
	);

	const Splat splat = splat_buffer[local_id];
	mat4 model_matrix = instance_model_matrices[instance_index];
	float is_visible = model_matrix[0][3];
	if (!finite_float(is_visible)) {
		store_invalid(output_id, local_id);
		return;
	}
	if (is_visible < 0.5) return;
	model_matrix[0][3] = 0.0;

	mat3 object_linear = mat3(model_matrix);
	mat3 world_covariance = object_linear * DECODE_COVARIANCE(splat.covariance) * transpose(object_linear);
	vec4 world_pos = model_matrix * vec4(splat.position, 1.0);
	vec4 view_pos = view_matrix * world_pos;
	vec4 clip_pos = projection_matrix * view_pos;
	if (!finite_vec4(world_pos) || !finite_vec4(view_pos) || !finite_vec4(clip_pos) || !finite_vec3(world_covariance[0]) || !finite_vec3(world_covariance[1]) || !finite_vec3(world_covariance[2])) {
		store_invalid(output_id, local_id);
		return;
	}
	if (clip_pos.w <= 0.0 || view_pos.z >= 0.0) return;
	vec3 ndc_pos = clip_pos.xyz / clip_pos.w;
	if (!finite_vec3(ndc_pos)) {
		store_invalid(output_id, local_id);
		return;
	}
	if (ndc_pos.z > 1.0) return;

	float splat_time = time - splat.time;
	float time_factor = ease_out_cubic(clamp(splat_time, 0.0, 1.0));
	float time_factor_late = ease_out_cubic(clamp(splat_time - 0.35, 0.0, 1.0));
	float splat_opacity = splat.opacity * time_factor_late * time_factor_late;
	float splat_scale = mix(2.0, 1.0, time_factor_late);
	if (!finite_float(splat_opacity) || !finite_float(splat_scale) || splat_opacity <= 0.0) return;

	vec3 covariance = project_covariance(world_covariance, splat_scale, view_pos.xyz, dims);
	if (!finite_vec3(covariance)) {
		store_invalid(output_id, local_id);
		return;
	}
	float determinant = covariance.x * covariance.z - covariance.y * covariance.y;
	if (!finite_float(determinant) || determinant <= 1e-12) {
		store_invalid(output_id, local_id);
		return;
	}
	float middle = 0.5 * (covariance.x + covariance.z);
	float discriminant = max(0.1, middle * middle - determinant);
	if (!finite_float(discriminant)) {
		store_invalid(output_id, local_id);
		return;
	}
	vec2 eigenvalues = middle + vec2(1.0, -1.0) * sqrt(discriminant);
	if (!finite_vec2(eigenvalues) || any(lessThan(eigenvalues, vec2(0.0)))) {
		store_invalid(output_id, local_id);
		return;
	}

	vec2 image_pos = ((ndc_pos.xy + 1.0) * 0.5 - vec2(1.0, 0.75) * (1.0 - time_factor)) * vec2(dims - 1);
	float radius_factor = pow(splat_opacity, 0.2) * 2.5;
	vec2 uncapped_radius = radius_factor * sqrt(max(covariance.xz, vec2(0.0)));
	float max_radius = min(1024.0, float(min(dims.x, dims.y)));
	if (!finite_vec2(image_pos) || !finite_vec2(uncapped_radius) || !finite_float(max_radius) || max_radius <= 0.0) {
		store_invalid(output_id, local_id);
		return;
	}
	float cap_scale = max(1.0, max(uncapped_radius.x, uncapped_radius.y) / max_radius);
	float inverse_cap_scale_squared = 1.0 / (cap_scale * cap_scale);
	covariance *= inverse_cap_scale_squared;
	determinant = covariance.x * covariance.z - covariance.y * covariance.y;
	if (!finite_float(determinant) || determinant <= 1e-12) {
		store_invalid(output_id, local_id);
		return;
	}
	vec2 radius = min(uncapped_radius / cap_scale, vec2(max_radius));

	uvec2 grid_size = uvec2((dims + TILE_SIZE - 1) / TILE_SIZE);
	uvec4 rect_bounds = get_rect(image_pos, radius, grid_size);
	uvec2 rect_size = rect_bounds.zw - rect_bounds.xy;
	uint requested = rect_size.x * rect_size.y;
	if (requested == 0u) return;

	float view_depth = -view_pos.z;
	vec3 view_delta = world_pos.xyz - camera_pos;
	float view_delta_length = length(view_delta);
	if (!finite_float(view_depth) || view_depth < 0.0 || !finite_float(view_delta_length)) {
		store_invalid(output_id, local_id);
		return;
	}
	vec3 view_dir = view_delta_length > 1e-8 ? view_delta / view_delta_length : vec3(0.0, 0.0, 1.0);
	vec3 color = get_color(view_dir, splat.sh_coefficients);
	if (!finite_vec3(color)) {
		store_invalid(output_id, local_id);
		return;
	}

	RasterizeData data;
	data.image_pos = image_pos;
	data.conic = vec3(covariance.z, -covariance.y, covariance.x) / determinant;
	data.color = vec4(color, splat_opacity);
	data.pos_xy = world_pos.xy;
	data.pos_z = world_pos.z;
	data.depth_data = vec4(view_depth, 0.0, 0.0, 0.0);
	culled_buffer[output_id] = data;

	ProjectionRange range_data = empty_range(
		RANGE_VALID,
		physical_page_id,
		local_id
	);
	range_data.bounds = rect_bounds;
	range_data.requested = requested;
	range_data.ordered_depth = floatBitsToUint(view_depth);
	projection_ranges[output_id] = range_data;
}
