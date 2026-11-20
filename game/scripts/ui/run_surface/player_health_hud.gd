extends Control

const PORTRAIT := preload("res://assets/ui/run_vector/raccoon_hud_portrait.png")
const SkinKit := preload("res://scripts/presentation/art10_ui_skin_kit.gd")
const PAUSE_SECONDS := 0.24
const CATCH_UP_SECONDS := 0.46
const WARM_WHITE := Color("#f3e6c9")

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
var _number: Label
var _maximum_label: Label
var _power: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
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
	var strength := "战力 %d" % power
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
	var face_size := floorf(clampf(size.y - 3.0, 24.0, 60.0))
	_portrait_rect = Rect2(0.0, floorf((size.y - face_size) * 0.5), face_size, face_size)
	var text_x := _portrait_rect.end.x + 8.0
	var digits_width := clampf(size.x * 0.44, 88.0, 130.0)
	var number_x := size.x - digits_width
	var track_y := roundf(size.y * 0.27)
	var channel_height := clampf(roundf(size.y * 0.25), 9.0, 15.0)
	_track = Rect2(text_x, track_y, maxf(0.0, number_x - text_x - 5.0), channel_height)
	_number_area = Rect2(number_x, 0.0, digits_width, _track.end.y - 1.0)
	_fit_health_number()
	var power_font := clampi(roundi(size.y * 0.32), 12, 18)
	_power.add_theme_font_size_override(&"font_size", power_font)
	_power.position = Vector2(text_x, _track.end.y + 1.0)
	_power.size = Vector2(maxf(1.0, size.x - text_x), _power.get_minimum_size().y)
	queue_redraw()

func _fit_health_number() -> void:
	var current_font := _number.get_theme_font(&"font")
	var maximum_font := _maximum_label.get_theme_font(&"font")
	var current_text := str(_health)
	var current_size := clampi(roundi(size.y * 0.43), 16, 30)
	var maximum_size := maxi(11, roundi(current_size * 0.52))
	var gap := 3.0
	var current_width := _text_width(current_font, current_text, current_size)
	var maximum_width := _text_width(maximum_font, _maximum_label.text, maximum_size)
	# Measure both native glyph runs because their font sizes and advances differ.
	while current_width + maximum_width + gap > _number_area.size.x and current_size > 10:
		current_size -= 1
		maximum_size = maxi(11, roundi(current_size * 0.55))
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
	draw_texture_rect(PORTRAIT, _portrait_rect, false)
	draw_rect(_track, Color("#203136"))
	draw_rect(_track, Color("#755e4c"), false, 1.0)
	var channel := _track.grow(-1.0)
	var damage_visible := roundf(channel.size.x * _white_ratio) > roundf(channel.size.x * _ratio)
	if damage_visible:
		_draw_fill(channel, _white_ratio, WARM_WHITE, Color("#fff9e5"), Color("#9c9074"))
	var red := Color("#b94139") if _ratio > 0.25 else Color("#ff4f42")
	_draw_fill(channel, _ratio, red, Color("#e17c60"), Color("#811820"), damage_visible)

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
