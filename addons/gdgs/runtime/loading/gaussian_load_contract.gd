@tool
extends RefCounted

## Shared value types for the asynchronous Gaussian source lifecycle.
##
## These objects intentionally contain no scene-tree or rendering state.  A
## LoadJob is the only object shared with a WorkerThreadPool worker, and all of
## its worker-visible mutable fields are guarded by a mutex.

enum LifecycleState {
	UNLOADED,
	QUEUED,
	LOADING,
	LOADED,
	FAILED
}

const ERROR_CANCELLED := "GDGS_CANCELLED"
const ERROR_INVALID_PATH := "GDGS_INVALID_PATH"
const ERROR_PATH_ESCAPE := "GDGS_PATH_ESCAPE"
const ERROR_UNSUPPORTED_FORMAT := "GDGS_UNSUPPORTED_FORMAT"
const ERROR_SOURCE_TOO_LARGE := "GDGS_SOURCE_TOO_LARGE"
const ERROR_DECODE_LIMIT := "GDGS_DECODE_LIMIT"
const ERROR_QUEUE_LIMIT := "GDGS_QUEUE_LIMIT"
const ERROR_NON_FINITE := "GDGS_NON_FINITE"
const ERROR_TRUNCATED := "GDGS_TRUNCATED"

class CancellationToken:
	extends RefCounted

	var _mutex := Mutex.new()
	var _cancelled := false

	func cancel() -> void:
		_mutex.lock()
		_cancelled = true
		_mutex.unlock()

	func is_cancelled() -> bool:
		_mutex.lock()
		var result := _cancelled
		_mutex.unlock()
		return result

class LoadRequest:
	extends RefCounted

	var id := 0
	var client_id := 0
	var generation := 0
	var cache_key := ""
	var source_path := ""
	var state := LifecycleState.UNLOADED
	var progress := 0.0
	var active := true

class LoadJob:
	extends RefCounted

	var cache_key := ""
	var source_path := ""
	var source_size := 0
	var modified_time := 0
	var task_id := -1
	var started := false
	var worker: Variant = null
	var waiting_request_ids: Array[int] = []
	var token := CancellationToken.new()

	var _mutex := Mutex.new()
	var _progress := 0.0
	var _done := false
	var _result: Dictionary = {}

	func report_decode_progress(value: float) -> void:
		_set_progress(clampf(value, 0.0, 1.0) * 0.72)

	func report_build_progress(value: float) -> void:
		_set_progress(0.72 + clampf(value, 0.0, 1.0) * 0.27)

	func report_finished_progress() -> void:
		_set_progress(1.0)

	func is_cancelled() -> bool:
		return token.is_cancelled()

	func finish(result: Dictionary) -> void:
		_mutex.lock()
		_result = result
		_done = true
		_mutex.unlock()

	func snapshot() -> Dictionary:
		_mutex.lock()
		var value := {
			"done": _done,
			"progress": _progress,
			"result": _result
		}
		_mutex.unlock()
		return value

	func _set_progress(value: float) -> void:
		_mutex.lock()
		_progress = maxf(_progress, clampf(value, 0.0, 1.0))
		_mutex.unlock()

class LoadLease:
	extends RefCounted

	var id := 0
	var cache_key := ""
	var source_path := ""
	var resource: Variant = null
	var released := false

class CacheEntry:
	extends RefCounted

	var cache_key := ""
	var source_path := ""
	var source_size := 0
	var modified_time := 0
	var resource: Variant = null
	var lease_ids: Dictionary = {}
