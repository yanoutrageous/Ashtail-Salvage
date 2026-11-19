extends Control

const SkinKit := preload("res://scripts/presentation/art10_ui_skin_kit.gd")
const PROFILES := {
	&"directional_guard": {"name": "闸门工偶", "cue": "正面重甲  ·  等待收招", "color": Color("#e9a15d"), "icon": &"fists", "scale": 2.04},
	&"four_way_laser": {"name": "四路配电桩", "cue": "四向光束  ·  避开轴线", "color": Color("#78d6e8"), "icon": &"coil", "scale": 1.65},
	&"magnetic_pull": {"name": "磁拖回收机", "cue": "磁力牵引  ·  远离核心", "color": Color("#d7a0ec"), "icon": &"magnet", "scale": 1.65},
}

const REVEAL_SECONDS := 0.22
const RETRACT_SECONDS := 0.20
const HOLD_SECONDS := 0.48
const TOTAL_SECONDS := REVEAL_SECONDS + RETRACT_SECONDS + HOLD_SECONDS

var _elapsed := 0.0
var _profile: Dictionary = {}
var _encounter := ""
var _opening := 0.0
var _title: Label
var _cue: Label
var _plate := Rect2()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title = _make_label(25, Color("#fff0d6"))
	_cue = _make_label(13, Color("#c8dbdd"))
	hide()


func try_begin(snapshot: Dictionary) -> bool:
	if _title == null or not snapshot.get("active", false) or int(snapshot.get("tick", -1)) != 0:
		return false
	var encounter := str(snapshot.get("encounter_id", ""))
	if encounter.is_empty() or encounter == _encounter:
		return false
	for enemy: Dictionary in snapshot.get("enemies", []):
		var behavior := StringName(enemy.get("behavior_id", &""))
		if not PROFILES.has(behavior) or int(enemy.get("hp", 0)) <= 0:
			continue
		_profile = PROFILES[behavior]
		_encounter = encounter
		_elapsed = 0.0
		_title.text = _profile["name"]
		_cue.text = "首领出现  /  " + str(_profile["cue"])
		show()
		advance(0.0)
		return true
	return false


func is_active() -> bool:
	return visible and not _profile.is_empty()


func cancel() -> void:
	hide()


func advance(delta: float) -> void:
	_elapsed += maxf(0.0, delta)
	if _elapsed >= TOTAL_SECONDS:
		hide()
		return
	var reveal := smoothstep(0.0, REVEAL_SECONDS, _elapsed)
	var retract := 1.0 - smoothstep(TOTAL_SECONDS - RETRACT_SECONDS, TOTAL_SECONDS, _elapsed)
	_opening = reveal * retract
	var width := clampf(size.x * 0.70, 168.0, 364.0)
	var height := 57.0
	_plate = Rect2((size.x - width) * 0.5, maxf(22.0, size.y * 0.16) - (1.0 - _opening) * 15.0, width, height)
	modulate.a = _opening
	var text_x := _plate.position.x + 67.0
	_title.position = Vector2(text_x, _plate.position.y + 5.0)
	_cue.position = Vector2(text_x, _plate.position.y + 34.0)
	_title.add_theme_font_size_override(&"font_size", 21 if width < 250.0 else 25)
	_cue.add_theme_font_size_override(&"font_size", 11 if width < 250.0 else 13)
	queue_redraw()


func _draw() -> void:
	if _profile.is_empty() or _opening <= 0.0:
		return
	var ink: Color = _profile["color"]
	_draw_plate(_plate.grow(2.0), Color("#101318"), 12.0)
	_draw_plate(_plate, ink.darkened(0.38), 11.0)
	_draw_plate(_plate.grow(-2.0), Color("#31424a"), 10.0)
	_draw_plate(_plate.grow(-4.0), Color("#17252d"), 9.0)
	var upper := _plate.position + Vector2(13.0, 3.0)
	draw_line(upper, Vector2(_plate.end.x - 14.0, upper.y), ink.lightened(0.23), 1.0)
	draw_line(Vector2(_plate.position.x + 61.0, _plate.position.y + 8.0),
		Vector2(_plate.position.x + 61.0, _plate.end.y - 8.0), ink.darkened(0.26), 1.0)
	draw_rect(Rect2(_plate.position.x + 12.0, _plate.end.y - 10.0, 3.0, 3.0), ink)
	draw_rect(Rect2(_plate.end.x - 15.0, _plate.end.y - 10.0, 3.0, 3.0), ink)
	_draw_mark(_plate.position + Vector2(35.0, 28.0), ink)
	var split := (1.0 - _opening) * 24.0
	for side in [-1.0, 1.0]:
		var edge := _plate.get_center() + Vector2(side * (_plate.size.x * 0.5 + split), -7.0)
		draw_polyline(PackedVector2Array([edge + Vector2(side * 18, -12), edge + Vector2(side * 8, -12),
			edge + Vector2(side * 3, -6), edge]), ink, 1.5)


func _make_label(font_size: int, tint: Color) -> Label:
	var label := Label.new()
	SkinKit.apply_label(label, font_size, tint)
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	return label


func _draw_plate(box: Rect2, tint: Color, corner: float) -> void:
	var p := box.position
	var q := box.end
	draw_colored_polygon(PackedVector2Array([p + Vector2(corner, 0), Vector2(q.x - corner, p.y),
		Vector2(q.x, p.y + corner), q - Vector2(0, corner), q - Vector2(corner, 0),
		Vector2(p.x + corner, q.y), Vector2(p.x, q.y - corner), p + Vector2(0, corner)]), tint)


func _draw_mark(center: Vector2, tint: Color) -> void:
	match _profile["icon"]:
		&"fists":
			for dx in [-9.0, 9.0]:
				var p := center + Vector2(dx, -2.0)
				_draw_plate(Rect2(p - Vector2(7, 8), Vector2(14, 17)), tint, 3.0)
				draw_rect(Rect2(p - Vector2(5, 6), Vector2(10, 4)), tint.lightened(0.27))
				draw_rect(Rect2(p + Vector2(-4, 8), Vector2(8, 4)), tint.darkened(0.36))
		&"coil":
			var ends := [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]
			for direction: Vector2 in ends:
				draw_line(center + direction * 4.0, center + direction * 14.0, tint, 3.0)
			_draw_plate(Rect2(center - Vector2(7, 7), Vector2(14, 14)), tint.lightened(0.26), 4.0)
		&"magnet":
			for dx in [-10.0, 6.0]:
				draw_rect(Rect2(center + Vector2(dx, -10), Vector2(4, 18)), tint)
				draw_rect(Rect2(center + Vector2(dx, -10), Vector2(4, 5)), tint.lightened(0.35))
			draw_rect(Rect2(center + Vector2(-10, 5), Vector2(20, 5)), tint.darkened(0.24))
