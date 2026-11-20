extends Control
class_name TutorialPopupPanel

const UILayoutProfileScript := preload("res://scripts/ui/shell/ui_layout_profile.gd")
const UILayerContractScript := preload("res://scripts/ui/shell/ui_layer_contract.gd")
const SemanticActionHintScript := preload("res://scripts/core/input/semantic_action_hint.gd")
const Art10UISkinKitScript := preload("res://scripts/presentation/art10_ui_skin_kit.gd")
const Art21UIPlacementContractScript := preload("res://scripts/presentation/art21_ui_placement_contract.gd")
const PresentationThemeScript := preload("res://scripts/presentation/presentation_theme.gd")
const RunSurfaceModelScript := preload("res://scripts/ui/run_surface/run_surface_model.gd")

signal confirmed
signal cancelled
signal learn_flag_requested
signal guidance_dismissed(popup_id: StringName)

var popup: Dictionary = {}
var layout_profile: Dictionary = {}
var ui_scale_factor := 1.0
var _last_popup_id: StringName = &""
var _presentation_occluded := false
var _training_active := false
var _learning_required := false
var _learning_enabled := false
var _training_scope := ""
var _last_guidance: Dictionary = {}
var _guidance_expanded := false
var _confirm_press_presentation := ""


func apply_training_state(snapshot: Dictionary, durable_learning_required: bool = false) -> void:
	var scope := "%s:%s" % [str(snapshot.get("run_id", "")), str(snapshot.get("position", snapshot.get("player_pos", Vector2i.ZERO)))]
	if scope != _training_scope:
		_last_guidance.clear()
		_guidance_expanded = false
		_training_scope = scope
	_training_active = str(snapshot.get("mode", "")) == "tutorial" and bool(snapshot.get("run_active", false))
	var profile: Dictionary = snapshot.get("profile_fields", {})
	var was_required := _learning_required
	# A valid older Meta backup can lose the paid entitlement while the native
	# checkpoint retains its runtime flag. Keep explicit learning reachable;
	# only the controller's durable business action may reconcile that state.
	_learning_required = _training_active and profile.get("z2_progression_version") == 1 and (not bool(profile.get("flag_unlocked", false)) or durable_learning_required)
	_learning_enabled = _learning_required and str(snapshot.get("phase", "")) == "running" and not TutorialService.is_blocking_popup(snapshot.get("tutorial_popup", {}))
	if was_required and not _learning_required and str(_last_guidance.get("id", "")) == "spawn_intro":
		_last_guidance.clear()
	if not _training_active:
		_last_guidance.clear()


func apply_popup(next_popup: Dictionary) -> void:
	var display := TutorialService.normalized_popup(next_popup)
	if TutorialService.is_guidance_popup(display):
		if str(display.get("id", "")) != str(_last_guidance.get("id", "")):
			_guidance_expanded = false
		_last_guidance = display.duplicate(true)
	if display.is_empty() and _training_active:
		if not _last_guidance.is_empty():
			display = _last_guidance.duplicate(true)
		else:
			display = {"id": &"tutorial_objective", "title": "教学目标", "blocking": false,
				"message": "先学习插旗，再朝地图上的出口图标前进。" if _learning_required else "朝右上角地图的出口图标前进，找到撤离信标。"}
			_guidance_expanded = false
	var next_id := StringName(display.get("id", &""))
	var popup_changed := next_id != _last_popup_id
	popup = display
	_last_popup_id = next_id
	_refresh(popup_changed)


func _confirm_presentation_key() -> String:
	return _training_scope + ":" + var_to_str(popup) + ":" + str(_guidance_expanded)


func _on_confirm_pressed() -> void:
	var press_presentation := _confirm_press_presentation
	_confirm_press_presentation = ""
	if not press_presentation.is_empty() and press_presentation != _confirm_presentation_key():
		# A mouse/key gesture that began on a lesson cannot become consent for
		# a newly mounted risk decision just because the same Button is reused.
		return
	if bool(popup.get("blocking", false)):
		confirmed.emit()
		return
	# Expanding/collapsing is local presentation only. Dismissal may record that
	# a once-only lesson was read, but never purchases a talent or grants power.
	_guidance_expanded = not _guidance_expanded
	if not _guidance_expanded:
		# Scene's first listener may synchronously replace this presentation.
		# Seal the emitted value before that listener updates our member fields.
		var dismissed_id: StringName = _last_popup_id
		guidance_dismissed.emit(dismissed_id)
	_refresh(false)


func set_presentation_occluded(occluded: bool) -> void:
	if _presentation_occluded == occluded:
		return
	_presentation_occluded = occluded
	_refresh(false)


func apply_layout_profile(next_profile: Dictionary) -> void:
	layout_profile = next_profile.duplicate(true)
	if layout_profile.has("ui_scale_factor"):
		ui_scale_factor = clampf(float(layout_profile.get("ui_scale_factor", 1.0)), 1.0, 1.5)
	else:
		layout_profile["ui_scale_factor"] = ui_scale_factor
	_refresh(false)


func set_ui_scale_factor(value: float) -> void:
	ui_scale_factor = Art10UISkinKitScript.normalize_runtime_ui_scale_factor(value)
	set_meta("runtime_ui_scale_factor", ui_scale_factor)
	layout_profile["ui_scale_factor"] = ui_scale_factor
	_refresh(false)


func layout_snapshot() -> Dictionary:
	var panel := get_node_or_null("Panel") as Panel
	var message := get_node_or_null("Panel/Content/Message") as RichTextLabel
	var button := get_node_or_null("Panel/Content/ConfirmButton") as Button
	var blocking := bool(popup.get("blocking", false))
	var learn := get_node_or_null("Panel/Content/LearnFlagButton") as Button
	var profile := _resolved_layout_profile()
	return {
		"guidance_expanded": _guidance_expanded,
		"learning_required": _learning_required,
		"learning_button_visible": learn != null and learn.visible,
		"learning_button_disabled": learn == null or learn.disabled,
		"learning_button_rect": learn.get_global_rect() if learn != null and learn.visible else Rect2(),
		"visible": visible,
		"blocking": blocking,
		"presentation_occluded": _presentation_occluded,
		"ui_scale_factor": ui_scale_factor,
		"panel_rect": panel.get_global_rect() if panel != null else Rect2(),
		"message_rect": message.get_global_rect() if message != null else Rect2(),
		"message_content_height": message.get_content_height() if message != null else 0.0,
		"message_scroll_active": message.scroll_active if message != null else false,
		"button_rect": button.get_global_rect() if button != null and button.visible else Rect2(),
		"button_text": button.text if button != null else "",
		"button_tooltip": button.tooltip_text if button != null else "",
		"geometry": _tutorial_geometry(profile),
	}


func _ready() -> void:
	ui_scale_factor = Art10UISkinKitScript.runtime_ui_scale_factor()
	Art10UISkinKitScript.apply_player_ui_theme(self)
	var panel := get_node_or_null("Panel") as Panel
	if panel != null:
		var panel_style := Art10UISkinKitScript.style_box_from_asset_ref(
			Art21UIPlacementContractScript.panel_ref(&"modal"),
			18,
			20
		)
		if panel_style != null:
			panel.add_theme_stylebox_override("panel", panel_style)
	var button := get_node_or_null("Panel/Content/ConfirmButton") as Button
	if button != null:
		Art10UISkinKitScript.apply_button(button, &"primary")
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		button.button_down.connect(func() -> void: _confirm_press_presentation = _confirm_presentation_key())
		button.pressed.connect(_on_confirm_pressed)
	var learn := Button.new()
	learn.name = "LearnFlagButton"
	learn.text = "100点 · 学习插旗"
	learn.tooltip_text = "主动花费100点学习插旗。收起或关闭教学说明不会购买；学习入口在所有训练房间均可使用。"
	learn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	learn.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	learn.focus_mode = Control.FOCUS_ALL
	learn.mouse_filter = Control.MOUSE_FILTER_STOP
	Art10UISkinKitScript.apply_button(learn, &"primary")
	learn.pressed.connect(func() -> void: learn_flag_requested.emit())
	get_node("Panel/Content").add_child(learn)
	var cancel := Button.new()
	cancel.name = "CancelButton"
	cancel.text = "取消 · Esc"
	cancel.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cancel.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	Art10UISkinKitScript.apply_button(cancel, &"secondary")
	cancel.pressed.connect(func() -> void: cancelled.emit())
	get_node("Panel/Content").add_child(cancel)
	_refresh(true)


func _unhandled_input(event: InputEvent) -> void:
	if not visible or not bool(popup.get("blocking", false)):
		return
	var confirm_action := StringName(popup.get("confirm_action", &"ui_accept"))
	if event.is_action_pressed(String(confirm_action)):
		var focus_owner := get_viewport().gui_get_focus_owner()
		if event.is_action("ui_accept") and focus_owner is BaseButton and is_ancestor_of(focus_owner) and focus_owner.is_visible_in_tree() and not focus_owner.disabled:
			# BaseButton may leave key-down unhandled until key-up activates it.
			# Never issue fallback Cancel in the middle of that GUI-owned gesture.
			return
		if _last_popup_id == &"flag_entry_confirm":
			# Without a focused decision, accepting follows the safe default.
			cancelled.emit()
		else:
			_on_confirm_pressed()
		get_viewport().set_input_as_handled()


func _refresh(reset_scroll: bool = false) -> void:
	var blocking := bool(popup.get("blocking", false))
	visible = not popup.is_empty() and (blocking or not _presentation_occluded)
	if not visible or not is_inside_tree():
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		if is_inside_tree():
			var focus_owner := get_viewport().gui_get_focus_owner()
			if focus_owner != null and (focus_owner == self or is_ancestor_of(focus_owner)):
				get_viewport().gui_release_focus()
		return
	var title := get_node_or_null("Panel/Content/Title") as Label
	var message := get_node_or_null("Panel/Content/Message") as RichTextLabel
	var button := get_node_or_null("Panel/Content/ConfirmButton") as Button
	var panel := get_node_or_null("Panel") as Panel
	var content := get_node_or_null("Panel/Content") as Control
	var profile := _resolved_layout_profile()
	var geometry := _tutorial_geometry(profile)

	mouse_filter = Control.MOUSE_FILTER_STOP if blocking else Control.MOUSE_FILTER_IGNORE
	UILayerContractScript.apply_layer(self, &"modal" if blocking else &"overlay", 4)
	if panel != null:
		# Non-blocking guidance does not own keyboard focus, but its visible
		# card still stops pointer clicks from reaching an obscured world target.
		panel.mouse_filter = Control.MOUSE_FILTER_STOP
		_set_rect(panel, geometry.get("panel_rect", Rect2(304, 12, 260, 520)))
	if content != null and panel != null:
		var content_inset := 20.0 + 4.0 * ((ui_scale_factor - 1.0) / 0.5) if blocking else 12.0
		_set_rect(
			content,
			Rect2(
				Vector2(content_inset, content_inset),
				Vector2(
					maxf(1.0, panel.size.x - content_inset * 2.0),
					maxf(1.0, panel.size.y - content_inset * 2.0)
				)
			)
		)

	if title != null:
		title.mouse_filter = Control.MOUSE_FILTER_IGNORE
		title.add_theme_color_override("font_color", PresentationThemeScript.color_for_key(&"ui.accent"))
		title.add_theme_font_size_override(
			"font_size",
			Art10UISkinKitScript.scaled_font_size(
				Art10UISkinKitScript.font_size(&"section_title"),
				ui_scale_factor
			)
		)
		title.text = String(popup.get("title", "教程：%s" % String(popup.get("id", ""))))
	if message != null:
		message.mouse_filter = Control.MOUSE_FILTER_STOP
		message.add_theme_color_override("default_color", PresentationThemeScript.text_color())
		var body_font := Art10UISkinKitScript.readable_font()
		if body_font is Font:
			message.add_theme_font_override("normal_font", body_font as Font)
			message.add_theme_font_override("bold_font", body_font as Font)
		message.add_theme_font_override("italics_font", body_font as Font)
		var body_size := Art10UISkinKitScript.scaled_font_size(
			Art10UISkinKitScript.font_size(&"body"),
			ui_scale_factor
		)
		message.add_theme_font_size_override("normal_font_size", body_size)
		message.add_theme_font_size_override("bold_font_size", body_size)
		message.add_theme_font_size_override("italics_font_size", body_size)
		message.add_theme_constant_override("line_separation", maxi(2, int(round(3.0 * ui_scale_factor))))
		var full_message := String(popup.get("message", ""))
		var summary := full_message.get_slice("\n", 0)
		message.text = summary if not blocking and not _guidance_expanded else full_message
		message.scroll_active = true
		message.scroll_following = false
		if reset_scroll:
			call_deferred("_reset_message_scroll", _last_popup_id)
	if button != null:
		button.visible = blocking or not _last_guidance.is_empty() or not _training_active
		button.mouse_filter = Control.MOUSE_FILTER_STOP
		Art10UISkinKitScript.apply_button(button, &"primary" if blocking else &"secondary")
		_reserve_button_focus_inset(button)
		button.focus_mode = Control.FOCUS_ALL if blocking else Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(0.0, round(40.0 * minf(ui_scale_factor, 1.25)))
		button.add_theme_font_size_override(
			"font_size",
			Art10UISkinKitScript.scaled_font_size(
				Art10UISkinKitScript.font_size(&"body"),
				ui_scale_factor
			)
		)
		if blocking:
			var confirm_hint := popup.get("confirm_action_hint", {}) as Dictionary
			var compact_hint := SemanticActionHintScript.compact_label_from_descriptor(
				confirm_hint,
				SemanticActionHintScript.current_device()
			)
			var full_hint := str(confirm_hint.get("display_label", ""))
			var confirm_text := str(popup.get("confirm_text", "继续"))
			button.text = "%s · %s" % [confirm_text, compact_hint] if not compact_hint.is_empty() else confirm_text
			button.tooltip_text = "确认操作：%s" % full_hint if not full_hint.is_empty() else confirm_text
		else:
			button.text = "收起教学说明" if _guidance_expanded else "查看教学说明"
			button.tooltip_text = "只收起说明，不锁定操作、不购买能力" if _guidance_expanded else "展开完整说明，不会打断探索"
		if blocking and reset_scroll:
			call_deferred("_grab_confirm_focus_if_valid", _last_popup_id)
	var learn := get_node_or_null("Panel/Content/LearnFlagButton") as Button
	if learn != null:
		learn.visible = _learning_required and not blocking and _last_popup_id != &"spawn_intro"
		learn.disabled = not _learning_enabled
		learn.add_theme_font_size_override("font_size", Art10UISkinKitScript.scaled_font_size(Art10UISkinKitScript.font_size(&"body"), ui_scale_factor))
		_reserve_button_focus_inset(learn)
	# Pure guidance never grabs focus. The separate, explicit purchase action
	# remains manually keyboard-focusable instead of making graduation mouse-only.
	_layout_content()
	# Wrapped Button minima settle after text/width changes. Reflow once after
	# Godot has shaped the new text so the bottom action keeps its safe inset.
	call_deferred("_layout_content")


func _layout_content() -> void:
	if not visible or not is_inside_tree():
		return
	var content := get_node_or_null("Panel/Content") as Control
	var title := get_node_or_null("Panel/Content/Title") as Label
	var message := get_node_or_null("Panel/Content/Message") as RichTextLabel
	var button := get_node_or_null("Panel/Content/ConfirmButton") as Button
	if not bool(popup.get("blocking", false)):
		var cancel := get_node_or_null("Panel/Content/CancelButton") as Button
		if cancel != null:
			cancel.hide()
		_layout_guidance_content(content, title, message, button)
		return
	if content != null:
		var gap := 8.0 + 4.0 * ((ui_scale_factor - 1.0) / 0.5)
		# Measure using the new width: Label's old wrapped minimum can otherwise
		# survive a resize until the next frame and overlap the message.
		var title_height := 30.0
		if title != null:
			title.size.x = content.size.x
			title_height = maxf(title_height, title.get_minimum_size().y)
		var cancel := get_node_or_null("Panel/Content/CancelButton") as Button
		var has_cancel := cancel != null and str(popup.get("id", "")) == "flag_entry_confirm"
		var stacked_actions := false
		var action_width := content.size.x
		if cancel != null:
			cancel.visible = has_cancel
			cancel.add_theme_font_size_override("font_size", button.get_theme_font_size("font_size"))
			_reserve_button_focus_inset(cancel)
		if has_cancel:
			var half_width := (content.size.x - gap) / 2.0
			stacked_actions = _single_line_button_width(button) > half_width or _single_line_button_width(cancel) > half_width
			if not stacked_actions:
				action_width = half_width
		var button_height := 0.0
		if button != null and button.visible:
			button_height = _wrapped_button_height(button, action_width)
		var cancel_height := _wrapped_button_height(cancel, action_width) if has_cancel else 0.0
		var actions_height := button_height
		if has_cancel:
			actions_height = button_height + gap + cancel_height if stacked_actions else maxf(button_height, cancel_height)
		if title != null:
			_set_rect(title, Rect2(0.0, 0.0, content.size.x, title_height))
		if message != null:
			var message_top := title_height + gap
			var message_bottom := content.size.y - (
				actions_height + gap
				if button != null and button.visible
				else 0.0
			)
			message.custom_minimum_size.y = 0.0
			_set_rect(
				message,
				Rect2(
					0.0,
					message_top,
					content.size.x,
					maxf(1.0, message_bottom - message_top)
				)
			)
		if button != null and button.visible:
			_set_rect(
				button,
				Rect2(
					action_width + gap if has_cancel and not stacked_actions else 0.0,
					content.size.y - button_height,
					action_width,
					button_height
				)
			)
		if has_cancel:
			_set_rect(cancel, Rect2(0.0, content.size.y - actions_height, action_width, cancel_height))


func _layout_guidance_content(content: Control, title: Label, message: RichTextLabel, details: Button) -> void:
	var panel := get_node_or_null("Panel") as Control
	if content == null or panel == null or title == null or message == null:
		return
	var learn := get_node_or_null("Panel/Content/LearnFlagButton") as Button
	var gap := 6.0 * ui_scale_factor
	var reserved: Rect2 = _tutorial_geometry(_resolved_layout_profile()).get("panel_rect", Rect2())
	var inset := content.position.y
	var width := content.size.x
	title.size.x = width
	var title_height := maxf(30.0, title.get_minimum_size().y)
	var actions: Array[Button] = []
	if details != null and details.visible:
		actions.append(details)
	if learn != null and learn.visible:
		actions.append(learn)
	var heights: Array[float] = []
	var actions_height := 0.0
	for action in actions:
		var height := _wrapped_button_height(action, width)
		heights.append(height)
		actions_height += height
	if actions.size() > 1:
		actions_height += gap * float(actions.size() - 1)
	message.size.x = width
	var compact_message_height := maxf(42.0 * ui_scale_factor, float(message.get_content_height()))
	var panel_height := reserved.size.y
	if not _guidance_expanded:
		panel_height = minf(reserved.size.y, 2.0 * inset + title_height + gap + compact_message_height + (gap + actions_height if not actions.is_empty() else 0.0))
	panel.size.y = panel_height
	content.size.y = maxf(1.0, panel_height - inset * 2.0)
	_set_rect(title, Rect2(0.0, 0.0, width, title_height))
	var message_top := title_height + gap
	var action_top := content.size.y - actions_height
	var message_height := action_top - gap - message_top if not actions.is_empty() else content.size.y - message_top
	message.custom_minimum_size.y = 0.0
	_set_rect(message, Rect2(0.0, message_top, width, maxf(1.0, message_height)))
	for index in range(actions.size()):
		_set_rect(actions[index], Rect2(0.0, action_top, width, heights[index]))
		action_top += heights[index] + gap


func _wrapped_button_height(button: Button, width: float) -> float:
	button.size.x = width
	return maxf(40.0 * minf(ui_scale_factor, 1.25), button.get_minimum_size().y)


func _single_line_button_width(button: Button) -> float:
	return button.get_theme_font("font").get_string_size(button.text, HORIZONTAL_ALIGNMENT_LEFT, -1, button.get_theme_font_size("font_size")).x + button.get_theme_stylebox("normal").get_minimum_size().x


func _reserve_button_focus_inset(button: Button) -> void:
	# Leave room for the corner marks without consuming a line of action text.
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var style := button.get_theme_stylebox(state).duplicate() as StyleBox
		style.content_margin_left = 12.0
		style.content_margin_right = 12.0
		button.add_theme_stylebox_override(state, style)


func _resolved_layout_profile() -> Dictionary:
	var profile := layout_profile.duplicate(true)
	if profile.is_empty():
		var viewport_size := get_viewport_rect().size
		profile = UILayoutProfileScript.profile_for_size(viewport_size)
		profile["actual_viewport_size"] = Vector2i(int(round(viewport_size.x)), int(round(viewport_size.y)))
	profile["ui_scale_factor"] = ui_scale_factor
	if is_inside_tree():
		profile["actual_viewport_size"] = Vector2i(UILayerContractScript.viewport_size_from_profile(profile).max(get_viewport_rect().size))
	return profile


func _tutorial_geometry(profile: Dictionary) -> Dictionary:
	var layout := RunSurfaceModelScript.layout_geometry(profile)
	var panel_rect: Rect2 = layout.description_rect
	# The weapon HUD sits above this card. Give its scroll view and actions
	# the available left-column height; collapsed guidance sizes to its contents.
	panel_rect.size.y = maxf(1.0, layout.viewport_size.y - panel_rect.position.y - 12.0)
	return {
		"panel_rect": panel_rect,
		"left_hud_rect": layout.protocol_rect,
		"right_status_rect": layout.scanner_rail_rect,
		"room_stage_rect": layout.room_stage_rect,
		"footer_rect": layout.action_rect.merge(layout.bag_rect),
	}


func _reset_message_scroll(expected_popup_id: StringName) -> void:
	if expected_popup_id != _last_popup_id:
		return
	var message := get_node_or_null("Panel/Content/Message") as RichTextLabel
	if message != null:
		message.scroll_to_line(0)


func _grab_confirm_focus_if_valid(expected_popup_id: StringName) -> void:
	if (
		expected_popup_id != _last_popup_id
		or not visible
		or not bool(popup.get("blocking", false))
	):
		return
	var button_path := "Panel/Content/CancelButton" if expected_popup_id == &"flag_entry_confirm" else "Panel/Content/ConfirmButton"
	var button := get_node_or_null(button_path) as Button
	if (
		button != null
		and button.visible
		and not button.disabled
		and button.focus_mode != Control.FOCUS_NONE
	):
		button.grab_focus()


func blocks_world_pointer(viewport_position: Vector2) -> bool:
	if not visible:
		return false
	var panel := get_node_or_null("Panel") as Control
	return panel != null and panel.is_visible_in_tree() and panel.get_global_rect().has_point(viewport_position)


func _set_rect(control: Control, rect: Rect2) -> void:
	if control == null:
		return
	control.set_anchors_preset(Control.PRESET_TOP_LEFT)
	control.position = rect.position
	control.size = rect.size
