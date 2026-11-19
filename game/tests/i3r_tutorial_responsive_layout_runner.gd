extends SceneTree

const TutorialPopupScene := preload("res://scenes/ui/tutorial/tutorial_popup_panel.tscn")
const TutorialServiceScript := preload("res://scripts/core/run/tutorial_service.gd")
const RunContextScript := preload("res://scripts/core/run/run_context.gd")
const RunSurfaceScript := preload("res://scripts/ui/run_surface/run_surface.gd")
const RunSurfaceModelScript := preload("res://scripts/ui/run_surface/run_surface_model.gd")
const UILayoutProfileScript := preload("res://scripts/ui/shell/ui_layout_profile.gd")
const UILayerContractScript := preload("res://scripts/ui/shell/ui_layer_contract.gd")
const Art10UISkinKitScript := preload("res://scripts/presentation/art10_ui_skin_kit.gd")

const PASS_MARKER := "I3R_TUTORIAL_RESPONSIVE_LAYOUT=PASS"
const FAIL_MARKER := "I3R_TUTORIAL_RESPONSIVE_LAYOUT=FAIL"
const PHYSICAL_SIZES := [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(960, 720), Vector2i(1600, 1000)]
const UI_SCALES := [1.0, 1.25, 1.5]
# Source frame ink is 12px; 36px NinePatch sampling protects corner ornaments.
# I2_ASSET_BINDING separately locks source/hash, ornaments and copy-safe rects.
const PROTOCOL_VISIBLE_BORDER_THICKNESS := 12.0

class WorldPointerProbe extends Node:
	var clicks := 0
	func _unhandled_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			clicks += 1

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	root.content_scale_factor = 1.0
	for physical_size in PHYSICAL_SIZES:
		root.size = physical_size
		await _frames(2)
		for ui_scale in UI_SCALES:
			await _check_case(physical_size, ui_scale)
	_finish()


func _check_case(physical_size: Vector2i, ui_scale: float) -> void:
	_check(is_equal_approx(root.content_scale_factor, 1.0), "canvas_scale_mutated")
	Art10UISkinKitScript.set_runtime_ui_scale_factor(ui_scale)
	var viewport_size := root.get_visible_rect().size
	var profile := UILayoutProfileScript.profile_for_size(viewport_size)
	profile["actual_viewport_size"] = Vector2i(int(round(viewport_size.x)), int(round(viewport_size.y)))
	profile["ui_scale_factor"] = ui_scale
	var viewport_rect := Rect2(Vector2.ZERO, viewport_size)

	var canvas := Control.new()
	canvas.name = "TutorialResponsiveCanvas_%dx%d_%d" % [
		physical_size.x,
		physical_size.y,
		int(round(ui_scale * 100.0)),
	]
	canvas.size = viewport_size
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(canvas)
	var world_pointer := WorldPointerProbe.new()
	canvas.add_child(world_pointer)

	var surface := RunSurfaceScript.new() as RunSurface
	canvas.add_child(surface)
	surface.build()
	surface.set_ui_scale_factor(ui_scale)
	surface.apply_layout_profile(profile)
	surface.apply_surface_model(_surface_model(profile))

	var external_focus := Control.new()
	external_focus.name = "ExternalGuidanceFocusSentinel"
	external_focus.size = Vector2.ONE
	external_focus.focus_mode = Control.FOCUS_ALL
	external_focus.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(external_focus)
	external_focus.grab_focus()
	_check(root.gui_get_focus_owner() == external_focus, _case_error(physical_size, ui_scale, "external_focus_fixture_missing"))
	var popup := TutorialPopupScene.instantiate() as TutorialPopupPanel
	surface.get_overlay_slot().add_child(popup)
	popup.set_ui_scale_factor(ui_scale)
	popup.apply_layout_profile(profile)
	popup.apply_popup(_spawn_popup())
	await _frames(4)
	_check(root.gui_get_focus_owner() == external_focus, _case_error(physical_size, ui_scale, "spawn_application_stole_external_focus"))

	var snapshot := popup.layout_snapshot()
	var geometry := snapshot.get("geometry", {}) as Dictionary
	var panel_rect: Rect2 = snapshot.get("panel_rect", Rect2())
	var message_rect: Rect2 = snapshot.get("message_rect", Rect2())
	var button_rect: Rect2 = snapshot.get("button_rect", Rect2())
	var left_hud_rect: Rect2 = geometry.get("left_hud_rect", Rect2())
	var room_stage_rect: Rect2 = geometry.get("room_stage_rect", Rect2())
	var footer_rect: Rect2 = geometry.get("footer_rect", Rect2())
	var right_status_rect: Rect2 = geometry.get("right_status_rect", Rect2())
	var panel := popup.get_node_or_null("Panel") as Panel
	var title := popup.get_node_or_null("Panel/Content/Title") as Label
	var message := popup.get_node_or_null("Panel/Content/Message") as RichTextLabel
	var button := popup.get_node_or_null("Panel/Content/ConfirmButton") as Button

	_check(viewport_rect.encloses(panel_rect), _case_error(physical_size, ui_scale, "panel_outside_viewport:%s" % panel_rect))
	_check(not panel_rect.intersects(left_hud_rect), _case_error(physical_size, ui_scale, "panel_overlaps_left_hud"))
	_check(not panel_rect.intersects(room_stage_rect), _case_error(physical_size, ui_scale, "panel_overlaps_room_stage"))
	_check(not panel_rect.intersects(footer_rect), _case_error(physical_size, ui_scale, "panel_overlaps_footer"))
	_check(not panel_rect.intersects(right_status_rect), _case_error(physical_size, ui_scale, "panel_overlaps_protocol"))
	_check(room_stage_rect.size.x >= 320.0 and room_stage_rect.size.y >= 320.0, _case_error(physical_size, ui_scale, "room_stage_too_small:%s" % room_stage_rect))
	_check(panel_rect.encloses(message_rect), _case_error(physical_size, ui_scale, "message_escapes_panel:%s" % message_rect))
	_check(panel_rect.encloses(button_rect), _case_error(physical_size, ui_scale, "button_escapes_panel:%s" % button_rect))
	_check(message != null and message.scroll_active, _case_error(physical_size, ui_scale, "message_not_scrollable"))
	_check(message != null and message.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART, _case_error(physical_size, ui_scale, "message_not_wrapped"))
	if message != null:
		_check(message.text == str(_spawn_popup().get("message", "")).get_slice("\n", 0), _case_error(physical_size, ui_scale, "collapsed_spawn_summary_changed"))
		_check(message.get_theme_font_size("normal_font_size") >= Art10UISkinKitScript.scaled_font_size(Art10UISkinKitScript.font_size(&"body"), ui_scale), _case_error(physical_size, ui_scale, "tutorial_body_font_reduced"))
		await _wheel_to_end(message, message.get_v_scroll_bar(), _case_error(physical_size, ui_scale, "tutorial_body"))
		_check(message.get_content_height() - message.get_v_scroll_bar().value <= message.size.y + 1.0, _case_error(physical_size, ui_scale, "tutorial_last_line_not_visible"))
		_mouse_button(message.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
		_check(world_pointer.clicks == 0, _case_error(physical_size, ui_scale, "tutorial_click_reached_world"))
	if message != null and message.get_content_height() > message.size.y + 0.5:
		_check(message.scroll_active, _case_error(physical_size, ui_scale, "overflow_without_scroll"))
	_check(title != null and title.get_line_count() == 1, _case_error(physical_size, ui_scale, "tutorial_title_wrapped"))
	_check(
		title != null and title.get_combined_minimum_size().x <= title.size.x + 0.5,
		_case_error(physical_size, ui_scale, "tutorial_title_clipped")
	)
	_check(panel != null and panel.get_theme_stylebox(&"panel") is StyleBoxTexture, _case_error(physical_size, ui_scale, "tutorial_frame_not_textured"))
	_check(button != null and button.text.find(" / ") < 0, _case_error(physical_size, ui_scale, "button_uses_full_binding_list"))
	_check(button != null and button.text == "查看教学说明" and button.tooltip_text.contains("展开完整说明"), _case_error(physical_size, ui_scale, "guidance_details_affordance_missing"))
	_check(
		button != null and button.get_combined_minimum_size().x <= button.size.x + 0.5,
		_case_error(physical_size, ui_scale, "button_text_visually_truncated")
	)

	await _check_guidance_layout(popup, _spawn_popup(), viewport_rect, physical_size, ui_scale, "spawn_collapsed", false)
	if button != null:
		_mouse_button(button.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
	await _frames(3)
	await _check_guidance_layout(popup, _spawn_popup(), viewport_rect, physical_size, ui_scale, "spawn_expanded", true)

	var risk_rect := surface.mine_risk_tag_art.get_global_rect()
	var key_rect := surface.bottom_overlay_art.get_global_rect()
	_check(surface.mine_risk_label.text == "周围雷险：3", _case_error(physical_size, ui_scale, "mine_risk_count_missing"))
	_check(not surface.command_feedback_art.visible, _case_error(physical_size, ui_scale, "steady_feedback_frame_visible"))
	_check(not surface.command_feedback_label.visible, _case_error(physical_size, ui_scale, "steady_feedback_copy_visible"))
	_check(not surface.action_hint_label.visible, _case_error(physical_size, ui_scale, "steady_action_hint_visible"))
	_check(not panel_rect.intersects(risk_rect), _case_error(physical_size, ui_scale, "tutorial_overlaps_mine_risk"))
	_check(not panel_rect.intersects(key_rect), _case_error(physical_size, ui_scale, "tutorial_overlaps_hotbar"))
	# The retired frame is hidden; the visible copy belongs to its real scroll viewport.
	_check(surface.command_feedback_scroll.is_ancestor_of(surface.command_feedback_label), _case_error(physical_size, ui_scale, "feedback_copy_outside_scroll_owner"))
	_check(key_rect.encloses(surface.action_bar.get_global_rect()), _case_error(physical_size, ui_scale, "action_bar_escapes_frame"))
	_check(surface.scanner_title_label.visible and surface.scanner_title_label.text == "区域扫描图", _case_error(physical_size, ui_scale, "scanner_title_missing"))
	_check(
		surface.scanner_title_label.get_combined_minimum_size().y <= surface.scanner_title_label.size.y + 0.5,
		_case_error(
			physical_size,
			ui_scale,
			"scanner_title_clipped:min=%s rect=%s"
			% [surface.scanner_title_label.get_combined_minimum_size(), surface.scanner_title_label.get_global_rect()]
		)
	)
	_check(surface.right_title_label.visible and surface.right_title_label.text == "协议 5", _case_error(physical_size, ui_scale, "protocol_title_missing"))
	_check(
		surface.right_title_label.get_combined_minimum_size().y <= surface.right_title_label.size.y + 0.5,
		_case_error(
			physical_size,
			ui_scale,
			"protocol_title_clipped:min=%s rect=%s"
			% [surface.right_title_label.get_combined_minimum_size(), surface.right_title_label.get_global_rect()]
		)
	)
	var status_art_rect := surface.status_card_art.get_global_rect()
	var protocol_title_rect := surface.right_title_label.get_global_rect()
	var protocol_body_rect := surface.right_body_label.get_global_rect()
	_check(
		protocol_title_rect.end.y + 1.0 <= protocol_body_rect.position.y,
		_case_error(physical_size, ui_scale, "protocol_title_overlaps_body")
	)
	var protocol_left_safe := maxf(
		PROTOCOL_VISIBLE_BORDER_THICKNESS,
		status_art_rect.size.x * 0.18
	)
	var protocol_top_safe := PROTOCOL_VISIBLE_BORDER_THICKNESS
	_check(
		protocol_title_rect.position.x >= status_art_rect.position.x + protocol_left_safe - 0.5
		and protocol_title_rect.position.y >= status_art_rect.position.y + protocol_top_safe - 0.5,
		_case_error(
			physical_size,
			ui_scale,
			"protocol_title_enters_art_border:frame=%s title=%s"
			% [status_art_rect, protocol_title_rect]
		)
	)
	for action_button_variant in surface.action_buttons.values():
		var action_button := action_button_variant as Button
		_check(
			action_button != null and surface.action_bar.get_global_rect().encloses(action_button.get_global_rect()),
			_case_error(physical_size, ui_scale, "action_button_escapes_hotbar")
		)
	for popup_id: StringName in [&"exit_goal", &"number_rule"]:
		var source := _tutorial_popup(popup_id)
		var focus_before_application := root.gui_get_focus_owner()
		popup.apply_popup(source)
		await _frames(3)
		_check(root.gui_get_focus_owner() == focus_before_application, _case_error(physical_size, ui_scale, "lesson_application_changed_focus:%s" % popup_id))
		await _check_guidance_layout(popup, source, viewport_rect, physical_size, ui_scale, "%s_collapsed" % popup_id, false)
		var details := popup.get_node_or_null("Panel/Content/ConfirmButton") as Button
		_check(details != null and details.visible and details.text == "查看教学说明" and details.focus_mode == Control.FOCUS_NONE, _case_error(physical_size, ui_scale, "pointer_only_details_missing:%s" % popup_id))
		if details != null:
			_mouse_button(details.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
		await _frames(3)
		await _check_guidance_layout(popup, source, viewport_rect, physical_size, ui_scale, "%s_expanded" % popup_id, true)
		if details != null:
			_mouse_button(details.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
		await _frames(3)
		await _check_guidance_layout(popup, source, viewport_rect, physical_size, ui_scale, "%s_collapsed_again" % popup_id, false)
	popup.apply_popup({})
	await _frames(2)
	await _check_fee_and_confirmation(popup, world_pointer, external_focus, viewport_rect, physical_size, ui_scale)
	await _check_feedback_scroll(surface, world_pointer, viewport_rect, physical_size, ui_scale)

	print(
		"I3R_TUTORIAL_RESPONSIVE_CASE physical=%dx%d logical=%dx%d ui=%d panel=%s room=%s footer=%s message_content=%s"
		% [
			physical_size.x,
			physical_size.y,
			int(round(viewport_size.x)),
			int(round(viewport_size.y)),
			int(round(ui_scale * 100.0)),
			panel_rect,
			room_stage_rect,
			footer_rect,
			snapshot.get("message_content_height", 0.0),
		]
	)
	canvas.queue_free()
	await _frames(3)


func _check_guidance_layout(popup: TutorialPopupPanel, source: Dictionary, viewport: Rect2, physical: Vector2i, scale: float, state: String, expanded: bool) -> void:
	var case_id := _case_error(physical, scale, state)
	var focus_before := root.gui_get_focus_owner()
	var snapshot := popup.layout_snapshot()
	var geometry: Dictionary = snapshot.get("geometry", {})
	var panel_rect: Rect2 = snapshot.get("panel_rect", Rect2())
	var title := popup.get_node_or_null("Panel/Content/Title") as Label
	var message := popup.get_node_or_null("Panel/Content/Message") as RichTextLabel
	_check(popup.is_visible_in_tree() and not bool(snapshot.get("blocking", true)) and popup.mouse_filter == Control.MOUSE_FILTER_IGNORE, case_id + ":guidance_acquired_modality")
	_check(bool(snapshot.get("guidance_expanded", not expanded)) == expanded, case_id + ":wrong_expansion_state")
	_check(viewport.encloses(panel_rect), case_id + ":panel_outside_viewport")
	for zone in ["left_hud_rect", "room_stage_rect", "footer_rect", "right_status_rect"]:
		_check(not panel_rect.intersects(geometry.get(zone, Rect2()) as Rect2), case_id + ":panel_overlaps_" + zone)
	var expected_body_size := Art10UISkinKitScript.scaled_font_size(Art10UISkinKitScript.font_size(&"body"), scale)
	_check(title != null and title.text == str(source.get("title", "")) and panel_rect.encloses(title.get_global_rect()), case_id + ":title_changed_or_escaped")
	if title != null:
		_check(title.get_line_count() == 1 and title.get_combined_minimum_size().x <= title.size.x + 0.5 and title.get_combined_minimum_size().y <= title.size.y + 0.5, case_id + ":title_wrapped_or_clipped")
		_check(title.get_theme_font_size("font_size") >= Art10UISkinKitScript.scaled_font_size(Art10UISkinKitScript.font_size(&"section_title"), scale), case_id + ":title_font_reduced")
	_check(message != null, case_id + ":message_missing")
	if message != null:
		var full_text := str(source.get("message", ""))
		var expected_text := full_text
		if not expanded:
			expected_text = full_text.get_slice("\n", 0)
			if expected_text.length() > 48:
				expected_text = expected_text.left(48) + "…"
		_check(str(popup.popup.get("message", "")) == full_text and message.text == expected_text, case_id + ":source_text_lost")
		_check(panel_rect.encloses(message.get_global_rect()) and message.scroll_active and message.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART, case_id + ":message_escaped_or_not_scrollable")
		_check(message.get_theme_font_size("normal_font_size") >= expected_body_size, case_id + ":body_font_reduced")
		var body_font := message.get_theme_font("normal_font")
		_check(body_font != null and message.size.y >= body_font.get_height(message.get_theme_font_size("normal_font_size")), case_id + ":message_cannot_show_one_full_line")
		if expanded:
			await _wheel_to_end(message, message.get_v_scroll_bar(), case_id)
			_check(message.get_content_height() - message.get_v_scroll_bar().value <= message.size.y + 1.0, case_id + ":full_text_last_line_inaccessible")
	var actions: Array[Button] = []
	for action_name in ["ConfirmButton", "LearnFlagButton"]:
		var action := popup.get_node_or_null("Panel/Content/" + action_name) as Button
		if action == null or not action.is_visible_in_tree():
			continue
		actions.append(action)
		var action_rect := action.get_global_rect()
		_check(viewport.encloses(action_rect) and panel_rect.encloses(action_rect), case_id + ":action_escaped_" + action_name)
		var expected_focus_mode := Control.FOCUS_ALL if action_name == "LearnFlagButton" else Control.FOCUS_NONE
		_check(action.focus_mode == expected_focus_mode and action.mouse_filter == Control.MOUSE_FILTER_STOP, case_id + ":guidance_action_focus_or_pointer_" + action_name)
		_check(action.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING and action.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART and action.get_combined_minimum_size().x <= action.size.x + 0.5 and action.get_combined_minimum_size().y <= action.size.y + 0.5, case_id + ":action_text_clipped_" + action_name)
		_check(action.get_theme_font_size("font_size") >= expected_body_size, case_id + ":action_font_reduced_" + action_name)
		_check(title == null or not action_rect.intersects(title.get_global_rect()), case_id + ":action_overlaps_title_" + action_name)
		_check(message == null or not action_rect.intersects(message.get_global_rect()), case_id + ":action_overlaps_message_" + action_name)
	for index in range(actions.size()):
		for other_index in range(index + 1, actions.size()):
			_check(not actions[index].get_global_rect().intersects(actions[other_index].get_global_rect()), case_id + ":guidance_actions_overlap")
	# A prior manual focus on the independent learning action is legitimate.
	_check(root.gui_get_focus_owner() == focus_before, case_id + ":guidance_measurement_or_scrolling_changed_focus")


func _check_fee_and_confirmation(popup: TutorialPopupPanel, world_pointer: WorldPointerProbe, external_focus: Control, viewport: Rect2, physical: Vector2i, scale: float) -> void:
	# Actual Z2 copy and dynamic training state, without a Main profile or payment.
	var context := RunContextScript.new()
	context.mode = &"tutorial"
	context.profile_fields = {"ruleset_id": "z2", "z2_progression_version": 1, "flag_unlocked": false}
	context.tutorial_triggers = {"0,0": &"spawn_intro"}
	TutorialServiceScript.trigger_for(context, Vector2i.ZERO)
	var source := context.tutorial_popup.duplicate(true)
	var training := {"run_id": "responsive-training", "position": Vector2i.ZERO, "mode": &"tutorial", "run_active": true, "phase": &"running", "profile_fields": context.profile_fields.duplicate(true), "tutorial_popup": source.duplicate(true)}
	var signals_seen := {"confirmed": 0, "cancelled": 0, "learned": 0, "dismissed": []}
	var on_confirm := func() -> void: signals_seen.confirmed += 1
	var on_cancel := func() -> void: signals_seen.cancelled += 1
	var on_learn := func() -> void: signals_seen.learned += 1
	var on_dismiss := func(id: StringName) -> void: signals_seen.dismissed.append(id)
	popup.confirmed.connect(on_confirm)
	popup.cancelled.connect(on_cancel)
	popup.learn_flag_requested.connect(on_learn)
	popup.guidance_dismissed.connect(on_dismiss)
	external_focus.grab_focus()
	popup.apply_training_state(training)
	popup.apply_popup(source)
	await _frames(3)
	var message := popup.get_node("Panel/Content/Message") as RichTextLabel
	var primary := popup.get_node("Panel/Content/ConfirmButton") as Button
	var learn := popup.get_node_or_null("Panel/Content/LearnFlagButton") as Button
	var case_id := _case_error(physical, scale, "z2_fee")
	_check(learn != null and learn.is_visible_in_tree() and not learn.disabled and learn.text == "100点 · 学习插旗" and learn.tooltip_text.contains("花费100点"), case_id + ":explicit_fee_action_missing")
	_check(primary.text == "查看教学说明" and not primary.text.contains("100点"), case_id + ":reading_still_looks_like_a_purchase")
	_check(root.gui_get_focus_owner() == external_focus, case_id + ":learning_presentation_automatically_grabbed_focus")
	if learn != null:
		# The unrelated sentinel supplies a deterministic native Tab predecessor;
		# only the business action, never the details toggle, is keyboard-focusable.
		external_focus.focus_next = external_focus.get_path_to(learn)
		for pressed in [true, false]:
			var tab := InputEventKey.new()
			tab.keycode = KEY_TAB
			tab.physical_keycode = KEY_TAB
			tab.pressed = pressed
			root.push_input(tab, true)
			await process_frame
		_check(root.gui_get_focus_owner() == learn and signals_seen.learned == 0 and signals_seen.confirmed == 0 and signals_seen.dismissed.is_empty(), case_id + ":manual_tab_did_not_reach_learning_without_action")
		popup.apply_training_state(training)
		popup.apply_popup(source)
		await _frames(3)
		_check(root.gui_get_focus_owner() == learn, case_id + ":guidance_refresh_displaced_manual_learning_focus")
		external_focus.grab_focus()
	await _check_guidance_layout(popup, source, viewport, physical, scale, "z2_fee_collapsed", false)
	var before := world_pointer.clicks
	_mouse_button(primary.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
	await _frames(3)
	await _check_guidance_layout(popup, source, viewport, physical, scale, "z2_fee_expanded", true)
	_check(message.text == str(source.message) and message.text.contains("100点"), case_id + ":fee_or_full_copy_missing")
	_check(signals_seen.confirmed == 0 and signals_seen.learned == 0 and signals_seen.dismissed.is_empty() and world_pointer.clicks == before, case_id + ":expanding_guidance_confirmed_bought_or_leaked")
	_mouse_button(primary.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
	await _frames(3)
	await _check_guidance_layout(popup, source, viewport, physical, scale, "z2_fee_collapsed_again", false)
	_check(signals_seen.confirmed == 0 and signals_seen.learned == 0 and signals_seen.dismissed == [&"spawn_intro"] and world_pointer.clicks == before, case_id + ":guidance_collapse_did_not_use_only_dismissal")
	if learn != null:
		_mouse_button(learn.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
	await _frames(2)
	_check(signals_seen.learned == 1 and signals_seen.confirmed == 0 and signals_seen.cancelled == 0 and signals_seen.dismissed == [&"spawn_intro"] and world_pointer.clicks == before, case_id + ":learning_request_not_isolated_or_leaked")
	_check(context.tutorial_popup == source and not bool(context.profile_fields.get("flag_unlocked", true)), case_id + ":component_mutated_authoritative_state")
	var manual_learning_focus := root.gui_get_focus_owner()
	_check(learn != null and manual_learning_focus == learn, case_id + ":explicit_learning_click_did_not_receive_keyboard_focus")

	# Learning remains available with no active lesson after changing rooms.
	var later_room := training.duplicate(true)
	later_room["position"] = Vector2i(0, 1)
	later_room["tutorial_popup"] = {}
	popup.apply_training_state(later_room)
	popup.apply_popup({})
	await _frames(3)
	var objective := {"title": "教学目标", "message": "学习插旗后，前往撤离信标完成训练。"}
	_check(root.gui_get_focus_owner() == manual_learning_focus, case_id + ":objective_refresh_displaced_manual_learning_focus")
	await _check_guidance_layout(popup, objective, viewport, physical, scale, "z2_objective_learn", false)
	_check(learn != null and learn.is_visible_in_tree() and not learn.disabled and not primary.is_visible_in_tree(), case_id + ":no_lesson_objective_lost_learning_action")
	external_focus.grab_focus()
	later_room["phase"] = &"confirm_extract"
	popup.apply_training_state(later_room)
	popup.apply_popup({})
	await _frames(2)
	_check(learn != null and learn.is_visible_in_tree() and learn.disabled, case_id + ":learning_enabled_outside_running_phase")
	_check(root.gui_get_focus_owner() == external_focus, case_id + ":disabled_learning_stole_external_focus")
	var learned_state := later_room.duplicate(true)
	learned_state["phase"] = &"running"
	learned_state["profile_fields"]["flag_unlocked"] = true
	popup.apply_training_state(learned_state)
	popup.apply_popup({})
	await _frames(3)
	await _check_guidance_layout(popup, {"title": "教学目标", "message": "前往撤离信标完成训练。"}, viewport, physical, scale, "z2_objective_learned", false)
	_check(learn != null and not learn.is_visible_in_tree() and not primary.is_visible_in_tree(), case_id + ":learned_state_kept_purchase_or_details_action")
	_check(root.gui_get_focus_owner() == external_focus, case_id + ":learned_objective_stole_external_focus")

	var risk := {"id": &"flag_entry_confirm", "title": "进入插旗房间？", "message": "此房间已插旗，进入前请再次确认。", "blocking": true, "confirm_text": "确认进入", "confirm_action": &"ui_accept", "confirm_action_hint": _spawn_popup().get("confirm_action_hint", {})}
	var risk_state := training.duplicate(true)
	risk_state["tutorial_popup"] = risk.duplicate(true)
	popup.apply_training_state(risk_state)
	popup.apply_popup(risk)
	await _frames(3)
	var cancel := popup.get_node("Panel/Content/CancelButton") as Button
	var panel := popup.get_node("Panel") as Panel
	var risk_snapshot := popup.layout_snapshot()
	var risk_geometry: Dictionary = risk_snapshot.get("geometry", {})
	_check(root.gui_get_focus_owner() == cancel, case_id + ":risk_default_focus_not_cancel")
	_check(bool(risk_snapshot.get("blocking", false)) and popup.mouse_filter == Control.MOUSE_FILTER_STOP and learn != null and not learn.is_visible_in_tree(), case_id + ":risk_decision_lost_modality_or_showed_learning")
	_check(viewport.encloses(panel.get_global_rect()) and panel.get_global_rect().encloses(message.get_global_rect()), case_id + ":risk_panel_or_message_escaped")
	for zone in ["left_hud_rect", "room_stage_rect", "footer_rect", "right_status_rect"]:
		_check(not panel.get_global_rect().intersects(risk_geometry.get(zone, Rect2()) as Rect2), case_id + ":risk_panel_overlaps_" + zone)
	for action: Button in [primary, cancel]:
		_check(action.is_visible_in_tree() and viewport.encloses(action.get_global_rect()) and panel.get_global_rect().encloses(action.get_global_rect()), case_id + ":confirmation_action_outside_panel")
		_check(action.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING and action.get_combined_minimum_size().y <= action.size.y + 0.5 and action.get_combined_minimum_size().x <= action.size.x + 0.5, case_id + ":confirmation_action_text_clipped")
		_check(action.get_theme_font_size("font_size") >= Art10UISkinKitScript.scaled_font_size(Art10UISkinKitScript.font_size(&"body"), scale), case_id + ":confirmation_action_font_reduced")
		_check(not action.get_global_rect().intersects(message.get_global_rect()), case_id + ":risk_action_overlaps_message")
	_check(primary.text.find(" / ") < 0 and primary.tooltip_text.find(" / ") >= 0, case_id + ":risk_semantic_hint_not_compact_with_full_tooltip")
	_check(not primary.get_global_rect().intersects(cancel.get_global_rect()), case_id + ":confirm_cancel_overlap")
	_mouse_button(cancel.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
	_check(signals_seen.cancelled == 1 and signals_seen.confirmed == 0 and signals_seen.learned == 1, case_id + ":native_cancel_not_isolated")
	_mouse_button(primary.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
	_check(signals_seen.confirmed == 1 and signals_seen.cancelled == 1 and signals_seen.learned == 1 and signals_seen.dismissed == [&"spawn_intro"] and world_pointer.clicks == before, case_id + ":native_confirmation_not_isolated")
	popup.confirmed.disconnect(on_confirm)
	popup.cancelled.disconnect(on_cancel)
	popup.learn_flag_requested.disconnect(on_learn)
	popup.guidance_dismissed.disconnect(on_dismiss)
	popup.apply_training_state({})
	popup.apply_popup({})
	await _frames(2)


func _check_feedback_scroll(surface: RunSurface, world_pointer: WorldPointerProbe, viewport: Rect2, physical: Vector2i, scale: float) -> void:
	var scroll := surface.command_feedback_scroll
	var label := surface.command_feedback_label
	for copy in ["背包容量不足，请先整理物资。", "背包容量不足，请先整理物资。\n".repeat(18) + "最后一行：整理后才能继续拾取。"]:
		surface.show_command_feedback({"ok": false, "accepted": false, "message": copy})
		await _frames(3)
		var case_id := _case_error(physical, scale, "feedback_long" if copy.contains("\n") else "feedback_short")
		var visible_rect := scroll.get_global_rect()
		_check(label.text == copy, case_id + ":source_text_changed")
		_check(label.visible and scroll.visible and not surface.command_feedback_art.visible, case_id + ":visible_scroll_contract")
		_check(label.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING and label.max_lines_visible == -1 and label.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART and not label.clip_text, case_id + ":copy_trimmed_or_unwrapped")
		_check(label.get_theme_font_size("font_size") >= Art10UISkinKitScript.scaled_font_size(13, scale), case_id + ":font_reduced")
		_check(viewport.encloses(visible_rect), case_id + ":viewport_outside_screen")
		_check(not visible_rect.intersects(surface.mine_risk_tag_art.get_global_rect()) and not visible_rect.intersects(surface.action_bar.get_global_rect()), case_id + ":viewport_overlaps_risk_or_actions")
		_check(label.get_global_rect().position.x >= visible_rect.position.x - 1.0 and label.get_global_rect().end.x <= visible_rect.end.x + 1.0, case_id + ":copy_exceeds_content_width")
		var bar := scroll.get_v_scroll_bar()
		_check((bar.max_value - bar.page > 1.0) == copy.contains("\n"), case_id + ":expected_real_overflow_branch_missing")
		await _wheel_to_end(scroll, bar, case_id)
		var tail := label.get_global_rect()
		tail.position.y = tail.end.y - label.get_line_height()
		tail.size.y = label.get_line_height()
		_check(visible_rect.grow(1.0).encloses(tail), case_id + ":last_full_line_not_visible")
		for action: Button in surface.action_buttons.values():
			_check(viewport.encloses(action.get_global_rect()), case_id + ":action_left_screen_while_scrolling")
		var clicks_before := world_pointer.clicks
		_mouse_button(visible_rect.get_center(), MOUSE_BUTTON_LEFT)
		_check(world_pointer.clicks == clicks_before, case_id + ":visible_feedback_click_reached_world")
		surface.clear_command_feedback()
		_check(not label.visible and not scroll.visible, case_id + ":empty_feedback_layer_remains_visible")
		_mouse_button(visible_rect.get_center(), MOUSE_BUTTON_LEFT)
		_check(world_pointer.clicks == clicks_before + 1, case_id + ":hidden_feedback_layer_blocks_world")
	surface.show_command_feedback({"ok": true, "accepted": true, "message": "已拾取物资。"})
	_check(not label.visible and not scroll.visible and not surface.command_feedback_art.visible, _case_error(physical, scale, "successful_feedback_became_permanent"))


func _wheel_to_end(control: Control, bar: VScrollBar, case_id: String) -> void:
	var end := maxf(0.0, bar.max_value - bar.page)
	if end <= 1.0:
		_check(not bar.is_visible_in_tree() and bar.value <= 1.0, case_id + ":unnecessary_actual_scroll_range")
		return
	var start := bar.value
	var deadline := Time.get_ticks_msec() + 3000
	while bar.value < bar.max_value - bar.page - 1.0 and Time.get_ticks_msec() < deadline:
		_mouse_button(control.get_global_rect().get_center(), MOUSE_BUTTON_WHEEL_DOWN)
		await process_frame
	_check(bar.value > start and bar.value >= bar.max_value - bar.page - 1.0, case_id + ":native_wheel_did_not_reach_end")


func _mouse_button(position: Vector2, button_index: MouseButton) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	root.push_input(motion, true)
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = button_index
	event.pressed = true
	root.push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event, true)


func _spawn_popup() -> Dictionary:
	return _tutorial_popup(&"spawn_intro")


func _tutorial_popup(popup_id: StringName) -> Dictionary:
	var context := RunContextScript.new()
	context.mode = &"tutorial"
	context.tutorial_triggers = {"0,0": popup_id}
	TutorialServiceScript.trigger_for(context, Vector2i.ZERO)
	return context.tutorial_popup.duplicate(true)


func _surface_model(profile: Dictionary) -> Dictionary:
	var model := RunSurfaceModelScript.build({
		"position": Vector2i(0, 0),
		"current_room": &"Normal",
		"protocol_level": 5,
		"pressure": 0,
		"adjacent_mines": 3,
		"inventory_items": [],
		"backpack_used": 0,
		"backpack_capacity": 10,
		"hp": 100,
		"max_hp": 100,
		"power": 5,
		"black_coin": 0,
		"gold_coin": 0,
		"run_active": true,
		"search_state_data": {"can_search": false, "searched": false},
		"run_map_snapshot": {"KnownMap": {"width": 5, "height": 5, "public_cells": []}},
	}, null, profile, {})
	model["command_feedback"] = "已进入普通房间。"
	model["action_hint"] = "靠近可交互目标后再行动。"
	return model


func _case_error(physical_size: Vector2i, ui_scale: float, detail: String) -> String:
	return "%dx%d@%d:%s" % [
		physical_size.x,
		physical_size.y,
		int(round(ui_scale * 100.0)),
		detail,
	]


func _frames(count: int) -> void:
	for _index in range(count):
		await process_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	Art10UISkinKitScript.set_runtime_ui_scale_factor(1.0)
	if failures.is_empty():
		print(
			"%s cases=1280x720,1920x1080,960x720,1600x1000@100,125,150 route=component_projection safe_zones=left_hud,room,protocol,footer text=collapsed+expanded_full_native_scroll teaching=dynamic_learn_button,guidance_signal risk=confirm+cancel footer=mine_risk,hotbar_compact feedback=transient+input_boundary"
			% PASS_MARKER
		)
		quit(0)
		return
	for failure in failures:
		push_error("I3R tutorial responsive layout failure: " + failure)
	print("%s failures=%d" % [FAIL_MARKER, failures.size()])
	quit(1)
