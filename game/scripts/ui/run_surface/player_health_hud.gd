extends Control

const PORTRAIT := preload("res://assets/ui/run_vector/raccoon_hud_portrait.png")
const SkinKit := preload("res://scripts/presentation/art10_ui_skin_kit.gd")
const PAUSE_SECONDS := 0.24
const CATCH_UP_SECONDS := 0.46
const WARM_WHITE := Color("#f3e6c9")
const STEEL_LIP := Color("#7da8b5")
const STEEL_SHADOW := Color("#0b131a")

var _health := 0
var _maximum := 0
var _run_id := ""
var _ratio := 0.0
var _white_ratio := 0.0
var _white_start := 0.0
var _damage_age := 0.0
var _portrait_rect := Rect2()
var _track := Rect2()
var _number_area := Rect2()
var _power_channel := Rect2()
var _caption: Label
var _number: Label
var _maximum_label: Label
var _power: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_caption = _label("HealthCaption", WARM_WHITE)
	_caption.text = "生命"
	_number = _label("HealthValue", WARM_WHITE)
	var digits := FontVariation.new()
	digits.base_font = SkinKit.pixel_font() as Font
	digits.variation_embolden = 0.75
	_number.add_theme_font_override(&"font", digits)
	_number.visible_characters_behavior = TextServer.VC_CHARS_BEFORE_SHAPING
	_number.text = "0 / 0"
	_number.visible_characters = 1
	_maximum_label = _label("HealthMaximum", Color("#b7cbd0"))
	_maximum_label.text = "/ 0"
	_power = _label("PowerValue", Color("#b7cbd0"))
	resized.connect(_layout)
	set_process(false)
	_layout()


func apply_vitals(hp: int, max_hp: int, power: int, run_id: String) -> void:
	var safe_max := maxi(max_hp, 0)
	var safe_hp := clampi(hp, 0, safe_max)
	if safe_hp != _health or safe_max != _maximum or run_id != _run_id:
		var ratio := float(safe_hp) / maxf(1.0, safe_max)
		if run_id == _run_id and safe_max == _maximum and safe_hp < _health:
			_white_start = maxf(_white_ratio, _ratio)
			_white_ratio = _white_start
			_damage_age = 0.0
			set_process(true)
		else:
			_white_ratio = ratio
			set_process(false)
		_health = safe_hp
		_maximum = safe_max
		_run_id = run_id
		_ratio = ratio
		_number.text = "%d / %d" % [_health, _maximum]
		_number.visible_characters = str(_health).length()
		_maximum_label.text = "/ %d" % _maximum
		_fit_health_number()
		_number.add_theme_color_override(&"font_color", Color("#ffc9ab") if _ratio <= 0.25 else WARM_WHITE)
		queue_redraw()
	var strength := "强度 %d" % power
	if _power.text != strength:
		_power.text = strength


func _process(delta: float) -> void:
	_damage_age += delta
	var progress := clampf((_damage_age - PAUSE_SECONDS) / CATCH_UP_SECONDS, 0.0, 1.0)
	if progress > 0.0:
		_white_ratio = lerpf(_white_start, _ratio, smoothstep(0.0, 1.0, progress))
		queue_redraw()
	if progress >= 1.0:
		set_process(false)


func _layout() -> void:
	var pad := clampf(roundf(size.y * 0.065), 5.0, 8.0)
	var face_size := maxf(0.0, floorf(minf(size.y - pad * 2.0, size.x * 0.35)))
	_portrait_rect = Rect2(Vector2(pad, floorf((size.y - face_size) * 0.5)), Vector2.ONE * face_size)
	var text_x := _portrait_rect.end.x + pad * 0.5
	var usable := maxf(1.0, size.x - text_x - pad - 2.0)
	var caption_font := clampi(roundi(size.y * 0.16), 12, 19)
	_caption.add_theme_font_size_override(&"font_size", caption_font)
	_power.add_theme_font_size_override(&"font_size", clampi(roundi(size.y * 0.14), 11, 18))
	_caption.position = Vector2(text_x + 6.0, roundf(size.y * 0.115))
	_caption.size = Vector2(caption_font * 2.0 + 3.0, roundf(size.y * 0.22))
	var number_x := _caption.get_rect().end.x + 4.0
	_number_area = Rect2(number_x, 0.0, maxf(1.0, size.x - pad - 8.0 - number_x), size.y * 0.405)
	_fit_health_number()
	_track = Rect2(Vector2(text_x, roundf(size.y * 0.435)), Vector2(usable, maxf(16.0, roundf(size.y * 0.27))))
	_power_channel = Rect2(Vector2(text_x, _track.end.y + 2.0), Vector2(usable, maxf(12.0, size.y - _track.end.y - pad - 2.0)))
	_power.position = _power_channel.position + Vector2(6.0, 0.0)
	_power.size = Vector2(usable - 12.0, _power_channel.size.y)
	queue_redraw()


func _fit_health_number() -> void:
	var current_font := _number.get_theme_font(&"font")
	var maximum_font := _maximum_label.get_theme_font(&"font")
	var current_text := str(_health)
	var current_size := clampi(roundi(size.y * 0.39), 21, 44)
	var maximum_size := maxi(11, roundi(current_size * 0.52))
	var gap := 3.0
	var current_width := _text_width(current_font, current_text, current_size)
	var maximum_width := _text_width(maximum_font, _maximum_label.text, maximum_size)
	# Measure both native glyph runs because their font sizes and advances differ.
	while current_width + maximum_width + gap > _number_area.size.x and current_size > 10:
		current_size -= 1
		maximum_size = maxi(9, roundi(current_size * 0.55))
		current_width = _text_width(current_font, current_text, current_size)
		maximum_width = _text_width(maximum_font, _maximum_label.text, maximum_size)
	var baseline := roundf(_number_area.end.y)
	var maximum_x := _number_area.end.x - maximum_width
	_set_number_label(_number, current_size, current_width, maximum_x - gap - current_width, baseline)
	_set_number_label(_maximum_label, maximum_size, maximum_width, maximum_x, baseline)


func _text_width(font: Font, value: String, font_size: int) -> float:
	return ceilf(font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x) + 1.0


func _set_number_label(label: Label, font_size: int, width: float, x: float, baseline: float) -> void:
	var font := label.get_theme_font(&"font")
	label.add_theme_font_size_override(&"font_size", font_size)
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.position = Vector2(x, roundf(baseline - font.get_ascent(font_size)))
	label.size = Vector2(width, ceilf(font.get_height(font_size)) + 1.0)


func _draw() -> void:
	if _track.size.x < 12.0 or _portrait_rect.size.x < 12.0:
		return
	_draw_chassis()
	_draw_portrait()
	_draw_bevel(Rect2(_caption.position - Vector2(6, 2), _caption.size + Vector2(13, 4)), 6.0, 1.0, Color("#263c49"), Color("#506e7c"), Color("#0b151c"))
	_draw_bevel(_power_channel, 6.0, 1.0, Color("#162730"), Color("#3c5664"), Color("#0a141a"))
	_draw_bevel(_track, 8.0, 2.0, Color("#263f4c"), STEEL_LIP, STEEL_SHADOW)
	_draw_bevel(_track.grow(-3.0), 5.0, 1.5, Color("#0a1116"), Color("#0b1922"), Color("#638493"))
	var channel := _track.grow(-5.0)
	var damage_visible := roundf(channel.size.x * _white_ratio) > roundf(channel.size.x * _ratio)
	if damage_visible:
		_draw_fill(channel, _white_ratio, WARM_WHITE, Color("#fff9e5"), Color("#9c9074"))
	var red := Color("#e02a29") if _ratio > 0.25 else Color("#ff4f42")
	_draw_fill(channel, _ratio, red, Color("#ff785e"), Color("#811820"), damage_visible)
	for tick in [0.25, 0.50, 0.75]:
		var x := roundf(channel.position.x + channel.size.x * tick)
		draw_line(Vector2(x, _track.position.y + 2.0), Vector2(x, channel.position.y + 1.0), Color("#b5c8cd"))
	var terminal := Vector2(_track.end.x - 4.0, _track.get_center().y)
	draw_polyline(PackedVector2Array([terminal + Vector2(-3, -7), terminal + Vector2(0, -4), terminal + Vector2(0, 4), terminal + Vector2(-3, 7)]), Color("#b64438"), 1.0, true)


func _draw_chassis() -> void:
	var plate := Rect2(0, 0, size.x, size.y - 1.0)
	_draw_plate(plate, 9.0, Color("#070e12"))
	_draw_bevel(plate.grow(-1.0), 9.0, 2.0, Color("#344d5c"), STEEL_LIP, STEEL_SHADOW)
	_draw_bevel(plate.grow(-4.0), 6.0, 1.0, Color("#142530"), Color("#1f3641"), Color("#577889"))
	var joint_x := roundf(size.x * 0.57)
	for joint_y in [1.0, plate.end.y - 5.0]:
		var joint := Rect2(joint_x, joint_y, 19.0, 5.0)
		_draw_bevel(joint, 2.0, 1.0, Color("#805e3c"), Color("#cbad79"), Color("#3d2b22"))
		for inset in [3.5, 15.5]:
			draw_circle(Vector2(joint_x + inset, joint_y + 2.5), 1.0, Color("#4c3628"), true, -1.0, true)
	_draw_bolt(Vector2(size.x - 9.0, 9.0))
	_draw_bolt(Vector2(size.x - 9.0, plate.end.y - 8.0))


func _draw_portrait() -> void:
	_draw_bevel(_portrait_rect, 12.0, 2.0, Color("#365563"), Color("#91bdc8"), STEEL_SHADOW)
	_draw_bevel(_portrait_rect.grow(-3.0), 9.0, 1.0, Color("#233944"), Color("#547781"), Color("#1b2a33"))
	var image_area := _portrait_rect.grow(-5.0)
	_draw_bevel(image_area, 7.0, 1.0, Color("#132932"), Color("#090f15"), Color("#769eae"))
	draw_texture_rect(PORTRAIT, image_area.grow(-1.5), false)
	_draw_bolt(_portrait_rect.position + Vector2(6.0, 6.0))
	_draw_bolt(Vector2(_portrait_rect.position.x + 6.0, _portrait_rect.end.y - 6.0))


func _draw_bolt(center: Vector2) -> void:
	var bolt := Rect2(center - Vector2(3.5, 3.5), Vector2(7.0, 7.0))
	_draw_bevel(bolt, 2.0, 1.0, Color("#987047"), Color("#e3be80"), Color("#382619"))
	draw_line(center - Vector2(1.2, 0.6), center + Vector2(1.2, 0.6), Color("#493a2b"), 1.0, true)


func _label(node_name: String, color: Color) -> Label:
	var label := Label.new()
	label.name = node_name
	SkinKit.apply_label(label, 14, color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.clip_text = true
	add_child(label)
	return label


func _draw_plate(rect: Rect2, cut: float, color: Color) -> void:
	draw_colored_polygon(_chamfer_points(rect, cut), color)


func _chamfer_points(rect: Rect2, cut: float) -> PackedVector2Array:
	cut = clampf(cut, 0.0, maxf(0.0, minf(rect.size.x, rect.size.y) * 0.5 - 0.25))
	var x := rect.position.x
	var y := rect.position.y
	var right := rect.end.x
	var bottom := rect.end.y
	return PackedVector2Array([
		Vector2(x + cut, y), Vector2(right - cut, y), Vector2(right, y + cut),
		Vector2(right, bottom - cut), Vector2(right - cut, bottom),
		Vector2(x + cut, bottom), Vector2(x, bottom - cut), Vector2(x, y + cut),
	])


func _draw_bevel(rect: Rect2, cut: float, depth: float, face: Color, light: Color, shadow: Color) -> void:
	var outer := _chamfer_points(rect, cut)
	var inner := _chamfer_points(rect.grow(-depth), maxf(0.5, cut - depth))
	draw_colored_polygon(outer, shadow)
	draw_colored_polygon(PackedVector2Array([outer[7], outer[0], outer[1], outer[2], inner[2], inner[1], inner[0], inner[7]]), light)
	draw_colored_polygon(inner, face)


func _draw_fill(channel: Rect2, ratio: float, base: Color, shine: Color, shadow: Color, square_end := false) -> void:
	if ratio <= 0.0:
		return
	var fill := Rect2(channel.position, Vector2(maxf(1.0, roundf(channel.size.x * ratio)), channel.size.y))
	if fill.size.x < 5.0:
		draw_rect(fill, base)
		return
	var depth := minf(2.0, channel.size.y * 0.22)
	_draw_bevel(fill, 3.0, depth, base, shine, shadow)
	if square_end:
		var join := Rect2(fill.end.x - 3.0, fill.position.y, 3.0, fill.size.y)
		draw_rect(join, shadow)
		draw_rect(Rect2(join.position, Vector2(join.size.x, depth)), shine)
		draw_rect(Rect2(join.position + Vector2(0.0, depth), Vector2(join.size.x, join.size.y - depth * 2.0)), base)
	if fill.size.x > 7.0:
		draw_line(fill.position + Vector2(4.0, 2.0), Vector2(fill.end.x - 3.0, fill.position.y + 2.0), shine.lightened(0.14), 1.0)
