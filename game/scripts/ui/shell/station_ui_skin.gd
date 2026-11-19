extends RefCounted
## Shared presentation for the front menu and deployment room.

const FONT := preload("res://assets/fonts/NotoSansCJKsc-Regular.otf")
const INK := Color("#e6eeeb")
const MUTED := Color("#a9bfc3")
const JADE := Color("#86cbc7")
const BRASS := Color("#e9bd76")
const SURFACE := Color("#121f27")
const EDGE := Color("#3e5960")
const DEEP := Color("#0b131b")
const PLATE := preload("res://assets/ui/run_vector/frame_panel.svg")
const RAIL := preload("res://assets/ui/run_vector/frame_rail.svg")
const STATUS := preload("res://assets/ui/run_vector/frame_status.svg")
const ALERT := preload("res://assets/ui/run_vector/frame_alert.svg")
const BUTTONS := {
	&"normal": preload("res://assets/ui/run_vector/button_normal.svg"),
	&"hover": preload("res://assets/ui/run_vector/button_hover.svg"),
	&"selected": preload("res://assets/ui/run_vector/button_selected.svg"),
	&"primary": preload("res://assets/ui/run_vector/button_primary.svg"),
	&"danger": preload("res://assets/ui/run_vector/button_danger.svg"),
	&"disabled": preload("res://assets/ui/run_vector/button_disabled.svg"),
	&"focus": preload("res://assets/ui/run_vector/button_focus.svg"),
	&"slot": preload("res://assets/ui/run_vector/slot_normal.svg"),
}


class Trim extends Control:
	var kind: StringName
	var accent: Color
	var selected := false

	func _ready() -> void:
		resized.connect(queue_redraw)

	func _draw() -> void:
		match kind:
			&"panel":
				_draw_panel()
			&"title":
				_draw_title_rule()
			&"fascia":
				_draw_fascia()
			&"tab":
				var ink := accent if selected else Color("#4a666a")
				draw_rect(Rect2(size.x * 0.5 - 9, size.y - 4, 18, 2), ink)
			_:
				_draw_button()

	func _draw_panel() -> void:
		var muted := accent.lerp(SURFACE, 0.48)
		draw_polyline(PackedVector2Array([Vector2(2, 17), Vector2(2, 8), Vector2(8, 2), Vector2(34, 2)]), accent, 1.5, true)
		draw_polyline(PackedVector2Array([size - Vector2(2, 17), size - Vector2(2, 8), size - Vector2(8, 2), size - Vector2(34, 2)]), accent, 1.5, true)
		_draw_rivet(Vector2(size.x - 8, 8), muted)
		_draw_rivet(Vector2(8, size.y - 8), muted)
		for index in range(3):
			var start := Vector2(size.x - 26 + 4 * index, size.y - 7)
			draw_line(start, start + Vector2(3, -4), muted, 1, true)

	func _draw_rivet(center: Vector2, ink: Color) -> void:
		draw_circle(center, 2.2, ink, false, 1, true)
		draw_line(center + Vector2(-1.0, 1.0), center + Vector2(1.0, -1.0), ink, 1, true)

	func _draw_title_rule() -> void:
		draw_line(Vector2(18, 7), Vector2(size.x, 7), Color("#4a666a"), 1, true)
		draw_line(Vector2(19, 7), Vector2(72, 7), accent, 2, true)
		draw_colored_polygon(PackedVector2Array([Vector2(0, 7), Vector2(7, 0), Vector2(14, 7), Vector2(7, 14)]), accent)
		draw_colored_polygon(PackedVector2Array([Vector2(4, 7), Vector2(7, 4), Vector2(10, 7), Vector2(7, 10)]), DEEP)
		for index in range(3):
			var start := Vector2(size.x - 14 + 4 * index, 10)
			draw_line(start, start + Vector2(3, -6), accent, 1, true)

	func _draw_fascia() -> void:
		draw_line(Vector2(18, 6), Vector2(size.x - 18, 6), Color("#527681"), 1, true)
		draw_line(Vector2(18, 9), Vector2(size.x - 18, 9), Color("#243e49"), 1, true)
		_draw_rivet(Vector2(9, 6), accent)
		_draw_rivet(Vector2(size.x - 9, 6), accent)
		for index in range(5):
			var x := size.x - 49 + index * 5
			draw_line(Vector2(x, 13), Vector2(x + 4, 2), Color(accent, 0.55), 2, true)

	func _draw_button() -> void:
		var center := Vector2(26, floorf(size.y / 2))
		draw_line(center + Vector2(16, -10), center + Vector2(16, 10), Color(accent, 0.40), 1)
		match kind:
			&"launch":
				_draw_chevron(center - Vector2(4, 0))
				_draw_chevron(center + Vector2(2, 0))
				_draw_rivet(Vector2(size.x - 12, size.y - 11), accent)
				draw_line(Vector2(6, size.y - 5), Vector2(size.x - 24, size.y - 5), Color(accent, 0.5), 1)
			&"archive":
				draw_rect(Rect2(center - Vector2(7, 6), Vector2(14, 12)), accent, false, 1.25)
				draw_line(center + Vector2(-7, -1), center + Vector2(7, -1), accent, 1)
				draw_line(center + Vector2(-2, 2), center + Vector2(2, 2), accent, 1)
			&"settings":
				for index in range(3):
					var start := center + Vector2(-7, -5 + index * 5)
					draw_line(start, start + Vector2(14, 0), accent, 1)
					draw_circle(start + Vector2(4 + (index % 2) * 5, 0), 1.8, accent, true, -1, true)
			&"exit":
				draw_polyline(PackedVector2Array([center + Vector2(0, -7), center + Vector2(-7, -7), center + Vector2(-7, 7), center + Vector2(0, 7)]), accent, 1.25, true)
				draw_line(center + Vector2(-3, 0), center + Vector2(7, 0), accent, 1.25, true)
				_draw_chevron(center + Vector2(3, 0))

	func _draw_chevron(center: Vector2) -> void:
		draw_polyline(PackedVector2Array([center + Vector2(-3, -5), center + Vector2(2, 0), center + Vector2(-3, 5)]), accent, 1.5, true)


static func add_trim(parent: Control, kind: StringName, accent: Color, rect := Rect2()) -> void:
	var trim := Trim.new()
	trim.name = "StationTrim"
	trim.kind = kind
	trim.accent = accent
	trim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(trim)
	if rect.has_area():
		trim.position = rect.position
		trim.size = rect.size
	else:
		trim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


static func add_plate(parent: Control, node_name: String, rect: Rect2, texture: Texture2D = PLATE) -> NinePatchRect:
	var patch := NinePatchRect.new()
	patch.name = node_name
	patch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	patch.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	patch.texture = texture
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		patch.set_patch_margin(side, 12)
	patch.position = rect.position
	patch.size = rect.size
	parent.add_child(patch)
	return patch


static func panel(fill: Color = SURFACE, border: Color = EDGE) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(1)
	box.set_corner_radius_all(3)
	box.content_margin_left = 10
	box.content_margin_right = 10
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	return box


static func style_button(button: Button, emphasis: StringName = &"normal", state: StringName = &"normal", left: float = 10, right: float = 10) -> void:
	var fill := SURFACE
	var border := EDGE
	var ink := INK
	if emphasis == &"primary":
		fill = Color("#b98140")
		border = BRASS
		ink = Color("#10171a")
	elif emphasis == &"danger":
		fill = Color("#34252a")
		border = Color("#805250")
		ink = Color("#ffd6c8")
	if state == &"selected":
		fill = Color("#21434a")
		border = JADE
		ink = Color.WHITE
	elif state == &"locked":
		fill = DEEP
		border = Color("#30424a")
		ink = MUTED
	var focus := panel(Color.TRANSPARENT, BRASS)
	focus.draw_center = false
	focus.set_border_width_all(2)
	button.add_theme_font_override("font", FONT)
	button.add_theme_stylebox_override("normal", _button_box(fill, border, left, right))
	button.add_theme_stylebox_override("hover", _button_box(fill.lightened(0.08), border.lightened(0.22), left, right))
	button.add_theme_stylebox_override("pressed", _button_box(fill.lightened(0.12), JADE, left, right))
	button.add_theme_stylebox_override("hover_pressed", _button_box(fill.lightened(0.12), JADE, left, right))
	button.add_theme_stylebox_override("disabled", _button_box(DEEP, Color("#30424a"), left, right))
	button.add_theme_stylebox_override("focus", focus)
	for token in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color", "font_hover_pressed_color"]:
		button.add_theme_color_override(token, ink)
	button.add_theme_color_override("font_disabled_color", Color("#91a4aa"))
	button.add_theme_constant_override("outline_size", 0)
	var trim := button.get_node_or_null("StationTrim") as Trim
	if trim != null and trim.kind == &"tab":
		trim.selected = state == &"selected"
		trim.queue_redraw()


static func _button_box(fill: Color, border: Color, left: float, right: float) -> StyleBoxFlat:
	var box := panel(fill, border)
	box.content_margin_left = left
	box.content_margin_right = right
	return box


static func apply_label(label: Label, color: Color) -> void:
	label.add_theme_font_override("font", FONT)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 0)
	label.add_theme_color_override("font_shadow_color", Color.TRANSPARENT)

