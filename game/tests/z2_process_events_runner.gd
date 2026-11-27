extends SceneTree

const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
const ProcessEvents = preload("res://scripts/core/run/z2_process_events.gd")
const Items = preload("res://scripts/core/content/z2_item_catalog.gd")
const Eligibility = preload("res://scripts/core/content/z2_content_eligibility.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_projection_and_pools()
	_test_mechanism()
	_test_recycle()
	_test_coil()
	_test_clock_in()
	_test_rps()
	_test_cage()
	_test_dice()
	_test_altar()
	_test_atomic_resume()
	_test_pending_restore()
	_test_recycle_full_bag()
	_test_stale_altar()
	for failure in failures:
		print("Z2_PROCESS_CASE_FAIL " + failure)
	print("Z2_PROCESS_EVENTS=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _runtime():
	var runtime = Runtime.new()
	runtime.command_bus.dispatch(&"start_demo_run", {})
	var c: RunContext = runtime.context
	c.run_id = &"t12-fixture-run"
	c.seed_value = 428
	c.profile_fields = {"ruleset_id": "z2", "z2_progression_version": 1,
		"content_eligibility": Eligibility.freeze_profile({"profile_level": 50})}
	c.run_start_config["profile_fields"] = c.profile_fields.duplicate(true)
	c.run_start_config["map_config_id"] = "classic_13x13_hard"
	c.asset_ledger.setup({"run_id": str(c.run_id), "backpack_capacity": 1000, "equipment_capacity": 100})
	c.asset_ledger.add_currency(&"black_coin", 300, "test_setup")
	c.hp = 200
	c.max_hp = 200
	c.pressure = 0
	c.protocol_level = 0
	c.protocol_pressure_reduce = 0
	c.z1_event_rooms.clear()
	c.z1_event_flags.clear()
	c.visited_cells.clear()
	_room(runtime, Vector2i(2, 2))
	return runtime

func _dispose(r) -> void:
	r.checkpoint_writer = Callable()
	r.command_bus.runtime_controller = null
	r.command_bus.room_resolver.bind_runtime_controller(null)
	r.in_run_runtime.bind(null)

func _room(r, pos: Vector2i) -> void:
	r.context.current_pos = pos
	r.context.player_pos = pos
	r.context.visited_cells[r.context.cell_key(pos)] = true

func _rules() -> Dictionary:
	# Explicit, small dependency fixtures. These are NOT official event distributions.
	return {"difficulty": "normal", "mechanism_failure_damage_type": "physical", "electric_damage_type": "physical",
		"pools": {"mechanism": {"channel": "mechanism_success", "items": ["eq_signal_pin"]},
			"electric": {"channel": "chest", "items": ["con_hemostatic_clasp"]},
			"recycle": {"channel": "search", "items": ["col_01"]},
			"normal_search": {"channel": "search", "items": ["col_05"]},
			"altar": {"channel": "altar", "items": ["col_19"]}},
		"material_tags": {"col_01": ["mechanical_material", "dismantling"], "col_02": ["anomalous_sample"],
			"con_tape_roll": ["repair", "insulation"], "col_03": ["stabilizing", "flow_control"]},
		"rps_reward_pool": [27], "enemy_pool": [{"enemy_id": "fixture_actual_enemy", "original_power": 17, "hp": 30}]}

func _state(r, event: String) -> Dictionary:
	return ProcessEvents.public_state(r.context, r.context.get_current_pos(), event)

func _call(r, event: String, option: String, payload: Dictionary = {}, rules: Dictionary = {}, action_id: String = "") -> Dictionary:
	var pos: Vector2i = r.context.get_current_pos()
	return r.execute_atomic_operation(&"z2_process", {"event": event, "pos": pos, "option_id": option, "payload": payload},
		func() -> Dictionary: return ProcessEvents.choose(r.context, pos, event, option, payload, rules), action_id)

func _act(r, event: String, option: String, payload: Dictionary = {}, rules: Dictionary = {}, action_id: String = "") -> Dictionary:
	var request := payload.duplicate(true)
	request["revision"] = _state(r, event).get("revision", 0)
	return _call(r, event, option, request, _rules() if rules.is_empty() else rules, action_id)

func _prepare(r, event: String, rules: Dictionary = {}) -> bool:
	var result := _act(r, event, "prepare", {}, rules)
	_check(result.get("ok", false), event + ": prepares (" + str(result.get("reason", "")) + ")")
	_check(not result.get("valid_stage", false), event + ": prepare has no stage")
	return bool(result.get("ok", false))

func _hook(r, hook: String, receipt: Dictionary = {}, event: String = "", rules: Dictionary = {}) -> Dictionary:
	var pos: Vector2i = r.context.get_current_pos()
	var dependencies := _rules() if rules.is_empty() else rules
	var operation := func() -> Dictionary:
		if hook == "enter":
			return ProcessEvents.on_room_entered(r.context, pos, event, dependencies)
		if hook == "search":
			return ProcessEvents.on_normal_search_completed(r.context, pos, receipt, dependencies)
		return ProcessEvents.on_cage_combat_completed(r.context, pos, receipt)
	return r.execute_atomic_operation(&"z2_process_hook", {"hook": hook, "pos": pos, "receipt": receipt, "event": event}, operation)

func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)

func _black(r) -> int:
	return r.context.asset_ledger.get_currency(&"black_coin")

func _reject(r, event: String, action: String, reason: String, payload: Dictionary = {}, rules: Dictionary = {}) -> void:
	var before: Dictionary = r.capture_authoritative_state()
	var result := _act(r, event, action, payload, rules)
	_check(not result.get("ok", true) and result.get("reason", "") == reason, event + ": rejects " + reason + " got " + str(result.get("reason", "")))
	_check(r.capture_authoritative_state() == before, event + ": rejection leaves authoritative state unchanged")

func _item(r, id: String) -> String:
	return str(r.context.asset_ledger.create_item_instance(Items.definition(id), &"inventory").instance_id)

func _stage(result: Dictionary, xp: int = 5, talent: int = 2) -> void:
	_check(result.get("ok", false) and result.get("valid_stage", false) and result.get("progress_completed", false), "actual result closes a valid stage")
	for key in ["stage_id", "room_id", "event_instance_id", "xp_key", "talent_key", "equipment_key"]:
		_check(not str(result.get(key, "")).is_empty(), "stage has " + key)
	_check(int(result.get("base_xp", -1)) == xp and int(result.get("base_talent", -1)) == talent, "stage separates XP/talent entitlement")

func _test_projection_and_pools() -> void:
	var r = _runtime()
	for event in ["mechanism", "recycle", "coil", "clock_in", "rps", "cage", "dice", "altar"]:
		_check(ProcessEvents.supports(event), "supports " + event)
		var before: Dictionary = r.capture_authoritative_state()
		for _i in range(3):
			_state(r, event)
		_check(r.capture_authoritative_state() == before, event + ": projection does not generate or change assets")
	for event in ["mechanism", "recycle", "coil", "altar"]:
		_reject(r, event, "prepare", "missing_pool", {}, {"pools": {}})
		var rules := _rules()
		var key: String = "normal_search" if event == "coil" else event
		rules.pools[key].items = ["con_red_battery", "unknown_item"]
		_reject(r, event, "prepare", "empty_eligible_pool", {}, rules)
	_dispose(r)

func _test_mechanism() -> void:
	for difficulty in {"easy": 0.8, "normal": 1.0, "hard": 1.3, "hell": 1.6}:
		var r = _runtime()
		r.context.current_adjacent_mines = 4
		var rules := _rules()
		rules.difficulty = difficulty
		if not _prepare(r, "mechanism", rules):
			_dispose(r)
			continue
		var initial := _state(r, "mechanism")
		var base := 34.0 * float({"easy": 0.8, "normal": 1.0, "hard": 1.3, "hell": 1.6}[difficulty])
		_check(float(initial.threshold) >= base * 0.85 and float(initial.threshold) <= base * 1.15, difficulty + ": frozen threshold bounds")
		_prepare(r, "mechanism", rules)
		_check(_state(r, "mechanism").threshold == initial.threshold, "prepare/reopen never rerolls threshold")
		var id := _item(r, "col_01")
		var assisted := _act(r, "mechanism", "assist", {"instance_id": id}, rules)
		_check(assisted.get("ok", false) and not assisted.get("valid_stage", true), "material assistance is not completion")
		_check(is_equal_approx(float(_state(r, "mechanism").threshold), float(initial.threshold) - 3.0), "natural material tag reduces threshold3")
		_reject(r, "mechanism", "assist", "material_unavailable", {"instance_id": id}, rules)
		r.context.power = 200
		var result := _act(r, "mechanism", "attempt", {}, rules)
		_stage(result)
		_check(_black(r) == 325 and result.get("facts", {}).get("items", []).size() == 2, "mechanism real reward25 and two items")
		_reject(r, "mechanism", "attempt", "completed", {}, rules)
		_dispose(r)
	var r = _runtime()
	if _prepare(r, "mechanism"):
		r.context.power = 0
		var rules := _rules()
		rules.erase("mechanism_failure_damage_type")
		_reject(r, "mechanism", "attempt", "missing_damage_type", {}, rules)
		var result := _act(r, "mechanism", "attempt")
		_stage(result)
		_check(r.context.hp == 199 and r.context.pressure == 5 and _black(r) == 300, "real failed challenge gets damage1 pressure5 no loot")
	_dispose(r)
	r = _runtime()
	var electric := _rules()
	electric.mechanism_variant = "electric"
	if _prepare(r, "mechanism", electric):
		r.context.hp = 5
		var result := _act(r, "mechanism", "attempt", {}, electric)
		_stage(result)
		_check(r.context.hp == 1 and _black(r) == 306, "electric cabinet actual limited damage leaves1 and grants6")
	_dispose(r)

func _test_recycle() -> void:
	var tutorial = _runtime()
	tutorial.context.run_start_config.map_config_id = "tutorial_5x5"
	tutorial.context.run_start_config.profile_fields.content_eligibility = Eligibility.freeze_profile({"profile_level": 0})
	var official := Z2LootCatalog.process_rules(tutorial.context)
	if _prepare(tutorial, "recycle", official):
		var taken := _act(tutorial, "recycle", "take", {}, official)
		var material_id := str(taken.get("facts", {}).get("item_instance_id", ""))
		var material: Dictionary = tutorial.context.asset_ledger.item_instances.get(material_id, {})
		_check(taken.get("ok", false) and material.get("item_id", "") in ["sp_transit_lead_seal", "sp_inspection_calibration_plate"], "Lv0 teaching recycle grants an eligible material instance")
	_dispose(tutorial)
	var r = _runtime()
	if not _prepare(r, "recycle"):
		_dispose(r)
		return
	var result := _act(r, "recycle", "take")
	_stage(result)
	var id := str(result.get("facts", {}).get("item_instance_id", ""))
	_check(not id.is_empty() and r.context.asset_ledger.item_instances.has(id), "recycling take creates an actual identifiable item")
	_reject(r, "recycle", "deliver", "completed", {"instance_id": id})
	_room(r, Vector2i(3, 2))
	if _prepare(r, "recycle"):
		result = _act(r, "recycle", "deliver", {"instance_id": id})
		_stage(result)
		_check(result.get("facts", {}).get("item_instance_id", "") == id and r.context.asset_ledger.get_currency(&"gold_coin") == 5, "same instance delivered at different point for S08")
		_check(r.context.asset_ledger.item_instances[id].location_state == &"consumed", "delivery consumes exact instance")
		_reject(r, "recycle", "take", "completed")
	_room(r, Vector2i(4, 2))
	if _prepare(r, "recycle"):
		var sample := _item(r, "col_02")
		result = _act(r, "recycle", "deliver", {"instance_id": sample})
		_check(result.get("ok", false) and r.context.asset_ledger.get_currency(&"gold_coin") == 15, "natural sample category pays10 safe gold")
	_dispose(r)

func _test_coil() -> void:
	var r = _runtime()
	if not _prepare(r, "coil"):
		_dispose(r)
		return
	r.context.asset_ledger.currency_balances[&"black_coin"] = 4
	_reject(r, "coil", "calibrate", "insufficient_black")
	r.context.asset_ledger.currency_balances[&"black_coin"] = 300
	var started := _act(r, "coil", "calibrate")
	_check(started.get("ok", false) and not started.get("progress_completed", true) and _black(r) == 295, "coil payment only starts pending service")
	_room(r, Vector2i(3, 2))
	_prepare(r, "coil")
	_reject(r, "coil", "calibrate", "coil_pending")
	var receipt := {"search_id": "actual-search-1", "room_id": r.context.cell_key(r.context.get_current_pos()), "room_type": "chest", "complete": true}
	var before: Dictionary = r.capture_authoritative_state()
	var result := _hook(r, "search", receipt)
	_check(not result.get("valid_stage", false) and r.capture_authoritative_state() == before, "chest never consumes coil")
	receipt.room_type = "normal"
	receipt.complete = false
	result = _hook(r, "search", receipt)
	_check(not result.get("valid_stage", false) and r.capture_authoritative_state() == before, "partial search never consumes coil")
	receipt.complete = true
	var empty := _rules()
	empty.pools.normal_search.items = []
	result = _hook(r, "search", receipt, "", empty)
	_check(not result.get("ok", true) and r.capture_authoritative_state() == before, "empty actual origin pool keeps pending state intact")
	result = _hook(r, "search", receipt)
	_stage(result)
	_check(result.get("room_id", "") == "2,2" and result.get("facts", {}).get("items", []).size() == 1, "coil completion belongs to source room only after extra real drop")
	before = r.capture_authoritative_state()
	result = _hook(r, "search", receipt)
	_check(not result.get("valid_stage", false) and r.capture_authoritative_state() == before, "search receipt replay cannot generate twice")
	_room(r, Vector2i(2, 2))
	_reject(r, "coil", "calibrate", "completed")
	_dispose(r)

func _test_clock_in() -> void:
	for deliver_at_origin in [true, false]:
		var r = _runtime()
		if not _prepare(r, "clock_in"):
			_dispose(r)
			continue
		var result := _act(r, "clock_in", "register")
		_check(result.get("ok", false) and not result.get("valid_stage", true) and _black(r) == 296, "registration4 is not completion")
		_reject(r, "clock_in", "claim", "work_incomplete")
		for pos in [Vector2i(3, 2), Vector2i(2, 2), Vector2i(3, 2), Vector2i(4, 2), Vector2i(4, 3)]:
			_room(r, pos)
			_hook(r, "enter", {}, "normal")
		_room(r, Vector2i(2, 2) if deliver_at_origin else Vector2i(5, 3))
		_prepare(r, "clock_in")
		result = _act(r, "clock_in", "claim")
		_stage(result)
		_check(_black(r) == 308, "eligible clock-in point including origin delivers12")
		_room(r, Vector2i(5, 4))
		_prepare(r, "clock_in")
		_reject(r, "clock_in", "register", "work_contract_exists")
		_reject(r, "clock_in", "claim", "work_claimed")
		_dispose(r)

func _rps_round(r, outcome: String) -> Dictionary:
	var snapshot: Dictionary = r.capture_authoritative_state()
	var probe := _act(r, "rps", "rock")
	if not probe.get("ok", false):
		return probe
	var opponent := str(probe.facts.opponent)
	r.install_authoritative_state(snapshot)
	var hand: String = opponent
	if outcome == "win":
		hand = {"rock": "paper", "paper": "scissors", "scissors": "rock"}[opponent]
	elif outcome == "loss":
		hand = {"rock": "scissors", "paper": "rock", "scissors": "paper"}[opponent]
	return _act(r, "rps", hand)

func _test_rps() -> void:
	for outcome in ["win", "loss"]:
		var r = _runtime()
		if not _prepare(r, "rps"):
			_dispose(r)
			continue
		var result := _rps_round(r, "tie")
		_check(result.get("ok", false) and not result.get("valid_stage", true) and _state(r, "rps").wins == 0 and _state(r, "rps").losses == 0, "tie persists no score and rerolls next round")
		result = _rps_round(r, outcome)
		_check(not result.get("valid_stage", true) and _black(r) == 300, "one RPS round no full score or fee")
		var saved: Dictionary = r.capture_authoritative_state()
		var restored = _runtime()
		restored.install_authoritative_state(saved)
		_check(_state(restored, "rps") == _state(r, "rps"), "RPS scores/history survive restore")
		result = _rps_round(restored, outcome)
		_stage(result)
		_check(_black(restored) == (327 if outcome == "win" else 300), "RPS match outcome actual payout/free loss")
		_reject(restored, "rps", "rock", "completed")
		_dispose(restored)
		_dispose(r)

func _test_cage() -> void:
	for outcome in ["win", "loss"]:
		var r = _runtime()
		var entered := _hook(r, "enter", {}, "cage")
		_check(entered.get("ok", false), "cage forced entry accepts actual enemy pool")
		if not entered.get("ok", false):
			_dispose(r)
			continue
		var request: Dictionary = entered.get("combat_request", {})
		_check(not entered.get("valid_stage", true) and request.get("allow_retreat", true) == false and request.get("ordinary_clear_rewards", true) == false, "cage only requests sealed actual combat without reward")
		var frozen := _state(r, "cage")
		_hook(r, "enter", {}, "cage", {"enemy_pool": [{"enemy_id": "wrong", "original_power": 999}]})
		_check(_state(r, "cage") == frozen, "cage repeated entry freezes original enemy and power")
		_reject(r, "cage", "win", "combat_hook_required")
		var receipt := {"room_id": "2,2", "encounter_id": "wrong", "actual_combat": true, "outcome": outcome}
		var before: Dictionary = r.capture_authoritative_state()
		var result := _hook(r, "combat", receipt)
		_check(not result.get("ok", true) and r.capture_authoritative_state() == before, "mismatched combat cannot complete cage")
		receipt.encounter_id = request.encounter_id
		receipt.actual_combat = false
		result = _hook(r, "combat", receipt)
		_check(not result.get("ok", true) and r.capture_authoritative_state() == before, "schema-only combat does not close stage")
		receipt.actual_combat = true
		var power: int = r.context.power
		result = _hook(r, "combat", receipt)
		_stage(result, 10 if outcome == "win" else 5, 5 if outcome == "win" else 2)
		_check(r.context.power == power + (34 if outcome == "win" else 0), "cage power uses2x frozen original17")
		before = r.capture_authoritative_state()
		result = _hook(r, "combat", receipt)
		_check(not result.get("valid_stage", false) and r.capture_authoritative_state() == before, "cage replay has no second power or growth")
		_dispose(r)

func _test_dice() -> void:
	var r = _runtime()
	if not _prepare(r, "dice"):
		_dispose(r)
		return
	r.context.asset_ledger.currency_balances[&"black_coin"] = 19
	_reject(r, "dice", "roll", "insufficient_black")
	r.context.asset_ledger.currency_balances[&"black_coin"] = 300
	var faces := {}
	var triple_win_found := false
	var baseline: Dictionary = r.capture_authoritative_state()
	for seed_value in range(160):
		r.install_authoritative_state(baseline)
		r.context.seed_value = seed_value
		var wins := 0
		for round_index in range(3):
			var before: int = _black(r)
			var result := _act(r, "dice", "roll")
			_check(result.get("ok", false), "dice actual roll")
			if not result.get("ok", false):
				break
			var facts: Dictionary = result.facts
			var face := int(facts.face)
			faces[face] = true
			var returned := 0 if face < 5 else (40 if face == 5 else 80)
			_check(_black(r) == before - 20 + returned, "dice ledger20 stake and actual0/40/80 return")
			_check(facts.weights == ([1, 1, 1, 1, 1, 1] if round_index == 0 else [9, 9, 9, 9, 8, 4]), "dice first uniform then frozen weights")
			_check(facts.win == (face >= 5) and facts.round_id != "", "dice actual per-round win fact for A16")
			_check(result.get("base_talent", -1) == (2 if round_index == 0 else 0) and result.get("base_xp", -1) == (5 if round_index == 0 else 0), "dice room scoring only once")
			wins += 1 if face >= 5 else 0
			var before_preview: Dictionary = r.capture_authoritative_state()
			_state(r, "dice")
			_check(r.capture_authoritative_state() == before_preview, "dice reopening cannot reroll")
		if wins == 3:
			triple_win_found = true
			_check(_state(r, "dice").rounds.size() == 3, "A16 only real3 recorded wins")
	_check(faces.size() == 6 and triple_win_found, "deterministic seed corpus exercises all faces and true triple win")
	_reject(r, "dice", "roll", "completed")
	_dispose(r)

func _test_altar() -> void:
	var r = _runtime()
	for tier in range(1, 6):
		if tier == 3:
			_room(r, Vector2i(3, 2))
		if not _prepare(r, "altar"):
			_dispose(r)
			return
		var preview := _state(r, "altar")
		var hp_cost: int = [10, 15, 25, 35, 50][tier - 1]
		_check(preview.tier == tier and preview.hp_cost == hp_cost, "altar global tier progresses across rooms")
		_prepare(r, "altar")
		_check(_state(r, "altar").rewards == preview.rewards, "altar visible reward fixed before paying")
		r.context.hp = hp_cost
		_reject(r, "altar", "offer", "insufficient_hp")
		r.context.hp = hp_cost + 1
		var black_before := _black(r)
		var result := _act(r, "altar", "offer")
		_stage(result, 5 if tier in [1, 3] else 0, 2)
		_check(r.context.hp == 1 and _black(r) - black_before == [2, 5, 8, 10, 15][tier - 1], "altar full exact cost leaves1 and pays tier black")
		_check(result.get("facts", {}).get("items", []).size() == 1, "altar gives actual single previewed supply")
	_reject(r, "altar", "offer", "completed")
	_room(r, Vector2i(4, 2))
	if _prepare(r, "altar"):
		var id := _item(r, "col_03")
		var assistance := _act(r, "altar", "assist", {"instance_id": id})
		_check(assistance.get("ok", false) and not assistance.get("valid_stage", true) and _state(r, "altar").hp_cost == 45, "altar natural stabilizing tag discounts5 without scoring")
		var second := _item(r, "col_03")
		_reject(r, "altar", "assist", "already_assisted", {"instance_id": second})
		r.context.hp = 46
		var result := _act(r, "altar", "offer")
		_stage(result, 5, 0)
		_check(result.get("facts", {}).get("tier", 0) == 5 and r.context.hp == 1, "new altar repeats fifth reward, unique XP/equipment, no tier talent")
		_reject(r, "altar", "offer", "completed")
	_room(r, Vector2i(2, 2))
	_reject(r, "altar", "prepare", "completed")
	_dispose(r)

func _test_atomic_resume() -> void:
	var r = _runtime()
	if not _prepare(r, "dice"):
		_dispose(r)
		return
	var before: Dictionary = r.capture_authoritative_state()
	var request := {"revision": _state(r, "dice").revision}
	r.checkpoint_writer = func(_state_data: Dictionary) -> Dictionary: return {"ok": false, "reason": "injected_disk_failure"}
	var failed := _call(r, "dice", "roll", request, _rules(), "dice-save-retry")
	_check(not failed.get("ok", true) and r.capture_authoritative_state() == before, "save failure rolls back stake, random, result and growth flags")
	r.checkpoint_writer = func(_state_data: Dictionary) -> Dictionary: return {"ok": true}
	r.retry_persistence()
	var result := _call(r, "dice", "roll", request, _rules(), "dice-save-retry")
	_check(result.get("ok", false), "same atomic command can retry after save failure")
	before = r.capture_authoritative_state()
	var replay := _call(r, "dice", "roll", request, _rules(), "dice-save-retry")
	_check(replay.get("duplicate", false) and r.capture_authoritative_state() == before, "duplicate command has no second charge/random/reward")
	var saved: Dictionary = r.encode_checkpoint_state(before)
	var restored = _runtime()
	var loaded: Dictionary = restored.restore_checkpoint_state(saved)
	_check(loaded.get("ok", false) and restored.capture_authoritative_state() == before, "checkpoint round-trip preserves actual state including flags/random/ledger")
	var a := _act(r, "dice", "roll")
	var b := _act(restored, "dice", "roll")
	_check(a.get("facts", {}) == b.get("facts", {}), "restored next random result equals uninterrupted run")
	var stale := _call(r, "dice", "roll", {"revision": 1}, _rules())
	_check(not stale.get("ok", true) and stale.get("reason", "") == "stale_revision", "stale UI request cannot spend next roll")
	_dispose(restored)
	_dispose(r)

func _test_pending_restore() -> void:
	for event in ["mechanism", "recycle", "coil", "clock_in", "rps", "cage", "dice", "altar"]:
		var r = _runtime()
		var ready: bool = _hook(r, "enter", {}, "cage").get("ok", false) if event == "cage" else _prepare(r, event)
		if not ready:
			_dispose(r)
			continue
		if event == "coil":
			_act(r, event, "calibrate")
		elif event == "clock_in":
			_act(r, event, "register")
		elif event == "rps":
			_rps_round(r, "win")
		elif event == "dice":
			_act(r, event, "roll")
		var snapshot: Dictionary = r.capture_authoritative_state()
		var restored = _runtime()
		var loaded: Dictionary = restored.restore_checkpoint_state(r.encode_checkpoint_state(snapshot))
		_check(loaded.get("ok", false) and restored.capture_authoritative_state() == snapshot, event + ": pending state survives real checkpoint codec")
		_check(_state(restored, event) == _state(r, event), event + ": public view resumes same offers/progress/request")
		_dispose(restored)
		_dispose(r)

func _test_recycle_full_bag() -> void:
	var r = _runtime()
	r.context.asset_ledger.backpack_capacity = 0
	if _prepare(r, "recycle"):
		var result := _act(r, "recycle", "deliver")
		_stage(result)
		_check(r.context.asset_ledger.get_currency(&"gold_coin") == 5, "onsite recycling delivery does not require backpack capacity")
		var id := str(result.get("facts", {}).get("item_instance_id", ""))
		_check(not id.is_empty() and r.context.asset_ledger.item_instances.get(id, {}).get("location_state", "") == &"consumed", "onsite delivered material has one real consumed identity")
	_dispose(r)

func _test_stale_altar() -> void:
	var r = _runtime()
	if not _prepare(r, "altar"):
		_dispose(r)
		return
	_room(r, Vector2i(3, 2))
	if _prepare(r, "altar"):
		_act(r, "altar", "offer")
		_room(r, Vector2i(2, 2))
		_reject(r, "altar", "offer", "stale_altar_offer")
		_prepare(r, "altar")
		_check(_state(r, "altar").tier == 2, "old room refresh advances to actual global altar tier")
		var saved: Dictionary = r.capture_authoritative_state()
		var shown: Array = _state(r, "altar").rewards
		r.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary: return {"ok": false, "reason": "injected_disk_failure"}
		var failed := _act(r, "altar", "offer")
		_check(not failed.get("ok", true) and r.capture_authoritative_state() == saved, "altar save failure restores HP, items, coins, tier and score")
		r.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary: return {"ok": true}
		r.retry_persistence()
		var result := _act(r, "altar", "offer")
		_check(result.get("ok", false) and result.get("facts", {}).get("items", [{}])[0].get("item_id", "") == shown[0].item_id, "altar retry delivers exactly the shown reward")
	_dispose(r)
