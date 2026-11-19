extends PanelContainer

signal weapon_requested(weapon: StringName)
signal reload_requested

const RunVectorSkin := preload("res://scripts/ui/run_surface/run_vector_skin.gd")
const FieldWeapons := preload("res://scripts/gameplay/combat/field_weapons.gd")
const ItemRarity := preload("res://scripts/presentation/item_rarity_descriptor.gd")
const SkinKit := preload("res://scripts/presentation/art10_ui_skin_kit.gd")
const WEAPON_KEYS := {
	FieldWeapons.AXE: "1 战斧",
	FieldWeapons.RIFLE: "2 卡宾",
	FieldWeapons.SCATTER: "3 霰弹",
}
const TEXT := Color("#eee2c3")
const WARNING := Color("#f4a195")
const GOLD := Color("#ecc780")

var weapon_name: Label
var weapon_rarity: Label
var weapon_icon: TextureRect
var ammunition: Label
var passive_name: Label
var skill_hint: Label
var reload_button: Button
var weapon_buttons: Dictionary = {}
var details: VBoxContainer
var last_projection: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override(&"panel", RunVectorSkin.frame(RunVectorSkin.STATUS, Vector4(10, 6, 10, 6)))

	details = VBoxContainer.new()
	details.name = "Details"
	details.mouse_filter = Control.MOUSE_FILTER_IGNORE
	details.add_theme_constant_override(&"separation", 2)
	add_child(details)
	var heading := HBoxContainer.new()
	heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	details.add_child(heading)
	weapon_icon = TextureRect.new()
	weapon_icon.name = "CurrentWeaponIcon"
	weapon_icon.texture = RunVectorSkin.WEAPON_ICONS[FieldWeapons.AXE]
	weapon_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	weapon_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	weapon_icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	weapon_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	heading.add_child(weapon_icon)
	weapon_name = _add_label("WeaponName", GOLD, heading)
	weapon_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	weapon_rarity = _add_label("WeaponRarity", TEXT, heading)
	var weapon_stats := HBoxContainer.new()
	weapon_stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	details.add_child(weapon_stats)
	ammunition = _add_label("WeaponAmmunition", TEXT, weapon_stats)
	ammunition.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	passive_name = _add_label("WeaponPassive", GOLD, weapon_stats)
	passive_name.mouse_filter = Control.MOUSE_FILTER_PASS
	var actions := HBoxContainer.new()
	actions.name = "WeaponActions"
	actions.add_theme_constant_override(&"separation", 6)
	actions.mouse_filter = Control.MOUSE_FILTER_IGNORE
	details.add_child(actions)
	skill_hint = _add_label("WeaponSkill", TEXT, actions)
	skill_hint.mouse_filter = Control.MOUSE_FILTER_PASS
	skill_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	skill_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	reload_button = Button.new()
	reload_button.name = "ReloadWeapon"
	reload_button.pressed.connect(func() -> void: reload_requested.emit())
	RunVectorSkin.set_icon(reload_button, RunVectorSkin.RELOAD)
	actions.add_child(reload_button)

	var slots := HBoxContainer.new()
	slots.add_theme_constant_override(&"separation", 4)
	slots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	details.add_child(slots)
	var group := ButtonGroup.new()
	for weapon: StringName in WEAPON_KEYS:
		var button := Button.new()
		button.name = "Weapon_%s" % weapon
		button.text = WEAPON_KEYS[weapon]
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.toggle_mode = true
		button.button_group = group
		button.pressed.connect(_request_weapon.bind(weapon))
		slots.add_child(button)
		weapon_buttons[weapon] = button
	apply_scale(1.0)


func _request_weapon(weapon: StringName) -> void:
	if not last_projection.is_empty() and last_projection[0] == weapon:
		return
	last_projection.clear()
	weapon_requested.emit(weapon)


func apply_scale(scale_factor: float) -> void:
	weapon_icon.custom_minimum_size = Vector2.ONE * roundf(18.0 * scale_factor)
	weapon_name.add_theme_font_size_override(&"font_size", SkinKit.scaled_font_size(16, scale_factor))
	weapon_rarity.add_theme_font_size_override(&"font_size", SkinKit.scaled_font_size(12, scale_factor))
	ammunition.add_theme_font_size_override(&"font_size", SkinKit.scaled_font_size(13, scale_factor))
	passive_name.add_theme_font_size_override(&"font_size", SkinKit.scaled_font_size(12, scale_factor))
	skill_hint.add_theme_font_size_override(&"font_size", SkinKit.scaled_font_size(12, scale_factor))
	var font_size := SkinKit.scaled_font_size(13, scale_factor)
	for button: Button in weapon_buttons.values():
		_style_button(button, font_size)
	_style_button(reload_button, font_size)


func apply_runtime_snapshot(snapshot: Dictionary) -> void:
	var loadout: Dictionary = snapshot.get("field_weapons", {})
	if loadout.is_empty():
		return
	var weapon := StringName(loadout.get("selected", FieldWeapons.AXE))
	var profile := FieldWeapons.profile(weapon)
	var rounds := int(loadout.get("magazines", {}).get(String(weapon), 0))
	var reserve := int(loadout.get("reserve", 0))
	var capacity := int(profile.get("magazine", 0))
	var reload_ticks := ceili(float(loadout.get("reload", 0.0)) * 10.0)
	var busy := bool(snapshot.get("field_weapon_busy", false))
	var skill_state: Dictionary = snapshot.get("field_skill", {})
	var skill_ticks := ceili(float(skill_state.get("cooldown", 0.0)) * 10.0)
	var skill_block := StringName(skill_state.get("block", &""))
	var projection := [weapon, rounds, reserve, reload_ticks, busy, skill_ticks, skill_block]
	if projection == last_projection:
		return
	last_projection = projection

	var rarity := ItemRarity.describe(profile["rarity"])
	weapon_name.text = String(profile["name"])
	weapon_rarity.text = String(rarity["label"])
	weapon_rarity.add_theme_color_override(&"font_color", Color(rarity["color"]))
	weapon_icon.texture = RunVectorSkin.WEAPON_ICONS[weapon]
	ammunition.text = "近战 · 无需弹药" if capacity == 0 else "弹匣 %d / %d  备弹 %d" % [rounds, capacity, reserve]
	ammunition.add_theme_color_override(&"font_color", WARNING if capacity > 0 and rounds == 0 else TEXT)
	_apply_trait_hint(weapon, skill_block, skill_ticks)
	reload_button.visible = capacity > 0
	reload_button.disabled = busy or rounds >= capacity or reserve == 0
	if reload_ticks > 0:
		reload_button.text = "装填中 %.1fs" % (reload_ticks / 10.0)
	elif reserve == 0 and rounds < capacity:
		reload_button.text = "无备弹"
	elif rounds >= capacity:
		reload_button.text = "弹匣满"
	elif busy:
		reload_button.text = "恢复中"
	elif rounds == 0:
		reload_button.text = "R 空弹"
	else:
		reload_button.text = "R 装填"
	for option: StringName in weapon_buttons:
		var button: Button = weapon_buttons[option]
		button.set_pressed_no_signal(option == weapon)
		button.disabled = busy and option != weapon


func _apply_trait_hint(weapon: StringName, skill_block: StringName, skill_ticks: int) -> void:
	var passive := FieldWeapons.passive(weapon)
	passive_name.visible = not passive.is_empty()
	passive_name.text = String(passive.get("name", ""))
	passive_name.tooltip_text = "" if passive.is_empty() else "被动  %s\n%s" % [passive["name"], passive["description"]]
	var ability := FieldWeapons.skill(weapon)
	if ability.is_empty():
		skill_hint.text = "无主动技能"
		skill_hint.tooltip_text = ""
		skill_hint.add_theme_color_override(&"font_color", TEXT)
		return
	var status := "  %d 发" % int(ability["ammo_cost"])
	match skill_block:
		&"cooldown":
			status = "  %.1f 秒" % (skill_ticks / 10.0)
		&"ammo":
			status = "  缺弹"
		&"busy":
			status = ""
	skill_hint.text = "K  %s%s" % [ability["name"], status]
	skill_hint.tooltip_text = "按 K 或在房间内点鼠标右键。\n%s  消耗 %d 发，冷却 %.1f 秒。" % [
		ability["description"], ability["ammo_cost"], ability["cooldown_seconds"],
	]
	skill_hint.add_theme_color_override(&"font_color", GOLD if skill_block == &"" else TEXT)


func _add_label(node_name: String, color: Color, parent: Container = null) -> Label:
	var label := Label.new()
	label.name = node_name
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override(&"font_color", color)
	(details if parent == null else parent).add_child(label)
	return label


func _style_button(button: Button, font_size: int) -> void:
	SkinKit.apply_button(button, &"secondary", font_size)
	RunVectorSkin.apply_button(button, Vector4(5, 2, 5, 2))
	button.add_theme_color_override(&"font_color", TEXT)
	button.add_theme_color_override(&"font_pressed_color", Color("#d3f1e1"))
	button.add_theme_color_override(&"font_disabled_color", Color("#c3a29b"))
