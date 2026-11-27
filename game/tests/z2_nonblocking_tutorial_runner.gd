extends SceneTree

# Fresh production Main + real Meta/Checkpoint storage. No awarded tutorial
# completion, edited level/HP, replacement map, or successful fake checkpoint.
# Only legacy popup payloads/long copy, failed atomic checkpoint renames and a
# corrupt private Meta primary are fixtures. Recovery uses the actual valid .bak.
# Input/geometry evidence is not real-render acceptance.
const Tutorial := preload("res://scripts/core/run/tutorial_map_catalog.gd")
const Guidance := preload("res://scripts/core/run/tutorial_service.gd")
const MetaScript := preload("res://scripts/core/save/meta_progress_adapter.gd")
const FIXED_GUIDANCE := ["spawn_intro", "number_rule", "mine_rule", "event_rule", "dice_rule", "altar_rule", "trap_rule", "monster_rule", "chest_rule", "map_rule", "mine_review", "route_rule", "exit_goal"]

class FailCheckpointCommit extends SaveAdapter:
	var armed := false
	var failures_injected := 0

	func _rename_file(source_path: String, target_path: String) -> bool:
		if armed and source_path.ends_with("/run_checkpoint.json.tmp") and target_path.ends_with("/run_checkpoint.json"):
			armed = false
			failures_injected += 1
			return false
		return super._rename_file(source_path, target_path)


var checks := 0
var failures: Array[String] = []
var main: Node
var scene
var guidance_confirmations := 0
var guidance_dismissals := 0
var pointer_hits := 0
var original_learning: Dictionary = {}
var pre_payment_meta_sha := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _check(_fresh_isolated_home(), "requires fresh user data under absolute Z2_TUTORIAL_QA_HOME"):
		_finish()
		return
	root.size = Vector2i(1280, 720)
	root.content_scale_size = root.size
	if await _open_main():
		if await _start_from_real_deploy():
			original_learning = _learning_state(scene.meta_progress_adapter.data)
			await _test_unconfirmed_intro()
			if _walk(Vector2i(0, 1)):
				await _test_14_legacy_guidance_payloads()
				await _test_guidance_card_and_long_copy()
				if await _play_teaching_route():
					if await _test_disk_reload_and_main_restart():
						await _test_flag_risk_confirmation()
						await _complete_training()
						_test_early_departures()
	await _close_main()
	_finish()


func _fresh_isolated_home() -> bool:
	var home := OS.get_environment("Z2_TUTORIAL_QA_HOME").simplify_path().replace("\\", "/").trim_suffix("/")
	var user_dir := OS.get_user_data_dir().simplify_path().replace("\\", "/")
	return home.is_absolute_path() and user_dir.to_lower().begins_with(home.to_lower() + "/") \
		and not FileAccess.file_exists("user://saves/manifest.json") \
		and not DirAccess.dir_exists_absolute("user://saves/profiles") \
		and not FileAccess.file_exists("user://graytail_m1_meta_progress.json")


func _open_main() -> bool:
	main = (load("res://scenes/main/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	current_scene = main
	scene = main.get_node("RunScene")
	# UI/input still process. Only explicit production frame calls advance time.
	scene.set_process(false)
	if not await _until(func() -> bool: return scene.runtime_controller.checkpoint_service != null or not scene.runtime_controller.persistence_error.is_empty(), "Main initializes its real durable services"):
		return false
	scene.tutorial_popup_panel.confirmed.connect(func() -> void: guidance_confirmations += 1)
	scene.tutorial_popup_panel.guidance_dismissed.connect(func(_id: StringName) -> void: guidance_dismissals += 1)
	return _check(scene.runtime_controller.persistence_error.is_empty() and not scene.runtime_controller.checkpoint_writer.is_valid(), "production checkpoint writer is active and healthy")


func _close_main() -> void:
	if not is_instance_valid(main):
		return
	var streams: Array[WeakRef] = []
	for child in scene.player_feedback_service.get_children():
		if child is AudioStreamPlayer and child.stream != null:
			streams.append(weakref(child.stream))
			child.stop()
			child.stream = null
	scene.in_run_runtime.bind(null)
	scene.command_bus.bind_runtime_controller(null)
	var closing: WeakRef = weakref(main)
	main.queue_free()
	await _until(func() -> bool: return closing.get_ref() == null, "Main teardown releases the actual scene")
	await _until(func() -> bool: return streams.all(func(stream: WeakRef) -> bool: return stream.get_ref() == null), "feedback streams release after Main teardown")
	main = null
	scene = null


func _start_from_real_deploy() -> bool:
	var meta: Dictionary = scene.meta_progress_adapter.data
	_check(meta.get("profile_level") == 0 and not meta.get("tutorial_completed", false), "fresh current profile starts at Lv0 with no teaching completion")
	_check(meta.get("talent_points") == 100 and meta.get("talent_earned") == 100 and meta.get("talent_spent") == 0 and meta.get("talent_flags", []).is_empty(), "fresh profile owns exactly 100 unspent teaching points")
	var menu: Control = scene.ui_shell.get_main_page()
	var explore := menu.entry_nodes.get(&"deploy", {}).get("button") as Button
	if not await _click(explore, "actual Main explore button"):
		return false
	if not await _until(func() -> bool: return scene.screen_state == &"deploy_shell", "Main explore reaches actual deploy"):
		return false
	var deploy: Control = scene.ui_shell.get_deploy_page()
	var split: Control = deploy.map_split_view
	if not await _click(split.scale_buttons.get(&"5x5") as Button, "actual tutorial scale button"):
		return false
	if not await _until(func() -> bool: return deploy.map_split_view.difficulty_buttons.has(StringName(Tutorial.MAP_ID)), "tutorial difficulty is exposed"):
		return false
	split = deploy.map_split_view
	if not await _click(split.difficulty_buttons.get(StringName(Tutorial.MAP_ID)) as Button, "actual fixed tutorial difficulty"):
		return false
	if not await _until(func() -> bool: return str(deploy.map_split_view.get_preview_map_id()) == Tutorial.MAP_ID, "tutorial map is previewed"):
		return false
	split = deploy.map_split_view
	if str(split.selected_map_id) != Tutorial.MAP_ID:
		if not await _click(split.select_action_button, "explicitly adopt the previewed tutorial"):
			return false
	if not await _until(func() -> bool: return str(deploy.current_model.get("config", {}).get("map_config_id", "")) == Tutorial.MAP_ID, "real deploy model adopts tutorial"):
		return false
	if not await _click(deploy.primary_action_button, "actual deploy primary starts teaching"):
		return false
	if not await _until(func() -> bool: return scene.screen_state == &"run" and scene.run_context.run_active, "real Main enters admitted teaching"):
		return false
	return _check(scene.run_context.mode == &"tutorial" and scene.run_context.seed_value == Tutorial.FIXED_SEED and scene.run_context.get_current_pos() == Vector2i.ZERO, "untouched fixed tutorial mode, seed and spawn")


func _test_unconfirmed_intro() -> void:
	var panel = scene.tutorial_popup_panel
	if not _check(str(scene.run_context.tutorial_popup.get("id", "")) == "spawn_intro", "actual intro exists before any confirmation"):
		return
	_check(not scene.run_context.has_blocking_tutorial_popup() and scene.run_context.can_accept_command(), "unconfirmed intro does not lock command authority")
	_check(not panel.layout_snapshot().get("guidance_expanded", true), "actual intro is collapsed by default")
	_check(!_learn_button().is_visible_in_tree(), "intro teaches automatic chest entry")
	await _assert_free_controls("unconfirmed intro")
	_key(KEY_E)
	# Spawn is intentionally not searchable. A precise domain rejection proves
	# the real E route reached RoomResolver; rejected actions roll back bus seq.
	_check(not scene.last_command_result.get("ok", true) and _reason(scene.last_command_result) == "spawn_not_searchable" and StringName(scene.last_command_result.get("command_name", &"")) in [&"interact_current_room", &"search_current_room"], "unconfirmed intro E reaches the real spawn_not_searchable rule, not a tutorial input lock")
	_check(str(scene.run_context.tutorial_popup.get("id", "")) == "spawn_intro", "movement/E/Q/M/Esc did not consume intro or purchase learning")
	var before_confirm := guidance_confirmations
	var before_dismiss := guidance_dismissals
	if await _click(_details_button(), "expand actual intro details"):
		await _until(func() -> bool: return panel.layout_snapshot().get("guidance_expanded", false), "intro details expand without business confirmation")
		_check(_message().text == str(panel.popup.get("message", "")), "expanded intro preserves its full source message")
		if await _click(_details_button(), "collapse actual intro details"):
			await _until(func() -> bool: return not panel.layout_snapshot().get("guidance_expanded", true), "intro details collapse")
	_check(guidance_confirmations == before_confirm and guidance_dismissals == before_dismiss + 1, "pure details buttons emit dismissal, never business confirmed")
	_check(scene.run_context.tutorial_popup.is_empty() and str(panel.popup.get("id", "")) == "spawn_intro", "same-room local cache retains the collapsed guide after explicit dismissal")
	_assert_not_purchased("intro collapse")


func _test_14_legacy_guidance_payloads() -> void:
	_check(scene.run_context.get_current_pos() == Vector2i(0, 1), "legacy compatibility checks occur after leaving birth room")
	_check(str(scene.tutorial_popup_panel.popup.get("id", "")) == "number_rule", "room change replaces cached spawn guidance with the real room lesson")
	_check(!_learn_button().is_visible_in_tree(), "no remote paid action before chest entry")
	var definitions: Dictionary = Guidance.popup_definitions()
	var defined: Array = []
	for key in definitions:
		defined.append(str(key))
	defined.sort()
	var expected := FIXED_GUIDANCE.duplicate()
	expected.sort()
	_check(defined == expected, "independent13 fixed guidance identities remain intact")
	var ids := FIXED_GUIDANCE.duplicate()
	ids.append("tutorial_objective")
	var focus_probe := Button.new()
	focus_probe.name = "ExternalTutorialFocusProbe"
	focus_probe.text = "focus probe"
	focus_probe.position = Vector2(700, 640)
	focus_probe.size = Vector2(120, 32)
	focus_probe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scene.ui_root.add_child(focus_probe)
	for id: String in ids:
		var raw := _legacy_popup(id)
		var normalized: Dictionary = Guidance.normalized_popup(raw)
		_check(raw.get("blocking", false) and not normalized.get("blocking", true), id + " old blocking=true is normalized without mutating input")
		_check(Guidance.is_guidance_popup(raw) and not Guidance.is_blocking_popup(raw), id + " is classified as guidance, not a risk decision")
		focus_probe.grab_focus()
		if not _install_popup(raw, id):
			break
		_check(scene.run_context.tutorial_popup.get("blocking", false), id + " fixture retains raw legacy field in core state")
		_check(not scene.run_context.has_blocking_tutorial_popup() and scene.run_context.can_accept_command(), id + " real RunContext ignores obsolete blocking field")
		_check(not scene.run_context.get_status_snapshot().get("tutorial_popup", {}).get("blocking", true), id + " public snapshot normalizes the legacy payload")
		_check(root.gui_get_focus_owner() == focus_probe and _details_button().focus_mode == Control.FOCUS_NONE, id + " actual guidance never steals keyboard focus")
		await _assert_free_controls("legacy " + id)
		_assert_not_purchased("legacy " + id)
	var focus_probe_ref: WeakRef = weakref(focus_probe)
	focus_probe.queue_free()
	await _until(func() -> bool: return focus_probe_ref.get_ref() == null, "external focus probe releases")
	_check(ids.size() == 14, "all13 fixed lessons plus UI objective tested as legacy non-blocking guidance")


func _legacy_popup(id: String) -> Dictionary:
	var definition: Dictionary = Guidance.popup_definition(StringName(id))
	return {"id": StringName(id), "title": str(definition.get("title", "教学目标")), "blocking": true,
		"message": str(definition.get("message_template", "学习插旗后前往撤离信标完成训练。")),
		"once": false, "room_scoped": true, "confirm_text": "查看教学说明", "confirm_action": &"ui_accept"}


func _install_popup(raw: Dictionary, label: String) -> bool:
	var result: Dictionary = scene.runtime_controller.execute_atomic_operation(&"tutorial_legacy_popup_fixture", {"case": label}, func() -> Dictionary:
		scene.run_context.tutorial_popup = raw.duplicate(true)
		return {"ok": true}
	)
	scene._refresh_view_models()
	return _check(result.get("ok", false), label + " installs only a declared legacy-popup compatibility fixture")


func _test_guidance_card_and_long_copy() -> void:
	var raw := _legacy_popup("number_rule")
	raw.message = "长文回归：展开后仍可滚动读取全部正文。\n" + "完整教学说明必须保留，不缩字、不删除，也不阻止继续探索。\n".repeat(60) + "正文末尾可达。"
	if not _install_popup(raw, "long-copy"):
		return
	var panel = scene.tutorial_popup_panel
	for scale_value in [1.0, 1.25, 1.5]:
		scene.set_ui_scale_factor(scale_value)
		scene._refresh_view_models()
		await _until(_guidance_geometry_ready, "collapsed learning/details geometry settles at scale%s" % scale_value)
		_assert_guidance_geometry("collapsed scale%s" % scale_value)
		_check(not panel.layout_snapshot().get("guidance_expanded", true) and _message().text.length() < str(raw.message).length(), "collapsed guide has a short summary at scale%s" % scale_value)
		var before := guidance_confirmations
		if not await _click(_details_button(), "actual details expand at scale%s" % scale_value):
			return
		await _until(func() -> bool: return panel.layout_snapshot().get("guidance_expanded", false) and _message().get_content_height() > _message().size.y, "expanded full copy overflows into its scroll viewport at scale%s" % scale_value)
		await _until(_guidance_geometry_ready, "expanded learning/details geometry settles at scale%s" % scale_value)
		_assert_guidance_geometry("expanded scale%s" % scale_value)
		_check(_message().text == str(raw.message) and _message().scroll_active, "expanded guide retains all source text with scroll at scale%s" % scale_value)
		await _wheel_to_end(_message(), "expanded guide scale%s" % scale_value)
		if not await _click(_details_button(), "actual details collapse at scale%s" % scale_value):
			return
		await _until(func() -> bool: return not panel.layout_snapshot().get("guidance_expanded", true), "actual details collapse at scale%s" % scale_value)
		_check(guidance_confirmations == before, "expand/collapse never emits business confirmation at scale%s" % scale_value)
		_assert_not_purchased("details geometry scale%s" % scale_value)
	scene.set_ui_scale_factor(1.0)
	scene._refresh_view_models()
	await _until(_guidance_geometry_ready, "pointer probe geometry settles")
	_check(panel.mouse_filter == Control.MOUSE_FILTER_IGNORE and panel.get_node("Panel").mouse_filter == Control.MOUSE_FILTER_STOP, "guidance ignores outside pointer while its card stops obscured clicks")
	var probe := Control.new()
	probe.name = "BehindGuidancePointerProbe"
	probe.mouse_filter = Control.MOUSE_FILTER_STOP
	probe.z_as_relative = false
	probe.z_index = panel.z_index - 1
	panel.get_parent().add_child(probe)
	# Canvas z_index affects drawing, not Control GUI picking. The probe must
	# also precede the actual guide in tree order to observe through its root.
	panel.get_parent().move_child(probe, panel.get_index())
	probe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_check(probe.get_index() < panel.get_index(), "pointer probe is genuinely behind guidance in native GUI picking order")
	probe.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			pointer_hits += 1
	)
	var card: Rect2 = panel.get_node("Panel").get_global_rect()
	var title: Control = panel.get_node("Panel/Content/Title")
	var inside := title.get_global_rect().get_center()
	var outside: Vector2 = panel.layout_snapshot().get("geometry", {}).get("room_stage_rect", Rect2()).get_center()
	_check(card.has_point(inside) and not card.has_point(outside), "pointer probes address inside card and unobscured room respectively")
	_check(panel.blocks_world_pointer(inside) and not panel.blocks_world_pointer(outside), "world pointer policy blocks exactly the card footprint")
	var before_hits := pointer_hits
	_mouse(inside, MOUSE_BUTTON_LEFT)
	_check(pointer_hits == before_hits, "native card click cannot reach the underlying pointer probe")
	_mouse(outside, MOUSE_BUTTON_LEFT)
	_check(pointer_hits == before_hits + 1, "native outside-card click reaches the underlying pointer probe")
	var probe_ref: WeakRef = weakref(probe)
	probe.queue_free()
	await _until(func() -> bool: return probe_ref.get_ref() == null, "pointer probe releases before gameplay continues")


func _guidance_geometry_ready() -> bool:
	var card: Rect2 = scene.tutorial_popup_panel.get_node("Panel").get_global_rect()
	var placed: Array[Rect2] = []
	for control: Control in [scene.tutorial_popup_panel.get_node("Panel/Content/Title"), _message(), _details_button()]:
		var rect := control.get_global_rect()
		if not control.is_visible_in_tree() or rect.size.x <= 1.0 or rect.size.y <= 1.0 or not card.grow(0.5).encloses(rect):
			return false
		for previous: Rect2 in placed:
			if previous.intersects(rect):
				return false
		placed.append(rect)
	for button: Button in [_details_button()]:
		if button.get_combined_minimum_size().y > button.size.y + 0.5:
			return false
	return true


func _assert_guidance_geometry(tag: String) -> void:
	var card: Rect2 = scene.tutorial_popup_panel.get_node("Panel").get_global_rect()
	var rects: Array[Rect2] = []
	for control: Control in [scene.tutorial_popup_panel.get_node("Panel/Content/Title"), _message(), _details_button()]:
		var rect := control.get_global_rect()
		_check(control.is_visible_in_tree() and rect.size.x > 0 and rect.size.y > 0 and card.grow(0.5).encloses(rect), tag + " visible control fits guidance card: " + control.name)
		for previous: Rect2 in rects:
			_check(not previous.intersects(rect), tag + " independent content/actions do not overlap: " + control.name)
		rects.append(rect)
	for button: Button in [_details_button()]:
		_check(button.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING and button.get_combined_minimum_size().y <= button.size.y + 0.5, tag + " action text is not height-clipped: " + button.name)
	_check(Rect2(Vector2.ZERO, root.get_visible_rect().size).grow(0.5).encloses(card), tag + " card remains inside the actual viewport")


func _play_teaching_route() -> bool:
	var context: RunContext = scene.run_context
	_check(context.asset_ledger.get_currency(&"black_coin") == 20, "fresh tutorial owns 20 practice black coins")
	if not await _use_teaching_event("information", "mine_locations", 5):
		return false
	if not _walk(Vector2i(0, 2)) or not _walk(Vector2i(0, 3)):
		return false
	var injured := context.hp
	var price := 4 if context.pressure >= 40 else 9
	if not await _use_teaching_event("first_aid", "buy", price):
		return false
	var patches := context.asset_ledger.get_items_by_location(&"inventory").filter(func(item: Dictionary) -> bool: return item.item_id == "con_med_patch")
	if not _check(patches.size() == 1, "Lv0 aid purchase delivered one real patch"):
		return false
	var healed := _command(&"use_consumable", {"instance_id": patches[0].instance_id})
	_check(healed.get("ok", false) and context.hp == mini(100, injured + 25), "patch used in the aid room heals up to 25")
	if not _walk(Vector2i(0, 4)):
		return false
	var fled: Dictionary = scene.in_run_runtime.request_flee()
	if not _check(fled.get("ok", false) and not scene.in_run_runtime.has_active_combat(), "public combat flee permits chest practice"):
		return false
	if not await _test_failed_learning_and_retry() or not await _test_meta_backup_learning_recovery():
		return false
	if not _walk(Vector2i(2, 4)) or not await _use_teaching_event("relief", "flat", 5):
		return false
	if not _walk(Vector2i(3, 4)) or not await _use_teaching_event("recycle", "deliver", 0):
		return false
	return _walk(Vector2i(4, 4))


func _use_teaching_event(event: String, option_id: String, price: int) -> bool:
	var context: RunContext = scene.run_context
	if not _check(context.event_state.get("event_type") == event and context.event_state.get("ruleset_id") == "z2" and not context.event_state.get("requires_prepare", true), "first entry has a fully prepared " + event):
		return false
	if not _place_at_entity(&"event"):
		return false
	_key(KEY_E)
	var adapter = scene.z2_event_adapter
	if not await _until(func() -> bool: return scene._runtime_modal_is_top(&"event") and adapter.is_visible_in_tree(), event + " opens real dialogue"):
		return false
	var dialogue = adapter.dialogue
	for step in range(dialogue._lines.size() * 2 + 3):
		if dialogue._choosing:
			break
		_key(KEY_SPACE)
	var before := context.asset_ledger.get_currency(&"black_coin")
	for index in adapter._options.size():
		if adapter._options[index].get("id") != option_id:
			continue
		var button: Button = dialogue._buttons[index]
		button.grab_focus()
		_key(KEY_ENTER)
		if not await _until(func() -> bool: return dialogue._pending_by_room.is_empty(), "settle real " + option_id):
			return false
		if not _check(scene.last_command_result.get("ok", false) and context.asset_ledger.get_currency(&"black_coin") == before - price, event + " applies the visible choice and price: " + _reason(scene.last_command_result)):
			return false
		_key(KEY_ESCAPE)
		await _assert_free_controls(event + " after close")
		return true
	return _check(false, "missing visible teaching choice " + option_id)


func _test_failed_learning_and_retry() -> bool:
	var runtime = scene.runtime_controller
	var service = runtime.checkpoint_service
	var real_adapter = service.save_adapter
	var checkpoint_path: String = service.checkpoint_path
	var before_hash := FileAccess.get_sha256(checkpoint_path)
	var before_loaded: Dictionary = service.load_checkpoint()
	pre_payment_meta_sha = FileAccess.get_sha256(scene.meta_progress_adapter.active_meta_progress_path)
	if not _check(before_loaded.get("ok", false) and not before_hash.is_empty(), "failure injection starts from a real readable committed checkpoint"):
		return false
	var fault := FailCheckpointCommit.new()
	service.save_adapter = fault
	fault.armed = true
	var request := {"direction": Vector2i.RIGHT, "action_id": "teaching-chest-entry"}
	var preview := _command(&"attempt_room_transition", {"direction": Vector2i.RIGHT, "preview": true})
	_check(preview.get("ok", false) and preview.get("preview", false) and FileAccess.get_sha256(checkpoint_path) == before_hash, "real chest preview leaves checkpoint untouched")
	_assert_not_purchased("preview")
	_command(&"attempt_room_transition", request)
	if not await _until(func() -> bool: return not runtime.persistence_error.is_empty(), "real checkpoint failure activates persistence guard"):
		service.save_adapter = real_adapter
		return false
	_check(fault.failures_injected == 1 and not scene.last_command_result.get("ok", true), "one exact checkpoint atomic-rename failure is injected")
	_assert_not_purchased("after failed checkpoint")
	_check(not scene.run_context.profile_fields.get("flag_unlocked", false), "durable talent purchase does not prematurely publish an uncommitted runtime capability")
	_check(FileAccess.get_sha256(checkpoint_path) == before_hash and service.load_checkpoint().get("snapshot", {}) == before_loaded.get("snapshot", {}), "failed checkpoint preserves exact previous primary bytes and snapshot")
	var before_local: Vector2 = scene.player_controller.get_local_position()
	_movement_frame(0.08)
	_key(KEY_Q)
	_key(KEY_M)
	_key(KEY_ESCAPE)
	_check(scene.player_controller.get_local_position().is_equal_approx(before_local) and scene.modal_controller.depth() == 0 and scene.persistence_controller.is_blocked(), "save failure still blocks movement, drawers and Esc rather than weakening isolation")
	var blocked: Dictionary = _command(&"learn_tutorial_flag")
	_check(not blocked.get("ok", true) and _reason(blocked) == "persistence_retry_required", "another purchase cannot bypass a pending checkpoint failure")
	_assert_not_purchased("blocked retry request")
	if not await _click(scene.persistence_controller.persistence_retry_button, "actual persistence retry-and-continue button"):
		service.save_adapter = real_adapter
		return false
	if not await _until(func() -> bool: return runtime.persistence_error.is_empty() and not scene.persistence_controller.persistence_error_panel.visible, "official persistence retry restores the committed checkpoint"):
		service.save_adapter = real_adapter
		return false
	_check(not scene.run_context.profile_fields.get("flag_unlocked", false) and scene.run_context.get_current_pos() == Vector2i(0, 4), "retry restores the old runtime position/capability, not the failed candidate")
	var entered := _command(&"attempt_room_transition", request)
	service.save_adapter = real_adapter
	_check(entered.get("ok", false) and scene.run_context.get_current_pos() == Vector2i(1, 4) and scene.run_context.profile_fields.get("flag_unlocked", false), "chest entry learns before searching")
	_assert_paid_once("successful retry")
	_check(not _learn_button().visible, "learning button retires after the capability is committed")
	for id in ["tutorial-learn-repeat-a", "tutorial-learn-repeat-b"]:
		var repeated: Dictionary = _command(&"learn_tutorial_flag", {"action_id": id})
		_check(repeated.get("ok", false), "repeated learning remains idempotent across distinct request identities " + id)
		_assert_paid_once(id)
	return _check(scene.run_context.profile_fields.get("flag_unlocked", false), "explicit learning capability remains active after repeats")


func _test_meta_backup_learning_recovery() -> bool:
	var meta = scene.meta_progress_adapter
	var path: String = meta.active_meta_progress_path
	var profile: String = meta.active_profile_id
	var home := OS.get_user_data_dir().replace("\\", "/").simplify_path().trim_suffix("/")
	var absolute := ProjectSettings.globalize_path(path).replace("\\", "/").simplify_path()
	if not _check(absolute.to_lower().begins_with(home.to_lower() + "/saves/profiles/") and not pre_payment_meta_sha.is_empty() and FileAccess.get_sha256(path + ".bak") == pre_payment_meta_sha, "recovery fixture owns its target and uses the exact native pre-payment Meta backup"):
		return false
	var backup := _read_native_meta(path + ".bak", profile)
	var paid := _read_native_meta(path, profile)
	var paid_disk := _disk_meta()
	if not _check(backup.get("admission", {}).get("phase") == "active" and backup.get("admission") == paid.get("admission") and _learning_state(backup) == original_learning and not paid.is_empty(), "actual valid backup has the same active admission and100 unspent points, not manually cleared flags"):
		return false
	if not _check(SaveAdapter.is_nonnegative_integer(paid.get("talent_spent")) and paid.talent_spent == 100, "original paid Meta observation contains exactly100 integral spent points"):
		return false
	var runtime = scene.runtime_controller
	var checkpoint_path: String = runtime.checkpoint_service.checkpoint_path
	var checkpoint_hash := FileAccess.get_sha256(checkpoint_path)
	var loaded: Dictionary = runtime.checkpoint_service.load_checkpoint()
	var decoded: Dictionary = runtime.decode_checkpoint_state(loaded.get("snapshot", {}).get("state", {}))
	var saved: Dictionary = decoded.get("state", {})
	if not _check(decoded.get("ok", false) and saved.get("context", {}).get("data", {}).get("profile_fields", {}).get("flag_unlocked", false), "paid native checkpoint really contains the runtime capability before Meta recovery"):
		return false
	var saved_popup: Dictionary = saved.context.data.tutorial_popup
	if not _check(str(saved_popup.get("id", "")) == "chest_rule" and saved_popup.get("blocking") == false and not saved_popup.has("presentation_kind"), "native recovery fixture has the exact unclassified nonblocking chest lesson"):
		return false
	# Existing restore classifies this one known presentation leaf after native
	# validation. Derive its exact value, retaining every other native fact.
	var expected_restore := saved.duplicate(true)
	expected_restore.context.data.tutorial_popup["presentation_kind"] = &"guidance"
	await _close_main()
	# Only this proven private primary is damaged. The real .bak and checkpoint
	# are never edited: normal native load/recovery must select and validate them.
	var broken := FileAccess.open(path, FileAccess.WRITE)
	if not _check(broken != null, "private Meta-primary corruption fixture opens its validated target"):
		return false
	broken.store_string("{intentional_private_meta_primary_parse_failure")
	broken.close()
	if not await _open_main():
		return false
	meta = scene.meta_progress_adapter
	runtime = scene.runtime_controller
	if not _check(scene._show_run_screen() and meta.active_profile_id == profile and meta.last_load_status == "recovered_backup" and not meta.write_blocked, "new Main natively restores the real valid Meta backup as writable"):
		return false
	_check(RunStateSnapshot.fingerprint(runtime.capture_authoritative_state()) == RunStateSnapshot.fingerprint(expected_restore), "backup recovery preserves native room state and guide classification")
	_check(FileAccess.get_sha256(checkpoint_path) == checkpoint_hash, "recovering the entitlement does not rewrite the good room checkpoint")
	_assert_paid_once("restored chest intent repays missing entitlement")
	_check(not runtime.is_tutorial_learning_required() and !_learn_button().visible and _disk_meta() == paid_disk, "native backup recovery automatically restores the original paid entitlement")

	# A subsequent already-paid commit and its retry both cost zero.
	var service = runtime.checkpoint_service
	var real_adapter = service.save_adapter
	var fault := FailCheckpointCommit.new()
	service.save_adapter = fault
	fault.armed = true
	var before_cut: Dictionary = runtime.capture_authoritative_state()
	var paid_hash := FileAccess.get_sha256(path)
	var before_cut_checkpoint := FileAccess.get_sha256(checkpoint_path)
	var failed: Dictionary = _command(&"learn_tutorial_flag", {"action_id": "meta-backup-paid-checkpoint-cut"})
	if not _check(fault.failures_injected == 1 and not failed.get("ok", true) and not runtime.persistence_error.is_empty(), "already-paid learning still honors a real checkpoint failure"):
		service.save_adapter = real_adapter
		return false
	_check(RunStateSnapshot.fingerprint(runtime.capture_authoritative_state()) == RunStateSnapshot.fingerprint(before_cut) and FileAccess.get_sha256(checkpoint_path) == before_cut_checkpoint, "already-paid failed candidate preserves the whole native state and previous checkpoint bytes")
	_check(FileAccess.get_sha256(path) == paid_hash, "already-paid checkpoint failure does not write or charge Meta")
	if not await _click(scene.persistence_controller.persistence_retry_button, "actual storage recovery after already-paid checkpoint failure"):
		service.save_adapter = real_adapter
		return false
	var recovered := await _until(func() -> bool: return runtime.persistence_error.is_empty() and not scene.persistence_controller.persistence_error_panel.visible, "official already-paid persistence retry completes")
	service.save_adapter = real_adapter
	if not recovered:
		return false
	_check(FileAccess.get_sha256(path) == paid_hash and RunStateSnapshot.fingerprint(runtime.capture_authoritative_state()) == RunStateSnapshot.fingerprint(before_cut), "official retry changes neither paid Meta bytes nor any native committed fact")
	var retry: Dictionary = _command(&"learn_tutorial_flag", {"action_id": "meta-backup-paid-checkpoint-retry"})
	_check(retry.get("ok", false) and FileAccess.get_sha256(path) == paid_hash, "subsequent successful already-paid learning commits at zero Meta cost")
	_assert_learning_commit_only(before_cut, runtime.capture_authoritative_state(), "already-paid checkpoint retry")
	_assert_paid_once("after native backup recovery and paid checkpoint retry")
	return failures.is_empty()


func _read_native_meta(path: String, profile: String) -> Dictionary:
	var reader := MetaScript.new()
	reader.set_active_profile_path(path, profile)
	if not _check(reader.last_load_status == "loaded" and not reader.write_blocked, "independent native Meta reader validates " + path.get_file()):
		return {}
	return reader.data.duplicate(true)


func _assert_learning_commit_only(before: Dictionary, after: Dictionary, tag: String) -> void:
	var observed := after.duplicate(true)
	var added: Array[String] = []
	for id: String in after.receipts:
		if not before.receipts.has(id):
			added.append(id)
	_check(after.revision == before.revision + 1 and after.command_sequence == before.command_sequence + 1 and added.size() == 1, tag + " produces exactly one native revision/command/receipt")
	for id: String in added:
		_check(after.receipts[id].result.get("action_id") == id and after.receipts[id].result.get("revision") == after.revision, tag + " new receipt binds the actual committed action and revision")
		observed.receipts.erase(id)
	observed.revision = before.revision
	observed.command_sequence = before.command_sequence
	_check(RunStateSnapshot.fingerprint(observed) == RunStateSnapshot.fingerprint(before), tag + " preserves every other native runtime field, context leaf, component and prior receipt")


func _test_disk_reload_and_main_restart() -> bool:
	var meta = scene.meta_progress_adapter
	var path: String = meta.active_meta_progress_path
	var reloaded := MetaScript.new()
	var before_hash := FileAccess.get_sha256(path)
	reloaded.set_active_profile_path(path, meta.active_profile_id)
	reloaded.load_or_create_default()
	_check(reloaded.last_load_status == "loaded" and not reloaded.write_blocked and _learning_state(reloaded.data) == _learning_state(meta.data), "independent disk reload preserves the exact100-point talent entitlement")
	_check(FileAccess.get_sha256(path) == before_hash, "independent disk reload never rewrites the durable Meta bytes")
	var run_id := str(scene.run_context.run_id)
	await _close_main()
	if not await _open_main():
		return false
	if not _check(scene.run_context.run_active and str(scene.run_context.run_id) == run_id and scene.run_context.get_current_pos() == Vector2i(4, 4) and scene._show_run_screen(), "new Main instance resumes the exact durable teaching run and room"):
		return false
	_assert_paid_once("Main disk restart")
	return _check(scene.run_context.profile_fields.get("flag_unlocked", false) and not _learn_button().visible and not scene.meta_progress_adapter.data.get("tutorial_completed", false), "disk restart preserves learned runtime flag without auto-completing training")


func _test_flag_risk_confirmation() -> void:
	var origin: Vector2i = scene.run_context.get_current_pos()
	var target := Vector2i(4, 3)
	var flagged: Dictionary = _command(&"toggle_flag_cell", {"pos": target})
	if not _check(flagged.get("ok", false) and scene.run_context.intel_map.is_flagged(target), "learned capability places a real manual flag"):
		return
	for cancel_mode in ["escape", "button"]:
		var request: Dictionary = _command(&"attempt_room_transition", {"direction": target - origin})
		if not _check(request.get("ok", false) and str(request.get("status", "")) == "flag_confirmation_required", "flagged entry requests a real risk confirmation: " + cancel_mode):
			return
		if not await _until(func() -> bool: return scene._runtime_modal_is_top(&"flag_entry_confirm") and str(scene.tutorial_popup_panel.popup.get("id", "")) == "flag_entry_confirm", "risk view and modal stack agree: " + cancel_mode):
			return
		_assert_business_modal_blocks(&"flag_entry_confirm", "flag risk " + cancel_mode)
		var confirm := _details_button()
		var cancel := scene.tutorial_popup_panel.get_node("Panel/Content/CancelButton") as Button
		_check(confirm.is_visible_in_tree() and cancel.is_visible_in_tree() and not confirm.get_global_rect().intersects(cancel.get_global_rect()), "true risk confirm/cancel buttons remain separately reachable")
		if cancel_mode == "escape":
			_key(KEY_ESCAPE)
		else:
			await _click(cancel, "actual risk cancel button")
		await _until(func() -> bool: return not scene._runtime_modal_is_top(&"flag_entry_confirm") and not scene.run_context.has_blocking_tutorial_popup(), "risk cancellation releases the real blocker: " + cancel_mode)
		_check(scene.run_context.get_current_pos() == origin and scene.run_context.intel_map.is_flagged(target), "risk cancellation neither enters target nor removes its flag: " + cancel_mode)
	var again: Dictionary = _command(&"attempt_room_transition", {"direction": target - origin})
	if _check(again.get("ok", false), "risk confirmation can be explicitly requested again"):
		await _until(func() -> bool: return scene._runtime_modal_is_top(&"flag_entry_confirm"), "real risk modal reopens for affirmative test")
		if await _click(_details_button(), "actual risk confirmation button"):
			await _until(func() -> bool: return scene.run_context.get_current_pos() == target and not scene.run_context.has_blocking_tutorial_popup(), "affirmative risk action performs exactly the requested entry")
			_check(scene.run_context.intel_map.is_flagged(target), "affirmative entry retains the manual flag")
	if scene.run_context.get_current_pos() == target:
		_walk(origin)
	await _assert_free_controls("after real risk decisions")


func _complete_training() -> void:
	if not _check(scene.run_context.get_current_pos() == Vector2i(4, 4) and not scene.meta_progress_adapter.data.get("tutorial_completed", false), "completion starts only from learned live tutorial exit"):
		return
	if not _place_at_entity(&"exit"):
		return
	_key(KEY_T)
	if not await _until(func() -> bool: return scene._runtime_modal_is_top(&"extract_confirm") and scene.extract_panel.visible, "learned player reaches the real extract confirmation"):
		return
	_assert_business_modal_blocks(&"extract_confirm", "extract confirmation")
	_key(KEY_ESCAPE)
	await _until(func() -> bool: return not scene._runtime_modal_is_top(&"extract_confirm") and scene.run_context.phase == &"running", "Esc cancels actual extraction rather than completing it")
	_check(scene.run_context.run_active and not scene.meta_progress_adapter.data.get("tutorial_completed", false), "cancelled extraction preserves the unfinished training state")
	_key(KEY_T)
	if not await _until(func() -> bool: return scene._runtime_modal_is_top(&"extract_confirm"), "extraction can be requested again"):
		return
	if not await _click(scene.extract_confirm_button, "actual final extraction confirm button"):
		return
	if not await _until(func() -> bool: return not scene.run_context.run_active and scene.meta_progress_adapter.data.get("tutorial_completed", false), "real terminal commit completes learned teaching"):
		_diagnose("terminal_commit", {"phase": str(scene.run_context.phase), "run_active": scene.run_context.run_active, "reason": _reason(scene.last_command_result), "status": str(scene.last_command_result.get("status", "")), "message": scene.last_command_result.get("message", scene.last_command_result.get("action_result", {}).get("message", "")), "meta_commit": scene.runtime_controller.last_meta_commit, "persistence": scene.runtime_controller.persistence_error})
		return
	var meta: Dictionary = scene.meta_progress_adapter.data
	var settlement: Dictionary = scene.run_context.result_snapshot.get("settlement", {})
	_check(settlement.get("finalized", false) and settlement.get("tutorial_completion_only", false) and scene.runtime_controller.last_meta_commit.get("ok", false), "real teaching-only settlement finalizes through the checkpoint/Meta boundary")
	_check(meta.get("profile_level") == 1 and meta.get("profile_exp") == 0 and meta.get("run_count") == 0 and meta.get("extract_count") == 0, "natural learned teaching reaches Lv1 without exploration XP or ordinary run counts")
	_check(meta.get("talent_points") == 0 and meta.get("talent_spent") == 100 and meta.get("talent_earned") == 100 and meta.get("talent_flags", []).count("z2_talent_01") == 1, "successful completion neither double-charges nor re-grants teaching points")
	_check(meta.get("gold") == 0 and meta.get("warehouse_items", []).is_empty() and meta.get("initial_supply_receipt", {}).is_empty() and meta.get("admission", {}).is_empty(), "tutorial completion grants no starter items and clears its admission")
	var reload := MetaScript.new()
	reload.set_active_profile_path(scene.meta_progress_adapter.active_meta_progress_path, scene.meta_progress_adapter.active_profile_id)
	reload.load_or_create_default()
	_check(reload.data.get("tutorial_completed", false) and reload.data.get("profile_level") == 1 and reload.data.get("talent_spent") == 100, "completed Lv1 entitlement survives an independent final disk reload")


func _test_early_departures() -> void:
	var map_id := "classic_7x7_simple"
	var offers := {}
	for index in range(6):
		var commission: Dictionary = M7ContentCatalog.commission_offer_candidates(map_id, index, 3)[0]
		var config := {"map_config_id": map_id, "difficulty": &"simple", "seed_value": 411, "selected_objective_id": commission.id}
		var start := _command(&"start_standard_run", {"run_start_config": config})
		if not _check(start.get("ok", false), "durable early departure %d: %s" % [index + 1, str(start.get("action_result", {}))]):
			return
		var context: RunContext = scene.run_context
		var planned: Array = context.run_start_config.get("early_offered_events", [])
		if index < 5:
			_check(planned.size() == (2 if index == 4 else 1), "graduated run has its scheduled route choices")
			offers[str(planned)] = true
			var targets: Array = context.truth_map.map_profile.get("early_event_positions", [])
			if not _check(not targets.is_empty(), "early route has a real event room"):
				return
			var delta: Vector2i = targets[0] - context.get_current_pos()
			_check(absi(delta.x) + absi(delta.y) == 1, "scheduled event can be entered in one actual step")
			if not _walk(targets[0]):
				return
			_check(context.event_state.get("event_type") == planned[0] and not context.event_state.get("requires_prepare", true), "scheduled offer resolves through real entry and preparation")
		else:
			_check(planned.is_empty(), "sixth valid departure returns to ordinary placement")
		var ended := _command(&"abandon_run", {"confirmed": true})
		if ended.get("ok", false) and scene.run_context.phase == &"failure_salvage":
			ended = _command(&"confirm_failure_salvage", {"selected_instance_ids": []})
		if not _check(ended.get("ok", false) and scene.meta_progress_adapter.data.run_count == index + 1, "abandoned run settlement advances the discovery ordinal once: %s" % _reason(ended)):
			return
		if index < 5:
			var record: Dictionary = scene.meta_progress_adapter.data.history_records.back()
			_check(record.get("early_offered_events") == planned and record.get("visited_event_types", []).has(planned[0]), "committed history distinguishes offered and actually visited events")
	_check(offers.size() == 5, "same-seed low-XP departures offer five different choices")


func _assert_free_controls(tag: String) -> void:
	if not _check(not scene._gameplay_input_blocked() and not scene._is_runtime_modal_open() and not scene.run_context.has_blocking_tutorial_popup(), tag + " has no guidance input guard"):
		return
	var room: Vector2i = scene.run_context.get_current_pos()
	var start: Vector2 = scene.player_controller.place_on_clear_floor(Vector2(0.50, 0.72))
	_movement_frame(0.08)
	_check(scene.player_controller.input_enabled and scene.player_controller.get_local_position().x > start.x and scene.run_context.get_current_pos() == room, tag + " physical D input produces actual local movement")
	_key(KEY_Q)
	if not await _until(func() -> bool: return scene._runtime_modal_is_top(&"inventory"), tag + " actual Q opens inventory"):
		return
	_key(KEY_Q)
	if not await _until(func() -> bool: return not scene._runtime_modal_is_top(&"inventory") and not scene.inventory_panel.visible, tag + " second Q closes inventory"):
		return
	_key(KEY_M)
	if not await _until(func() -> bool: return scene._runtime_modal_is_top(&"map"), tag + " actual M opens the map"):
		return
	_key(KEY_ESCAPE)
	if not await _until(func() -> bool: return not scene._runtime_modal_is_top(&"map") and not scene.map_overlay_panel.visible, tag + " Esc closes map without confirming a lesson"):
		return
	_key(KEY_ESCAPE)
	if not await _until(func() -> bool: return scene._runtime_modal_is_top(&"pause"), tag + " actual Esc opens pause"):
		return
	_key(KEY_ESCAPE)
	await _until(func() -> bool: return scene.modal_controller.depth() == 0 and not scene.pause_panel.visible and scene.player_controller.input_enabled, tag + " next Esc closes pause and restores movement")


func _assert_business_modal_blocks(id: StringName, tag: String) -> void:
	var position: Vector2i = scene.run_context.get_current_pos()
	var local: Vector2 = scene.player_controller.get_local_position()
	_movement_frame(0.08)
	_key(KEY_E)
	_key(KEY_Q)
	_key(KEY_M)
	_check(scene._runtime_modal_is_top(id) and scene.modal_controller.depth() == 1 and scene.run_context.get_current_pos() == position and scene.player_controller.get_local_position().is_equal_approx(local), tag + " still truly blocks movement and E/Q/M")
	_check(not scene.player_controller.input_enabled and not scene.inventory_panel.visible and not scene.map_overlay_panel.visible, tag + " does not leak background input while the business decision is pending")


func _movement_frame(delta: float) -> void:
	for down: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = KEY_D
		event.physical_keycode = KEY_D
		event.pressed = down
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		if down:
			scene._process(delta)


func _walk(target: Vector2i) -> bool:
	var result: Dictionary = _command(&"attempt_room_transition", {"direction": target - scene.run_context.get_current_pos()})
	return _check(result.get("ok", false) and scene.run_context.get_current_pos() == target, "public real room entry reaches fixed tutorial cell " + str(target))


func _place_at_entity(kind: StringName) -> bool:
	for entity: Node in scene.room_runtime_view.special_entities.values():
		if StringName(entity.interaction_kind) == kind:
			scene.player_controller.set_local_position(entity.local_pos)
			scene._process(0.0)
			return true
	return _check(false, "real current room exposes an interaction marker " + str(kind))


func _assert_not_purchased(tag: String) -> void:
	var memory := _learning_state(scene.meta_progress_adapter.data)
	var disk := _learning_state(_disk_meta())
	if not _check(memory == original_learning and disk == original_learning, tag + " changes neither in-memory nor durable teaching points/entitlement"):
		_diagnose("learning_observation", {"case": tag, "original": original_learning, "memory": memory, "disk": disk})
	_check(not scene.run_context.profile_fields.get("flag_unlocked", false), tag + " grants no runtime flag by reading/closing guidance")


func _assert_paid_once(tag: String) -> void:
	for source: Dictionary in [scene.meta_progress_adapter.data, _disk_meta()]:
		_check(source.get("talent_points") == 0 and source.get("talent_spent") == 100 and source.get("talent_earned") == 100 and source.get("talent_flags", []).count("z2_talent_01") == 1 and source.get("profile_level") == 0 and not source.get("tutorial_completed", false), tag + " durable/in-memory learning costs exactly100 once and does not finish teaching")


func _learning_state(data: Dictionary) -> Dictionary:
	# JSON numbers are floats; Dictionary equality does not coerce their Variant
	# types. Validate integral values first, then compare canonical observations.
	var valid := data.get("talent_flags") is Array and data.get("tutorial_completed") is bool
	for field: String in ["talent_points", "talent_earned", "talent_spent", "profile_level"]:
		valid = valid and SaveAdapter.is_nonnegative_integer(data.get(field))
	if not _check(valid, "observed learning state contains actual nonnegative integers, flags and completion boolean"):
		return {"invalid_learning_observation": true}
	var flags: Array[String] = []
	for flag: Variant in data.talent_flags:
		if not _check(flag is String or flag is StringName, "observed learning entitlement is an actual string identity"):
			return {"invalid_learning_observation": true}
		flags.append(str(flag))
	return {"points": int(data.talent_points), "earned": int(data.talent_earned), "spent": int(data.talent_spent),
		"flags": flags, "level": int(data.profile_level), "completed": data.tutorial_completed}


func _disk_meta() -> Dictionary:
	var path: String = scene.meta_progress_adapter.active_meta_progress_path
	if not _check(FileAccess.file_exists(path), "real active-profile Meta file exists for durable observation"):
		return {}
	var parser := JSON.new()
	var parsed := parser.parse(FileAccess.get_file_as_string(path))
	if not _check(parsed == OK and parser.data is Dictionary, "real active-profile Meta bytes decode as a dictionary"):
		return {}
	var data: Dictionary = parser.data
	_check(data.get("profile_id") == scene.meta_progress_adapter.active_profile_id and data.get("ruleset_id") == "z2", "durable observation belongs to the actual active Z2 profile")
	return data


func _details_button() -> Button:
	return scene.tutorial_popup_panel.get_node("Panel/Content/ConfirmButton") as Button


func _learn_button() -> Button:
	return scene.tutorial_popup_panel.get_node("Panel/Content/LearnFlagButton") as Button


func _message() -> RichTextLabel:
	return scene.tutorial_popup_panel.get_node("Panel/Content/Message") as RichTextLabel


func _wheel_to_end(message: RichTextLabel, tag: String) -> void:
	var scrollbar := message.get_v_scroll_bar()
	# This is a 60-paragraph stress fixture, not a performance gate: at 150%
	# its native one-notch scroll is ~7000 px. Allow enough actual wheel events
	# at the project's frame cadence; never teleport/set the scrollbar value.
	var deadline := Time.get_ticks_msec() + 15000
	# A newly shaped font/text can precede its deferred scrollbar range update.
	# Never treat the previous scale's bar end as evidence about the new tail.
	while not _message_tail_visible(message) and Time.get_ticks_msec() < deadline:
		_mouse(message.get_global_transform_with_canvas() * (message.size * 0.5), MOUSE_BUTTON_WHEEL_DOWN)
		await process_frame
	if not _check(_message_tail_visible(message), tag + " actual wheel reaches the full source last line"):
		_diagnose("wheel_tail", {"case": tag, "content_height": message.get_content_height(), "rect": message.get_global_rect(), "bar_value": scrollbar.value, "bar_max": scrollbar.max_value, "bar_page": scrollbar.page})


func _message_tail_visible(message: RichTextLabel) -> bool:
	var scrollbar := message.get_v_scroll_bar()
	return scrollbar.value >= scrollbar.max_value - scrollbar.page - 0.5 and message.get_content_height() - scrollbar.value <= message.size.y + 1.0


func _click(button: Button, label: String) -> bool:
	if not _check(button != null, label + " exists"):
		return false
	var button_ref: WeakRef = weakref(button)
	if not await _until(func() -> bool: return _button_hit_testable(button_ref), label + " becomes natively hit-testable"):
		var hovered := root.gui_get_hovered_control()
		_diagnose("button_hit_test", {"case": label, "rect": button.get_global_rect() if is_instance_valid(button) else Rect2(), "hovered": str(hovered.get_path()) if hovered != null else "none"})
		return false
	var observed := {"pressed": false}
	var on_pressed := func() -> void: observed.pressed = true
	button.pressed.connect(on_pressed, CONNECT_ONE_SHOT)
	var point := button.get_global_transform_with_canvas() * (button.size * 0.5)
	_mouse(point, MOUSE_BUTTON_LEFT)
	if is_instance_valid(button) and button.pressed.is_connected(on_pressed):
		button.pressed.disconnect(on_pressed)
	return _check(observed.pressed, label + " receives the real native Button.pressed activation")


func _button_hit_testable(button_ref: WeakRef) -> bool:
	var button := button_ref.get_ref() as Button
	if button == null or not button.is_visible_in_tree() or button.disabled or button.size.x <= 1.0 or button.size.y <= 1.0:
		return false
	_motion(button.get_global_transform_with_canvas() * (button.size * 0.5))
	var hovered := root.gui_get_hovered_control()
	while hovered != null:
		if hovered == button:
			return true
		if hovered.mouse_filter == Control.MOUSE_FILTER_STOP:
			return false
		hovered = hovered.get_parent_control()
	return false


func _motion(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)


func _mouse(point: Vector2, button_index: MouseButton) -> void:
	_motion(point)
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = button_index
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down and button_index == MOUSE_BUTTON_LEFT else 0
		event.pressed = down
		root.push_input(event, true)


func _key(code: Key) -> void:
	for down: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = down
		root.push_input(event, true)


func _command(command: StringName, payload: Dictionary = {}) -> Dictionary:
	return scene._dispatch_command(command, payload, false, false)


func _reason(result: Dictionary) -> String:
	return str(result.get("reason_code", result.get("reason", result.get("status", ""))))


func _until(predicate: Callable, label: String, timeout_ms: int = 4000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not bool(predicate.call()) and Time.get_ticks_msec() < deadline:
		await process_frame
	return _check(bool(predicate.call()), label)


func _diagnose(label: String, evidence: Dictionary) -> void:
	print("Z2_NONBLOCKING_TUTORIAL_DIAG " + label + " " + JSON.stringify(evidence))


func _check(ok: bool, label: String) -> bool:
	checks += 1
	if not ok:
		failures.append(label)
		print("Z2_NONBLOCKING_TUTORIAL_FAIL " + label)
	return ok


func _finish() -> void:
	print("Z2_NONBLOCKING_TUTORIAL=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
