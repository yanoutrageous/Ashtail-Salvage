extends RefCounted
class_name Z2EventRuntime

const Economy = preload("res://scripts/core/run/z2_economy_events.gd")
const Information = preload("res://scripts/core/run/z2_information_events.gd")
const Process = preload("res://scripts/core/run/z2_process_events.gd")
const Dialogue = preload("res://scripts/core/run/z2_event_dialogue_catalog.gd")
const Loot = preload("res://scripts/core/content/z2_loot_catalog.gd")
const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
const KEY := "z2_event_runtime"
const MECHANISM_VARIANT_VERSION := 1
# EventService's enabled Z1 pool: e06 at slot5 and trap at slot28, one
# ticket each out of29. S3/事件确认/76-89 merges them into one of22 events.
const MECHANISM_VARIANT_POOL := [
	{"variant": "electric", "legacy_event_id": "z1_event_e06", "legacy_slot": 5, "roll_weight": 1},
	{"variant": "mechanical", "legacy_event_id": "trap", "legacy_slot": 28, "roll_weight": 1},
]
const EVENT_LEVELS := {"information": 1, "relief": 1, "first_aid": 1, "altar": 1,
	"shop": 3, "recycle": 2, "demine": 3, "clock_in": 3, "mechanism": 4, "coil": 4,
	"compress": 5, "rps": 5, "shortcut": 6, "consign": 8, "trader": 10, "expand": 12,
	"savings": 15, "recon": 18, "cage": 21, "seal": 22, "pawn": 23, "dice": 26}
const EVENT_WEIGHT_TOTAL := 29.0
const ECONOMY := ["shop", "savings", "seal", "relief", "first_aid", "consign", "expand", "compress", "trader", "pawn"]
const INFORMATION := ["information", "shortcut", "demine", "recon"]
const PROCESS := ["mechanism", "recycle", "coil", "clock_in", "rps", "cage", "dice", "altar"]
const ALIASES := {
	"z1_event_e01": "information", "z1_event_e04": "information", "z1_event_e17": "information",
	"z1_event_e02": "recycle", "z1_event_e07": "recycle", "z1_event_e08": "recycle",
	"z1_event_e03": "savings", "z1_event_e05": "seal", "z1_event_e06": "mechanism", "trap": "mechanism",
	"z1_event_e09": "relief", "z1_event_e23": "relief", "z1_event_e10": "first_aid", "z1_event_e11": "consign",
	"z1_event_e12": "expand", "z1_event_e13": "compress", "z1_event_e14": "trader", "merchant": "trader",
	"z1_event_e15": "pawn", "z1_event_e16": "shortcut", "z1_event_e18": "coil", "z1_event_e19": "demine",
	"z1_event_e20": "clock_in", "z1_event_e21": "recon", "z1_event_e22": "rps", "z1_event_e24": "cage", "z1_event_e25": "shop",
}
const TITLES := {"shop": "补给商店", "savings": "储蓄兑付", "seal": "封条柜", "relief": "减压", "first_aid": "急救柜", "consign": "托运", "expand": "扩容", "compress": "压缩", "trader": "旅商", "pawn": "预支", "information": "线报", "shortcut": "捷径", "demine": "排雷", "recon": "侦察", "mechanism": "机关", "recycle": "回收", "coil": "拾料线圈", "clock_in": "打卡", "rps": "博弈", "cage": "围笼", "dice": "骰局", "altar": "祭坛"}
const ACTION_TITLES := {"prepare": "查看服务", "leave": "返回探索", "buy": "购买", "refresh": "刷新三格货架", "deposit": "存入黑币", "withdraw": "取回本息", "use": "使用抢救封条", "flat": "简单休息", "ten_percent": "泡脚", "thirty_percent": "按摩", "consign": "托运", "expand": "扩充战利品背包", "compress": "压缩两件一档藏品", "sell": "出售", "pawn": "抵押预支", "mine_count": "查看5×5雷数", "mine_locations": "查看3×3雷位", "chest_locations": "查看5×5宝箱", "exit_direction": "询问最近出口方向", "preview_target": "查看捷径出口", "travel": "通过捷径", "detonate": "远程起爆", "recon_3": "侦察3×3", "recon_5": "侦察5×5", "recon_7": "侦察7×7", "assist": "交付辅助材料", "attempt": "尝试处理机关", "take": "带走材料", "deliver": "交付材料", "calibrate": "校准线圈", "register": "登记开工", "claim": "签退领款", "rock": "石头", "paper": "布", "scissors": "剪刀", "roll": "掷骰", "offer": "献祭"}

# This is the production routing/consumer boundary. It never starts a transaction
# or saves; all entry, choose and continuation hooks run in the existing candidate.
static func event_ids() -> Array:
	return ECONOMY + INFORMATION + PROCESS


# S2/事件与联动/C11: current29 types approximately equal, seeded by position.
# User authorized inheritance on 2026-11-16. Collapse aliases BEFORE assigning
# equal shares to the approved D02 level-filtered22; information has one share.
# Preserve the former total29, not the superseded four-event30/25/25/20 split.
static func event_pool(frozen: Dictionary) -> Array:
	var qualified: Array[String] = []
	var level := int(frozen.get("profile_level", 0))
	for event: String in event_ids():
		if level >= int(EVENT_LEVELS[event]):
			qualified.append(event)
	var result: Array[Dictionary] = []
	for event: String in qualified:
		result.append({"event_type": event, "min_level": int(EVENT_LEVELS[event]),
			"roll_weight": EVENT_WEIGHT_TOTAL / qualified.size(), "probability": 1.0 / qualified.size()})
	return result


static func select_event(context: RunContext, pos: Vector2i) -> Dictionary:
	if not applies_to(context) or not context.run_active:
		return _fail("wrong_ruleset")
	var key := context.cell_key(pos)
	var room: Dictionary = context.z1_event_rooms.get(key, {}).duplicate(true)
	var existing := str(room.get("event_type", ""))
	if not existing.is_empty():
		if not event_ids().has(canonical(existing)):
			return _fail("unsupported_saved_event")
		if canonical(existing) == "mechanism":
			var bound := _bind_mechanism_variant(context, pos, room)
			if not bound.ok:
				return bound
			context.z1_event_rooms[key] = room
		return {"ok": true, "event_type": existing, "canonical_event_type": canonical(existing),
			"pool_id": str(room.get("z2_event_selection", {}).get("pool_id", "inherited_saved_event")), "already_selected": true}
	var profile: Dictionary = context.run_start_config.get("profile_fields", {})
	if not profile.get("content_eligibility") is Dictionary:
		return _fail("missing_frozen_eligibility")
	var pool := event_pool(profile.content_eligibility)
	if pool.is_empty():
		return _fail("empty_eligible_event_pool")
	var rng := RandomNumberGenerator.new()
	rng.seed = pos.x * 73 + pos.y * 137 + context.seed_value * 31
	var ticket := rng.randf() * EVENT_WEIGHT_TOTAL
	var remaining := ticket
	var selected: String = pool.back().event_type
	for entry: Dictionary in pool:
		remaining -= float(entry.roll_weight)
		if remaining < 0.0:
			selected = str(entry.event_type)
			break
	room["event_type"] = StringName(selected)
	room["z2_event_selection"] = {"pool_id": "z2_event_types", "source": "S2/事件与联动/C11; D02 approved levels",
		"source_weight_total": EVENT_WEIGHT_TOTAL, "policy": "unique22_equal_after_level_filter",
		"pool": pool.duplicate(true), "ticket": ticket, "event_type": selected}
	if selected == "mechanism":
		var bound := _bind_mechanism_variant(context, pos, room)
		if not bound.ok:
			return bound
	context.z1_event_rooms[key] = room
	return {"ok": true, "event_type": selected, "canonical_event_type": selected, "pool_id": "z2_event_types", "already_selected": false}


# Mutates only the supplied candidate room, never a new global field. A saved
# encounter wins over seed changes, later caller overrides and reopened UI.
static func _bind_mechanism_variant(context: RunContext, pos: Vector2i, room: Dictionary, rules: Dictionary = {}) -> Dictionary:
	var selection: Dictionary = room.get("z2_event_selection", {}).duplicate(true)
	var prepared := str(room.get("z2_process", {}).get("mechanism", {}).get("variant", ""))
	var allowed := ["electric", "mechanical"]
	if not prepared.is_empty() and not allowed.has(prepared):
		return _fail("invalid_mechanism_variant")
	if selection.has("mechanism_variant"):
		var saved: Variant = selection.mechanism_variant
		if not saved is Dictionary:
			return _fail("invalid_mechanism_binding")
		var unsigned: Dictionary = saved.duplicate(true)
		unsigned.erase("hash")
		var variant := str(saved.get("variant", ""))
		if saved.get("version") != MECHANISM_VARIANT_VERSION or not allowed.has(variant) or str(saved.get("hash", "")) != Snapshot.fingerprint(unsigned):
			return _fail("invalid_mechanism_binding")
		if not prepared.is_empty() and prepared != variant:
			return _fail("mechanism_binding_conflict")
		return {"ok": true, "variant": variant}
	var legacy_id := str(room.get("event_type", ""))
	var variant := prepared
	var origin := "saved_process"
	var ticket := -1
	if variant.is_empty():
		if legacy_id in ["z1_event_e06", "trap"]:
			variant = "electric" if legacy_id == "z1_event_e06" else "mechanical"
			origin = "legacy_identity"
		elif rules.has("mechanism_variant"):
			variant = str(rules.mechanism_variant)
			origin = "trusted_rule"
		else:
			# Reuse Z1's position+seed modulo strategy on its two inherited slots.
			var total := 0
			for entry: Dictionary in MECHANISM_VARIANT_POOL:
				total += int(entry.roll_weight)
			ticket = posmod(pos.x * 73 + pos.y * 137 + context.seed_value * 31, total)
			var remaining := ticket
			for entry: Dictionary in MECHANISM_VARIANT_POOL:
				remaining -= int(entry.roll_weight)
				if remaining < 0:
					variant = str(entry.variant)
					break
			origin = "inherited_seed_position_modulo"
	if not allowed.has(variant):
		return _fail("invalid_mechanism_variant")
	var record := {"version": MECHANISM_VARIANT_VERSION, "variant": variant, "origin": origin,
		"source": "S3/事件确认/76-89; Z1 EventService enabled29 slots5/28",
		"pool": MECHANISM_VARIANT_POOL.duplicate(true), "ticket": ticket,
		"seed": context.seed_value, "position": pos, "canonical_event_type": "mechanism"}
	record["hash"] = Snapshot.fingerprint(record)
	selection["mechanism_variant"] = record
	room["z2_event_selection"] = selection
	return {"ok": true, "variant": variant}

static func canonical(event_id: String) -> String:
	return str(ALIASES.get(event_id, event_id))

static func applies_to(context: RunContext) -> bool:
	# Tutorials retain Z2 profile identity, but their fixed four-event lesson
	# follows the same legacy boundary as Z2RunHooks.applies_to.
	if context == null or context.mode == &"tutorial":
		return false
	var profile: Dictionary = context.run_start_config.get("profile_fields", context.profile_fields)
	return str(profile.get("ruleset_id", "")) == "z2" and int(profile.get("z2_progression_version", 0)) == 1

static func stored_event_type(context: RunContext, pos: Vector2i) -> StringName:
	var room: Dictionary = context.z1_event_rooms.get(context.cell_key(pos), {})
	var id := str(room.get("event_type", ""))
	return StringName(id) if event_ids().has(canonical(id)) else &""


static func hooks_for(authority: Variant, context: RunContext, pos: Vector2i, event_id: String) -> Dictionary:
	if authority is Dictionary:
		return authority.duplicate(true)
	if authority is Object and is_instance_valid(authority) and authority.has_method("z2_event_hooks"):
		var result: Variant = authority.call("z2_event_hooks", context, pos, event_id)
		if result is Dictionary:
			return result
	return {}


# Official pools are the default. Only trusted hooks may override dependency
# entries (e.g. the actual search-origin pool); player payloads never can.
static func _dependencies(context: RunContext, hooks: Dictionary) -> Dictionary:
	var result := hooks.duplicate(true)
	var economy := Loot.economy_catalog(context)
	economy.merge(hooks.get("economy_catalog", {}), true)
	result["economy_catalog"] = economy
	var stage := mini(5, int(context.z1_event_flags.get("z2_process", {}).get("altar_tier", 0)) + 1)
	var rules := Loot.process_rules(context, stage)
	var overrides: Dictionary = hooks.get("process_rules", {})
	for key: Variant in overrides:
		if key in ["pools", "definitions", "material_tags"] and overrides[key] is Dictionary:
			var entries: Dictionary = rules.get(key, {}).duplicate(true)
			entries.merge(overrides[key], true)
			rules[key] = entries
		else:
			rules[key] = overrides[key]
	result["process_rules"] = rules
	return result


static func public_state(context: RunContext, pos: Vector2i, event_id: String) -> Dictionary:
	var event := canonical(event_id)
	if not applies_to(context) or not event_ids().has(event):
		return _fail("unassigned_z2_event")
	var owner := _owner(event)
	var state: Dictionary
	match owner:
		"economy": state = Economy.public_state(context, pos, event)
		"information": state = Information.public_state(context, pos, event)
		_: state = Process.public_state(context, pos, event)
	state = state.duplicate(true)
	state.merge({"ruleset_id": "z2", "event_type": event, "source_event_id": event_id,
		"owner": owner, "room_key": context.cell_key(pos), "player_title": TITLES[event]}, true)
	if event == "mechanism":
		var binding: Dictionary = context.z1_event_rooms.get(context.cell_key(pos), {}).get("z2_event_selection", {}).get("mechanism_variant", {})
		state["variant_selection"] = binding.duplicate(true)
		if not state.has("variant") and binding.has("variant"):
			state["variant"] = str(binding.variant)
	var prepared := bool(state.get("prepared", false))
	state["requires_prepare"] = bool(state.get("requires_prepare", not prepared and not state.get("completed", false)))
	if event == "altar" and not state.get("completed", false) and int(state.get("tier", 0)) != mini(5, int(state.get("global_tier", 0)) + 1):
		state["requires_prepare"] = true
	state["progress_completed"] = bool(state.get("progress_completed", state.get("stage_awarded", state.get("completed", false))))
	state["allow_after_completion"] = not bool(state.get("completed", false)) or event == "shop"
	var raw_options: Array = state.get("options", [])
	if owner == "process":
		raw_options = _process_options(context, pos, event, state)
	var options: Array[Dictionary] = []
	var edit_principal: bool = event == "savings" and not state.get("completed", false) and context.z1_event_flags.get("z2_economy", {}).get("savings_pending", {}).is_empty()
	if (bool(state.requires_prepare) or edit_principal) and event != "cage":
		var prepare := _ui_option("prepare", 0, {}, true, "", "输入本金后，更新存款保底与异房取款报价。" if edit_principal else "确认当前报价与服务内容。")
		if edit_principal:
			prepare.player_title = "更新本金报价"
			prepare.label = prepare.player_title
		options.append(prepare)
	for raw: Dictionary in raw_options:
		var id := str(raw.get("option_id", raw.get("id", "")))
		var payload: Dictionary = raw.get("params", raw.get("payload", {})).duplicate(true)
		if owner in ["economy", "information"]:
			payload["quote_id"] = str(state.get("quote_id", ""))
		else:
			payload["revision"] = int(state.get("revision", 0))
		var reason := str(raw.get("reason", ""))
		if state.requires_prepare:
			reason = "stale_quote"
		var option := _ui_option(id, int(raw.get("fee_black", 0)), payload, bool(raw.get("enabled", true)) and reason.is_empty(), reason, str(raw.get("effect", "")))
		option.player_effect = _option_effect(context, pos, event, id, raw, state)
		if raw.has("cost_kind"):
			option.player_cost = {"kind": StringName(raw.cost_kind), "amount": int(raw.get("cost_amount", 0)), "display_text": str(raw.get("cost_text", ""))}
		if raw.get("requires_confirmation", false):
			option["requires_confirmation"] = true
			option["confirmation_payload"] = {"confirmed_flag": true}
		var item: Dictionary = raw.get("reward", {}).get("item", {})
		if item.is_empty() and payload.has("instance_id"):
			item = context.asset_ledger.item_instances.get(str(payload.instance_id), {})
		if not item.is_empty() and id in ["buy", "sell", "consign", "pawn", "assist", "deliver"]:
			option.player_title += " " + str(item.get("display_name", item.get("item_id", "")))
			option.label = option.player_title
		if id == "assist":
			option.player_cost = {"kind": &"item", "amount": 1, "display_text": "消耗1件" + _item_name(item)}
		elif id == "compress":
			option.player_cost = {"kind": &"item", "amount": 2, "display_text": "消耗2件一档普通藏品"}
		elif id == "withdraw" and int(raw.get("reward", {}).get("revoke_safe", 0)) > 0:
			option.player_cost = {"kind": &"gold_coin", "amount": int(raw.reward.revoke_safe), "display_text": "撤销%d安全金币保底" % int(raw.reward.revoke_safe)}
		options.append(option)
	if event != "cage" or bool(state.get("completed", false)):
		options.append(_ui_option("leave", 0, {}, true))
	state["options"] = options
	state["input_fields"] = ["amount"] if event == "savings" else (["instance_ids"] if event == "compress" else [])
	var room: Dictionary = context.z1_event_rooms.get(context.cell_key(pos), {})
	if room.has("z2_event_last_result"):
		state["last_result"] = room.z2_event_last_result.duplicate(true)
	state["player_summary"] = _summary(context, event, state)
	state.merge(Dialogue.project(event, state, {
		"returning": int(room.get("z2_dialogue_visits", 0)) > 1,
		"savings_pending": context.z1_event_flags.get("z2_economy", {}).get("savings_pending", {}),
		"information_discount": context.z1_event_flags.get(Information.INFORMATION_SERVICE_FLAG, false),
		"seal_discount": context.z1_event_flags.get(Economy.EVACUATION_SERVICE_FLAG, false),
	}), true)
	return state

static func prepare_event(context: RunContext, pos: Vector2i, event_id: String, payload: Dictionary = {}, hooks: Dictionary = {}) -> Dictionary:
	if not applies_to(context) or not event_ids().has(canonical(event_id)):
		return _fail("unsupported_z2_event")
	var key := context.cell_key(pos)
	var room: Dictionary = context.z1_event_rooms.get(key, {}).duplicate(true)
	var existing := str(room.get("event_type", ""))
	if not existing.is_empty() and canonical(existing) != canonical(event_id):
		return _fail("event_binding_conflict")
	room["event_type"] = StringName(event_id)
	context.z1_event_rooms[key] = room
	if canonical(event_id) == "cage":
		return on_room_entered(context, pos, event_id, hooks)
	return choose(context, pos, event_id, "prepare", payload, hooks)


static func choose(context: RunContext, pos: Vector2i, event_id: String, option_id: String, payload: Dictionary = {}, hooks: Dictionary = {}) -> Dictionary:
	var event := canonical(event_id)
	if not applies_to(context) or not event_ids().has(event):
		return _fail("unsupported_z2_event")
	if canonical(str(stored_event_type(context, pos))) != event:
		return _fail("event_binding_conflict")
	if option_id == "leave":
		if event == "cage" and not bool(public_state(context, pos, event).get("completed", false)):
			return _fail("cage_combat_locked")
		return {"ok": true, "event_type": event, "completed": false, "stage_completed": false, "stage_facts": [], "facts": {}, "message": "已返回探索。"}
	hooks = _dependencies(context, hooks)
	var raw: Dictionary
	match _owner(event):
		"economy": raw = Economy.choose(context, pos, event, option_id, payload, hooks.get("economy_catalog", {}))
		"information": raw = Information.execute(context, pos, event, option_id, payload, hooks.get("enter_room", Callable()))
		_:
			var rules: Dictionary = hooks.get("process_rules", {}).duplicate(true)
			if event == "mechanism":
				var room: Dictionary = context.z1_event_rooms[context.cell_key(pos)].duplicate(true)
				var bound := _bind_mechanism_variant(context, pos, room, rules)
				if not bound.ok:
					return bound
				context.z1_event_rooms[context.cell_key(pos)] = room
				rules["mechanism_variant"] = str(bound.variant)
			raw = Process.choose(context, pos, event, option_id, payload, rules)
			if raw.get("ok", false) and option_id == "prepare":
				var room: Dictionary = context.z1_event_rooms[context.cell_key(pos)]
				room["z2_event_rules_view"] = {"material_tags": rules.get("material_tags", {}).duplicate(true),
					"mechanism_failure_damage_type": rules.get("mechanism_failure_damage_type", ""), "electric_damage_type": rules.get("electric_damage_type", "")}
				context.z1_event_rooms[context.cell_key(pos)] = room
	return _finish(context, pos, event, option_id, raw, hooks, option_id not in ["prepare", "preview_target"], true)

static func on_room_entered(context: RunContext, pos: Vector2i, event_id: String, hooks: Dictionary = {}) -> Dictionary:
	if not applies_to(context):
		return _fail("wrong_ruleset")
	var event := canonical(event_id)
	hooks = _dependencies(context, hooks)
	var raw := Process.on_room_entered(context, pos, event, hooks.get("process_rules", {}))
	var result := _finish(context, pos, event, "room_entered", raw, hooks, raw.has("combat_request"), false)
	if result.get("ok", false) and event_ids().has(event):
		var room_key := context.cell_key(pos)
		var room: Dictionary = context.z1_event_rooms.get(room_key, {}).duplicate(true)
		room["z2_dialogue_visits"] = int(room.get("z2_dialogue_visits", 0)) + 1
		context.z1_event_rooms[room_key] = room
	return result

static func on_normal_search_completed(context: RunContext, pos: Vector2i, receipt: Dictionary, hooks: Dictionary = {}) -> Dictionary:
	if not applies_to(context):
		return _fail("wrong_ruleset")
	hooks = _dependencies(context, hooks)
	var raw := Process.on_normal_search_completed(context, pos, receipt, hooks.get("process_rules", {}))
	return _finish(context, pos, "coil", "search_completed", raw, hooks, not raw.get("ignored", false), false)

static func on_cage_combat_completed(context: RunContext, pos: Vector2i, receipt: Dictionary, hooks: Dictionary = {}) -> Dictionary:
	if not applies_to(context):
		return _fail("wrong_ruleset")
	var raw := Process.on_cage_combat_completed(context, pos, receipt)
	return _finish(context, pos, "cage", "combat_completed", raw, hooks, not raw.get("ignored", false), false)


static func cage_state(context: RunContext, pos: Vector2i) -> Dictionary:
	var state := Process.public_state(context, pos, "cage")
	var request: Dictionary = state.get("combat_request", {})
	if request.is_empty():
		return {}
	return {"active": not state.get("completed", false), "combat_request": request.duplicate(true),
		"monster_type": StringName(str(request.get("enemy", {}).get("enemy_id", ""))),
		"base_power": int(request.get("original_power", 0)), "completed": state.get("completed", false)}


static func _owner(event: String) -> String:
	return "economy" if ECONOMY.has(event) else ("information" if INFORMATION.has(event) else "process")


static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "blocked_reason": reason, "message": _reason_text(reason), "stage_completed": false, "stage_facts": []}


static func _consume(hooks: Dictionary, name: String, context: RunContext, fact: Dictionary) -> Dictionary:
	var callback: Variant = hooks.get(name)
	if not callback is Callable or not callback.is_valid():
		return _fail("missing_" + name)
	var result: Variant = callback.call(context, fact.duplicate(true))
	if not result is Dictionary or not result.get("ok", false):
		return _fail(str(result.get("reason", name + "_failed")) if result is Dictionary else name + "_failed")
	return {"ok": true}


static func _finish(context: RunContext, pos: Vector2i, event: String, option: String, raw: Dictionary, hooks: Dictionary, actual_action: bool, update_ui: bool) -> Dictionary:
	if not raw.get("ok", false):
		var rejected := raw.duplicate(true)
		if str(rejected.get("message", "")).is_empty():
			rejected["message"] = _reason_text(str(raw.get("reason", "unavailable")))
		return rejected
	var result := raw.duplicate(true)
	var global: Dictionary = context.z1_event_flags.get(KEY, {}).duplicate(true)
	var room_key := str(raw.get("room_key", raw.get("room_id", context.cell_key(pos))))
	var facts := _source_facts(context, pos, room_key, event, option, raw)
	var source := {"position": facts.get("position", pos), "source_position": facts.get("position", pos),
		"canonical_type": event, "substage": facts.get("substage", option), "origin": "event"}
	var action_id := str(hooks.get("action_id", ""))
	var gross := int(facts.get("black_income_gross", 0))
	var duplicate := bool(raw.get("duplicate", false)) or bool(raw.get("ignored", false))
	var stage_facts: Array[Dictionary] = []
	var valid_stage := bool(raw.get("stage_completed", false)) and not duplicate
	if actual_action and not duplicate and not facts.is_empty():
		if action_id.is_empty():
			return _fail("missing_atomic_action_id")
		var fact_id := action_id + ":" + event + ":" + room_key + ":" + option
		var observations: Dictionary = global.get("facts", {})
		if not observations.has(fact_id):
			var observation := {"kind": "event_action_resolved", "fact_id": fact_id, "action_id": action_id,
				"event_type": event, "room_key": room_key, "option_id": option, "valid_stage": valid_stage, "facts": facts}
			observation.merge(source, true)
			var observed := _consume(hooks, "consume_facts", context, observation)
			if not observed.ok:
				return observed
			observations[fact_id] = true
			global["facts"] = observations
		if gross > 0:
			var incomes: Dictionary = global.get("income", {})
			if not incomes.has(fact_id):
				var income := {"kind": "black_income_gross", "action_id": action_id,
					"fact_id": fact_id, "event_type": event, "room_key": room_key, "gross_amount": gross, "already_credited": true, "facts": facts}
				income.merge(source, true)
				var consumed := _consume(hooks, "consume_income", context, income)
				if not consumed.ok:
					return consumed
				incomes[fact_id] = true
				global["income"] = incomes
	if valid_stage:
		var stage_id := str(raw.get("stage_id", ""))
		if stage_id.is_empty():
			return _fail("missing_stage_id")
		var stages: Dictionary = global.get("stages", {})
		if not stages.has(stage_id):
			var xp_key := str(context.run_id) + ":z2:event_room:" + room_key
			var talent_key := str(raw.get("talent_key", stage_id))
			var equipment_key := str(raw.get("equipment_key", stage_id + ":equipment"))
			var xp: Dictionary = global.get("xp", {})
			var talent: Dictionary = global.get("talent", {})
			var equipment: Dictionary = global.get("equipment", {})
			var fact := {"kind": "event_stage_completed", "effective": true, "stage_id": stage_id,
				"event_type": event, "room_key": room_key, "xp_key": xp_key, "talent_key": talent_key, "equipment_key": equipment_key,
				"base_xp": 0 if xp.has(xp_key) else int(raw.get("base_xp", 0)),
				"base_talent": 0 if talent.has(talent_key) else int(raw.get("base_talent", 0)),
				"equipment_eligible": event != "cage" and not equipment.has(equipment_key), "actual_combat": event == "cage", "facts": facts}
			fact.merge(source, true)
			var consumed := _consume(hooks, "consume_stage", context, fact)
			if not consumed.ok:
				return consumed
			stages[stage_id] = true
			if not xp.has(xp_key):
				context.run_stats["events_completed"] = int(context.run_stats.get("events_completed", 0)) + 1
				context.run_stats["events_" + event] = int(context.run_stats.get("events_" + event, 0)) + 1
				context.interacted_cells[room_key] = true
			xp[xp_key] = true
			talent[talent_key] = true
			if fact.equipment_eligible:
				equipment[equipment_key] = true
			global.merge({"stages": stages, "xp": xp, "talent": talent, "equipment": equipment}, true)
			stage_facts.append(fact)
	if not global.is_empty():
		context.z1_event_flags[KEY] = global
	if event == "recycle" and str(facts.get("operation", "")) == "deliver":
		context.z1_event_flags[Economy.EVACUATION_SERVICE_FLAG] = true
	result.merge({"event_type": event, "option_id": option, "room_key": room_key, "ruleset_id": "z2",
		"stage_facts": stage_facts, "stage_completed": not stage_facts.is_empty(), "facts": facts,
		"base_xp": 0, "base_talent": 0, "effects_already_applied": true}, true)
	result.merge(source, true)
	result.erase("stage_fact")
	if not stage_facts.is_empty():
		result["stage_fact"] = stage_facts[0]
		result.base_xp = int(stage_facts[0].base_xp)
		result.base_talent = int(stage_facts[0].base_talent)
	# Do not expose the legacy shortcut_target instruction: T11 already entered.
	result.erase("shortcut_target")
	var message := _result_text(context, event, option, result)
	result["message"] = message
	# Omitted speaker inherits the authoritative view; an empty string hides it.
	result["response_lines"] = [{"text": message}] if not message.is_empty() else []
	var dialogue_state := public_state(context, facts.get("position", pos), event) if event_ids().has(event) else {}
	if option == "prepare":
		result["response_lines"] = dialogue_state.get("dialogue", []).duplicate(true)
		message = str(result.response_lines[0].get("text", "")) if not result.response_lines.is_empty() else str(dialogue_state.get("player_summary", ""))
		result["message"] = message
	elif actual_action and not duplicate:
		result.response_lines.append_array(Dialogue.response(event, option, facts, dialogue_state))
	if actual_action and not duplicate:
		var room: Dictionary = context.z1_event_rooms.get(room_key, {}).duplicate(true)
		room["z2_event_last_result"] = {"event_type": event, "option_id": option, "stage_facts": stage_facts.duplicate(true),
			"facts": facts.duplicate(true), "message": message, "response_lines": result.response_lines.duplicate(true)}
		context.z1_event_rooms[room_key] = room
	if update_ui:
		# A shortcut may already be in another room; never replace its entry state.
		if context.get_current_pos() == pos:
			context.event_state = public_state(context, pos, str(stored_event_type(context, pos)))
			result["public_state"] = context.event_state.duplicate(true)
			result["completed"] = bool(context.event_state.get("completed", false))
			result["allow_after_completion"] = bool(context.event_state.get("allow_after_completion", false))
		context.last_reward = result.duplicate(true)
		context.last_message = message
		context.blocked_reason = ""
		result["message"] = context.last_message
	return result


static func _source_facts(context: RunContext, pos: Vector2i, room_key: String, event: String, option: String, raw: Dictionary) -> Dictionary:
	var facts: Dictionary = raw.get("facts", {}).duplicate(true)
	if facts.is_empty():
		return facts
	var source_pos := pos
	var coordinates := room_key.split(",")
	if coordinates.size() == 2 and coordinates[0].is_valid_int() and coordinates[1].is_valid_int():
		source_pos = Vector2i(int(coordinates[0]), int(coordinates[1]))
	var substage := option
	var instance := str(raw.get("event_instance_id", ""))
	var stage_id := str(raw.get("stage_id", ""))
	if not instance.is_empty() and stage_id.begins_with(instance + ":"):
		substage = stage_id.substr(instance.length() + 1)
	if event in ["dice", "rps"] and facts.has("round"):
		substage = "round:%d" % int(facts.round)
	elif event == "rps" and str(facts.get("round_id", "")).contains(":round:"):
		substage = "round:" + str(facts.round_id).get_slice(":round:", 1)
	facts.merge({"position": source_pos, "source_position": source_pos, "canonical_type": event,
		"event_type": event, "room_key": room_key, "substage": substage, "effect_origin": "event"}, true)
	# T11's shortcut origin is a real coordinate; retain owner facts verbatim.
	if not facts.has("origin"):
		facts["origin"] = "event"
	match event:
		"mechanism":
			var binding: Dictionary = context.z1_event_rooms.get(room_key, {}).get("z2_event_selection", {}).get("mechanism_variant", {})
			facts["mechanism_variant"] = str(binding.get("variant", ""))
			facts["mechanism_variant_hash"] = str(binding.get("hash", ""))
		"compress":
			if facts.has("consumed_instance_ids"):
				facts["input_instance_ids"] = facts.consumed_instance_ids.duplicate()
				var inputs: Array[Dictionary] = []
				for id: Variant in facts.consumed_instance_ids:
					inputs.append(context.asset_ledger.item_instances.get(str(id), {}).duplicate(true))
				facts["inputs"] = inputs
				facts["output"] = facts.get("delivery", {}).duplicate(true)
		"savings":
			if facts.has("deposit"):
				facts["transaction_id"] = str(facts.deposit.get("deposit_id", ""))
				facts["principal"] = int(facts.deposit.get("principal", 0))
			if option == "withdraw":
				facts["withdrawn"] = int(facts.get("black_income_gross", 0))
		"dice":
			if facts.has("win"):
				facts["won"] = bool(facts.win)
	return facts


static func _ui_option(id: String, fee: int = 0, payload: Dictionary = {}, enabled: bool = true, reason: String = "", effect: String = "") -> Dictionary:
	var title := str(ACTION_TITLES.get(id, id))
	return {"id": StringName(id), "label": title, "player_title": title, "enabled": enabled,
		"player_cost": {"kind": &"black_coin" if fee > 0 else &"none", "amount": fee, "display_text": "%d黑币" % fee if fee > 0 else "无需花费"},
		"player_effect": effect if not effect.is_empty() else ("关闭服务，继续探索。" if id == "leave" else "查看本房当前服务内容。"), "reason": reason, "disabled_reason": reason,
		"player_disabled_reason": _reason_text(reason) if not enabled else "", "payload": payload}


static func _process_row(id: String, fee: int = 0, enabled: bool = true, params: Dictionary = {}, effect: String = "") -> Dictionary:
	return {"id": id, "fee_black": fee, "enabled": enabled, "params": params, "reason": "" if enabled else "unavailable", "effect": effect}


# Presentation reads the owners' saved quotes/rewards/facts. The fixed process
# descriptions below mirror the frozen T12 rules; they do not drive settlement.
static func _item_name(item: Dictionary) -> String:
	return str(item.get("display_name", item.get("item_id", "所选物品")))


static func _item_names(items: Array) -> String:
	var names: PackedStringArray = []
	for item: Dictionary in items:
		names.append(_item_name(item))
	return "、".join(names)


static func _pos_text(pos: Variant) -> String:
	return "（%d，%d）" % [pos.x, pos.y] if pos is Vector2i else "所选房间"


static func _summary(context: RunContext, event: String, state: Dictionary) -> String:
	var descriptions := {
		"shop": "货架提供3件补给，可逐件购买或付费刷新。已生成的商品与报价会保留；首次成功购买完成本房阶段。",
		"savings": "全局只保留一笔待兑存款。本房存入或取出二选一；存款提供本金一半的安全金币保底，异房取款兑付本息并撤销保底。",
		"seal": "使用抢救封条增加抢救容量；失败或放弃时，选中的最重普通藏品按减重规则结算。本局封条效果只能使用一次。",
		"relief": "选择减压服务。比例方案按当前压力向下取整；没有减压效果时不可购买。当前压力：%d。" % context.pressure,
		"first_aid": "购买一张急救贴。报价随当前压力变化；低价方案同时增加基础压力。购买后仍需在背包中使用急救贴。",
		"consign": "每房可托运1件背包中的普通藏品，重量不超过20；费用按该实例的价值和重量计算。托运后由终局结算交付。",
		"expand": "付费扩充本局战利品背包容量。本房只能使用一次。",
		"compress": "选择背包中2件不同的一档普通藏品，压缩为本房已生成的二档藏品。两件投入会一起消耗，满包时产出放在本房地面。",
		"trader": "出售背包中的合格物品：非补给按基础价值的75%向下取整兑换安全金币；未使用补给按退货规则返还黑币。",
		"pawn": "抵押1件价值至少21的普通藏品，取得黑币预支。本局只能预支一次，成功撤离时可支付赎回费取回原实例。",
		"information": "免费查看附近雷数，或购买雷位、宝箱位置、最近出口方向。获得情报不会把目标房记为实际到访。",
		"shortcut": "先查看本房已生成的斜向出口，再确认进入。实际通行才付费，并照常结算目标房入口危险。",
		"demine": "选择相邻且手动插旗的格子远程起爆。猜中解除地雷并增加基础压力；猜错仍支付服务费，不会制造命中收益。",
		"recon": "购买指定范围的雷位情报，只记录新发现的地雷。范围内没有新情报时不收费。",
		"mechanism": "处理本房机关。战力判定、辅助材料与奖励使用本房保存的条件；完成后不能重复领取。",
		"recycle": "带走本房材料，或交付合格材料兑换安全金币。交付使用实际物品实例。",
		"coil": "校准后等待下一次完整普通房搜索，额外领取1件来自该搜索渠道的物品；实际交付时才完成阶段。",
		"clock_in": "付费登记，实际进入3间登记时尚未到访的新房后，回到任一打卡处领款；原登记房也可领款。",
		"rps": "石头、布、剪刀先得两胜者结束。平局继续；胜局领取本房已确定的奖金，败局不领取奖金。",
		"cage": "进入围笼即开始强制战斗，封门期间不能撤退。胜利提升战力；按真实战果结清，不领取普通清场奖励。",
		"dice": "每押20黑币，每房最多3押。1至4点返还0，5点返还40，6点返还80黑币；后两押使用后续权重。",
		"altar": "按全局祭坛阶段支付生命，领取本阶段黑币及已生成物品。生命支付后必须至少保留1点；辅助材料可降低本次生命费用。",
	}
	var text := str(descriptions.get(event, ""))
	if event == "savings":
		var pending: Dictionary = context.z1_event_flags.get("z2_economy", {}).get("savings_pending", {})
		if not pending.is_empty():
			text += " 待兑本金%d黑币，可取回%d黑币，需撤销%d安全金币保底。" % [int(pending.principal), int(pending.withdrawal), int(pending.guarantee)]
	elif event == "clock_in" and not state.get("contract", {}).is_empty():
		text += " 当前已进入%d间新房。" % state.contract.get("new_rooms", {}).size()
	elif event == "mechanism" and state.has("threshold"):
		text += " 当前战力%d，要求至少%s。" % [context.power, str(state.threshold)]
	elif event == "altar" and state.has("tier"):
		text += " 当前报价为第%d阶段。" % int(state.tier)
	elif event == "cage" and state.has("combat_request"):
		var enemy := str(state.combat_request.get("enemy", {}).get("enemy_id", ""))
		text += " 对手：%s，原始战力%d。" % [str({"slime": "史莱姆", "bat": "蝙蝠", "drone": "无人机"}.get(enemy, enemy)), int(state.combat_request.get("original_power", 0))]
	if state.get("completed", false):
		var response := str(state.get("last_result", {}).get("message", ""))
		return "本房服务已结清。" + (" " + response if not response.is_empty() else "")
	return text


static func _option_effect(context: RunContext, pos: Vector2i, event: String, action: String, row: Dictionary, state: Dictionary) -> String:
	var reward: Dictionary = row.get("reward", {})
	var params: Dictionary = row.get("params", row.get("payload", {}))
	var room: Dictionary = context.z1_event_rooms.get(context.cell_key(pos), {})
	var item: Dictionary = reward.get("item", {})
	if item.is_empty() and params.has("instance_id"):
		item = context.asset_ledger.item_instances.get(str(params.instance_id), {})
	match event:
		"shop":
			return "获得1件%s；满包时放在本房地面。" % _item_name(item) if action == "buy" else "重新生成3件商品；本房下次刷新费用继续增加。"
		"savings":
			if action == "deposit":
				return "存款生效后获得%d安全金币保底；异房可取回%d黑币本息。" % [int(reward.get("safe_guarantee", 0)), int(reward.get("withdrawal", 0))]
			return "取回%d黑币本息，同时撤销%d安全金币保底。" % [int(reward.get("black", 0)), int(reward.get("revoke_safe", 0))]
		"seal": return "抢救容量增加%d；选中最重普通藏品的结算重量减少%d，最低%d。本局限一次。" % [int(reward.get("salvage_capacity", 0)), int(reward.get("weight_reduction", 0)), int(reward.get("min_weight", 1))]
		"relief": return "降低%d压力（当前报价）。" % int(reward.get("pressure_reduction", 0))
		"first_aid": return "获得1张%s；基础压力增加%d。满包时放在本房地面。" % [_item_name(item), int(reward.get("base_pressure", 0))]
		"consign": return "托运%s（重量%d、价值%d），保留原实例并在终局交付。" % [_item_name(item), int(item.get("weight", 0)), int(item.get("base_value", 0))]
		"expand": return "本局战利品背包容量增加%d。" % int(reward.get("loot_capacity", 0))
		"compress": return "消耗%d件%d档普通藏品，获得二档%s；满包时放在本房地面。" % [int(reward.get("input_count", 0)), int(reward.get("input_tier", 0)), _item_name(item)]
		"trader": return "出售%s，获得%d%s。" % [_item_name(item), int(reward.get("amount", 0)), "安全金币" if str(reward.get("currency", "")) == "gold_coin" else "黑币"]
		"pawn": return "抵押%s，获得%d黑币；成功撤离时可付%d黑币赎回。" % [_item_name(item), int(reward.get("black", 0)), int(reward.get("redeem_cost", 0))]
		"information":
			return str({"mine_count": "查看以本房为中心5×5范围的雷数。", "mine_locations": "揭示3×3范围内尚未知晓的雷位。", "chest_locations": "揭示5×5范围内尚未知晓的宝箱位置。", "exit_direction": "获知最近出口方向，不直接进入出口。"}.get(action, ""))
		"shortcut": return "查看%s的已知情报；实际通行需6黑币。" % _pos_text(params.get("target_pos")) if action == "preview_target" else "进入%s，结算目标房入口危险。" % _pos_text(params.get("target_pos"))
		"demine": return "起爆%s；命中解除地雷并增加10基础压力，未命中仍收费。" % _pos_text(params.get("target_pos"))
		"recon": return "揭示%d×%d范围内的新雷位；无新情报不收费。" % [int(action.trim_prefix("recon_")), int(action.trim_prefix("recon_"))]
		"mechanism":
			var electric := str(state.get("variant", "")) == "electric"
			if action == "assist":
				return "消耗该材料，免除本次电流伤害并领取6黑币及本房物品。" if electric else "消耗该材料，机关战力要求降低3。当前要求：%s。" % str(state.get("threshold", 0))
			return "承受最多10点基础伤害（保留至少1生命），领取6黑币及%s。" % _item_names(state.get("rewards", [])) if electric else "战力至少%s时获得25黑币及%s；失败承受1基础伤害和5基础压力。" % [str(state.get("threshold", 0)), _item_names(state.get("rewards", []))]
		"recycle":
			if item.is_empty() and not state.get("rewards", []).is_empty():
				item = state.rewards[0]
			if action == "take":
				return "带走%s；满包时放在本房地面。" % _item_name(item)
			var tags: Array = room.get("z2_event_rules_view", {}).get("material_tags", {}).get(str(item.get("item_id", "")), [])
			return "交付%s，获得%d安全金币。" % [_item_name(item), 10 if tags.has("anomalous_sample") else (5 if tags.has("mechanical_material") else 0)]
		"coil": return "校准后，下一次完整普通房搜索额外交付1件来自该搜索渠道的物品。"
		"clock_in": return "登记后实际进入3间新房，可回到本处或其它打卡处领取12黑币。" if action == "register" else "签退领取12黑币。已进入%d间新房。" % state.get("contract", {}).get("new_rooms", {}).size()
		"rps":
			var prize := int(room.get("z2_process", {}).get("rps", {}).get("prize", 0))
			return "出%s，先得两胜者结束；胜局奖金%d黑币。" % [str(ACTION_TITLES.get(action, action)), prize]
		"dice": return "掷第%d押：1至4点返还0、5点返还40、6点返还80黑币。" % (state.get("rounds", []).size() + 1)
		"altar": return "消耗该材料，本阶段生命费用降低5。" if action == "assist" else "支付%d生命，获得%d黑币及%s；支付后至少保留1生命。" % [int(state.get("hp_cost", 0)), int(state.get("black_reward", 0)), _item_names(state.get("rewards", []))]
	return str(row.get("effect", "查看当前服务内容。"))


static func _delivered_text(item: Dictionary) -> String:
	return "获得%s，%s。" % [_item_name(item), "已放在本房地面" if str(item.get("location_state", "")) == "room_floor" else "已放入背包"]


static func _result_text(context: RunContext, event: String, option: String, result: Dictionary) -> String:
	if option == "prepare":
		return ""
	if result.get("ignored", false):
		return "该结果已处理。"
	var facts: Dictionary = result.get("facts", {})
	var text := ""
	var fee := int(facts.get("fee_black", 0))
	match event:
		"shop": text = "已刷新本房3格货架。" if option == "refresh" else _delivered_text(facts.get("delivery", {}))
		"savings":
			var deposit: Dictionary = facts.get("deposit", {})
			text = "已存入%d黑币，获得%d安全金币保底；异房可取回%d黑币。" % [int(deposit.get("principal", 0)), int(deposit.get("guarantee", 0)), int(deposit.get("withdrawal", 0))] if option == "deposit" else "取回%d黑币（本金%d、利息%d），已撤销%d安全金币保底。" % [int(facts.get("withdrawn", 0)), int(facts.get("principal", 0)), int(facts.get("interest", 0)), int(deposit.get("guarantee", 0))]
		"seal": text = "抢救容量增加20；最重选中普通藏品结算重量减少%d，最低%d。本局封条已使用。" % [int(facts.get("salvage_rule", {}).get("weight_reduction", 0)), int(facts.get("salvage_rule", {}).get("min_weight", 1))]
		"relief": text = "降低%d压力，当前压力%d。" % [-int(facts.get("pressure", {}).get("actual_pressure_delta", 0)), context.pressure]
		"first_aid": text = _delivered_text(facts.get("delivery", {}))
		"consign": text = "已托运%s，保留原物品等待终局交付。" % _item_name(facts.get("item", {}))
		"expand": text = "战利品背包容量增加%d。" % int(facts.get("loot_capacity_delta", 0))
		"compress": text = "已消耗%s。" % _item_names(facts.get("inputs", [])) + _delivered_text(facts.get("output", {}))
		"trader": text = "已出售%s，获得%d%s。" % [_item_name(facts.get("item", {})), int(facts.get("safe_income_gross", 0)) if int(facts.get("safe_income_gross", 0)) > 0 else int(facts.get("black_income_gross", 0)), "安全金币" if int(facts.get("safe_income_gross", 0)) > 0 else "黑币"]
		"pawn": text = "已抵押%s，获得%d黑币；成功撤离时可付%d黑币赎回原物品。" % [_item_name(facts.get("item", {})), int(facts.get("black_income_gross", 0)), int(facts.get("redeem_cost", 0))]
		"information":
			if facts.has("mine_count"):
				text = "5×5范围内共有%d处地雷。" % int(facts.mine_count)
			elif facts.has("exit_direction"):
				text = "最近出口位于%s。" % str({"N": "北方", "NE": "东北方", "E": "东方", "SE": "东南方", "S": "南方", "SW": "西南方", "W": "西方", "NW": "西北方", "HERE": "本房"}.get(str(facts.exit_direction), str(facts.exit_direction)))
			else:
				text = "已标明%d处新的%s位置。" % [int(facts.get("intel_revealed_count", 0)), "宝箱" if option == "chest_locations" else "地雷"]
		"shortcut": text = "已查看目标%s；确认通行才支付6黑币并结算入口危险。" % _pos_text(result.get("preview", {}).get("target_pos")) if option == "preview_target" else "已进入目标房%s。" % _pos_text(facts.get("target_pos"))
		"demine": text = "命中，已解除目标地雷；压力变化%+d。" % int(facts.get("pressure_delta", 0)) if facts.get("hit", false) else "未命中地雷，本次服务已结清。"
		"recon": text = "已在%d×%d范围标明%d处新雷位。" % [int(facts.get("scan_size", 0)), int(facts.get("scan_size", 0)), int(facts.get("intel_revealed_count", 0))]
		"mechanism":
			text = "辅助材料已消耗，机关战力要求降至%s。" % str(facts.threshold) if facts.has("threshold") else ("机关处理成功，获得%d黑币。" % int(facts.get("black_income_gross", 0)) if facts.get("success", false) else "机关判定未通过，本次已结清。")
		"recycle":
			var item: Dictionary = context.asset_ledger.item_instances.get(str(facts.get("item_instance_id", "")), {})
			text = "已带走%s。" % _item_name(item) if str(facts.get("operation", "")) == "take" else "已交付%s，获得%d安全金币。" % [_item_name(item), int(facts.get("safe_income", 0))]
		"coil": text = "线圈已校准，等待下一次完整普通房搜索交付额外物品。" if option == "calibrate" else "线圈额外物品已在搜索房交付。"
		"clock_in": text = "登记成功，实际进入3间新房后可签退领款。" if option == "register" else "已核验%d间新房，签退领取%d黑币。" % [facts.get("new_rooms", []).size(), int(facts.get("black_income_gross", 0))]
		"rps":
			text = "你出%s，对方出%s：%s。" % [str(ACTION_TITLES.get(str(facts.get("player", "")), "")), str(ACTION_TITLES.get(str(facts.get("opponent", "")), "")), str({"win": "本轮获胜", "loss": "本轮落败", "tie": "本轮平局"}.get(str(facts.get("outcome", "")), ""))]
			if facts.has("match_win"):
				text += " 本局获胜，领取%d黑币。" % int(facts.get("black_income_gross", 0)) if facts.match_win else " 本局落败，奖金为0黑币，已结清。"
		"cage": text = "围笼战斗开始，封门期间不能撤退。" if facts.get("combat_requested", false) else ("围笼战斗胜利，战力增加%d。" % int(facts.get("power_gain", 0)) if facts.get("win", false) else "围笼战斗落败，已按真实战果结清。")
		"dice": text = "第%d押掷出%d点，%s；返还%d黑币，本押净额%+d黑币。" % [int(facts.get("round", 0)), int(facts.get("face", 0)), "赢了本押" if facts.get("win", false) else "输了本押", int(facts.get("returned_black", 0)), int(facts.get("net_black", 0))]
		"altar": text = "辅助材料已消耗，本阶段生命费用降至%d。" % int(facts.hp_cost) if facts.has("hp_cost") else "第%d阶段献祭完成，支付%d生命，获得%d黑币。" % [int(facts.get("tier", 0)), int(facts.get("payment", {}).get("paid", 0)), int(facts.get("black_income_gross", 0))]
	if fee > 0:
		text = "支付%d黑币。" % fee + text
	if facts.has("damage"):
		text += " 实际损失%d生命。" % int(facts.damage.get("actual_hp_loss", 0))
	if facts.has("pressure") and event != "relief":
		text += " 实际压力变化%+d，当前%d。" % [int(facts.pressure.get("actual_pressure_delta", 0)), context.pressure]
	for item: Dictionary in facts.get("items", []):
		text += " " + _delivered_text(item)
	return text


static func _reason_text(reason: String) -> String:
	var messages := {"stale_quote": "报价已变化，请重新查看后选择。", "stale_revision": "服务状态已变化，请刷新后选择。",
		"stale_altar_offer": "祭坛阶段已变化，请重新查看当前报价。", "not_prepared": "请先查看当前报价。",
		"insufficient_black": "本局黑币不足。", "insufficient_hp": "生命不足，支付后须至少保留1点。",
		"sold": "该商品已售出。", "room_complete": "本房服务已结清。", "completed": "本房服务已结清。", "already_completed": "本房服务已结清。",
		"no_effect": "当前不会产生有效变化，未收取费用。", "no_new_intel": "范围内没有新的情报，未收取费用。",
		"select_principal": "请先输入本金并更新报价。", "invalid_principal": "本金必须是大于零的整数。",
		"pending_deposit": "本局已有一笔待兑存款。", "no_pending_deposit": "当前没有待兑存款。", "same_room_savings": "请到另一间储蓄房取款。",
		"guarantee_unavailable": "当前安全金币不足以撤销这笔存款的保底。", "seal_already_used": "本局抢救封条已使用。", "pawn_already_used": "本局抵押预支已使用。",
		"invalid_compression_inputs": "请选择背包中两件不同的一档普通藏品。", "item_not_in_inventory": "所选物品已不在背包中。",
		"material_unavailable": "辅助材料已不在背包中。", "invalid_material": "所选材料不适用于本项服务。",
		"manual_flag_required": "目标需要先手动插旗。", "invalid_target": "请选择本房提供的有效目标。",
		"preview_required": "请先查看这个出口。", "stale_preview": "目标情报已变化，请重新查看出口。", "flag_confirmation_required": "目标有风险标记，请确认后通行。",
		"empty_eligible_pool": "当前没有符合条件的物品，未收取费用。", "empty_material_pool": "当前没有符合条件的材料，未收取费用。",
		"coil_pending": "已有一只线圈等待实际搜索交付。", "work_contract_exists": "本局已登记打卡。", "work_incomplete": "尚未进入3间新的房间。", "work_claimed": "打卡款项已经领取。",
		"already_assisted": "本次祭坛已经使用辅助材料。", "cage_combat_locked": "围笼战斗尚未结束，不能离开。", "combat_hook_required": "等待真实围笼战斗结果。",
		"unavailable": "当前条件尚未满足。"}
	return str(messages.get(reason, "操作未完成（%s）。" % reason))


static func _tagged_items(context: RunContext, view: Dictionary, required: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var memberships: Dictionary = view.get("material_tags", {})
	for item: Dictionary in context.asset_ledger.get_items_by_location(&"inventory"):
		var tags: Array = memberships.get(str(item.get("item_id", "")), [])
		for tag: Variant in required:
			if tags.has(tag):
				result.append(item)
				break
	return result


static func _process_options(context: RunContext, pos: Vector2i, event: String, state: Dictionary) -> Array:
	var rows: Array[Dictionary] = []
	if not state.get("prepared", false) or state.get("completed", false):
		return rows
	var room: Dictionary = context.z1_event_rooms.get(context.cell_key(pos), {})
	var view: Dictionary = room.get("z2_event_rules_view", {})
	var money := context.asset_ledger.get_currency(&"black_coin")
	match event:
		"mechanism":
			var electric := str(state.get("variant", "mechanical")) == "electric"
			var can_attempt := not str(view.get("electric_damage_type" if electric else "mechanism_failure_damage_type", "")).is_empty() or (not electric and float(context.power) >= float(state.get("threshold", INF)))
			rows.append(_process_row("attempt", 0, can_attempt))
			for item: Dictionary in _tagged_items(context, view, ["insulation", "repair"] if electric else ["dismantling", "reset"]):
				rows.append(_process_row("assist", 0, true, {"instance_id": str(item.instance_id)}))
		"recycle":
			rows.append(_process_row("take"))
			rows.append(_process_row("deliver"))
			for item: Dictionary in _tagged_items(context, view, ["mechanical_material", "anomalous_sample"]):
				rows.append(_process_row("deliver", 0, true, {"instance_id": str(item.instance_id)}))
		"coil":
			rows.append(_process_row("calibrate", 5, money >= 5 and state.get("pending", {}).is_empty()))
		"clock_in":
			var work: Dictionary = state.get("contract", {})
			rows.append(_process_row("register", 4, money >= 4 and work.is_empty()))
			rows.append(_process_row("claim", 0, not work.is_empty() and not work.get("claimed", false) and work.get("new_rooms", {}).size() >= 3))
		"rps":
			for hand in ["rock", "paper", "scissors"]:
				rows.append(_process_row(hand))
		"dice":
			rows.append(_process_row("roll", 20, money >= 20 and state.get("rounds", []).size() < 3))
		"altar":
			var price := int(state.get("hp_cost", 0))
			var row := _process_row("offer", 0, context.hp > price)
			row.merge({"cost_kind": "hp", "cost_amount": price, "cost_text": "%d生命" % price}, true)
			rows.append(row)
			if not state.get("assisted", false):
				for item: Dictionary in _tagged_items(context, view, ["stabilizing", "flow_control"]):
					rows.append(_process_row("assist", 0, true, {"instance_id": str(item.instance_id)}))
	return rows
