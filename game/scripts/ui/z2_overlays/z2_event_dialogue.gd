extends Control
## Mount z2_event_dialogue.tscn in a viewport-sized Control or CanvasLayer.

signal choice_requested(request: Dictionary)
signal dismissed(context: Dictionary)

const RunVectorSkin := preload("res://scripts/ui/run_surface/run_vector_skin.gd")
const REFERENCE_SIZE := Vector2(1920.0, 1080.0)
const NORMAL_TEXT := Color(0.89, 0.93, 0.88)
const MUTED_TEXT := Color(0.65, 0.74, 0.71)
const COST_TEXT := Color(0.94, 0.80, 0.56)
const EFFECT_TEXT := Color(0.65, 0.85, 0.76)
const FAILURE_TEXT := Color(1.0, 0.64, 0.48)

@export_range(1.0, 120.0) var characters_per_second := 42.0

@onready var _dialogue_frame: PanelContainer = %DialogueFrame
@onready var _nameplate: PanelContainer = %Nameplate
@onready var _speaker: Label = %SpeakerName
@onready var _body: RichTextLabel = %DialogueText
@onready var _feedback: RichTextLabel = %DialogueStatus
@onready var _hint: Label = %InputHint
@onready var _close: Button = %CloseDialogue
@onready var _choices: PanelContainer = %ChoicesFrame
@onready var _options: VBoxContainer = %Options

var _view: Dictionary = {}
var _lines: Array = []
var _line_index := 0
var _shown_chars := 0.0
var _choosing := false
var _buttons: Array[Button] = []
var _selected := -1
var _pending_by_room := {}
var _attempt_id := 0
var _previous_focus: Control
var _choices_heading: Label
var _frame_style: StyleBoxTexture
var _laying_out := false


func _ready() -> void:
	set_process(false)
	# Keep the imported component and its public API; the source layout puts the
	# nameplate across the frame, outside the text container.
	_nameplate.reparent(self)
	_speaker.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_speaker.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	_body.custom_minimum_size.y = 52.0
	_frame_style = _panel_style(22.0, 24.0, 22.0, 12.0)
	_dialogue_frame.add_theme_stylebox_override(&"panel", _frame_style)
	_choices.add_theme_stylebox_override(&"panel", _panel_style(10.0, 10.0, 10.0, 10.0))
	_nameplate.add_theme_stylebox_override(&"panel", RunVectorSkin.frame(RunVectorSkin.STATUS, Vector4(12, 5, 12, 5)))
	RunVectorSkin.apply_button(_close, Vector4(10, 4, 10, 4))
	RunVectorSkin.set_icon(_close, RunVectorSkin.CLOSE)
	_close.custom_minimum_size = Vector2(112, 36)
	var scroll: ScrollContainer = %OptionsScroll
	var contents := VBoxContainer.new()
	contents.mouse_filter = Control.MOUSE_FILTER_IGNORE
	contents.add_theme_constant_override(&"separation", 8)
	_choices.add_child(contents)
	_choices_heading = Label.new()
	_choices_heading.name = "ChoicesHeading"
	_choices_heading.text = "你的选择"
	_choices_heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_choices_heading.add_theme_font_size_override(&"font_size", 16)
	_choices_heading.add_theme_color_override(&"font_color", MUTED_TEXT)
	contents.add_child(_choices_heading)
	scroll.reparent(contents)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	resized.connect(_layout)
	_dialogue_frame.minimum_size_changed.connect(_layout)
	_nameplate.minimum_size_changed.connect(_layout)
	_options.minimum_size_changed.connect(_layout)
	_body.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
	_body.gui_input.connect(_on_dialogue_click)
	_dialogue_frame.gui_input.connect(_on_dialogue_click)
	_close.pressed.connect(dismiss)
	_layout()


func _panel_style(left: float, top: float, right: float, bottom: float) -> StyleBoxTexture:
	return RunVectorSkin.frame(RunVectorSkin.PANEL, Vector4(left, top, right, bottom))


## Call after ready with {room_id, phase_id, revision: int, speaker?, lines?, options?}.
## IDs are stable strings. Revisions increase per room, including phase transitions.
## The optional speaker names the NPC when the view has no lines or a line omits its speaker.
## Lines use {speaker?: String, text: String}. Options use {option_id, action_id, label,
## cost?, effect?, enabled: bool, disabled_reason?}. Cost/effect/reason are display strings.
## A caller may reuse action_id for an idempotent retry. Echo the entire emitted request,
## including the per-panel attempt_id, to distinguish late replies to earlier attempts.
func present_view(view: Dictionary) -> bool:
	if not is_node_ready() or not _is_view(view):
		return false
	var room := str(view.room_id)
	if room == str(_view.get("room_id", "")) and not _is_current_or_newer(view, _view):
		return false
	var pending: Dictionary = _pending_by_room.get(room, {})
	if not pending.is_empty():
		if not _is_current_or_newer(view, pending):
			return false
		if view.revision != pending.revision:
			_pending_by_room.erase(room)
	if not visible:
		_previous_focus = get_viewport().gui_get_focus_owner()
		if _previous_focus != null:
			_previous_focus.release_focus()
		show()
	_replace_view(view)
	return true


## Echo {request, ok: bool, committed: bool, message?, response_lines?, view?}.
## An optional refreshed view must be for the same room at the same or newer revision.
## Only a matched committed success can supply response_lines. Without a refreshed view
## a success retires the displayed options until the caller presents authority again.
## Returns true if applied to the open view. A valid offscreen result releases its lock
## while the caller remains responsible for supplying the authoritative view on revisit.
func apply_result(result: Dictionary) -> bool:
	var echoed: Variant = result.get("request")
	var ok: Variant = result.get("ok")
	var committed: Variant = result.get("committed", false)
	if not echoed is Dictionary or not ok is bool or not committed is bool or ok != committed:
		return false
	var room := str(echoed.get("room_id", ""))
	var pending: Dictionary = _pending_by_room.get(room, {})
	if pending.is_empty() or echoed != pending:
		return false
	var refresh: Variant = result.get("view")
	if result.has("view") and (not _is_view(refresh) or not _is_current_or_newer(refresh, pending)):
		return false
	var response: Variant = result.get("response_lines", [])
	if ok and not _are_lines(response):
		return false

	_pending_by_room.erase(room)
	if not is_visible_in_tree() or not _same_scope(pending, _view):
		return false
	if ok:
		if refresh != null:
			_view = refresh.duplicate(true)
		else:
			_view["options"] = []
		_build_options()
		_show_feedback("")
		_start_lines(response.duplicate(true))
	else:
		if refresh != null:
			_replace_view(refresh)
		_show_feedback(str(result.get("message", "操作未完成。")), FAILURE_TEXT)
		_update_controls()
	return true


## Hides the UI. dismissed carries room_id, phase_id, revision and pending_request (or {}).
## An outstanding request can settle after dismissal. Reopening its scope keeps its lock.
func dismiss() -> void:
	if not visible:
		return
	var context := _scope(_view)
	context["pending_request"] = _pending().duplicate(true)
	hide()
	set_process(false)
	if is_instance_valid(_previous_focus) and _previous_focus.is_visible_in_tree():
		_previous_focus.grab_focus()
	_previous_focus = null
	dismissed.emit(context)


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not event is InputEventKey:
		return
	var key: Key = event.keycode if event.keycode != KEY_NONE else event.physical_keycode
	if key not in [KEY_ESCAPE, KEY_SPACE, KEY_ENTER, KEY_KP_ENTER, KEY_UP, KEY_DOWN]:
		return
	get_viewport().set_input_as_handled()
	if not event.pressed or event.echo:
		return
	if key == KEY_ESCAPE:
		dismiss()
	elif key in [KEY_UP, KEY_DOWN]:
		if _choosing:
			_step_focus(-1 if key == KEY_UP else 1)
	elif _close.has_focus():
		dismiss()
	elif _choosing:
		var index := _buttons.find(get_viewport().gui_get_focus_owner())
		if index >= 0:
			_request_option(index)
	else:
		_advance()


func _on_dialogue_click(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		get_viewport().set_input_as_handled()
		_advance()


func _process(delta: float) -> void:
	_shown_chars += delta * characters_per_second
	if _shown_chars >= _body.text.length():
		_complete_line()
	else:
		_body.visible_characters = int(_shown_chars)


func _advance() -> void:
	if _choosing or not _pending().is_empty():
		return
	if _body.visible_characters >= 0:
		_complete_line()
	elif _line_index + 1 < _lines.size():
		_line_index += 1
		_show_line()
	elif not _buttons.is_empty():
		_choosing = true
		_update_controls()
	else:
		dismiss()


func _replace_view(view: Dictionary) -> void:
	_view = view.duplicate(true)
	_build_options()
	_show_feedback("" if _pending().is_empty() else "等待结果…")
	_start_lines(_view.get("lines", []))


func _start_lines(lines: Array) -> void:
	_lines = lines
	_line_index = 0
	_body.visible = not lines.is_empty()
	_choosing = lines.is_empty() and not _buttons.is_empty()
	_feedback.size_flags_vertical = Control.SIZE_FILL if _body.visible else Control.SIZE_EXPAND_FILL
	_feedback.custom_minimum_size.y = 41.0 if _body.visible else 25.0
	if lines.is_empty():
		_show_speaker(str(_view.get("speaker", "")))
		_body.text = ""
		_complete_line()
	else:
		var focus := get_viewport().gui_get_focus_owner()
		if focus != null and is_ancestor_of(focus):
			focus.release_focus()
		_show_line()
	_update_controls()


func _show_line() -> void:
	var line: Dictionary = _lines[_line_index]
	_show_speaker(str(line.get("speaker", _view.get("speaker", ""))))
	_body.text = line.text
	_body.scroll_to_line(0)
	_body.visible_characters = 0
	_shown_chars = 0.0
	set_process(true)
	_layout()


func _show_speaker(copy: String) -> void:
	_speaker.text = copy
	_nameplate.visible = not copy.is_empty()


func _complete_line() -> void:
	_body.visible_characters = -1
	set_process(false)


func _show_feedback(copy: String, color: Color = EFFECT_TEXT) -> void:
	_feedback.text = copy
	_feedback.add_theme_color_override(&"default_color", color)
	_feedback.scroll_to_line(0)
	_feedback.visible = not copy.is_empty()


func _build_options() -> void:
	for button in _buttons:
		_options.remove_child(button)
		button.queue_free()
	_buttons.clear()
	_selected = -1
	for option: Dictionary in _view.get("options", []):
		var index := _buttons.size()
		var button := Button.new()
		button.name = "Option_%d" % index
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _enabled(option) else Control.CURSOR_ARROW
		button.accessibility_name = str(option.label)
		RunVectorSkin.apply_button(button, Vector4.ZERO)
		button.pressed.connect(_request_option.bind(index))
		button.focus_entered.connect(func() -> void: _selected = index)
		button.mouse_entered.connect(func() -> void:
			if not button.disabled:
				button.grab_focus()
		)
		_options.add_child(button)
		_buttons.append(button)

		var padding := MarginContainer.new()
		padding.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for edge in ["left", "right", "top", "bottom"]:
			padding.add_theme_constant_override("margin_" + edge, 12 if edge in ["left", "right"] else 6)
		button.add_child(padding)
		padding.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var text := VBoxContainer.new()
		text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text.add_theme_constant_override(&"separation", 3)
		padding.add_child(text)
		var enabled := _enabled(option)
		var header := HBoxContainer.new()
		header.mouse_filter = Control.MOUSE_FILTER_IGNORE
		header.add_theme_constant_override(&"separation", 10)
		text.add_child(header)
		var title := _add_option_text(header, "OptionLabel", str(option.label), 19, NORMAL_TEXT if enabled else MUTED_TEXT)
		title.size_flags_stretch_ratio = 3.0
		var cost := _add_option_text(header, "OptionCost", str(option.get("cost", "")), 16, COST_TEXT if enabled else MUTED_TEXT)
		if cost != null:
			cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			cost.size_flags_stretch_ratio = 2.0
		_add_option_text(text, "OptionEffect", str(option.get("effect", "")), 16, EFFECT_TEXT if enabled else MUTED_TEXT)
		if not enabled:
			_add_option_text(text, "OptionReason", str(option.get("disabled_reason", "")), 16, FAILURE_TEXT)
		padding.minimum_size_changed.connect(func() -> void:
			button.custom_minimum_size.y = padding.get_combined_minimum_size().y
		)
		button.custom_minimum_size.y = padding.get_combined_minimum_size().y


func _add_option_text(parent: Container, node_name: String, copy: String, font_size: int, color: Color) -> Label:
	if copy.is_empty():
		return null
	var label := Label.new()
	label.name = node_name
	label.text = copy
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", color)
	parent.add_child(label)
	return label


func _update_controls() -> void:
	var pending := not _pending().is_empty()
	_choices.visible = _choosing
	var has_enabled := false
	for index in _buttons.size():
		var button := _buttons[index]
		button.disabled = pending or not _enabled(_view.options[index])
		button.focus_mode = Control.FOCUS_NONE if button.disabled else Control.FOCUS_ALL
		has_enabled = has_enabled or not button.disabled
	if pending or (_choosing and not has_enabled):
		_hint.text = ""
	elif _choosing:
		_hint.text = "↑ ↓  选择     回车  确认"
	else:
		_hint.text = "点击 / 空格  继续"
	_layout()
	if _choosing and has_enabled:
		if _selected >= 0 and not _buttons[_selected].disabled:
			_buttons[_selected].grab_focus()
		else:
			_step_focus(1)


func _step_focus(direction: int) -> void:
	var start := _buttons.find(get_viewport().gui_get_focus_owner())
	if start < 0 and direction < 0:
		start = 0
	for step in range(1, _buttons.size() + 1):
		var button := _buttons[posmod(start + direction * step, _buttons.size())]
		if not button.disabled:
			button.grab_focus()
			return


func _request_option(index: int) -> void:
	if not is_visible_in_tree() or not _choosing or not _pending().is_empty() or _buttons[index].disabled:
		return
	var option: Dictionary = _view.options[index]
	_attempt_id += 1
	var request := _scope(_view)
	request["option_id"] = str(option.option_id)
	request["action_id"] = str(option.action_id)
	request["attempt_id"] = _attempt_id
	_pending_by_room[request.room_id] = request
	_show_feedback("等待结果…")
	_update_controls()
	choice_requested.emit(request.duplicate(true))


func _layout() -> void:
	if not is_node_ready() or _laying_out:
		return
	_laying_out = true
	var dialogue_width := size.x * 1468.0 / REFERENCE_SIZE.x
	var bottom := size.y * 1017.0 / REFERENCE_SIZE.y
	_fit_nameplate(dialogue_width)
	var gap := maxf(10.0, size.y * 30.0 / REFERENCE_SIZE.y)
	if _nameplate.visible:
		gap = maxf(gap, _nameplate.size.y * 0.35 + 8.0)
	_frame_style.content_margin_top = maxf(24.0, _nameplate.size.y * 0.65 + 8.0) if _nameplate.visible else 20.0
	var dialogue_height := maxf(_dialogue_frame.get_combined_minimum_size().y, size.y * 233.0 / REFERENCE_SIZE.y)
	_dialogue_frame.size = Vector2(dialogue_width, dialogue_height)
	_dialogue_frame.position = Vector2((size.x - dialogue_width) / 2.0, bottom - _dialogue_frame.size.y)
	_nameplate.position = _dialogue_frame.position + Vector2(18.0, -_nameplate.size.y * 0.35)

	# At the supported minimum and all three font scales these retain the source
	# proportions. Very narrow component previews use the available width.
	var choices_width := size.x * 606.0 / REFERENCE_SIZE.x
	if size.x < 760.0:
		choices_width = size.x - 28.0
	var choices_bottom := _dialogue_frame.position.y - gap
	var height_limit := maxf(1.0, minf(size.y * 466.0 / REFERENCE_SIZE.y, choices_bottom - 18.0))
	if size.x < 760.0:
		height_limit = maxf(1.0, choices_bottom - 108.0)
	var choices_inset := _choices.get_theme_stylebox(&"panel").get_minimum_size().y + _choices_heading.get_combined_minimum_size().y + 8.0
	var choices_height := minf(height_limit, _options.get_combined_minimum_size().y + choices_inset)
	_choices.size = Vector2(choices_width, choices_height)
	_choices.position = Vector2(size.x * 1871.0 / REFERENCE_SIZE.x - choices_width, choices_bottom - _choices.size.y)
	if size.x < 760.0:
		_choices.position.x = 14.0
	_laying_out = false


func _fit_nameplate(dialogue_width: float) -> void:
	if not _nameplate.visible:
		return
	var inset := _nameplate.get_theme_stylebox(&"panel").get_minimum_size().x
	var font := _speaker.get_theme_font(&"font")
	var font_size := _speaker.get_theme_font_size(&"font_size")
	var text_width := font.get_string_size(_speaker.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var width := clampf(ceilf(text_width) + inset, minf(134.0, dialogue_width - 36.0), dialogue_width - 36.0)
	_speaker.custom_minimum_size.x = maxf(0.0, width - inset)
	_nameplate.size = Vector2(width, 0.0)


func _pending() -> Dictionary:
	return _pending_by_room.get(str(_view.get("room_id", "")), {})


func _scope(view: Dictionary) -> Dictionary:
	return {"room_id": str(view.room_id), "phase_id": str(view.phase_id), "revision": view.revision}


func _same_scope(a: Dictionary, b: Dictionary) -> bool:
	return _scope(a) == _scope(b)


func _is_current_or_newer(candidate: Dictionary, current: Dictionary) -> bool:
	return str(candidate.room_id) == str(current.room_id) and (
		candidate.revision > current.revision or _same_scope(candidate, current)
	)


func _is_id(value: Variant) -> bool:
	return (value is String or value is StringName) and not str(value).strip_edges().is_empty()


func _enabled(option: Dictionary) -> bool:
	return option.get("enabled", false) == true


func _are_lines(lines: Variant) -> bool:
	if not lines is Array:
		return false
	for line in lines:
		if not line is Dictionary or not line.get("text") is String:
			return false
	return true


func _is_view(value: Variant) -> bool:
	if not value is Dictionary or not _is_id(value.get("room_id")) or not _is_id(value.get("phase_id")):
		return false
	if not value.get("revision") is int or value.revision < 0 or not _are_lines(value.get("lines", [])):
		return false
	var options: Variant = value.get("options", [])
	if not options is Array:
		return false
	for option in options:
		if not option is Dictionary or not _is_id(option.get("option_id")) or not _is_id(option.get("label")):
			return false
		if _enabled(option) and not _is_id(option.get("action_id")):
			return false
	return true
