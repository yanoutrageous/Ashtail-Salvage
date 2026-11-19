extends RefCounted
## SVG skin for the deployed run and its panels.

const SkinKit := preload("res://scripts/presentation/art10_ui_skin_kit.gd")
const FRAME_SLICE := 12.0
const BUTTON_SLICE := 9.0
const ICON_SIZE := 16
const STATUS := preload("res://assets/ui/run_vector/frame_status.svg")
const PANEL := preload("res://assets/ui/run_vector/frame_panel.svg")
const RAIL := preload("res://assets/ui/run_vector/frame_rail.svg")
const ALERT_FRAME := preload("res://assets/ui/run_vector/frame_alert.svg")
const HEALTH := preload("res://assets/ui/run_vector/icon_health.svg")
const PRESSURE := preload("res://assets/ui/run_vector/icon_pressure.svg")
const ALERT := preload("res://assets/ui/run_vector/icon_alert.svg")
const RELOAD := preload("res://assets/ui/run_vector/icon_reload.svg")
const CLOSE := preload("res://assets/ui/run_vector/icon_close.svg")
const MAP := preload("res://assets/ui/run_vector/icon_map.svg")
const BAG := preload("res://assets/ui/run_vector/icon_backpack.svg")
const ROUTE := preload("res://assets/ui/run_vector/icon_map_exit.svg")
const BUTTON_TEXTURES := {
	&"normal": preload("res://assets/ui/run_vector/button_normal.svg"),
	&"hover": preload("res://assets/ui/run_vector/button_hover.svg"),
	&"selected": preload("res://assets/ui/run_vector/button_selected.svg"),
	&"disabled": preload("res://assets/ui/run_vector/button_disabled.svg"),
	&"focus": preload("res://assets/ui/run_vector/button_focus.svg"),
	&"primary": preload("res://assets/ui/run_vector/button_primary.svg"),
	&"danger": preload("res://assets/ui/run_vector/button_danger.svg"),
	&"slot": preload("res://assets/ui/run_vector/slot_normal.svg"),
}
const MAP_TILES := {
	&"unknown": preload("res://assets/ui/run_vector/map_tile_unknown.svg"),
	&"scanned": preload("res://assets/ui/run_vector/map_tile_scanned.svg"),
	&"explored": preload("res://assets/ui/run_vector/map_tile_explored.svg"),
	&"selected": preload("res://assets/ui/run_vector/map_tile_selected.svg"),
	&"danger": preload("res://assets/ui/run_vector/map_tile_danger.svg"),
	&"flagged": preload("res://assets/ui/run_vector/map_tile_flagged.svg"),
	&"player": preload("res://assets/ui/run_vector/map_tile_player.svg"),
}
const MAP_SYMBOLS := {
	&"player": preload("res://assets/ui/run_vector/icon_map_player.svg"),
	&"exit": preload("res://assets/ui/run_vector/icon_map_exit.svg"),
	&"flagged": preload("res://assets/ui/run_vector/icon_map_flag.svg"),
	&"mine": preload("res://assets/ui/run_vector/icon_alert.svg"),
	&"monster": preload("res://assets/ui/run_vector/icon_map_monster.svg"),
	&"chest": preload("res://assets/ui/run_vector/icon_map_chest.svg"),
	&"event": preload("res://assets/ui/run_vector/icon_map_event.svg"),
}
const WEAPON_ICONS := {
	&"axe": preload("res://assets/ui/run_vector/icon_axe.svg"),
	&"rifle": preload("res://assets/ui/run_vector/icon_rifle.svg"),
	&"scattergun": preload("res://assets/ui/run_vector/icon_scattergun.svg"),
}

static func frame(texture: Texture2D, insets: Vector4) -> StyleBoxTexture:
	return SkinKit.style_box_from_texture_with_insets(texture, insets, Vector4.ONE * FRAME_SLICE)


static func apply_button(button: Button, insets: Vector4, normal: StringName = &"normal") -> void:
	button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	for state: StringName in [&"normal", &"hover", &"pressed", &"hover_pressed", &"disabled", &"focus"]:
		var token := state
		match state:
			&"normal":
				token = normal
			&"pressed", &"hover_pressed":
				token = &"selected"
		var texture: Texture2D = BUTTON_TEXTURES[token]
		button.add_theme_stylebox_override(state, SkinKit.style_box_from_texture_with_insets(
			texture, insets, Vector4.ONE * BUTTON_SLICE
		))


static func set_icon(button: Button, texture: Texture2D, width: int = ICON_SIZE) -> void:
	button.icon = texture
	button.expand_icon = true
	button.add_theme_constant_override(&"icon_max_width", width)


static func map_tile(state: StringName) -> Texture2D:
	match state:
		&"mine", &"monster":
			return MAP_TILES[&"danger"]
		&"event":
			return MAP_TILES[&"flagged"]
	return MAP_TILES.get(state, MAP_TILES[&"explored"])


static func map_symbol(state: StringName) -> Texture2D:
	return MAP_SYMBOLS.get(state)

