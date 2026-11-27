extends RefCounted
class_name Z2OpeningRuntime

# Candidate-only module. Parent owns durable commit, meta payment, real hook
# production and combat/event routing. No UI, file IO or new Context fields.
const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
const Effects = preload("res://scripts/core/run/run_effect_applier.gd")
const Talents = preload("res://scripts/core/progression/z2_talent_runtime.gd")
const Inventory = preload("res://scripts/core/run/run_inventory.gd")
const Offer = preload("res://scripts/core/progression/z2_opening_offer.gd")
const KEY := "z2_opening"
const IDS = Offer.IDS
const LABELS = Offer.LABELS
const D06_POLICY := {"id": "d06_stop_before_terminal_fee_v1", "threshold_order": "stop_before_fee", "insufficient": "skip_whole_fee_no_debt"}


static func public_state(context: RunContext) -> Dictionary:
	var state := _state(context).duplicate(true)
	state.erase("receipts")
	state.erase("hooks")
	state["unlocked"] = _unlocked(context)
	state["future_batches"] = _future_batches(context)
	state["status"] = str(state.get("status", "unprepared"))
	state["attack_allowed"] = not (state.get("selected", "") == "avoidance" and bool(state.get("effect_state", {}).get("active", false)))
	state["next_refresh_gold"] = (int(state.get("refresh_count", 0)) + 1) * 5 if int(state.get("refresh_count", 0)) < 10 and state.status == "offered" else 0
	return state


static func admit_departure(context: RunContext, trusted_offer: Dictionary) -> Dictionary:
	if context == null or context.asset_ledger == null:
		return _fail("no_context")
	if context.run_start_config.get("z2_opening_offer", {}) != trusted_offer:
		return _fail("trusted_final_offer_required")
	if trusted_offer.is_empty() and _unlocked(context) and context.mode != &"tutorial":
		trusted_offer = Offer.initial_offer(str(context.run_id) + ":opening", context.seed_value)
		context.run_start_config["z2_opening_offer"] = trusted_offer.duplicate(true)
	if trusted_offer.is_empty():
		var noop := _ok(false)
		noop["noop"] = true
		return noop
	if not _unlocked(context):
		return _fail("first_batch_locked")
	if not Offer.valid_offer(trusted_offer):
		return _fail("trusted_final_offer_required")
	var state := _state(context)
	if not state.is_empty():
		return _duplicate(_ok(false)) if state.get("admitted_offer", {}) == trusted_offer else _fail("opening_already_admitted")
	if not _before_departure(context):
		return _fail("departure_already_started")
	state = {"version": 1, "status": trusted_offer.status, "selected": trusted_offer.selected,
		"initial_power": context.power, "refresh_count": int(trusted_offer.refresh_count), "paid_gold": int(trusted_offer.paid_gold),
		"offer_id": trusted_offer.offer_id, "candidates": trusted_offer.candidates.duplicate(), "admitted_offer": trusted_offer.duplicate(true),
		"effect_state": {}, "receipts": {}, "hooks": {}}
	if state.status == "selected":
		state.effect_state = _activate(context, str(state.selected), int(state.initial_power))
	context.z1_event_flags[KEY] = state
	context.asset_ledger.sync_compat_fields(context)
	return _ok(state.status == "selected", {"opening_selected": state.selected, "offer_key": trusted_offer.offer_key, "initial_power": state.initial_power})


static func confirm_spawn_offer(context: RunContext, offer: Dictionary, action: String, payload: Dictionary) -> Dictionary:
	var state := _state(context)
	if state.get("status") != "offered" or not Offer.valid_offer(offer) or offer.status != "offered":
		return _fail("choice_closed")
	if str(payload.get("offer_id", "")) != str(offer.offer_id):
		return _fail("stale_offer")
	for key in ["offer_id", "candidates", "refresh_count", "paid_gold"]:
		state[key] = offer[key]
	state["admitted_offer"] = offer.duplicate(true)
	var result := execute(context, action, payload, {"d06_policy": D06_POLICY})
	if result.get("ok", false):
		var selected := str(_state(context).selected)
		state = _state(context)
		state.admitted_offer.status = state.status
		state.admitted_offer.selected = selected
		context.run_start_config["opening_effect"] = {"id": selected, "batch": 1} if not selected.is_empty() else {}
		context.run_start_config["z2_opening_offer"] = state.admitted_offer.duplicate(true)
	return result


static func options(context: RunContext) -> Array[Dictionary]:
	var state := public_state(context)
	var result: Array[Dictionary] = []
	if state.status != "offered":
		return result
	for id in state.get("candidates", []):
		result.append({"effect_id": id, "label": LABELS[IDS.find(id)], "description": Offer.DESCRIPTIONS[IDS.find(id)], "offer_id": state.offer_id, "initial_power": state.initial_power})
	return result


static func plan_trigger(context: RunContext, fact: Dictionary) -> Dictionary:
	var state := public_state(context)
	var predicted := _ok(false)
	if context != null and not _state(context).is_empty():
		var candidate := RunContext.new()
		Snapshot.install_context(candidate, Snapshot.capture_context(context))
		predicted = _hook(candidate, _state(candidate).duplicate(true), fact)
	return {"read_only": true, "selected": state.get("selected", ""), "kind": fact.get("kind", ""),
		"attack_allowed": state.attack_allowed, "candidate_required": true,
		"predicted": predicted,
		"hook_phase": "after_credit_before_spend" if fact.get("kind", "") in ["black_income", "currency_income"] else "after_actual_before_default_consequence",
		"effect_state": state.get("effect_state", {}).duplicate(true)}


static func execute(context: RunContext, action: String, payload: Dictionary = {}, services: Dictionary = {}) -> Dictionary:
	if context == null or context.asset_ledger == null:
		return _fail("no_context")
	var action_id := str(payload.get("action_id", ""))
	if action_id.is_empty():
		return _fail("action_id_required")
	var state := _state(context)
	var request := {"action": action, "payload": payload.duplicate(true)}
	if state.get("receipts", {}).has(action_id):
		var saved: Dictionary = state.receipts[action_id]
		if saved.request != request:
			return _fail("action_id_conflict")
		return _duplicate(saved.result)
	var before := Snapshot.capture_context(context)
	var result := _execute(context, state.duplicate(true), action, payload, services)
	if not bool(result.get("ok", false)):
		Snapshot.install_context(context, before)
		return result
	state = _state(context)
	if not state.is_empty():
		state.receipts[action_id] = {"request": request, "result": result.duplicate(true)}
		context.z1_event_flags[KEY] = state
	context.asset_ledger.sync_compat_fields(context)
	return result


static func _execute(c: RunContext, state: Dictionary, action: String, p: Dictionary, services: Dictionary) -> Dictionary:
	if action == "prepare":
		if not state.is_empty():
			return _ok(false)
		if not _unlocked(c):
			return _fail("first_batch_locked")
		if not _before_departure(c):
			return _fail("departure_already_started")
		state = {"version": 1, "status": "offered", "selected": "", "initial_power": c.power,
			"refresh_count": 0, "paid_gold": 0, "receipts": {}, "hooks": {}, "effect_state": {}}
		_offer(c, state)
		c.z1_event_flags[KEY] = state
		return _ok(true, {"offered": true})
	if state.is_empty():
		return _ok(false) if action == "hook" else _fail("requires_prepare")
	match action:
		"choose", "skip", "refresh":
			if state.status != "offered" or not _before_departure(c):
				return _fail("choice_closed")
			if action != "skip" and str(p.get("offer_id", "")) != str(state.offer_id):
				return _fail("stale_offer")
			if action == "skip":
				state.status = "skipped"
			elif action == "refresh":
				if int(state.refresh_count) >= 10:
					return _fail("refresh_limit")
				var pay: Callable = services.get("pay_refresh", Callable())
				if not pay.is_valid():
					return _fail("candidate_meta_payment_required")
				var amount := (int(state.refresh_count) + 1) * 5
				var receipt: Variant = pay.call(c, amount, str(p.action_id))
				if not receipt is Dictionary or not receipt.get("ok", false) or receipt.get("spent", -1) != amount or receipt.get("currency", "") != "meta_gold":
					return _fail("meta_payment_failed")
				state.refresh_count = int(state.refresh_count) + 1
				state.paid_gold = int(state.paid_gold) + amount
				_offer(c, state)
			else:
				var effect_id := str(p.get("effect_id", ""))
				if not state.candidates.has(effect_id):
					return _fail("effect_not_offered")
				if effect_id == "rebate" and services.get("d06_policy", {}) != D06_POLICY:
					return _fail("d06_policy_required")
				state.status = "selected"
				state.selected = effect_id
				state.effect_state = _activate(c, effect_id, int(state.initial_power))
			c.z1_event_flags[KEY] = state
			return _ok(true, {"selected": state.selected, "refresh_count": state.refresh_count, "paid_gold": state.paid_gold})
		"end":
			if state.status != "selected" or not state.selected in ["avoidance", "power_life"] or not bool(state.effect_state.get("active", false)):
				return _fail("cannot_end")
			if state.selected == "power_life":
				# Same contribution/floor accounting as unequipping maxHP equipment.
				Inventory.apply_equipment_change(c, {"ok": true, "equipment_changes": [
					{"from": &"equipped", "to": &"inventory", "item": {"effect_kind": "max_hp", "effect_amount": state.effect_state.hp_bonus}}]})
				c.power += int(state.effect_state.power_cost)
			state.effect_state.active = false
			c.z1_event_flags[KEY] = state
			return _ok(true, {"ended": state.selected})
		"hook":
			return _hook(c, state, p.get("fact", {}))
		"dismantle", "use_tool":
			if state.get("selected", "") != "dismantle":
				return _fail("dismantle_not_selected")
			var result := _dismantle(c, state.effect_state, p) if action == "dismantle" else _tool(c, state.effect_state, p, services)
			if result.get("ok", false):
				c.z1_event_flags[KEY] = state
			return result
	return _fail("unknown_action")


static func _activate(c: RunContext, id: String, power: int) -> Dictionary:
	match id:
		"mine_pressure":
			return {"mine_uses": 0}
		"rebate":
			return {"gross": 0, "boundaries": 0, "fees_paid": 0, "fees_skipped": 0, "done": false, "policy": D06_POLICY.duplicate(true)}
		"avoidance":
			return {"active": true, "rooms": 0, "power_bonus": 0, "initial_power": power, "spawn": c.cell_key(c.get_current_pos())}
		"power_life":
			var bonus := floori(power * 0.5)
			var cost := floori(power * 0.1)
			Inventory.apply_equipment_change(c, {"ok": true, "equipment_changes": [
				{"from": &"inventory", "to": &"equipped", "item": {"effect_kind": "max_hp", "effect_amount": bonus}}]})
			c.power -= cost
			return {"active": true, "hp_bonus": bonus, "power_cost": cost}
		"status_clear":
			return {"uses": 0}
		"sacrifice":
			return {"uses": 0}
		"forced_cash":
			var bonus := floori(c.asset_ledger.backpack_capacity * 0.4)
			c.asset_ledger.backpack_capacity += bonus
			return {"active": true, "capacity_bonus": bonus}
		"dismantle":
			return {"uses": 0, "tools": {"scan": 0, "trap": 0}}
		"auto_clear":
			return {"clears": 0, "empty_chests": 0}
	return {}


static func _hook(c: RunContext, state: Dictionary, fact_value: Variant) -> Dictionary:
	if not fact_value is Dictionary:
		return _fail("invalid_fact")
	var fact: Dictionary = fact_value
	if fact.get("actual", false) != true or str(fact.get("fact_id", "")).is_empty():
		return _fail("actual_fact_required")
	if state.status != "selected":
		return _ok(false)
	var kind := str(fact.get("kind", ""))
	var pos: Vector2i = c.get_current_pos()
	var identity := kind + ":" + str(fact.fact_id)
	var income_currency := ""
	if kind in ["room_entered", "mine_hit", "chest_opened", "ordinary_combat_cleared", "forced_cage"]:
		if not fact.get("pos") is Vector2i or fact.pos != pos or not c.visited_cells.has(c.cell_key(pos)):
			return _fail("actual_room_required")
		identity = kind + ":" + c.cell_key(pos)
	if kind in ["black_income", "currency_income"]:
		var valid := _income_receipt(c, fact, kind == "black_income")
		if not valid.get("ok", false):
			return valid
		income_currency = str(valid.facts.currency_id)
		identity = "income:" + str(fact.ledger_index)
	if state.hooks.has(identity):
		return _duplicate(state.hooks[identity])
	var effect: Dictionary = state.effect_state
	var result := _ok(false)
	match str(state.selected):
		"rebate":
			if income_currency == "black_coin":
				result = _rebate(c, effect, int(fact.gross))
		"mine_pressure":
			if kind == "mine_hit" and c.truth_map.is_mine(pos) and c.truth_map.is_triggered(pos) and int(effect.mine_uses) < 3:
				result = _pressure(c, -10)
				if result.ok:
					effect.mine_uses = int(effect.mine_uses) + 1
					result.applied = true # Waiving the actual +10 is useful even at zero pressure.
					result.facts.replace_mine_pressure = true
			elif kind == "chest_opened" and c.truth_map.get_room_type(pos) == &"Chest":
				result = _pressure(c, 4)
		"avoidance":
			if bool(effect.active):
				if kind == "forced_cage" and str(fact.get("event_id", "")) == "cage" and c.truth_map.get_room_type(pos) == &"Event":
					effect.active = false
					result = _ok(true, {"avoidance_ended": "forced_cage"})
				elif kind == "room_entered" and fact.get("first_visit", false) == true and c.cell_key(pos) != effect.spawn:
					effect.rooms = mini(8, int(effect.rooms) + 1)
					var next_bonus := floori(int(effect.initial_power) * int(effect.rooms) / 40.0)
					var delta := next_bonus - int(effect.power_bonus)
					c.power += delta
					effect.power_bonus = next_bonus
					effect.active = int(effect.rooms) < 8
					result = _ok(true, {"new_rooms": 1, "power_delta": delta, "gain_percent": int(effect.rooms) * 2.5})
		"status_clear":
			if kind == "statuses_changed" and int(effect.uses) == 0 and _temporary_types(c).size() >= 3:
				var cleared := Effects.advance_statuses(c, 0.0, {"kind": "clear_temporary"})
				if not cleared.get("ok", false):
					return cleared
				var ended: Array = cleared.get("facts", {}).get("ended", [])
				if not ended.is_empty():
					effect.uses = 1
					result = _ok(true, {"statuses_cleared": ended})
		"sacrifice":
			if kind == "ordinary_combat_cleared" and c.truth_map.get_room_type(pos) == &"Monster" and c.truth_map.is_cleared(pos) and not bool(fact.get("automatic", true)) and str(fact.get("combat_id", "")) != "" and int(effect.uses) < 6 and c.max_hp > 5:
				var payment := Effects.apply_damage_packet(c, {"damage_type": "max_hp_payment", "amount": 5, "source_id": "opening_sacrifice"})
				if not payment.get("ok", false):
					return payment
				c.power += 2
				effect.uses = int(effect.uses) + 1
				result = _ok(true, {"power_delta": 2, "max_hp_delta": -5, "payment": payment.facts})
		"forced_cash":
			if kind == "inventory_changed" and bool(effect.active):
				result = _cash(c, effect)
		"auto_clear":
			if kind == "room_entered" and fact.get("first_visit", false) == true and c.truth_map.get_room_type(pos) == &"Monster" and not c.truth_map.is_cleared(pos) and int(effect.clears) < 2:
				c.truth_map.mark_cleared(pos)
				c.intel_map.reveal_cell(pos, c.truth_map)
				effect.clears = int(effect.clears) + 1
				result = _ok(true, {"automatic_combat_clear": true, "suppress_combat_rewards": true, "pos": pos})
			elif kind == "chest_opened" and c.truth_map.get_room_type(pos) == &"Chest" and int(effect.empty_chests) == 0:
				effect.empty_chests = 1
				result = _ok(true, {"suppress_loot": true, "empty_chest": true, "pos": pos})
	if not result.get("ok", false):
		return result
	state.effect_state = effect
	state.hooks[identity] = result.duplicate(true)
	c.z1_event_flags[KEY] = state
	return result


static func _income_receipt(c: RunContext, fact: Dictionary, black_only: bool) -> Dictionary:
	if not fact.get("ledger_index") is int or not fact.get("gross") is int or int(fact.gross) <= 0:
		return _fail("invalid_gross_receipt")
	var index := int(fact.ledger_index)
	if index < 0 or index >= c.asset_ledger.settlement_log.size():
		return _fail("missing_income_entry")
	var entry: Dictionary = c.asset_ledger.settlement_log[index]
	var currency := str(entry.get("currency_id", ""))
	if str(entry.get("type", "")) != "currency_delta" or currency.is_empty() or (black_only and currency != "black_coin") or entry.get("amount", 0) != fact.gross:
		return _fail("gross_receipt_mismatch")
	return _ok(false, {"currency_id": currency})


static func _rebate(c: RunContext, effect: Dictionary, gross: int) -> Dictionary:
	if bool(effect.done):
		return _ok(false)
	if effect.get("policy", {}) != D06_POLICY:
		return _fail("unsupported_d06_policy")
	var total := int(effect.gross) + gross
	var target_boundaries := mini(16, floori(total / 5.0))
	var charged := 0
	var skipped := 0
	var rebate := 0
	for boundary in range(int(effect.boundaries) + 1, target_boundaries + 1):
		if boundary * 5 >= 80:
			effect.done = true
			c.asset_ledger.add_currency(&"gold_coin", 50, "opening_rebate_safe")
			rebate = 50
			break
		var paid := c.asset_ledger.spend_currency(&"black_coin", 2, "opening_rebate_fee")
		if paid.get("ok", false):
			charged += 2
		else:
			skipped += 1
	effect.gross = total
	effect.boundaries = target_boundaries
	effect.fees_paid = int(effect.fees_paid) + charged
	effect.fees_skipped = int(effect.fees_skipped) + skipped
	return _ok(true, {"black_income_gross": gross, "fee_black": charged, "skipped_fees": skipped, "safe_gold": rebate})


static func _cash(c: RunContext, effect: Dictionary) -> Dictionary:
	var ledger = c.asset_ledger
	if ledger.get_backpack_used() * 5 <= ledger.backpack_capacity * 4:
		return _ok(false)
	var ids: Array = []
	var proceeds := 0
	for item in ledger.get_items_by_location(&"inventory"):
		var price := floori(int(item.get("base_value", 0)) * 0.6)
		if _loot(item) and bool(item.get("can_sell", false)) and price > 0:
			ids.append(str(item.instance_id))
			proceeds += price
	if proceeds <= 0:
		return _ok(false)
	var moved: Dictionary = ledger.transfer_event_items(ids, &"consumed")
	if not moved.get("ok", false):
		return moved
	ledger.add_currency(&"black_coin", proceeds, "opening_forced_cash")
	var index: int = ledger.settlement_log.size() - 1
	ledger.backpack_capacity = maxi(0, ledger.backpack_capacity - int(effect.capacity_bonus))
	var dropped: Array = []
	var remaining: Array = ledger.get_items_by_location(&"inventory")
	# Preserve every unsold instance. Acquisition order is deterministic on replay.
	remaining.sort_custom(func(a: Dictionary, b: Dictionary): return int(a.get("acquired_sequence", 0)) > int(b.get("acquired_sequence", 0)))
	for item in remaining:
		if ledger.get_backpack_used() <= ledger.backpack_capacity:
			break
		if bool(item.get("can_consume", false)) or str(item.get("item_type", "")) == "consumable":
			continue
		var drop: Dictionary = ledger.drop_inventory_item(str(item.instance_id), c.get_current_pos())
		if not drop.get("ok", false):
			return drop
		dropped.append(str(item.instance_id))
	if ledger.get_backpack_used() > ledger.backpack_capacity:
		return _fail("overflow_unresolved")
	effect.active = false
	return _ok(true, {"sold_instances": ids, "black_income_gross": proceeds, "ledger_index": index, "overflow_dropped": dropped})


static func _dismantle(c: RunContext, effect: Dictionary, p: Dictionary) -> Dictionary:
	var tool := str(p.get("tool", ""))
	var id := str(p.get("instance_id", ""))
	var item: Dictionary = c.asset_ledger.item_instances.get(id, {})
	if not tool in ["scan", "trap"] or int(effect.uses) >= 3:
		return _fail("invalid_tool_or_limit")
	if not _loot(item) or str(item.get("location_state", "")) != "inventory":
		return _fail("requires_non_equipment_loot")
	var consumed := c.asset_ledger.transfer_event_items([id], &"consumed")
	if not consumed.get("ok", false):
		return consumed
	effect.uses = int(effect.uses) + 1
	effect.tools[tool] = int(effect.tools[tool]) + 1
	return _ok(true, {"dismantled_instance": id, "tool": tool, "tools_created": 1})


static func _tool(c: RunContext, effect: Dictionary, p: Dictionary, services: Dictionary) -> Dictionary:
	var tool := str(p.get("tool", ""))
	if not tool in ["scan", "trap"] or int(effect.tools.get(tool, 0)) <= 0:
		return _fail("no_tool")
	var resolver: Callable = services.get("resolve_tool", Callable())
	if not resolver.is_valid():
		return _fail("actual_tool_resolver_required")
	var request := {"tool": tool, "action_id": p.action_id}
	if tool == "trap":
		if c.truth_map.get_room_type(c.get_current_pos()) != &"Event" or not c.visited_cells.has(c.cell_key(c.get_current_pos())):
			return _fail("actual_mechanism_room_required")
		var threshold_source: Callable = services.get("trap_threshold", Callable())
		if not threshold_source.is_valid():
			return _fail("actual_trap_threshold_required")
		var base: Variant = threshold_source.call(c)
		if not (base is int or base is float) or not is_finite(float(base)) or base <= 0:
			return _fail("invalid_trap_threshold")
		request.base_threshold = base
		request.threshold = maxf(0.0, float(base) - 3.0)
		if float(c.power) >= float(base) or float(c.power) < float(request.threshold):
			return _fail("no_trap_tool_benefit")
	var before_known: Dictionary = c.intel_map.known_rooms.duplicate(true)
	var before_visits := c.visited_cells.duplicate(true)
	var before_explored := c.explored_cells.duplicate(true)
	var before_truth := Snapshot.capture_data(c.truth_map)
	var before_marks := c.intel_map.mark_map.duplicate(true)
	var before_pos := c.get_current_pos()
	var before_rooms := c.z1_event_rooms.duplicate(true)
	var receipt: Variant = resolver.call(c, request.duplicate(true))
	if not receipt is Dictionary or not receipt.get("ok", false) or not receipt.get("applied", false):
		return _fail("tool_resolution_failed")
	var revealed := 0
	if tool == "scan":
		if before_visits != c.visited_cells or before_explored != c.explored_cells or before_pos != c.get_current_pos() or before_truth != Snapshot.capture_data(c.truth_map) or before_marks != c.intel_map.mark_map:
			return _fail("scan_changed_actual_visits")
		for key in c.intel_map.known_rooms:
			var old: Dictionary = before_known.get(key, {})
			var next: Dictionary = c.intel_map.known_rooms[key]
			if bool(old.get("flagged", false)) != bool(next.get("flagged", false)) or bool(old.get("revealed", false)) != bool(next.get("revealed", false)):
				return _fail("scan_changed_actual_reveal_or_flag")
			if _new_intelligence(c, old, next):
				revealed += 1
		if revealed == 0:
			return _fail("no_new_scan_information")
	else:
		var room_key := c.cell_key(before_pos)
		if receipt.get("threshold", -1) != request.threshold or not receipt.get("stage_completed", false) or not receipt.get("facts", {}).get("success", false) or before_rooms.get(room_key, {}) == c.z1_event_rooms.get(room_key, {}):
			return _fail("trap_not_actually_completed")
	var pressure := _pressure(c, 4)
	if not pressure.ok:
		return pressure
	effect.tools[tool] = int(effect.tools[tool]) - 1
	pressure.applied = true
	pressure.facts.merge({"tool": tool, "tools_consumed": 1, "intel_revealed_count": revealed, "threshold_reduction": float(request.get("base_threshold", 0)) - float(request.get("threshold", 0))})
	pressure["tool_result"] = receipt.duplicate(true)
	return pressure


static func _new_intelligence(c: RunContext, old: Dictionary, next: Dictionary) -> bool:
	if not next.get("pos") is Vector2i or not c.truth_map.is_inside(next.pos):
		return false
	if bool(next.get("confirmed_mine", false)) and not bool(old.get("confirmed_mine", false)) and c.truth_map.is_mine(next.pos):
		return true
	var count := int(next.get("adjacent_mines", -1))
	if count >= 0 and count != int(old.get("adjacent_mines", -1)) and count == c.truth_map.get_adjacent_mine_count(next.pos):
		return true
	var hint := str(next.get("scan_room_type_hint", "unknown"))
	return hint != str(old.get("scan_room_type_hint", "unknown")) and hint == str(c.truth_map.get_room_type(next.pos))


static func _pressure(c: RunContext, amount: int) -> Dictionary:
	var applied := Effects.apply_pressure_packet(c, {"amount": amount, "source_id": "opening_pressure", "reason": "opening_pressure"})
	if not applied.get("ok", false):
		return applied
	return _ok(int(applied.facts.actual_pressure_delta) != 0, {"pressure_delta": int(applied.facts.actual_pressure_delta), "pressure": applied.facts})


static func _temporary_types(c: RunContext) -> Dictionary:
	var types := {}
	for raw in c.temporary_statuses:
		if raw is Dictionary and str(raw.get("type", "")) in ["temporary_buff", "temporary_debuff"] and str(raw.get("phase", "ended")) != "ended" and str(raw.get("temporary_type", "")) != "":
			types[str(raw.temporary_type)] = true
	return types


static func _loot(item: Dictionary) -> bool:
	return not item.is_empty() and not bool(item.get("can_equip", false)) and not bool(item.get("can_consume", false)) and not bool(item.get("is_unique", false)) and str(item.get("item_type", "")) in ["collectible", "material"]


static func _offer(c: RunContext, state: Dictionary) -> void:
	var key := str(c.run_id) + ":opening"
	state.candidates = Offer.draw_candidates(key, c.seed_value, int(state.refresh_count))
	state.offer_id = key + ":" + str(state.refresh_count)


static func _before_departure(c: RunContext) -> bool:
	return c.visited_cells.size() <= 1 and c.searched_cells.is_empty() and c.interacted_cells.is_empty() and int(c.run_stats.get("moves", 0)) == 0


static func _unlocked(c: RunContext) -> bool:
	if c == null:
		return false
	for effect in Talents.from_context(c).get("effects", []):
		if effect.get("talent_id", "") == "z2_talent_15" and effect.get("effect_kind", "") == "opening_effect_batch_unlock" and effect.get("effect_params", {}).get("batch", 0) == 1:
			return true
	return false


static func _future_batches(c: RunContext) -> Array:
	var batches: Array = []
	if c != null:
		for effect in Talents.from_context(c).get("effects", []):
			var batch := int(effect.get("effect_params", {}).get("batch", 0))
			if effect.get("talent_id", "") in ["z2_talent_29", "z2_talent_39"] and batch in [2, 3] and not batches.has(batch):
				batches.append(batch)
	batches.sort()
	return batches


static func _state(c: RunContext) -> Dictionary:
	if c == null:
		return {}
	return c.z1_event_flags.get(KEY, {})


static func _ok(applied: bool, facts: Dictionary = {}) -> Dictionary:
	return {"ok": true, "applied": applied, "facts": facts, "stage_completed": false}


static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "applied": false, "reason": reason}


static func _duplicate(result: Dictionary) -> Dictionary:
	var copy := result.duplicate(true)
	copy["duplicate"] = true
	copy["applied"] = false
	return copy
