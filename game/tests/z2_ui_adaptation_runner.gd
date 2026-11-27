extends "res://tests/z2_event_ui_runner.gd"

# Production Main and its normal page entry points; fixtures only seed saved eligibility/results.
const SIZES := [Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(1600, 1000)]
var _main: Node
var _meta: MetaProgressAdapter
var _case := ""
var _matrix: Array[Dictionary] = []
var _geometry := {}
var _rendered_size := Vector2i.ZERO
var _opening_action_cases: Array[Dictionary] = []
var _action_ink := {}

class ActionInkProbe:
	extends Control
	var surface: StyleBox
	var button_rect := Rect2()
	func _draw() -> void:
		draw_style_box(surface, button_rect)

func _run() -> void:
	root.size = SIZES[0]
	_main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(_main)
	current_scene = _main
	scene = _main.get_node("RunScene")
	await process_frame
	scene.set_process(false)
	scene.set_physics_process(false)
	_setup_runtime()
	_prepare_camp_profile("adaptation")
	var camp_layout_only := OS.get_cmdline_user_args().has("--camp-layout-only")
	var opening_cost_only := OS.get_cmdline_user_args().has("--opening-cost-only")
	var resolutions: Array = [SIZES[0]] if OS.get_cmdline_user_args().has("--quick") or camp_layout_only else SIZES
	if OS.get_cmdline_user_args().has("--camp-only"): resolutions = []
	if opening_cost_only: resolutions = []
	for resolution in resolutions:
		await _resize_window(resolution)
		for scale_value in [1.0, 1.25, 1.5]:
			var checks_before := checks
			var failures_before := failures.size()
			_case = "%dx%d-%d" % [resolution.x, resolution.y, roundi(scale_value * 100)]
			scene.set_ui_scale_factor(scale_value)
			await _settle()
			_check(root.size == resolution, _case + ": actual window size")
			if camp_layout_only:
				await _camp_matrix()
				continue
			await _events_matrix()
			await _long_text_matrix()
			await _camp_matrix()
			await _goals_matrix()
			await _inventory_matrix()
			await _notification_matrix()
			_matrix.append({"case": _case, "window": [root.size.x, root.size.y], "window_mode": root.mode, "ui_scale": scale_value,
				"canvas": [root.get_visible_rect().size.x, root.get_visible_rect().size.y],
				"rendered_pixels": [_rendered_size.x, _rendered_size.y],
				"checks": checks - checks_before, "failures": failures.size() - failures_before, "geometry": _geometry.duplicate(true)})
			print("Z2_UI_ADAPTATION_CASE=" + _case)
	if not OS.get_cmdline_user_args().has("--camp-only") and not camp_layout_only and not opening_cost_only:
		await _scroll_regression()
		await _many_materials()
	if opening_cost_only:
		await _opening_cost_safearea()

	if not OS.get_cmdline_user_args().has("--camp-only") and not camp_layout_only and not opening_cost_only:
		await _resize_window(Vector2i(1920, 1080))
		scene.set_ui_scale_factor(1.0)
		_case = "1920x1080-100-actual"
		await _actual_notification()
		var queue: Control = root.get_node("Z2PersistentOverlays/NotificationQueue")
		await queue.notification_shown
		_check(queue.find_child("NotificationKind", true, false).text == "任务完成", "actual persisted completion displays authoritative task kind")
		await _capture("committed-notification-result")
		scene._show_run_screen()
		await _settle()
		await _capture("committed-notification-run")
	if not opening_cost_only and DisplayServer.get_name() != "headless":
		_prepare_camp_profile("opening_action_safearea")
		await _opening_cost_safearea()
	DirAccess.make_dir_recursive_absolute("user://captures/adaptation")
	var matrix_file := FileAccess.open("user://captures/adaptation/matrix.json", FileAccess.WRITE)
	matrix_file.store_string(JSON.stringify({"matrix": _matrix, "opening_actions": _opening_action_cases, "checks": checks, "failures": failures,
		"renderer": DisplayServer.get_name(), "engine": Engine.get_version_info().string}, "\t"))
	matrix_file.close()
	scene.set_ui_scale_factor(1.0)
	_release_runtime(runtime)
	_main.free()
	runtime = null
	_meta = null
	await process_frame
	await process_frame
	_check(root.get_node_or_null("Z2PersistentOverlays") == null, "Main teardown releases the persistent overlay")
	for failure in failures: print("Z2_UI_ADAPTATION_FAIL " + failure)
	print("Z2_UI_ADAPTATION=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _prepare_camp_profile(prefix: String) -> void:
	# Each cost/selection fixture uses a separate real saved profile, never
	# clears an already selected offer to bypass its immutable choice.
	_meta = Meta.new()
	_meta.set_active_profile_path("user://%s_%d/meta.json" % [prefix, Time.get_ticks_usec()], prefix + "_ui")
	_check(_meta.initialize_z2_profile(Rules.CONTENT_VERSION).get("ok", false), "real isolated UI profile")
	_meta.begin_tutorial_training()
	_meta.purchase_tutorial_flag()
	_meta._apply_tutorial_settlement({"mode": "tutorial", "outcome": "Training Complete", "settlement": {"outcome": "success"}}, prefix + "_teaching")
	_meta.data.gold = 1000
	_meta.data.talent_flags.append("z2_talent_15")
	_check(_meta.save(), "camp prerequisite fixture persisted")
	# Camp preparation must not leave the following in-run matrix inactive.
	var was_active: bool = runtime.context.run_active
	runtime.context.run_active = false
	runtime.bind_meta_progress_adapter(_meta)
	runtime.context.run_active = was_active

func _settle() -> void:
	for frame in range(3): await process_frame

func _resize_window(resolution: Vector2i) -> void:
	# A decorated 1440-high window is clamped by Windows on this 1440-high screen.
	# Exercise the project's supported borderless mode for native monitor size.
	root.mode = Window.MODE_WINDOWED
	await _settle()
	root.size = resolution
	if DisplayServer.get_name() != "headless" and resolution == DisplayServer.screen_get_size():
		root.mode = Window.MODE_FULLSCREEN
	await _settle()

func _rect(control: Control) -> Rect2:
	return control.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, control.size)

func _coordinates(rect: Rect2) -> Array:
	return [rect.position.x, rect.position.y, rect.size.x, rect.size.y]

func _inside(control: Control, label: String) -> void:
	if control == null:
		_check(false, _case + ": missing visible control " + label)
		return
	_check(control.is_visible_in_tree() and root.get_visible_rect().grow(1).encloses(_rect(control)), _case + ": visible viewport bounds " + label + " " + str(_rect(control)) + " viewport=" + str(root.get_visible_rect()))

func _label_fits(label: Label, description: String) -> void:
	var font := label.get_theme_font("font")
	var height := font.get_multiline_string_size(label.text, label.horizontal_alignment, label.size.x, label.get_theme_font_size("font_size")).y
	_check(height <= label.size.y + 2, _case + ": full text height " + description)
	if label.autowrap_mode == TextServer.AUTOWRAP_OFF:
		_check(font.get_string_size(label.text, label.horizontal_alignment, -1, label.get_theme_font_size("font_size")).x <= label.size.x + 1, _case + ": full text width " + description)

func _capture(page: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("user://captures/adaptation")
	var picture := root.get_texture().get_image()
	# The existing keep-aspect setting letterboxes a 16:10 window. The raw GPU
	# texture excludes those bars; preserve it unchanged instead of fabricating a window capture.
	var canvas := root.get_visible_rect().size
	var stretch := minf(float(root.size.x) / canvas.x, float(root.size.y) / canvas.y)
	var expected := Vector2i((canvas * stretch).floor())
	_rendered_size = picture.get_size()
	_check(_rendered_size == expected, _case + ": GPU image matches actual keep-aspect render size " + page + " actual=" + str(_rendered_size) + " expected=" + str(expected))
	_check(picture.save_png("user://captures/adaptation/%s-%s.png" % [_case, page]) == OK, _case + ": capture " + page)

func _mouse_click(control: Control) -> void:
	var point := _rect(control).get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	# Positions are already in viewport coordinates. Keep the project's stretch
	# transform from being applied a second time after a real window resize.
	root.push_input(motion, true)
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		root.push_input(event, true)
	await _settle()

func _keyboard(key: Key) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = key
		event.pressed = down
		root.push_input(event, true)
	await _settle()

func _wheel(control: Control, down: bool) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = _rect(control).get_center()
		event.button_index = MOUSE_BUTTON_WHEEL_DOWN if down else MOUSE_BUTTON_WHEEL_UP
		event.pressed = pressed
		root.push_input(event, true)
	await _settle()

func _events_matrix() -> void:
	scene._show_run_screen()
	runtime.context.pressure = 40
	_open("relief")
	await _press("prepare")
	var adapter: Control = scene.z2_event_adapter
	_advance_to_choices(adapter.dialogue)
	await _settle()
	for path in ["%DialogueFrame", "%ChoicesFrame", "%CloseDialogue"]:
		_inside(adapter.dialogue.get_node(path), "event " + path)
	var dialogue_rect := _rect(adapter.dialogue.get_node("%DialogueFrame"))
	var choices_rect := _rect(adapter.dialogue.get_node("%ChoicesFrame"))
	var name_rect := _rect(adapter.dialogue.get_node("%Nameplate"))
	_geometry = {"dialogue": _coordinates(dialogue_rect), "choices": _coordinates(choices_rect), "nameplate": _coordinates(name_rect)}
	_check(absf(dialogue_rect.get_center().x - root.get_visible_rect().get_center().x) <= 1, _case + ": reference dialogue centered across bottom")
	_check(absf(dialogue_rect.size.x / root.get_visible_rect().size.x - 1468.0 / 1920.0) < 0.015, _case + ": reference dialogue width proportion")
	_check(choices_rect.end.y < dialogue_rect.position.y, _case + ": reference choices independent above dialogue on right")
	_check(name_rect.position.y < dialogue_rect.position.y and name_rect.end.y > dialogue_rect.position.y, _case + ": reference nameplate straddles top border")
	var first_option: Control = adapter.dialogue._buttons[0]
	var title := first_option.find_child("OptionLabel", true, false) as Label
	var cost := first_option.find_child("OptionCost", true, false) as Label
	_check(absf(_rect(title).position.y - _rect(cost).position.y) < 3, _case + ": reference option title and fee share header row")
	var scroll: ScrollContainer = adapter.dialogue.get_node("%OptionsScroll")
	var buttons: Array = adapter.dialogue._buttons
	_check(buttons.size() >= 3, _case + ": actual relief choices")
	for button: Button in buttons:
		scroll.ensure_control_visible(button)
		await _settle()
		# Scroll offsets are integers; allow one local pixel after the existing UI scale.
		_check(_rect(scroll).grow(adapter.dialogue.scale.x).encloses(_rect(button)), _case + ": each event choice reachable " + str(button.name) + " button=" + str(_rect(button)) + " scroll=" + str(_rect(scroll)))
	scroll.scroll_vertical = 0
	await _capture("event")
	adapter.dialogue.get_node("%CloseDialogue").pressed.emit()
	_check(not adapter.is_visible_in_tree(), _case + ": event closes from actual close button")

func _long_text_matrix() -> void:
	# Explicit presentation stress fixture, never an authored NPC line or game option.
	_open("relief")
	var before := runtime.capture_authoritative_state()
	var adapter: Control = scene.z2_event_adapter
	var dialogue: Control = adapter.dialogue
	var copy := "长中文适配验证：回收材料的名称、领取条件与实际费用必须完整显示，超出可见区域时可以继续滚动阅读。"
	dialogue.present_view({"room_id": "layout-fixture-" + _case, "phase_id": "long_text", "revision": 1,
		"lines": [{"speaker": "地下仓库夜班巡检与物资回收联络员（姓名适配测试）".repeat(2), "text": copy.repeat(7)}],
		"options": [{"option_id": "stress", "action_id": "layout-only", "label": "核对待回收物资与现场交付条件的长中文行动标题",
			"cost": "费用以当前正式报价与背包实际材料为准", "effect": copy.repeat(3), "enabled": true},
			{"option_id": "leave", "action_id": "layout-only-leave", "label": "暂时离开", "enabled": true}]})
	await _keyboard(KEY_SPACE)
	var body: RichTextLabel = dialogue.get_node("%DialogueText")
	_check(body.visible_characters == -1 and body.get_content_height() > body.size.y, _case + ": long Chinese dialogue has reachable scroll")
	await _wheel(body, true)
	_check(body.get_v_scroll_bar().value > 0, _case + ": actual wheel scrolls long Chinese dialogue")
	body.scroll_to_line(0)
	await _keyboard(KEY_SPACE)
	dialogue.get_node("%InputHint").text = "长提示适配验证：上下选择；回车确认；离开后可以再次查看当前进度。"
	dialogue._layout()
	await _settle()
	for path in ["%Nameplate", "%DialogueFrame", "%ChoicesFrame", "%CloseDialogue", "%InputHint"]:
		_inside(dialogue.get_node(path), "long text " + path)
	_label_fits(dialogue.get_node("%SpeakerName"), "long speaker")
	_label_fits(dialogue.get_node("%InputHint"), "long input hint")
	_check(not _rect(dialogue.get_node("%Nameplate")).intersects(_rect(dialogue.get_node("%ChoicesFrame"))), _case + ": long nameplate does not cover choices")
	var first: Button = dialogue._buttons[0]
	for label_name in ["OptionLabel", "OptionCost", "OptionEffect"]:
		var label := first.find_child(label_name, true, false) as Label
		_label_fits(label, "long " + label_name)
		_check(_rect(first).grow(1).encloses(_rect(label)), _case + ": long option text stays within button " + label_name)
	var scroll: ScrollContainer = dialogue.get_node("%OptionsScroll")
	_check(scroll.get_v_scroll_bar().visible and not scroll.get_h_scroll_bar().visible, _case + ": long choices use vertical scrolling only")
	await _capture("long-text-fixture")
	await _keyboard(KEY_DOWN)
	_check(dialogue._buttons[1].has_focus() and _rect(scroll).grow(dialogue.scale.x).encloses(_rect(dialogue._buttons[1])), _case + ": keyboard reaches last long-list option")
	await _keyboard(KEY_ESCAPE)
	_check(not adapter.is_visible_in_tree(), _case + ": keyboard leaves long dialogue")
	_check(runtime.capture_authoritative_state() == before, _case + ": presentation stress does not change game state")

func _notification_matrix() -> void:
	# The component receives the actual catalog text; this receipt is explicitly a UI fixture.
	var queue: Control = root.get_node("Z2PersistentOverlays/NotificationQueue")
	while not queue._current.is_empty(): await process_frame
	var definition: Dictionary = Catalog.task_definitions(_meta.get_summary())[1]
	var notice := {"goal_id": definition.id, "kind": "main", "tier": 1,
		"title": "熟悉现场后核对仓库和东侧通风井的巡查记录（长标题适配测试）", "body": definition.get("description", definition.get("condition", ""))}
	var receipt := {"ok": true, "committed": true, "receipt_id": "layout-fixture-" + _case}
	_check(scene.enqueue_z2_committed_notifications(receipt, [notice]) == 1, _case + ": notification enters persistent RunScene queue")
	await queue.notification_shown
	_inside(queue.get_node("%NotificationCard"), "notification")
	var card := _rect(queue.get_node("%NotificationCard"))
	_geometry["notification"] = _coordinates(card)
	_check(absf(card.get_center().x - root.get_visible_rect().get_center().x) < 1, _case + ": Steam notification centered above scene")
	for label_name in ["NotificationTitle", "NotificationBody"]:
		var label := queue.find_child(label_name, true, false) as Label
		_check(label.max_lines_visible == -1 and label.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING, _case + ": notification text is not truncated " + label_name)
		_label_fits(label, label_name)
		_check(card.encloses(_rect(label)), _case + ": notification text contained " + label_name)
	var kind := queue.find_child("NotificationKind", true, false) as Label
	_check(kind != null and kind.is_visible_in_tree() and kind.text == "任务完成", _case + ": actual main kind has source notification hierarchy")
	_check(queue.get_node("%NotificationTitle").get_theme_font_size("font_size") == roundi(22 * scene.get_ui_scale_factor()), _case + ": notification follows current UI font size")
	await _capture("notification-long-title-fixture")
	_check(scene.enqueue_z2_committed_notifications(receipt, [notice]) == 0, _case + ": repeated notice is deduplicated")
	await queue.notification_finished

func _camp_matrix() -> void:
	runtime.context.run_active = false
	scene._show_deploy_shell(&"loadout")
	var page: Control = scene.ui_shell.get_deploy_page()
	page.reduced_motion = true
	page.apply_snapshot({"meta_progress_summary": _meta.get_summary()})
	page.show_tab(&"loadout")
	await _settle()
	for card: Control in page.card_views:
		_check(not str(card.card_id).begins_with("opening_"), _case + ": camp loadout contains no spawn offers")
	await _capture("camp")
	var back := page.find_child("DeployNavMain", true, false) as Button
	_inside(back, "camp return")
	back.pressed.emit()
	await _settle()
	_check(not page.is_visible_in_tree(), _case + ": camp actual return")

func _goals_matrix() -> void:
	scene._show_long_term_shell(&"tasks")
	var page: Control = scene.ui_shell.get_long_term_page()
	page.reduced_motion = true
	var summary := _meta.get_summary()
	summary["achievement_states"] = {"A08": {"status": "claimable", "progress": 200, "target": 200, "claimable_tiers": [1, 2, 3], "claimed_tiers": []}}
	summary["achievement_definitions"] = Catalog.achievement_definitions(summary)
	page.apply_snapshot({"meta_progress_summary": summary})
	page.show_secondary(&"achievement")
	# Hover previews are intentional. Park the probe pointer away from the list
	# before scrolling a chosen record into view, so resize/hover cannot replace it.
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2.ZERO
	root.push_input(motion, true)
	await _settle()
	for index in page.current_content_cards.size():
		if str(page.current_content_cards[index].get("id", "")) == "A08":
			page.long_term_card_buttons[index].pressed.emit()
			break
	await _settle()
	_check(str(page.current_content_cards[page.selected_content_card_index].id) == "A08", _case + ": actual achievement selection remains A08")
	for tier in [1, 2, 3]:
		var button := page.find_child("ClaimGoalTier%d" % tier, true, false) as Button
		_inside(button, "claim tier%d" % tier)
		if button == null: continue
		_check(button.get_theme_font("font").get_string_size(button.text, HORIZONTAL_ALIGNMENT_LEFT, -1, button.get_theme_font_size("font_size")).x <= button.size.x - 16, _case + ": claim label fits tier%d" % tier)
	for label: Label in [page.content_record_title_label, page.content_record_body_label, page.content_record_facts_label]:
		_inside(label, str(label.name))
		_label_fits(label, str(label.name))
	_check(not _rect(page.content_record_facts_label).intersects(_rect(page.goal_tier_actions)), _case + ": tier actions do not overlap facts")
	await _capture("goals")
	for group in [&"achievement", &"task"]:
		page.show_secondary(group)
		var longest := 0
		for index in page.current_content_cards.size():
			if str(page.current_content_cards[index].get("title", "")).length() > str(page.current_content_cards[longest].get("title", "")).length(): longest = index
		page.long_term_card_buttons[longest].pressed.emit()
		await _settle()
		_label_fits(page.content_record_title_label, "longest actual " + str(group) + " title")
		_label_fits(page.content_record_body_label, "longest actual " + str(group) + " description")
		var last_card: Control = page.long_term_card_buttons.back()
		page.content_list_scroll.ensure_control_visible(last_card)
		await _settle()
		_check(_rect(page.content_list_scroll).grow(1).encloses(_rect(last_card)), _case + ": last " + str(group) + " record reachable")
	var back := page.find_child("LongTermNavMainButton", true, false) as Button
	_inside(back, "goals return")
	await _mouse_click(back)
	_check(not page.is_visible_in_tree(), _case + ": goals mouse return")

func _inventory_matrix() -> void:
	runtime.context.run_active = true
	scene._show_run_screen()
	_opening_fixture("dismantle")
	runtime.context.asset_ledger.create_item_instance(Items.definition("col_01"), &"inventory")
	scene._show_inventory_panel()
	scene._refresh_opening_inventory_controls()
	await _settle()
	var panel: Control = scene.inventory_panel
	_inside(panel, "inventory drawer")
	_inside(panel.close_button, "inventory close")
	_inside(panel.opening_item_choice, "opening exact item input")
	_check(panel.opening_item_choice.selected == 0, _case + ": dismantle requires explicit item choice")
	for button_name in ["DismantleOpening_scan", "DismantleOpening_trap", "UseOpening_scan", "UseOpening_trap"]:
		_inside(panel.find_child(button_name, true, false), button_name)
	await _capture("inventory")
	panel.close_button.pressed.emit()
	_check(not panel.is_visible_in_tree(), _case + ": inventory actual close")

func _scroll_regression() -> void:
	await _resize_window(SIZES[0])
	scene.set_ui_scale_factor(1.5)
	scene._show_run_screen()
	runtime.context.pressure = 0
	_open("relief")
	await _press("prepare")
	var adapter: Control = scene.z2_event_adapter
	_advance_to_choices(adapter.dialogue)
	await _settle()
	var scroll: ScrollContainer = adapter.dialogue.get_node("%OptionsScroll")
	scroll.scroll_vertical = 9999
	await _settle()
	var previous := scroll.scroll_vertical
	_check(previous > 0, "regression fixture has overflowing quote")
	var state := Service.get_event_state(runtime.context, runtime.context.current_pos)
	adapter.apply_event(state, scene._z2_event_presentation())
	_advance_to_choices(adapter.dialogue)
	await _settle()
	_check(scroll.scroll_vertical == previous, "same quote refresh retains scroll and selection")
	_open("relief", true)
	await _press("prepare")
	_advance_to_choices(adapter.dialogue)
	await _settle()
	_check(scroll.scroll_vertical == 0, "new quote resets to first option")
	_check(_rect(scroll).grow(1).encloses(_rect(adapter.dialogue._buttons[0])), "simple rest first option visible on new quote")
	scene._cancel_event_modal()

func _many_materials() -> void:
	_case = "1280x720-150-stress"
	for index in range(12):
		runtime.context.asset_ledger.create_item_instance(Items.definition("col_01" if index % 2 == 0 else "col_02"), &"inventory")
	_open("compress")
	await _press("prepare")
	var adapter: Control = scene.z2_event_adapter
	_advance_to_choices(adapter.dialogue)
	await _settle()
	var scroll: ScrollContainer = adapter.dialogue.get_node("%OptionsScroll")
	var boxes: Array[Node] = adapter._fields.find_children("Material_*", "CheckBox", false, false)
	_check(boxes.size() >= 12, "many real material candidates shown")
	for box: CheckBox in [boxes.front(), boxes.back()]:
		scroll.ensure_control_visible(box)
		await _settle()
		_inside(box, "scrolled material input")
		await _mouse_click(box)
	_check(adapter._selected_items.size() == 2, "real viewport mouse input selects two distinct candidates")
	var compress: Button
	for index in adapter._options.size():
		if str(adapter._options[index].id) == "compress": compress = adapter.dialogue._buttons[index]
	scroll.ensure_control_visible(compress)
	await _settle()
	_inside(compress, "many-input submit")
	await _capture("many-materials")
	await _mouse_click(compress)
	_check(Service.get_event_state(runtime.context, runtime.context.current_pos).completed, "actual Main mouse submit commits compression")
	scene._cancel_event_modal()

func _opening_cost_safearea() -> void:
	_check(DisplayServer.get_name() != "headless", "opening text safearea uses native rendered glyphs")
	if DisplayServer.get_name() == "headless": return
	await _resize_window(Vector2i(1280, 720))
	runtime.context.reset()
	runtime.checkpoint_writer = Callable()
	runtime.checkpoint_service = RunCheckpointService.new()
	runtime.checkpoint_service.configure(_meta, "z2", Rules.CONTENT_VERSION)
	var map_id := "classic_7x7_simple"
	var commission: Dictionary = M7ContentCatalog.commission_offer_candidates(map_id, int(_meta.data.run_count), 3)[0]
	var start: Dictionary = runtime.command_bus.dispatch(&"start_standard_run", {"run_start_config": {"map_config_id": map_id, "difficulty": "simple", "seed_value": 27, "selected_objective_id": commission.id}})
	_check(start.get("ok", false), "actual ordinary start for spawn panel: " + str(start.get("action_result", start)))
	if not start.get("ok", false): return
	scene._show_run_screen()
	var panel: Control = scene.z2_ui_controller.opening_panel
	var refresh := panel.find_child("OpeningRefresh", true, false) as Button
	var skip := panel.find_child("OpeningSkip", true, false) as Button
	for count in range(10):
		var price := (count + 1) * 5
		if count in [0, 9]:
			for scale_value in [1.0, 1.25, 1.5]:
				scene.set_ui_scale_factor(scale_value)
				await _settle()
				_case = "1280x720-%d-cost%d" % [roundi(scale_value * 100), price]
				_inside(refresh, "spawn refresh")
				_inside(skip, "spawn skip")
				_check(not refresh.disabled and refresh.text.contains(str(price)), _case + ": real affordable price")
				_check(refresh.get_theme_font_size("font_size") == roundi(16 * scale_value), _case + ": requested font size")
				var refresh_ink := await _action_safearea(refresh, "refresh")
				var skip_ink := await _action_safearea(skip, "skip")
				_check(not refresh_ink.intersects(skip_ink), _case + ": captions stay separate")
				await _capture("spawn-opening")
				_opening_action_cases.append({"case": _case, "fee": price, "scale": scale_value, "ink": _action_ink.duplicate(true)})
		var balance := int(_meta.data.gold)
		await _mouse_click(refresh)
		_check(int(_meta.data.gold) == balance - price, "pointer redraw charges exactly %d" % price)
	_check(refresh.disabled and not skip.disabled, "tenth redraw leaves final decision available")
	var offer: Dictionary = runtime.spawn_opening_offer()
	await _mouse_click(panel.find_child("OpeningChoice0", true, false))
	_check(runtime.context.run_start_config.opening_effect.get("id") == offer.candidates[0], "actual Main pointer chooses the displayed effect")


func _action_safearea(button: Button, tag: String) -> Rect2:
	var style := button.get_theme_stylebox("normal")
	var face := button.get_theme_font("font")
	var font_size := button.get_theme_font_size("font_size")
	var advance := face.get_string_size(button.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var padding := maxf(6, ceilf((advance - button.size.x) / 2.0) + 6)
	var local_rect := Rect2(Vector2(padding, padding), button.size)
	var views: Array[SubViewport] = []
	var ink_button: Button
	for ink_only in [false, true]:
		var viewport := SubViewport.new()
		viewport.size = Vector2i((button.size + Vector2.ONE * padding * 2).ceil())
		viewport.transparent_bg = true
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(viewport)
		if ink_only:
			ink_button = button.duplicate(0) as Button
			ink_button.clip_text = false
			ink_button.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
			ink_button.focus_mode = Control.FOCUS_NONE
			ink_button.mouse_filter = Control.MOUSE_FILTER_IGNORE
			ink_button.add_theme_font_override("font", face)
			var clear := StyleBoxEmpty.new()
			for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
				clear.set_content_margin(side, style.get_margin(side))
			for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
				ink_button.add_theme_stylebox_override(state, clear)
			for color_name in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_disabled_color", "font_outline_color"]:
				ink_button.add_theme_color_override(color_name, Color.WHITE)
			viewport.add_child(ink_button)
			ink_button.position = local_rect.position
			ink_button.size = button.size
		else:
			var probe := ActionInkProbe.new()
			probe.surface = style
			probe.button_rect = local_rect
			viewport.add_child(probe)
		views.append(viewport)
	await process_frame
	await RenderingServer.frame_post_draw
	_check(ink_button.size.is_equal_approx(button.size), _case + ": " + tag + " complete label fits the actual button without clipping")
	var background := views[0].get_texture().get_image()
	var glyphs := views[1].get_texture().get_image()
	var outside := 0
	for y in glyphs.get_height():
		for x in glyphs.get_width():
			if glyphs.get_pixel(x, y).a < 0.25: continue
			for offset in [Vector2i.LEFT * 2, Vector2i.RIGHT * 2, Vector2i.UP * 2, Vector2i.DOWN * 2]:
				var point: Vector2i = Vector2i(x, y) + offset
				if not Rect2i(Vector2i.ZERO, background.get_size()).has_point(point) or background.get_pixelv(point).a < 0.5:
					outside += 1
					break
	var used := Rect2(glyphs.get_used_rect())
	_check(used.has_area() and outside == 0, _case + ": " + tag + " rendered glyphs stay inside painted surface with2px padding")
	print("OPENING_ACTION_SAFEAREA ", _case, " ", tag, " text=", button.text, " font=", font_size, " button=", button.size,
		" glyph=", used, " painted=", background.get_used_rect(), " outside_pixels=", outside)
	_action_ink[tag] = {"text": button.text, "font_size": font_size, "button_size": [button.size.x, button.size.y],
		"glyph_rect": _coordinates(used), "painted_rect": _coordinates(Rect2(background.get_used_rect())), "outside_pixels": outside, "padding": 2}
	for viewport in views: viewport.free()
	return button.get_global_transform_with_canvas() * Rect2(used.position - local_rect.position, used.size)
