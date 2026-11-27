extends RefCounted
class_name Z2TalentCatalog

const CATALOG_VERSION := 2
const TALENT_FLAG_MARKING := "z2_talent_01"
const SOURCE_SHA256 := "db630e72cb711b07ee75160b75ab4445a92b232b899390ed36e909389c299a6b"

# S1 / 05 天赋树与节点, sheet rows 11–49. IDs are sheet row minus 10.
# name, cost, AND parent numbers, effect kind, amount, label, compound parameters.
# Percent amounts are percentage units (5 means 5%, not a multiplier of 5).
# Descriptors are not runtime handlers; opening batches grant eligibility only.
const NODES := [
	["插旗标记", 100, [], &"flag_marking", 1, "可在小地图为房间插旗；进入已插旗房间须再次确认", {"confirm_flagged_entry": true}],
	["背包容量Ⅰ", 10, [1], &"backpack_capacity", 5, "背包容量＋5", {}],
	["初始战力Ⅰ", 10, [1], &"initial_power", 2, "开局战力＋2", {}],
	["最大生命Ⅰ", 10, [1], &"max_hp", 10, "生命上限＋10", {}],
	["首次增压豁免", 30, [2, 3], &"first_pressure_waiver", 1, "首次单次增压达到10点时免除该次增压，每局触发1次", {"threshold": 10, "charges_per_run": 1}],
	["装备负重上限", 10, [5], &"equipment_capacity", 3, "出发时可携带的总重量＋3", {}],
	["普怪成长Ⅰ", 10, [5], &"normal_combat_growth_cap", 3, "普通战斗房提供的战力成长上限＋3", {}],
	["失败抢救容量Ⅰ", 10, [4], &"salvage_capacity", 3, "失败或主动放弃时，可抢救的重量＋3", {}],
	["物理减伤Ⅰ", 10, [8], &"physical_damage_reduction_percent", 5, "外来物理直伤减少5%，每次至少抵挡1点", {"minimum_block": 1}],
	["首次致死保护", 30, [7, 9], &"lethal_protection", 1, "首次受到致死伤害时保留1点生命，每局触发1次", {"charges_per_run": 1}],
	["移动速度Ⅰ", 10, [6], &"movement_speed_percent", 2, "移动速度＋2%", {}],
	["搜索速度Ⅰ", 10, [11], &"search_speed_percent", 10, "搜索速度＋10%", {}],
	["攻击速度Ⅰ", 10, [10], &"attack_speed_percent", 2, "攻击速度＋2%", {}],
	["撤离收入Ⅰ", 10, [10], &"extraction_gold_percent", 5, "成功撤离时，带出黑币兑换的金币＋5%", {}],
	["解锁第一批开局效果", 90, [12, 13, 14], &"opening_effect_batch_unlock", 1, "开放第一批开局效果的选择资格", {"batch": 1}],
	["搜索速度Ⅱ", 30, [15], &"search_speed_percent", 20, "搜索速度＋20%", {}],
	["攻击速度Ⅱ", 30, [15], &"attack_speed_percent", 5, "攻击速度＋5%", {}],
	["撤离收入Ⅱ", 30, [15], &"extraction_gold_percent", 10, "成功撤离时，带出黑币兑换的金币＋10%", {}],
	["消耗品保留", 50, [16, 17], &"consumable_retention", 1, "结算时可保留1件未用消耗品，三种结局均生效；抢救时占10点容量", {"salvage_weight": 10, "all_endings": true}],
	["物理减伤Ⅱ", 30, [18], &"physical_damage_reduction_percent", 10, "外来物理直伤减少10%，每次至少抵挡2点", {"minimum_block": 2}],
	["移动速度Ⅱ", 30, [19], &"movement_speed_percent", 3, "移动速度＋3%", {}],
	["普怪成长Ⅱ", 30, [19], &"normal_combat_growth_cap", 5, "普通战斗房提供的战力成长上限＋5", {}],
	["失败抢救容量Ⅱ", 30, [20], &"salvage_capacity", 5, "失败或主动放弃时，可抢救的重量＋5", {}],
	["背包容量Ⅱ", 30, [21], &"backpack_capacity", 5, "背包容量＋5", {}],
	["暴击启用", 50, [22, 23], &"critical_unlock", 5, "直接攻击可暴击，暴击率5%，暴击伤害为普通伤害的150%", {"damage_percent": 150, "direct_attacks_only": true}],
	["背包容量Ⅲ", 30, [24], &"backpack_capacity", 5, "背包容量＋5", {}],
	["初始战力Ⅱ", 30, [25], &"initial_power", 3, "开局战力＋3", {}],
	["最大生命Ⅱ", 30, [25], &"max_hp", 15, "生命上限＋15", {}],
	["解锁第二批开局效果", 90, [26, 27, 28], &"opening_effect_batch_unlock", 2, "开放第二批开局效果的选择资格；具体效果待定", {"batch": 2, "effects_pending": true}],
	["失败消耗品转换数量", 50, [29], &"failure_consumable_conversion_count", 1, "失败后可转换的消耗品数量＋1", {}],
	["暴击率提升", 50, [29], &"critical_chance_percent", 10, "暴击率＋10个百分点", {}],
	["致死保护强化", 50, [29], &"lethal_protection_hp", 15, "致死保护触发后保留生命由1提高到15，最多恢复到当时的生命上限", {"clamp_to_max_hp": true}],
	["消耗品减重", 50, [30], &"consumable_weight_reduce", 2, "每件消耗品重量－2，最低为1", {"minimum_weight": 1}],
	["暴击伤害提升", 50, [31], &"critical_damage_percent", 20, "暴击伤害＋20个百分点", {}],
	["低血恢复", 50, [32], &"low_hp_healing_percent", 20, "生命不高于上限的30%时，治疗量＋20%", {"hp_threshold_percent": 30, "threshold_inclusive": true}],
	["单次增压上限", 70, [33], &"pressure_increase_cap", 15, "每次压力增加量最多为15点", {}],
	["暴击溢出", 70, [34], &"critical_overflow", 1, "暴击率超过100%的部分，每1个百分点转为1个百分点暴击伤害", {"chance_threshold_percent": 100, "damage_percent_per_chance_percent": 1}],
	["专属回收", 70, [35], &"exclusive_drop_bonus_percent", 20, "旧齿轮组、断裂巡逻牌、过热驱动核、搬运机黑箱、异常指令片的战斗掉率×1.20；仅在已开放的掉落池生效", {"eligible_pools_only": true}],
	["解锁第三批开局效果", 90, [36, 37, 38], &"opening_effect_batch_unlock", 3, "开放第三批开局效果的选择资格；具体效果待定", {"batch": 3, "effects_pending": true}],
]


static func definitions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in range(NODES.size()):
		var row: Array = NODES[index]
		var number := index + 1
		var phase := 1 if number <= 15 else (2 if number <= 29 else 3)
		var prerequisites: Array[String] = []
		var tier := 1
		for parent_number in row[2]:
			prerequisites.append(_id(int(parent_number)))
			tier = maxi(tier, int(result[int(parent_number) - 1].tier) + 1)
		result.append({
			"catalog_version": CATALOG_VERSION,
			"talent_id": _id(number),
			"id": _id(number),
			# Presentation groups follow the source's 15/14/10 progression phases.
			"branch_id": StringName("z2_phase_%d" % phase),
			"branch_label": "第%d阶段" % phase,
			"tier": tier,
			"display_name": str(row[0]),
			"prerequisite_ids": prerequisites,
			"cost": int(row[1]),
			"effect_kind": StringName(row[3]),
			"effect_amount": int(row[4]),
			"effect_label": str(row[5]),
			"effect_params": (row[6] as Dictionary).duplicate(true),
			"runtime_scope": &"opening_effect_eligibility" if row[3] == &"opening_effect_batch_unlock" else &"new_run_start_config",
			"source_sheet": "05 天赋树与节点",
			"source_row": number + 10,
		})
	return result


static func definition(talent_id: String) -> Dictionary:
	for node in definitions():
		if str(node.talent_id) == talent_id:
			return node
	return {}


static func sync_progress(data: Dictionary) -> Dictionary:
	# The save adapter validates the full profile and grants teaching/run rewards.
	# Never infer earnings from level, balance, flags, or today's node prices.
	if not _is_z2_profile(data) or not _has_ledger(data):
		return data
	data["talent_points"] = int(data.talent_earned) - int(data.talent_spent)
	data["talent_budget_granted"] = int(data.talent_earned)
	data["talent_catalog_version"] = CATALOG_VERSION
	return data


static func projection(meta: Dictionary) -> Array[Dictionary]:
	var valid_profile := _is_z2_profile(meta)
	var valid_ledger := _has_ledger(meta)
	var flags := _known_flags(meta)
	var points := int(meta.talent_earned) - int(meta.talent_spent) if valid_profile and valid_ledger else 0
	var level := int(meta.get("profile_level", 0))
	var result: Array[Dictionary] = []
	for node in definitions():
		var talent_id := str(node.talent_id)
		var unlocked := flags.has(talent_id)
		var missing_prerequisites: Array[String] = []
		for prerequisite in node.prerequisite_ids:
			if not flags.has(str(prerequisite)):
				missing_prerequisites.append(str(prerequisite))
		var cost := int(node.cost)
		var reason_code := &"available"
		var reason := "可消耗 %d 天赋点解锁" % cost
		if not valid_profile:
			reason_code = &"z2_profile_required"
			reason = "请使用新版成长档案查看和购买天赋。"
		elif not valid_ledger:
			reason_code = &"invalid_talent_ledger"
			reason = "天赋点记录不完整或不一致，暂时无法购买。"
		elif unlocked:
			reason_code = &"already_unlocked"
			reason = "已解锁"
			if node.effect_kind == &"opening_effect_batch_unlock":
				reason = "已解锁该批开局效果的选择资格"
				if bool(node.effect_params.get("effects_pending", false)):
					reason += "，具体效果待定"
		elif talent_id == TALENT_FLAG_MARKING and (level != 0 or bool(meta.get("tutorial_completed", false)) or not bool(meta.get("tutorial_purchase_available", false))):
			reason_code = &"tutorial_purchase_required"
			reason = "首次进入教程宝箱房，系统会用100教学点解锁插旗。"
		elif talent_id != TALENT_FLAG_MARKING and not flags.has(TALENT_FLAG_MARKING) and not bool(meta.get("tutorial_completed", false)):
			reason_code = &"tutorial_required"
			reason = "先进入教学宝箱房点亮插旗，开放天赋树。"
		elif not missing_prerequisites.is_empty():
			reason_code = &"prerequisite_missing"
			reason = "需先解锁全部前置：%s" % _talent_names(missing_prerequisites)
		elif points < cost:
			reason_code = &"insufficient_talent_points"
			reason = "天赋点不足：需要%d，当前%d。" % [cost, points]
		var available := reason_code == &"available"
		node["unlocked"] = unlocked
		node["available"] = available
		node["reason_code"] = reason_code
		node["reason"] = reason
		node["missing_prerequisite_ids"] = missing_prerequisites
		node["current_talent_points"] = points
		node["state"] = &"unlocked" if unlocked else (&"available" if available else &"blocked")
		result.append(node)
	return result


static func active_effects(meta: Dictionary) -> Array[Dictionary]:
	var flags := _known_flags(meta)
	var result: Array[Dictionary] = []
	for node in definitions():
		if not flags.has(str(node.talent_id)):
			continue
		result.append({
			"talent_id": str(node.talent_id),
			"branch_id": node.branch_id,
			"branch_label": node.branch_label,
			"display_name": node.display_name,
			"effect_kind": node.effect_kind,
			"effect_amount": node.effect_amount,
			"effect_label": node.effect_label,
			"effect_params": node.effect_params.duplicate(true),
			"runtime_scope": node.runtime_scope,
		})
	return result


static func summary(meta: Dictionary) -> Dictionary:
	var earned := int(meta.talent_earned) if _is_z2_profile(meta) and _has_ledger(meta) else 0
	var spent := int(meta.talent_spent) if _is_z2_profile(meta) and _has_ledger(meta) else 0
	var known_unlocked := 0
	var available_count := 0
	var branches := {}
	var nodes := projection(meta)
	for node in nodes:
		branches[node.branch_id] = true
		if bool(node.unlocked):
			known_unlocked += 1
		if bool(node.available):
			available_count += 1
	return {
		"catalog_version": CATALOG_VERSION,
		"profile_level": maxi(0, int(meta.get("profile_level", 0))),
		"budget_total": earned,
		"budget_granted": earned,
		"points_available": earned - spent,
		"known_unlocked_count": known_unlocked,
		"available_count": available_count,
		"node_count": nodes.size(),
		"branch_count": branches.size(),
	}


static func unlock_evaluation(meta: Dictionary, talent_id: String) -> Dictionary:
	for node in projection(meta):
		if str(node.talent_id) != talent_id:
			continue
		if bool(node.unlocked):
			return {"ok": true, "status": &"talent_already_unlocked", "talent_id": talent_id, "duplicate": true}
		if not bool(node.available):
			return {
				"ok": false,
				"status": node.reason_code,
				"talent_id": talent_id,
				"reason": node.reason,
				"missing_prerequisite_ids": node.missing_prerequisite_ids.duplicate(),
				"cost": int(node.cost),
			}
		return {"ok": true, "status": &"available", "talent_id": talent_id, "cost": int(node.cost)}
	return {"ok": false, "status": &"unknown_talent", "talent_id": talent_id, "reason": "未找到此天赋。"}


static func _id(number: int) -> String:
	return "z2_talent_%02d" % number


static func _is_z2_profile(meta: Dictionary) -> bool:
	return str(meta.get("ruleset_id", "")) == "z2" and meta.get("z2_progression_version") == 1


static func _has_ledger(meta: Dictionary) -> bool:
	return _nonnegative_integer(meta.get("talent_earned")) and _nonnegative_integer(meta.get("talent_spent")) and meta.talent_earned >= meta.talent_spent


static func _nonnegative_integer(value: Variant) -> bool:
	if value is int:
		return value >= 0
	return value is float and is_finite(value) and value >= 0.0 and value == floor(value)


static func _known_flags(meta: Dictionary) -> Array[String]:
	var result: Array[String] = []
	if not _is_z2_profile(meta) or not _has_ledger(meta):
		return result
	var flags: Variant = meta.get("talent_flags", [])
	if flags is not Array:
		return result
	for node in definitions():
		if flags.has(node.talent_id):
			result.append(str(node.talent_id))
	return result


static func _talent_names(talent_ids: Array[String]) -> String:
	var names := PackedStringArray()
	for talent_id in talent_ids:
		names.append(str(definition(talent_id).get("display_name", talent_id)))
	return "、".join(names)
