extends RefCounted

# Presentation and input forwarding only. Runtime owns commands and durable receipts.
const Z2EventAdapterScript = preload("res://scripts/ui/event/event_interaction_model.gd")
const Z2NotificationScene = preload("res://scenes/components/z2_overlays/z2_notification_queue.tscn")
const Z2OpeningRuntimeScript = preload("res://scripts/core/run/z2_opening_runtime.gd")
const Z2EventRuntimeScript = preload("res://scripts/core/run/z2_event_runtime.gd")
const EventChoicePanelScript = preload("res://scripts/ui/run_surface/z1_event_choice_panel.gd")
const UILayerContractScript = preload("res://scripts/ui/shell/ui_layer_contract.gd")

var _scene: Node
var _closing_event_modal := false


func _init(scene: Node) -> void:
	_scene = scene


func request_tutorial_flag_learning() -> void:
	if _scene._is_runtime_modal_open() or _scene.run_context == null:
		return
	_scene._dispatch_command(&"learn_tutorial_flag")
	# A rejected/meta-save-failed request does not publish speculative changes.
	# Refresh only presentation; runtime still owns payment and retry semantics.
	var snapshot: Dictionary = _scene.run_context.get_status_snapshot()
	_scene.tutorial_popup_panel.apply_training_state(snapshot, _scene.runtime_controller.is_tutorial_learning_required())
	_scene.tutorial_popup_panel.apply_popup(snapshot.get("tutorial_popup", {}))


func dismiss_tutorial_guidance(popup_id: StringName) -> void:
	if _scene.run_context == null or not TutorialService.is_guidance_popup(_scene.run_context.tutorial_popup):
		return
	if StringName(_scene.run_context.tutorial_popup.get("id", &"")) == popup_id:
		_scene._dispatch_command(&"confirm_tutorial_popup")


# Completed events retain their source revisit text. Only the nearby displayed
# entity grants this read path; all options still go through the core command.
func completed_event_in_range() -> bool:
	if _scene.run_context == null or not _scene.run_context.run_active or _scene.run_context.current_room_type != &"Event":
		return false
	if _scene.room_runtime_view == null or _scene.player_controller == null:
		return false
	var state: Dictionary = _scene.run_context.get_status_snapshot().get("event_state", {})
	if str(state.get("ruleset_id", "")) != "z2" or not bool(state.get("completed", false)):
		return false
	var entity = _scene.room_runtime_view.special_entities.get("event:" + _scene.run_context.cell_key(_scene.run_context.get_current_pos()))
	return is_instance_valid(entity) and entity.interaction_kind == &"event" and entity.can_interact_from(_scene.player_controller.get_local_position())


func open_completed_event_in_range() -> bool:
	if not completed_event_in_range():
		return false
	_show_event_panel(_scene.run_context.get_status_snapshot().get("event_state", {}))
	return true


func _refresh_opening_inventory_controls() -> void:
	if _scene.inventory_panel == null or _scene.run_context == null:
		return
	var state = Z2OpeningRuntimeScript.public_state(_scene.run_context) if _scene.run_context.run_active else {}
	var items: Array = _scene.run_context.asset_ledger.get_items_by_location(&"inventory") if _scene.run_context.asset_ledger != null else []
	_scene.inventory_panel.apply_opening_state(state, items, _scene.opening_inventory_pending)


func _on_opening_inventory_action_requested(command: StringName, payload: Dictionary) -> void:
	if not _scene._runtime_modal_is_top(&"inventory") or _scene.opening_inventory_pending or command not in [&"end_opening_effect", &"dismantle_opening_item", &"use_opening_tool"]:
		return
	_scene.opening_inventory_pending = true
	var request = payload.duplicate(true)
	request["source"] = "inventory"
	request["action_id"] = "z2_opening_ui:" + JSON.stringify([str(_scene.run_context.run_id), _scene.run_context.cell_key(_scene.run_context.get_current_pos()), Z2OpeningRuntimeScript.public_state(_scene.run_context), command, payload]).sha256_text()
	var result = _scene._dispatch_command(command, request, false, false)
	_scene.call_deferred("_finish_opening_inventory_action", result)


func _finish_opening_inventory_action(result: Dictionary) -> void:
	_scene.opening_inventory_pending = false
	_scene.inventory_panel.apply_snapshot(_scene.run_context.get_status_snapshot())
	_scene._refresh_opening_inventory_controls()
	_scene.inventory_panel.show_command_result(result)


func _show_event_panel(event_state: Dictionary, presentation: Dictionary = {}) -> void:
	if _scene.event_panel == null or _scene._is_runtime_modal_open():
		return
	if not _scene._require_world_interaction(&"event"):
		return
	var display: Dictionary = _scene.runtime_controller.guarded_event_display(event_state)
	# A failed Z2 projection has no ruleset_id. It is not permission to open a
	# legacy decision surface in an ordinary Z2 run. Tutorials/diagnostic legacy
	# contexts deliberately keep their existing fallback and close behavior.
	if Z2EventRuntimeScript.applies_to(_scene.run_context) and (str(display.get("ruleset_id", "")) != "z2" or display.get("ok") == false):
		_scene._show_command_feedback({"ok": false, "reason": display.get("reason", &"event_state_unavailable"),
			"message": display.get("message", "事件状态暂不可用，请重新靠近事件后重试。")})
		return
	if str(display.get("ruleset_id", "")) == "z2":
		_scene.event_panel.hide()
		_scene.z2_event_adapter.apply_event(display, _scene._z2_event_presentation())
		if not _scene._push_runtime_modal(&"event", _scene.event_modal_root, null, Callable(_scene, "_cancel_event_modal")):
			_cancel_event_modal(&"push_rejected")
		return
	_scene.z2_event_adapter.hide()
	_scene.event_panel.show()
	var event_presentation = presentation.duplicate(true)
	event_presentation["room_pos"] = _scene.run_context.get_current_pos()
	event_presentation["inventory_items"] = _scene.run_context.asset_ledger.get_items_by_location(&"inventory")
	var event_type = String(display.get("event_type", ""))
	if event_type.begins_with("z1_event_"):
		event_presentation["event_icon_asset_id"] = StringName("z1.event." + event_type.trim_prefix("z1_event_"))
	_scene.event_choice_panel.call("apply_event", display, event_presentation)
	_scene._apply_runtime_modal_layout(_scene._current_layout_profile())
	var pushed = _scene._push_runtime_modal(
		&"event",
		_scene.event_modal_root,
		_scene._preferred_modal_focus(_scene.event_panel),
		Callable(_scene, "_cancel_event_modal")
	)
	if not pushed:
		_cancel_event_modal(&"push_rejected")


func _cancel_event_modal(_reason: StringName = &"cancel") -> void:
	if _closing_event_modal:
		return
	_closing_event_modal = true
	# The stack owns EventModalRoot, not the old panel. Hide both presentations
	# BEFORE popping so stack_changed cannot resync input against stale visible.
	if _scene.event_panel != null:
		_scene.event_panel.hide()
	if _scene.z2_event_adapter != null:
		# dismiss() retains outstanding requests: the deferred committed result
		# must still release the dialogue lock even after leave/travel/combat.
		_scene.z2_event_adapter.dismiss()
	if _scene._runtime_modal_is_top(&"event"):
		_scene._pop_runtime_modal(&"event")
	_closing_event_modal = false
	_scene._sync_player_input_enabled()


func _on_event_dialogue_dismissed() -> void:
	# An explicit close also emits dismissed synchronously. Do not enter the
	# cancellation path again, or pop a different modal opened by a command.
	if not _closing_event_modal:
		_cancel_event_modal(&"dialogue_dismissed")


func _z2_event_presentation() -> Dictionary:
	return {"run_id": str(_scene.run_context.run_id),
		"inventory_items": _scene.run_context.asset_ledger.get_items_by_location(&"inventory"),
		"black_coin": _scene.run_context.asset_ledger.get_currency(&"black_coin")}


func _on_z2_event_choice_requested(request: Dictionary, option: Dictionary) -> void:
	if not _scene._runtime_modal_is_top(&"event") or not _scene._require_world_interaction(&"event"):
		_scene.z2_event_adapter.apply_committed_result(request, {"ok": false, "message": "请靠近当前事件后重试。"}, {}, {})
		return
	var room_key = _scene.run_context.cell_key(_scene.run_context.get_current_pos())
	var payload: Dictionary = option.get("payload", {}).duplicate(true)
	payload["option_id"] = option.get("id", "")
	payload["source"] = "ui"
	var guard: Dictionary = option.get("input_guard_payload", {})
	if not guard.is_empty() and str(guard.get("expected_conditions", "")) == _scene.runtime_controller.action_condition_fingerprint(&"select_event_option", guard):
		# Check displayed authority before adding user-entered fields to its guard.
		payload["expected_conditions"] = _scene.runtime_controller.action_condition_fingerprint(&"select_event_option", payload)
	var result = _scene._dispatch_command(&"select_event_option", payload, false, false)
	var action_id = str(payload.get("action_id", ""))
	# RunActionTransaction installs its receipt only after durable persistence.
	# Never infer commit from an option click or the inner speculative result.
	var committed: bool = bool(result.get("ok", false)) and not action_id.is_empty() and _scene.runtime_controller.action_receipts.has(action_id)
	var action_result: Dictionary = result.get("action_result", result).duplicate(true)
	action_result["ok"] = committed
	action_result["committed"] = committed
	if not committed:
		action_result["status"] = result.get("status", "")
	var same_room = _scene.run_context.cell_key(_scene.run_context.get_current_pos()) == room_key
	var next_state: Dictionary = _scene.runtime_controller.guarded_event_display(_scene.run_context.get_status_snapshot().get("event_state", {})) if same_room else {}
	# Keep the delivered component's request lock through the current input event.
	_scene.z2_event_adapter.call_deferred("apply_committed_result", request, action_result, next_state, _scene._z2_event_presentation())
	if committed:
		_scene._show_world_reward_feedback(result, action_result, &"event")
		_scene._publish_z2_notifications(result)
		if str(option.get("id", "")) == "leave" or not same_room or not _scene.run_context.run_active or (_scene.in_run_runtime != null and _scene.in_run_runtime.has_active_combat()):
			_scene._cancel_event_modal()


func _ensure_z2_notification_queue() -> Control:
	var root = _scene.get_tree().root
	var layer = root.get_node_or_null("Z2PersistentOverlays") as CanvasLayer
	if layer == null:
		layer = CanvasLayer.new()
		layer.name = "Z2PersistentOverlays"
		layer.layer = 100
		root.add_child(layer)
		# Outlive page changes, but not the Main that owns this queue.
		var lifetime_owner: Node = _scene
		while lifetime_owner.get_parent() != root:
			lifetime_owner = lifetime_owner.get_parent()
		lifetime_owner.tree_exiting.connect(layer.queue_free, CONNECT_ONE_SHOT)
	var queue = layer.get_node_or_null("NotificationQueue") as Control
	if queue == null:
		queue = Z2NotificationScene.instantiate()
		queue.name = "NotificationQueue"
		layer.add_child(queue)
	queue.set_ui_scale_factor(_scene._ui_scale_factor)
	return queue


func enqueue_z2_committed_notifications(receipt: Dictionary, notices: Array) -> int:
	if receipt.get("ok") != true or receipt.get("committed") != true:
		return 0
	var queue = _scene._ensure_z2_notification_queue()
	var accepted = 0
	for notice: Variant in notices:
		if notice is Dictionary and queue.enqueue_committed(receipt, notice):
			accepted += 1
	return accepted


func _publish_z2_notifications(result: Dictionary) -> void:
	# The meta adapter publishes exact completion receipts after its save succeeds.
	for entry: Variant in result.get("quest_notifications", []):
		if entry is Dictionary:
			_scene.enqueue_z2_committed_notifications(entry.get("receipt", {}), [entry.get("notice", {})])
	for field in ["result", "adapter_result", "meta_progress_commit"]:
		if result.get(field) is Dictionary:
			_scene._publish_z2_notifications(result[field])


func build_event_panel() -> void:
	_scene.event_panel = _scene._new_modal_panel("EventOptionPanel", Rect2(420, 140, 450, 360))
	_scene.event_modal_root = Control.new()
	_scene.event_modal_root.name = "EventModalRoot"
	_scene.event_modal_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UILayerContractScript.apply_layer(_scene.event_modal_root, &"modal")
	_scene.ui_root.add_child(_scene.event_modal_root)
	_scene.event_modal_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scene.event_panel.reparent(_scene.event_modal_root, false)
	_scene.z2_event_adapter = Z2EventAdapterScript.new()
	_scene.z2_event_adapter.name = "Z2EventAdapter"
	_scene.event_modal_root.add_child(_scene.z2_event_adapter)
	_scene.z2_event_adapter.choice_requested.connect(_scene._on_z2_event_choice_requested)
	_scene.z2_event_adapter.dismissed.connect(_on_event_dialogue_dismissed)
	_scene.event_modal_root.hide()
	_scene.call_deferred("_ensure_z2_notification_queue")
	if _scene.run_surface != null:
		_scene.run_surface.apply_legacy_modal_style(_scene.event_panel, &"mini.event")
	_scene.event_choice_panel = EventChoicePanelScript.new()
	_scene.event_choice_panel.option_selected.connect(func(option: Dictionary) -> void:
		_scene._select_event_option(StringName(option.get("id", &"")), option.get("payload", {}) as Dictionary)
	)
	_scene.event_choice_panel.close_requested.connect(func() -> void: _scene._cancel_event_modal(&"button_cancel"))
	_scene.event_panel.add_child(_scene.event_choice_panel)
	_scene.event_title_label = _scene.event_choice_panel.get("_title")
	_scene.event_body_label = _scene.event_choice_panel.get("_body")
	_scene.event_options_box = _scene.event_choice_panel.get("_options")


func _select_event_option(option_id: StringName, option_payload: Dictionary = {}) -> void:
	if not _scene._runtime_modal_is_top(&"event"):
		return
	if not _scene._require_world_interaction(&"event"):
		return
	var submitted_room_key = _scene.run_context.cell_key(_scene.run_context.get_current_pos())
	_cancel_event_modal(&"legacy_option")
	var command_payload = option_payload.duplicate(true)
	command_payload["option_id"] = option_id
	command_payload["source"] = "ui"
	var result = _scene._dispatch_command(
		&"select_event_option",
		command_payload,
		true,
		false
	)
	var action_result: Dictionary = result.get("action_result", {})
	_scene._show_world_reward_feedback(result, action_result, &"event")
	if _scene.run_context.cell_key(_scene.run_context.get_current_pos()) != submitted_room_key:
		return
	var next_event: Dictionary = _scene.run_context.get_status_snapshot().get("event_state", {})
	if option_id != &"leave" and _scene.run_context.run_active and not bool(next_event.get("completed", true)) and (_scene.in_run_runtime == null or not _scene.in_run_runtime.has_active_combat()):
		var last_attempt = action_result if not bool(action_result.get("ok", true)) else {}
		_scene._show_event_panel(next_event, {"attempt_result": last_attempt})
		return
	if bool(result.get("accepted", result.get("ok", false))) and _scene.room_runtime_view != null:
		var popup = _scene.room_runtime_view.get("context_popup")
		if is_instance_valid(popup):
			popup.show_event_result(submitted_room_key, action_result)
