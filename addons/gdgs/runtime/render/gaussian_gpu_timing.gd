@tool
extends RefCounted
class_name GaussianGpuTiming

const SCHEMA := "gdgs-gpu-timing-v1"
const MARKER_PREFIX := "gdgs_gpu_timing/"
const RESULT_TIMEOUT_USEC := 60_000_000
const NANOSECONDS_PER_MICROSECOND := 1000.0
const REQUIRED_PHASES := [
	"begin",
	"projection_end",
	"sort_end",
	"boundaries_end",
	"raster_end",
	"composite_begin",
	"composite_end"
]

static func marker(token: int, phase: String) -> String:
	return "%s%d/%s" % [MARKER_PREFIX, token, phase]

static func build_sample(
	pending: Dictionary,
	frame: int,
	names: Array,
	gpu_times_nsec: Array
) -> Dictionary:
	var token := int(pending.get("token", 0))
	if token <= 0 or names.size() != gpu_times_nsec.size():
		return {
			"schema": SCHEMA,
			"valid": false,
			"error_id": "GDGS_GPU_TIMING_INPUT_INVALID",
			"token": token
		}

	var prefix := "%s%d/" % [MARKER_PREFIX, token]
	var marker_times := {}
	for index in names.size():
		var name := String(names[index])
		if not name.begins_with(prefix):
			continue
		marker_times[name.trim_prefix(prefix)] = int(gpu_times_nsec[index])

	for phase: String in REQUIRED_PHASES:
		if not marker_times.has(phase):
			return {}

	for index in range(1, REQUIRED_PHASES.size()):
		var previous_phase: String = REQUIRED_PHASES[index - 1]
		var phase: String = REQUIRED_PHASES[index]
		if int(marker_times[phase]) < int(marker_times[previous_phase]):
			return {
				"schema": SCHEMA,
				"valid": false,
				"error_id": "GDGS_GPU_TIMING_ORDER_INVALID",
				"token": token,
				"frame": frame,
				"previous_phase": previous_phase,
				"phase": phase
			}

	var begin_nsec := int(marker_times["begin"])
	var projection_end_nsec := int(marker_times["projection_end"])
	var sort_end_nsec := int(marker_times["sort_end"])
	var boundaries_end_nsec := int(marker_times["boundaries_end"])
	var raster_end_nsec := int(marker_times["raster_end"])
	var composite_begin_nsec := int(marker_times["composite_begin"])
	var composite_end_nsec := int(marker_times["composite_end"])
	return {
		"schema": SCHEMA,
		"valid": true,
		"token": token,
		"frame": frame,
		"generation": int(pending.get("generation", 0)),
		"texture_size": pending.get("texture_size", Vector2i.ZERO),
		"requested_usec": int(pending.get("requested_usec", 0)),
		"captured_usec": Time.get_ticks_usec(),
		"gpu_usec": {
			"projection_and_admission": _nsec_delta_to_usec(begin_nsec, projection_end_nsec),
			"radix_sort": _nsec_delta_to_usec(projection_end_nsec, sort_end_nsec),
			"boundaries": _nsec_delta_to_usec(sort_end_nsec, boundaries_end_nsec),
			"gaussian_raster": _nsec_delta_to_usec(boundaries_end_nsec, raster_end_nsec),
			"pre_composite_gap": _nsec_delta_to_usec(raster_end_nsec, composite_begin_nsec),
			"composite": _nsec_delta_to_usec(composite_begin_nsec, composite_end_nsec),
			"total": _nsec_delta_to_usec(begin_nsec, composite_end_nsec)
		},
		"marker_gpu_nsec": marker_times
	}

static func _nsec_delta_to_usec(begin_nsec: int, end_nsec: int) -> float:
	return float(end_nsec - begin_nsec) / NANOSECONDS_PER_MICROSECOND

static func timeout_sample(pending: Dictionary) -> Dictionary:
	return {
		"schema": SCHEMA,
		"valid": false,
		"error_id": "GDGS_GPU_TIMING_TIMEOUT",
		"token": int(pending.get("token", 0)),
		"generation": int(pending.get("generation", 0)),
		"texture_size": pending.get("texture_size", Vector2i.ZERO),
		"requested_usec": int(pending.get("requested_usec", 0)),
		"captured_usec": Time.get_ticks_usec()
	}
