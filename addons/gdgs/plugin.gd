@tool
extends EditorPlugin

const MANAGER_NODE_NAME := "_GdgsGaussianRenderManager"
const DIRECT_TEXTURE_OVERLAY_NAME := "_GdgsDirectTextureOverlay"
const COLLISION_FEATURE_PATH := "res://addons/gdgs/collision/collision_feature.gd"
const GaussianDiagnostics = preload("res://addons/gdgs/runtime/diagnostics/gaussian_diagnostics.gd")
const LegacyBuilder = preload("res://addons/gdgs/editor/workflows/gaussian_legacy_builder.gd")
const LegacyMigration = preload("res://addons/gdgs/editor/workflows/gaussian_legacy_migration.gd")
const BUILD_LEGACY_MENU := "Gaussian Splatting/Build legacy GaussianResource..."
const MIGRATE_LEGACY_MENU := "Gaussian Splatting/Migrate selected nodes to lazy sources"

var gizmo_plugin: EditorNode3DGizmoPlugin
var collision_inspector_plugin: EditorInspectorPlugin
var export_plugin: EditorExportPlugin
var _legacy_source_dialog: EditorFileDialog
var _legacy_destination_dialog: EditorFileDialog
var _message_dialog: AcceptDialog
var _pending_legacy_source := ""

func _enter_tree() -> void:
	GaussianDiagnostics.begin_session("editor-plugin")
	gizmo_plugin = preload("res://addons/gdgs/editor/gizmos/gaussian_splat_gizmo_plugin.gd").new()
	add_node_3d_gizmo_plugin(gizmo_plugin)
	export_plugin = preload("res://addons/gdgs/editor/export/gaussian_export_plugin.gd").new()
	add_export_plugin(export_plugin)
	add_tool_menu_item(BUILD_LEGACY_MENU, _open_legacy_builder)
	add_tool_menu_item(MIGRATE_LEGACY_MENU, _migrate_selected_nodes)
	_create_editor_dialogs()

	print("[gdgs] enable gaussian splatting plugin")

	# Registered last and loaded at runtime: if the optional collision module
	# is missing or fails to parse, rendering above is already up and stays up.
	_enable_collision_feature()

func _exit_tree() -> void:
	_disable_collision_feature()
	if gizmo_plugin != null:
		remove_node_3d_gizmo_plugin(gizmo_plugin)
	if export_plugin != null:
		remove_export_plugin(export_plugin)
	remove_tool_menu_item(BUILD_LEGACY_MENU)
	remove_tool_menu_item(MIGRATE_LEGACY_MENU)
	_dispose_editor_dialogs()

	var tree := get_tree()
	if tree != null and tree.root != null:
		var manager := tree.root.get_node_or_null(MANAGER_NODE_NAME)
		if manager != null:
			if manager.has_method("shutdown"):
				manager.shutdown()
			manager.queue_free()

		var direct_texture_overlay := tree.root.get_node_or_null(DIRECT_TEXTURE_OVERLAY_NAME)
		if direct_texture_overlay != null:
			direct_texture_overlay.queue_free()

	print("[gdgs] disable gaussian splatting plugin")
	var diagnostics_error := GaussianDiagnostics.flush_environment_report()
	if diagnostics_error != OK:
		push_warning("[gdgs] unable to write diagnostics report (%d)" % diagnostics_error)

func _enable_collision_feature() -> void:
	if not ResourceLoader.exists(COLLISION_FEATURE_PATH, "Script"):
		print("[gdgs] collision feature not present; skipping")
		return
	var feature_script: Variant = load(COLLISION_FEATURE_PATH)
	if feature_script == null or not feature_script is GDScript:
		push_warning("[gdgs] collision feature failed to load; splat rendering is unaffected")
		return
	# load() returns a script object even when compilation failed anywhere in
	# the module, so ask the feature to walk its own dependency chain first:
	# on a healthy module self_test() returns true, on a broken one the call
	# errors out and yields null.
	var gdscript := feature_script as GDScript
	if not gdscript.can_instantiate():
		push_warning("[gdgs] collision feature failed to compile; splat rendering is unaffected")
		return
	var healthy: Variant = gdscript.call(&"self_test")
	if not (healthy is bool and healthy == true):
		push_warning("[gdgs] collision feature failed its self-test; splat rendering is unaffected")
		return
	var inspector: Variant = gdscript.call(&"create_inspector_plugin", get_undo_redo(), get_editor_interface())
	if not inspector is EditorInspectorPlugin:
		push_warning("[gdgs] collision feature returned no inspector plugin; splat rendering is unaffected")
		return
	collision_inspector_plugin = inspector
	add_inspector_plugin(collision_inspector_plugin)
	print("[gdgs] collision feature enabled")

func _disable_collision_feature() -> void:
	if collision_inspector_plugin == null:
		return
	if collision_inspector_plugin.has_method("shutdown"):
		collision_inspector_plugin.call(&"shutdown")
	remove_inspector_plugin(collision_inspector_plugin)
	collision_inspector_plugin = null

func _create_editor_dialogs() -> void:
	_legacy_source_dialog = EditorFileDialog.new()
	_legacy_source_dialog.title = "Select Gaussian source"
	_legacy_source_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_legacy_source_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_legacy_source_dialog.filters = PackedStringArray([
		"*.ply ; PLY Gaussian source",
		"*.splat ; Legacy SPLAT source",
		"*.sog ; Bundled SOG source"
	])
	_legacy_source_dialog.file_selected.connect(_on_legacy_source_selected)
	add_child(_legacy_source_dialog)

	_legacy_destination_dialog = EditorFileDialog.new()
	_legacy_destination_dialog.title = "Save legacy GaussianResource"
	_legacy_destination_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_legacy_destination_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_legacy_destination_dialog.filters = PackedStringArray([
		"*.res ; Binary Godot Resource",
		"*.tres ; Text Godot Resource"
	])
	_legacy_destination_dialog.file_selected.connect(_on_legacy_destination_selected)
	add_child(_legacy_destination_dialog)

	_message_dialog = AcceptDialog.new()
	add_child(_message_dialog)

func _dispose_editor_dialogs() -> void:
	for dialog in [_legacy_source_dialog, _legacy_destination_dialog, _message_dialog]:
		if dialog != null and is_instance_valid(dialog):
			dialog.queue_free()
	_legacy_source_dialog = null
	_legacy_destination_dialog = null
	_message_dialog = null

func _open_legacy_builder() -> void:
	if _legacy_source_dialog != null:
		_legacy_source_dialog.popup_centered_ratio(0.75)

func _on_legacy_source_selected(source_path: String) -> void:
	_pending_legacy_source = source_path
	_legacy_destination_dialog.current_path = source_path.get_basename() + ".gaussian.res"
	_legacy_destination_dialog.popup_centered_ratio(0.75)

func _on_legacy_destination_selected(destination_path: String) -> void:
	var result: Dictionary = LegacyBuilder.build(_pending_legacy_source, destination_path)
	_pending_legacy_source = ""
	if not result.get("ok", false):
		var message := String(result.get("message", "Unable to build legacy GaussianResource"))
		push_error("[gdgs] %s" % message)
		_show_message("Gaussian build failed", message)
		return
	get_editor_interface().get_resource_filesystem().scan()
	_show_message(
		"Gaussian resource built",
		"Saved %d splats to %s. This is the eager compatibility format; use source_path for lazy runtime loading." % [
			int(result["point_count"]),
			String(result["destination_path"])
		]
	)

func _migrate_selected_nodes() -> void:
	var selected: Array[Node] = []
	for value in get_editor_interface().get_selection().get_selected_nodes():
		if value is Node:
			selected.push_back(value)
	if selected.is_empty():
		_show_message("Gaussian migration", "Select one or more GaussianSplatNode roots first.")
		return
	var migration: Dictionary = LegacyMigration.plan(selected)
	var changes: Array = migration["changes"]
	if not changes.is_empty():
		var undo_redo := get_undo_redo()
		undo_redo.create_action("Migrate Gaussian nodes to lazy source paths")
		for change in changes:
			var node: Node = change["node"]
			undo_redo.add_do_property(node, &"source_path", change["source_path"])
			undo_redo.add_do_property(node, &"gaussian", null)
			undo_redo.add_undo_property(node, &"gaussian", change["legacy"])
			undo_redo.add_undo_property(node, &"source_path", String(node.get("source_path")))
		undo_redo.commit_action()

	var unresolved_lines := PackedStringArray()
	for unresolved in migration["unresolved"]:
		unresolved_lines.push_back("- %s (%s)" % [unresolved["node_path"], unresolved["resource_path"]])
	var report := "Migrated %d node(s); skipped %d already-lazy/empty node(s)." % [changes.size(), int(migration["skipped"])]
	if not unresolved_lines.is_empty():
		report += "\n\nCould not recover source metadata for %d node(s); they were left unchanged:\n%s" % [
			unresolved_lines.size(),
			"\n".join(unresolved_lines)
		]
	_show_message("Gaussian migration", report)

func _show_message(title: String, message: String) -> void:
	if _message_dialog == null:
		print("[gdgs] %s: %s" % [title, message])
		return
	_message_dialog.title = title
	_message_dialog.dialog_text = message
	_message_dialog.popup_centered(Vector2i(720, 360))
