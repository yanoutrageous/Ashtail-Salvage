extends RefCounted
class_name RunScenePersistenceController

const UILayerContractScript := preload("res://scripts/ui/shell/ui_layer_contract.gd")

var persistence_error_panel: Control
var persistence_error_label: Label
var persistence_retry_button: Button
var _scene: Node
var _runtime_ref: WeakRef
var _quit_after_retry := false


func bind_targets(scene: Node) -> void:
	_scene = scene
	_runtime_ref = weakref(scene.runtime_controller)
	_build_error_panel()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _runtime_ref != null:
		var runtime = _runtime_ref.get_ref()
		if runtime != null:
			runtime.checkpoint_service = null
			runtime._persistence_manager = null


func is_blocked() -> bool:
	return _scene != null and not _scene.runtime_controller.persistence_error.is_empty()


func capture_player_location() -> void:
	if _scene.player_controller != null and not _scene.in_run_runtime.has_active_combat():
		_scene.runtime_controller.update_player_location(_scene.player_controller.get_local_position())


func request_quit() -> void:
	if _scene == null:
		return
	_quit_after_retry = true
	if present_error():
		return
	capture_player_location()
	var saved: Dictionary = _scene.runtime_controller.save_current_checkpoint()
	if bool(saved.get("ok", false)):
		_scene.get_tree().quit()
	else:
		if _scene.runtime_controller.persistence_error.is_empty():
			_scene.runtime_controller.persistence_error = saved.duplicate(true)
		present_error()


func present_error() -> bool:
	if not is_blocked():
		return false
	_scene._sync_player_input_enabled()
	var reason := String(_scene.runtime_controller.persistence_error.get("reason", ""))
	if reason == "checkpoint_content_mismatch":
		persistence_error_label.text = "这份探索存档来自不同的游戏版本。原存档仍保留，请使用创建它的游戏版本继续。"
	else:
		persistence_error_label.text = "保存未完成，探索已停止推进。请检查存储空间或文件访问权限后重试。"
	persistence_retry_button.text = "重试保存并退出" if _quit_after_retry else "重试并继续"
	if not persistence_error_panel.visible:
		persistence_error_panel.show()
		persistence_retry_button.call_deferred("grab_focus")
	return true


func retry() -> void:
	var recovered: Dictionary = _scene.runtime_controller.retry_persistence()
	if not bool(recovered.get("ok", false)):
		present_error()
		return
	persistence_error_panel.hide()
	_scene.player_controller.set_local_position(_scene.runtime_controller.get_restored_local_position(_scene.player_controller.get_local_position()))
	_scene._refresh_view_models()
	_scene._sync_player_input_enabled()
	if _quit_after_retry:
		request_quit()
	elif not _scene.run_context.run_active and not _scene.run_context.result_snapshot.is_empty():
		_scene._on_result_available(_scene.run_context.result_snapshot)
	else:
		restore_pending_phase()


func restore_pending_phase() -> void:
	if _scene == null or is_blocked() or _scene.screen_state != _scene.SCREEN_RUN:
		return
	if not _scene.run_context.run_active or _scene.run_context.phase != &"confirm_extract":
		return
	if _scene._runtime_modal_is_top(&"extract_confirm"):
		_scene._pop_runtime_modal(&"extract_confirm", false)
	if _scene._is_runtime_modal_open():
		return
	# Recovery must validate the current world position, not reuse an opening
	# permission from before rollback or submit a second extraction request.
	_scene._clear_exit_interaction_authorization()
	_scene.room_runtime_view.advance(0.0, _scene.player_controller.get_local_position(), _scene.in_run_runtime.build_read_only_snapshot())
	if _scene._world_interaction_in_range(&"exit"):
		_scene._capture_exit_interaction_authorization()
	_scene._show_extract_panel(_scene.run_context.get_status_snapshot())


func _build_error_panel() -> void:
	# A sibling of both shells stays available when the run view is hidden.
	persistence_error_panel = Control.new()
	persistence_error_panel.name = "PersistenceErrorOverlay"
	persistence_error_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	UILayerContractScript.apply_layer(persistence_error_panel, &"modal", 1)
	_scene.ui_root.add_child(persistence_error_panel)
	var shield := ColorRect.new()
	shield.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shield.color = Color(0.0, 0.0, 0.0, 0.52)
	persistence_error_panel.add_child(shield)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	persistence_error_panel.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(440, 0)
	center.add_child(panel)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 16)
	panel.add_child(content)
	var title := Label.new()
	title.text = "存档暂时不可用"
	title.add_theme_font_size_override("font_size", 20)
	content.add_child(title)
	persistence_error_label = Label.new()
	persistence_error_label.custom_minimum_size = Vector2(400, 64)
	persistence_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(persistence_error_label)
	persistence_retry_button = _scene._add_menu_button(content, "重试并继续", retry)
	if _scene.run_surface != null:
		_scene.run_surface.apply_legacy_modal_style(panel, &"ui.danger")
		_scene.run_surface.apply_legacy_button_style(persistence_retry_button, &"primary")
	persistence_error_panel.hide()
