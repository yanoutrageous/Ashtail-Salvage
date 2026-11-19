extends RefCounted
## A run-owned arsenal. The combat simulator still owns every attack and hit.

const AXE := &"axe"
const RIFLE := &"rifle"
const SCATTER := &"scattergun"
const INITIAL_RESERVE := 24
const AXE_PROFILE := {"name": "战斧", "rarity": &"common"}
const RARITY_ORDER := [&"common", &"uncommon", &"rare", &"epic", &"legendary"]
const PROFILES := {
	RIFLE: {
		"name": "回收卡宾枪", "rarity": &"rare",
		"range": 0.59, "magazine": 6, "reload": 0.88, "cooldown": 0.48, "power": 1.00, "rays": [0.0],
		"passive": {"name": "战术装填", "description": "弹匣还有子弹时，装填用时减少 30%。", "reload_multiplier": 0.70},
		"skill": {
			"id": &"piercing_shot", "name": "穿甲点射", "description": "射出一发穿甲弹，最多命中直线上的三名敌人。掩体会挡住子弹。",
			"ammo_cost": 2, "cooldown_seconds": 5.5, "range": 0.74, "power": 1.55, "rays": [0.0], "penetration": 3,
		},
	},
	SCATTER: {
		"name": "岩盐霰弹枪", "rarity": &"epic",
		"range": 0.41, "magazine": 3, "reload": 1.21, "cooldown": 0.76, "power": 0.44, "rays": [-0.16, -0.08, 0.0, 0.08, 0.16],
		"passive": {"name": "贴身重创", "description": "近距离命中的弹丸伤害提高 20%。", "close_power_multiplier": 1.20},
		"skill": {
			"id": &"sweeping_volley", "name": "横扫齐射", "description": "向前方更宽的扇面发射九枚弹丸。",
			"ammo_cost": 2, "cooldown_seconds": 7.0, "range": 0.48, "power": 0.54,
			"rays": [-0.48, -0.36, -0.24, -0.12, 0.0, 0.12, 0.24, 0.36, 0.48],
		},
	},
}


static func initial_state() -> Dictionary:
	return {
		"selected": AXE, "reserve": INITIAL_RESERVE,
		"magazines": {String(RIFLE): 6, String(SCATTER): 3}, "reload": 0.0,
		"skill_cooldowns": {}, "field_attack_cooldown": 0.0,
	}


static func valid(state: Variant) -> bool:
	if not state is Dictionary:
		return false
	var allowed_count := 4 + int(state.has("skill_cooldowns")) + int(state.has("field_attack_cooldown"))
	if state.size() != allowed_count:
		return false
	if not valid_weapon(state.get("selected")):
		return false
	var reserve = state.get("reserve")
	var reload = state.get("reload")
	var magazines = state.get("magazines")
	if not reserve is int or reserve < 0 or not reload is float or not is_finite(reload) or reload < 0.0:
		return false
	if not magazines is Dictionary or magazines.size() != PROFILES.size():
		return false
	for weapon in PROFILES:
		var rounds = magazines.get(String(weapon))
		if not rounds is int or rounds < 0 or rounds > int(PROFILES[weapon]["magazine"]):
			return false
	var cooldowns: Variant = state.get("skill_cooldowns", {})
	if not cooldowns is Dictionary or not _valid_cooldown(state.get("field_attack_cooldown", 0.0)):
		return false
	for weapon in cooldowns:
		if not (weapon is String and valid_weapon(weapon)) or skill(StringName(weapon)).is_empty():
			return false
		if not _valid_cooldown(cooldowns[weapon]):
			return false
	return true


static func valid_weapon(weapon: Variant) -> bool:
	return (weapon is String or weapon is StringName) and StringName(weapon) in [AXE, RIFLE, SCATTER]


static func _valid_cooldown(value: Variant) -> bool:
	return value is float and is_finite(value) and value >= 0.0


static func profile(weapon: StringName) -> Dictionary:
	return PROFILES.get(weapon, AXE_PROFILE)


static func passive(weapon: StringName) -> Dictionary:
	var data := profile(weapon)
	return data.get("passive", {}) if RARITY_ORDER.find(data["rarity"]) >= RARITY_ORDER.find(&"uncommon") else {}


static func skill(weapon: StringName) -> Dictionary:
	var data := profile(weapon)
	return data.get("skill", {}) if RARITY_ORDER.find(data["rarity"]) >= RARITY_ORDER.find(&"rare") else {}


static func skill_matches(weapon: StringName, skill_id: Variant) -> bool:
	return (skill_id is String or skill_id is StringName) and not String(skill_id).is_empty() and skill(weapon).get("id") == StringName(skill_id)


static func shot_profile(weapon: StringName, use_skill: bool) -> Dictionary:
	return skill(weapon) if use_skill else PROFILES.get(weapon, {})


static func ray_contract(weapon: StringName, use_skill: bool) -> Dictionary:
	var shot := shot_profile(weapon, use_skill)
	var rays: Array = shot["rays"]
	var half_angle := maxf(absf(float(rays.front())), absf(float(rays.back())))
	var geometry := {
		"weapon": weapon, "shape": &"rays", "range": shot["range"],
		"half_angle_radians": half_angle, "cone_dot": cos(half_angle),
	}
	if use_skill:
		geometry["skill_id"] = shot["id"]
		geometry["skill_name"] = shot["name"]
	return geometry
