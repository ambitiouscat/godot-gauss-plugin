@tool
extends RefCounted
class_name GdgsGaussianDiagnostics

## Test-only counters used by the lazy-loading regression harness.
##
## Diagnostics are disabled unless `GDGS_DIAGNOSTICS=1` is present or a test
## calls `configure_for_tests(true)`.  All shared state is protected because
## future loader callbacks may report from WorkerThreadPool workers.

const ENABLE_ENV := "GDGS_DIAGNOSTICS"
const REPORT_ENV := "GDGS_DIAGNOSTICS_REPORT"
const MAX_EVENTS := 256

static var _mutex := Mutex.new()
static var _force_enabled := false
static var _state: Dictionary = {}

static func configure_for_tests(enabled: bool) -> void:
	_force_enabled = enabled
	if enabled:
		reset("headless-tests")

static func is_enabled() -> bool:
	return _force_enabled or OS.get_environment(ENABLE_ENV) == "1"

static func reset(label: String = "") -> void:
	if not is_enabled():
		return
	_mutex.lock()
	_state = _make_state(label)
	_mutex.unlock()

static func begin_session(label: String) -> void:
	if not is_enabled():
		return
	_mutex.lock()
	_ensure_state_locked(label)
	if String(_state.get("label", "")).is_empty():
		_state["label"] = label
	_mutex.unlock()

static func begin_import(source_path: String) -> int:
	if not is_enabled():
		return -1
	var started_usec := Time.get_ticks_usec()
	_mutex.lock()
	_ensure_state_locked("import")
	_state["import_invocations"] = int(_state["import_invocations"]) + 1
	_state["active_imports"] = int(_state["active_imports"]) + 1
	_append_event_locked("import_started", {
		"source": source_path.get_file()
	})
	_sample_memory_locked()
	_mutex.unlock()
	return started_usec

static func finish_import(started_usec: int, ok: bool, error_code: int = OK) -> void:
	if started_usec < 0 or not is_enabled():
		return
	var duration_usec := maxi(Time.get_ticks_usec() - started_usec, 0)
	_mutex.lock()
	_ensure_state_locked("import")
	_state["active_imports"] = maxi(int(_state["active_imports"]) - 1, 0)
	_state["import_total_usec"] = int(_state["import_total_usec"]) + duration_usec
	_state["import_successes" if ok else "import_failures"] = int(_state["import_successes" if ok else "import_failures"]) + 1
	_append_event_locked("import_finished", {
		"ok": ok,
		"error": error_code,
		"duration_usec": duration_usec
	})
	_sample_memory_locked()
	_mutex.unlock()

static func begin_decoder(format_name: String, source_path: String) -> int:
	if not is_enabled():
		return -1
	var started_usec := Time.get_ticks_usec()
	_mutex.lock()
	_ensure_state_locked("decode")
	_state["decoder_invocations"] = int(_state["decoder_invocations"]) + 1
	_state["active_decoders"] = int(_state["active_decoders"]) + 1
	var by_format: Dictionary = _state["decoder_invocations_by_format"]
	by_format[format_name] = int(by_format.get(format_name, 0)) + 1
	_append_event_locked("decoder_started", {
		"format": format_name,
		"source": source_path.get_file()
	})
	_sample_memory_locked()
	_mutex.unlock()
	return started_usec

static func finish_decoder(started_usec: int, format_name: String, ok: bool, error_code: int = OK) -> void:
	if started_usec < 0 or not is_enabled():
		return
	var duration_usec := maxi(Time.get_ticks_usec() - started_usec, 0)
	_mutex.lock()
	_ensure_state_locked("decode")
	_state["active_decoders"] = maxi(int(_state["active_decoders"]) - 1, 0)
	_state["decoder_total_usec"] = int(_state["decoder_total_usec"]) + duration_usec
	_state["decoder_successes" if ok else "decoder_failures"] = int(_state["decoder_successes" if ok else "decoder_failures"]) + 1
	_append_event_locked("decoder_finished", {
		"format": format_name,
		"ok": ok,
		"error": error_code,
		"duration_usec": duration_usec
	})
	_sample_memory_locked()
	_mutex.unlock()

static func begin_builder(point_count: int) -> int:
	if not is_enabled():
		return -1
	var started_usec := Time.get_ticks_usec()
	_mutex.lock()
	_ensure_state_locked("build")
	_state["builder_invocations"] = int(_state["builder_invocations"]) + 1
	_state["active_builders"] = int(_state["active_builders"]) + 1
	_append_event_locked("builder_started", {
		"point_count": point_count
	})
	_sample_memory_locked()
	_mutex.unlock()
	return started_usec

static func finish_builder(started_usec: int, ok: bool, point_count: int, payload_bytes: int, error_code: int = OK) -> void:
	if started_usec < 0 or not is_enabled():
		return
	var duration_usec := maxi(Time.get_ticks_usec() - started_usec, 0)
	_mutex.lock()
	_ensure_state_locked("build")
	_state["active_builders"] = maxi(int(_state["active_builders"]) - 1, 0)
	_state["builder_total_usec"] = int(_state["builder_total_usec"]) + duration_usec
	_state["builder_successes" if ok else "builder_failures"] = int(_state["builder_successes" if ok else "builder_failures"]) + 1
	_state["last_built_point_count"] = point_count
	_state["last_built_payload_bytes"] = payload_bytes
	_state["total_built_payload_bytes"] = int(_state["total_built_payload_bytes"]) + payload_bytes
	_append_event_locked("builder_finished", {
		"ok": ok,
		"error": error_code,
		"point_count": point_count,
		"payload_bytes": payload_bytes,
		"duration_usec": duration_usec
	})
	_sample_memory_locked()
	_mutex.unlock()

static func set_active_jobs(count: int) -> void:
	_set_gauge("active_jobs", count)

static func set_cache_leases(count: int) -> void:
	_set_gauge("cache_leases", count)

static func set_queued_source_bytes(bytes: int) -> void:
	_set_gauge("queued_source_bytes", bytes)

static func set_registry_metrics(registered_nodes: int, retained_payload_bytes: int) -> void:
	if not is_enabled():
		return
	_mutex.lock()
	_ensure_state_locked("runtime")
	_state["registered_nodes"] = maxi(registered_nodes, 0)
	_state["retained_payload_bytes"] = maxi(retained_payload_bytes, 0)
	_state["peak_registered_nodes"] = maxi(int(_state["peak_registered_nodes"]), registered_nodes)
	_state["peak_retained_payload_bytes"] = maxi(int(_state["peak_retained_payload_bytes"]), retained_payload_bytes)
	_sample_memory_locked()
	_mutex.unlock()

static func set_gpu_bytes(bytes: int) -> void:
	if not is_enabled():
		return
	_mutex.lock()
	_ensure_state_locked("runtime")
	_state["gpu_bytes"] = maxi(bytes, 0)
	_state["peak_gpu_bytes"] = maxi(int(_state["peak_gpu_bytes"]), bytes)
	_mutex.unlock()

static func snapshot() -> Dictionary:
	if not is_enabled():
		return {}
	_mutex.lock()
	_ensure_state_locked("snapshot")
	_sample_memory_locked()
	var result := _state.duplicate(true)
	result["captured_usec"] = Time.get_ticks_usec()
	result["elapsed_usec"] = maxi(int(result["captured_usec"]) - int(result["started_usec"]), 0)
	result["static_memory_bytes"] = OS.get_static_memory_usage()
	result["static_memory_peak_bytes"] = OS.get_static_memory_peak_usage()
	_mutex.unlock()
	return result

static func flush_environment_report() -> Error:
	if not is_enabled():
		return OK
	var report_path := OS.get_environment(REPORT_ENV)
	if report_path.is_empty():
		return OK
	return write_report(report_path)

static func write_report(path: String) -> Error:
	var report := snapshot()
	if report.is_empty():
		return ERR_UNCONFIGURED
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(report, "\t") + "\n")
	return OK

static func _set_gauge(name: String, value: int) -> void:
	if not is_enabled():
		return
	_mutex.lock()
	_ensure_state_locked("runtime")
	_state[name] = maxi(value, 0)
	var peak_name := "peak_%s" % name
	if _state.has(peak_name):
		_state[peak_name] = maxi(int(_state[peak_name]), value)
	_sample_memory_locked()
	_mutex.unlock()

static func _ensure_state_locked(label: String) -> void:
	if _state.is_empty():
		_state = _make_state(label)

static func _make_state(label: String) -> Dictionary:
	var memory_bytes := OS.get_static_memory_usage()
	return {
		"schema": "gdgs-diagnostics-v1",
		"label": label,
		"started_usec": Time.get_ticks_usec(),
		"initial_static_memory_bytes": memory_bytes,
		"sampled_static_memory_bytes": memory_bytes,
		"sampled_static_memory_peak_bytes": memory_bytes,
		"import_invocations": 0,
		"import_successes": 0,
		"import_failures": 0,
		"import_total_usec": 0,
		"active_imports": 0,
		"decoder_invocations": 0,
		"decoder_successes": 0,
		"decoder_failures": 0,
		"decoder_total_usec": 0,
		"active_decoders": 0,
		"decoder_invocations_by_format": {},
		"builder_invocations": 0,
		"builder_successes": 0,
		"builder_failures": 0,
		"builder_total_usec": 0,
		"active_builders": 0,
		"last_built_point_count": 0,
		"last_built_payload_bytes": 0,
		"total_built_payload_bytes": 0,
		"active_jobs": 0,
		"peak_active_jobs": 0,
		"cache_leases": 0,
		"peak_cache_leases": 0,
		"queued_source_bytes": 0,
		"peak_queued_source_bytes": 0,
		"registered_nodes": 0,
		"peak_registered_nodes": 0,
		"retained_payload_bytes": 0,
		"peak_retained_payload_bytes": 0,
		"gpu_bytes": 0,
		"peak_gpu_bytes": 0,
		"events": []
	}

static func _append_event_locked(name: String, details: Dictionary) -> void:
	var events: Array = _state["events"]
	var event := details.duplicate(true)
	event["name"] = name
	event["ticks_usec"] = Time.get_ticks_usec()
	events.push_back(event)
	if events.size() > MAX_EVENTS:
		events.pop_front()

static func _sample_memory_locked() -> void:
	var current := OS.get_static_memory_usage()
	_state["sampled_static_memory_bytes"] = current
	_state["sampled_static_memory_peak_bytes"] = maxi(int(_state.get("sampled_static_memory_peak_bytes", 0)), current)
