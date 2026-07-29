@tool
extends Node
class_name GaussianAssetLoader

const LoadContract = preload("res://addons/gdgs/runtime/loading/gaussian_load_contract.gd")
const LoadWorker = preload("res://addons/gdgs/runtime/loading/gaussian_load_worker.gd")
const GaussianResourceBuilder = preload("res://addons/gdgs/importers/builders/gaussian_resource_builder.gd")
const GaussianSourceDecoder = preload("res://addons/gdgs/importers/gaussian_source_decoder.gd")
const GaussianDiagnostics = preload("res://addons/gdgs/runtime/diagnostics/gaussian_diagnostics.gd")
const DecodeControl = preload("res://addons/gdgs/importers/decoders/gaussian_decode_control.gd")

signal request_state_changed(request_id: int, generation: int, state: int)
signal request_progress(request_id: int, generation: int, progress: float)
signal request_completed(request_id: int, generation: int, lease: Variant)
signal request_failed(request_id: int, generation: int, error: int, error_id: String, message: String)
signal request_cancelled(request_id: int, generation: int)
signal shutting_down(loader: Node)

const DEFAULT_MAX_ACTIVE_JOBS := 2
const DEFAULT_MAX_QUEUED_JOBS := 64
const DEFAULT_MAX_QUEUED_SOURCE_BYTES := 4 * 1024 * 1024 * 1024

var _limits := {
	"max_active_jobs": DEFAULT_MAX_ACTIVE_JOBS,
	"max_queued_jobs": DEFAULT_MAX_QUEUED_JOBS,
	"max_queued_source_bytes": DEFAULT_MAX_QUEUED_SOURCE_BYTES,
	"max_source_bytes": DecodeControl.DEFAULT_MAX_SOURCE_BYTES,
	"max_decoded_bytes": DecodeControl.DEFAULT_MAX_DECODED_BYTES,
	"max_point_count": DecodeControl.DEFAULT_MAX_POINT_COUNT,
	"io_chunk_bytes": DecodeControl.DEFAULT_IO_CHUNK_BYTES,
	"check_interval": DecodeControl.DEFAULT_CHECK_INTERVAL
}

var _requests: Dictionary = {}
var _jobs: Dictionary = {}
var _queued_jobs: Array = []
var _cache: Dictionary = {}
var _leases: Dictionary = {}
var _next_request_id := 1
var _next_lease_id := 1
var _active_task_count := 0
var _queued_source_bytes := 0
var _admitting := true

func _ready() -> void:
	set_process(true)
	_update_diagnostics()

func _exit_tree() -> void:
	shutdown()

func configure_limits(overrides: Dictionary) -> Error:
	if not _jobs.is_empty() or not _requests.is_empty() or not _leases.is_empty():
		return ERR_BUSY
	for key in overrides:
		if _limits.has(key):
			_limits[key] = maxi(int(overrides[key]), 0)
	_limits["max_active_jobs"] = maxi(int(_limits["max_active_jobs"]), 1)
	_limits["io_chunk_bytes"] = maxi(int(_limits["io_chunk_bytes"]), 1)
	_limits["check_interval"] = maxi(int(_limits["check_interval"]), 1)
	return OK

func request_load(source_path: String, client_id: int, generation: int) -> Dictionary:
	if not Thread.is_main_thread():
		return _error(ERR_BUSY, "Gaussian load requests must be created on the main thread", "GDGS_WRONG_THREAD")
	if not _admitting:
		return _error(ERR_UNAVAILABLE, "Gaussian asset loader is shutting down", "GDGS_SHUTTING_DOWN")

	var source_result := inspect_source(source_path, _limits)
	if not source_result.get("ok", false):
		return source_result
	var canonical_path: String = source_result["source_path"]
	var source_size: int = source_result["source_size"]
	var modified_time: int = source_result["modified_time"]
	var cache_key := _make_cache_key(canonical_path, source_size, modified_time)

	var request := LoadContract.LoadRequest.new()
	request.id = _next_request_id
	_next_request_id += 1
	request.client_id = client_id
	request.generation = generation
	request.cache_key = cache_key
	request.source_path = canonical_path
	request.state = LoadContract.LifecycleState.QUEUED
	_requests[request.id] = request

	if _cache.has(cache_key):
		call_deferred("_complete_cache_hit", request.id)
		return _request_result(request)

	if _jobs.has(cache_key):
		var shared_job = _jobs[cache_key]
		shared_job.waiting_request_ids.push_back(request.id)
		request.state = LoadContract.LifecycleState.LOADING if shared_job.started else LoadContract.LifecycleState.QUEUED
		call_deferred("_emit_request_state", request.id)
		return _request_result(request)

	var will_queue := _active_task_count >= int(_limits["max_active_jobs"])
	if will_queue:
		if _queued_jobs.size() >= int(_limits["max_queued_jobs"]):
			_requests.erase(request.id)
			return _error(ERR_BUSY, "Gaussian load queue has reached its job limit", LoadContract.ERROR_QUEUE_LIMIT)
		if source_size > int(_limits["max_queued_source_bytes"]) - _queued_source_bytes:
			_requests.erase(request.id)
			return _error(ERR_OUT_OF_MEMORY, "Gaussian load queue has reached its byte limit", LoadContract.ERROR_QUEUE_LIMIT)

	var job := LoadContract.LoadJob.new()
	job.cache_key = cache_key
	job.source_path = canonical_path
	job.source_size = source_size
	job.modified_time = modified_time
	job.waiting_request_ids.push_back(request.id)
	_jobs[cache_key] = job

	if will_queue:
		_queued_jobs.push_back(job)
		_queued_source_bytes += source_size
		call_deferred("_emit_request_state", request.id)
	else:
		_start_job(job)
	_update_diagnostics()
	return _request_result(request)

func cancel_request(request_id: int) -> void:
	if not _requests.has(request_id):
		return
	var request = _requests[request_id]
	request.active = false
	_requests.erase(request_id)
	if _jobs.has(request.cache_key):
		var job = _jobs[request.cache_key]
		job.waiting_request_ids.erase(request_id)
		if job.waiting_request_ids.is_empty():
			job.token.cancel()
			if not job.started:
				_jobs.erase(job.cache_key)
				_queued_jobs.erase(job)
				_queued_source_bytes = maxi(_queued_source_bytes - job.source_size, 0)
	request_cancelled.emit(request_id, request.generation)
	_update_diagnostics()

func release_lease(lease: Variant) -> void:
	if lease == null:
		return
	var lease_id := int(lease.id)
	if not _leases.has(lease_id):
		lease.released = true
		lease.resource = null
		return
	var owned_lease = _leases[lease_id]
	_leases.erase(lease_id)
	if _cache.has(owned_lease.cache_key):
		var entry = _cache[owned_lease.cache_key]
		entry.lease_ids.erase(lease_id)
		if entry.lease_ids.is_empty():
			entry.resource = null
			_cache.erase(owned_lease.cache_key)
	owned_lease.released = true
	owned_lease.resource = null
	_update_diagnostics()

func shutdown() -> void:
	if not _admitting and _jobs.is_empty() and _leases.is_empty():
		return
	_admitting = false
	shutting_down.emit(self)
	set_process(false)
	for request_id in _requests.keys():
		cancel_request(int(request_id))
	for job in _jobs.values():
		job.token.cancel()
	for job in _jobs.values():
		if job.started and job.task_id >= 0:
			WorkerThreadPool.wait_for_task_completion(job.task_id)
	for lease in _leases.values():
		lease.released = true
		lease.resource = null
	for entry in _cache.values():
		entry.resource = null
	_requests.clear()
	_jobs.clear()
	_queued_jobs.clear()
	_cache.clear()
	_leases.clear()
	_active_task_count = 0
	_queued_source_bytes = 0
	_update_diagnostics()

func debug_snapshot() -> Dictionary:
	return {
		"admitting": _admitting,
		"requests": _requests.size(),
		"jobs": _jobs.size(),
		"active_jobs": _active_task_count,
		"queued_jobs": _queued_jobs.size(),
		"queued_source_bytes": _queued_source_bytes,
		"cache_entries": _cache.size(),
		"leases": _leases.size()
	}

static func canonicalize_project_path(source_path: String) -> Dictionary:
	var normalized := source_path.strip_edges().replace("\\", "/")
	if not normalized.begins_with("res://"):
		return _error(ERR_INVALID_PARAMETER, "Gaussian source path must use a project-local res:// path", LoadContract.ERROR_INVALID_PATH)
	var relative := normalized.trim_prefix("res://")
	if relative.is_empty() or relative.contains(":"):
		return _error(ERR_INVALID_PARAMETER, "Gaussian source path is invalid", LoadContract.ERROR_INVALID_PATH)
	var simplified := relative.simplify_path().replace("\\", "/")
	if simplified == ".." or simplified.begins_with("../") or simplified.begins_with("/"):
		return _error(ERR_INVALID_PARAMETER, "Gaussian source path escapes the project root", LoadContract.ERROR_PATH_ESCAPE)
	var canonical := "res://%s" % simplified
	var absolute_path := ProjectSettings.globalize_path(canonical).simplify_path().replace("\\", "/")
	return {
		"ok": true,
		"source_path": canonical,
		"absolute_path": absolute_path
	}

static func inspect_source(source_path: String, limits: Dictionary = {}) -> Dictionary:
	var path_result := canonicalize_project_path(source_path)
	if not path_result.get("ok", false):
		return path_result
	var canonical: String = path_result["source_path"]
	if GaussianSourceDecoder.source_format(canonical) == "unsupported":
		return _error(ERR_FILE_UNRECOGNIZED, "Unsupported Gaussian source format", LoadContract.ERROR_UNSUPPORTED_FORMAT)
	var file := FileAccess.open(canonical, FileAccess.READ)
	if file == null:
		return _error(FileAccess.get_open_error(), "Gaussian source cannot be opened: %s" % canonical, "GDGS_SOURCE_MISSING")
	var source_size := file.get_length()
	file = null
	var max_source_bytes := DecodeControl.limit(limits, "max_source_bytes", DecodeControl.DEFAULT_MAX_SOURCE_BYTES)
	if source_size > max_source_bytes:
		return _error(ERR_OUT_OF_MEMORY, "Gaussian source exceeds the configured byte limit", LoadContract.ERROR_SOURCE_TOO_LARGE)
	return {
		"ok": true,
		"source_path": canonical,
		"absolute_path": path_result["absolute_path"],
		"source_size": source_size,
		"modified_time": int(FileAccess.get_modified_time(canonical))
	}

func _process(_delta: float) -> void:
	var completed: Array = []
	for job in _jobs.values():
		if not job.started:
			continue
		var snapshot: Dictionary = job.snapshot()
		_publish_progress(job, float(snapshot["progress"]))
		if bool(snapshot["done"]):
			completed.push_back({"job": job, "result": snapshot["result"]})

	for completion in completed:
		var job = completion["job"]
		if job.task_id >= 0:
			WorkerThreadPool.wait_for_task_completion(job.task_id)
		_active_task_count = maxi(_active_task_count - 1, 0)
		_finish_job(job, completion["result"])

	_start_queued_jobs()
	_update_diagnostics()

func _start_job(job: Variant) -> void:
	if job.started or not _jobs.has(job.cache_key):
		return
	job.started = true
	job.worker = LoadWorker.new()
	_active_task_count += 1
	for request_id in job.waiting_request_ids:
		if _requests.has(request_id):
			_requests[request_id].state = LoadContract.LifecycleState.LOADING
			call_deferred("_emit_request_state", request_id)
	job.task_id = WorkerThreadPool.add_task(
		Callable(job.worker, "run").bind(job, _limits.duplicate(true)),
		false,
		"Decode Gaussian %s" % job.source_path.get_file()
	)

func _start_queued_jobs() -> void:
	while _active_task_count < int(_limits["max_active_jobs"]) and not _queued_jobs.is_empty():
		var job = _queued_jobs.pop_front()
		if not _jobs.has(job.cache_key) or job.waiting_request_ids.is_empty():
			continue
		_queued_source_bytes = maxi(_queued_source_bytes - job.source_size, 0)
		_start_job(job)

func _publish_progress(job: Variant, value: float) -> void:
	for request_id in job.waiting_request_ids:
		if not _requests.has(request_id):
			continue
		var request = _requests[request_id]
		var progress := maxf(request.progress, clampf(value, 0.0, 1.0))
		if progress <= request.progress:
			continue
		request.progress = progress
		request_progress.emit(request.id, request.generation, progress)

func _finish_job(job: Variant, result: Dictionary) -> void:
	if _jobs.get(job.cache_key) == job:
		_jobs.erase(job.cache_key)
	job.worker = null
	var waiting_ids: Array = job.waiting_request_ids.duplicate()
	job.waiting_request_ids.clear()
	if waiting_ids.is_empty():
		return

	if not result.get("ok", false):
		for request_id in waiting_ids:
			_fail_request(request_id, result)
		return

	var publish_result: Dictionary = GaussianResourceBuilder.publish(result.get("payload", {}))
	if not publish_result.get("ok", false):
		for request_id in waiting_ids:
			_fail_request(request_id, publish_result)
		return

	var entry := LoadContract.CacheEntry.new()
	entry.cache_key = job.cache_key
	entry.source_path = job.source_path
	entry.source_size = job.source_size
	entry.modified_time = job.modified_time
	entry.resource = publish_result["resource"]
	# Preserve the decoded-source generation identity without adding it to the
	# public GaussianResource ABI. The paged renderer combines this stable
	# loader identity with the immutable payload hash, allowing shared leases
	# to resolve to one physical device page.
	entry.resource.set_meta(
		&"gdgs_content_identity",
		"source-%s" % job.cache_key.sha256_text()
	)
	_cache[job.cache_key] = entry
	for request_id in waiting_ids:
		_complete_request(request_id, entry)
	if entry.lease_ids.is_empty():
		entry.resource = null
		_cache.erase(job.cache_key)

func _complete_cache_hit(request_id: int) -> void:
	if not _requests.has(request_id):
		return
	var request = _requests[request_id]
	if not _cache.has(request.cache_key):
		_fail_request(request_id, _error(ERR_DOES_NOT_EXIST, "Gaussian cache entry expired before lease acquisition", "GDGS_CACHE_EXPIRED"))
		return
	_complete_request(request_id, _cache[request.cache_key])

func _complete_request(request_id: int, entry: Variant) -> void:
	if not _requests.has(request_id):
		return
	var request = _requests[request_id]
	_requests.erase(request_id)
	if not request.active:
		return
	var lease := LoadContract.LoadLease.new()
	lease.id = _next_lease_id
	_next_lease_id += 1
	lease.cache_key = entry.cache_key
	lease.source_path = entry.source_path
	lease.resource = entry.resource
	entry.lease_ids[lease.id] = true
	_leases[lease.id] = lease
	request.state = LoadContract.LifecycleState.LOADED
	request.progress = 1.0
	request_progress.emit(request.id, request.generation, 1.0)
	request_state_changed.emit(request.id, request.generation, request.state)
	request_completed.emit(request.id, request.generation, lease)
	_update_diagnostics()

func _fail_request(request_id: int, result: Dictionary) -> void:
	if not _requests.has(request_id):
		return
	var request = _requests[request_id]
	_requests.erase(request_id)
	if bool(result.get("cancelled", false)):
		request_cancelled.emit(request.id, request.generation)
		return
	request.state = LoadContract.LifecycleState.FAILED
	request_state_changed.emit(request.id, request.generation, request.state)
	request_failed.emit(
		request.id,
		request.generation,
		int(result.get("error", FAILED)),
		String(result.get("error_id", "GDGS_DECODE_FAILED")),
		String(result.get("message", "Gaussian source load failed"))
	)

func _emit_request_state(request_id: int) -> void:
	if not _requests.has(request_id):
		return
	var request = _requests[request_id]
	request_state_changed.emit(request.id, request.generation, request.state)

func _request_result(request: Variant) -> Dictionary:
	return {
		"ok": true,
		"request_id": request.id,
		"generation": request.generation,
		"state": request.state,
		"source_path": request.source_path,
		"cache_key": request.cache_key
	}

func _update_diagnostics() -> void:
	GaussianDiagnostics.set_active_jobs(_active_task_count)
	GaussianDiagnostics.set_cache_leases(_leases.size())
	GaussianDiagnostics.set_queued_source_bytes(_queued_source_bytes)

static func _make_cache_key(source_path: String, source_size: int, modified_time: int) -> String:
	return "%s|%d|%d" % [source_path, source_size, modified_time]

static func _error(code: Error, message: String, error_id: String) -> Dictionary:
	return DecodeControl.error(code, message, error_id)
