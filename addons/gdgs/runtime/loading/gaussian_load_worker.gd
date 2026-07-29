@tool
extends RefCounted

const GaussianSourceDecoder = preload("res://addons/gdgs/importers/gaussian_source_decoder.gd")
const GaussianResourceBuilder = preload("res://addons/gdgs/importers/builders/gaussian_resource_builder.gd")
const DecodeControl = preload("res://addons/gdgs/importers/decoders/gaussian_decode_control.gd")

## WorkerThreadPool entry point.  This object owns no Node, Resource, RID, or
## rendering state; the only cross-thread object is the mutex-protected job.
func run(job: Variant, limits: Dictionary) -> void:
	if job.is_cancelled():
		job.finish(DecodeControl.cancellation_error())
		return

	var decode_result: Dictionary = GaussianSourceDecoder.decode(
		job.source_path,
		Callable(job, "report_decode_progress"),
		Callable(job, "is_cancelled"),
		limits
	)
	if not decode_result.get("ok", false):
		job.finish(decode_result)
		return
	if job.is_cancelled():
		job.finish(DecodeControl.cancellation_error())
		return

	var build_result: Dictionary = GaussianResourceBuilder.build_payload(
		decode_result["canonical"],
		Callable(job, "report_build_progress"),
		Callable(job, "is_cancelled"),
		limits
	)
	decode_result = {}
	if not build_result.get("ok", false):
		job.finish(build_result)
		return
	if job.is_cancelled():
		job.finish(DecodeControl.cancellation_error())
		return

	job.report_finished_progress()
	job.finish(build_result)
