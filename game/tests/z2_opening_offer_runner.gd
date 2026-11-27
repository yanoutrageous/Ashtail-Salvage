extends SceneTree

const Context = preload("res://scripts/core/run/run_context.gd")
var Runtime = load("res://scripts/core/run/z2_opening_runtime.gd")
const Talents = preload("res://scripts/core/progression/z2_talent_catalog.gd")
var offer
var checks := 0
var failures: Array[String] = []
var serial := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := "res://scripts/core/progression/z2_opening_offer.gd"
	if not ResourceLoader.exists(path):
		_check(false, "camp reducer missing; run fixture is not camp persistence")
	else:
		offer = load(path)
		_test_camp()
		_test_failure_and_reload()
		_test_admission()
	for failure in failures:
		print("Z2_OPENING_OFFER_CASE_FAIL " + failure)
	print("Z2_OPENING_OFFER=%s checks=%d" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)


func _meta() -> Dictionary:
	return {"profile_id": "opening-offer-test", "ruleset_id": "z2", "z2_progression_version": 1,
		"gold": 1000, "run_count": 0, "talent_flags": ["z2_talent_15"], "admission": {}}


func _execute(meta: Dictionary, action: String, payload: Dictionary = {}, seed_value: int = 17) -> Dictionary:
	var p := payload.duplicate(true)
	serial += 1
	if not p.has("request_id"):
		p.request_id = "offer-test-%d" % serial
	var before := meta.duplicate(true)
	var result: Dictionary = offer.execute(meta, action, p, seed_value)
	_check(meta == before, "pure reducer input immutable " + action)
	return result


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _test_camp() -> void:
	var meta := _meta()
	var result := _execute(meta, "prepare")
	_check(result.get("ok", false) and result.expense.amount == 0, "camp prepare free")
	meta = result.meta
	var first: Dictionary = offer.public_state(meta)
	_check(first.candidates.size() == 3 and offer.valid_offer(first), "camp three valid distinct IDs")
	result = _execute(meta, "prepare", {}, 987)
	_check(result.offer.candidates == first.candidates and result.offer.seed == first.seed and result.offer.offer_key == first.offer_key, "close/reopen cannot change seed or draw")
	for i in range(10):
		var old: Dictionary = offer.public_state(meta)
		result = _execute(meta, "refresh", {"offer_id": old.offer_id})
		_check(result.get("ok", false) and result.expense.amount == (i + 1) * 5, "camp real refresh price " + str(i))
		meta = result.meta
		_check(result.offer.refresh_count == i + 1 and result.offer.candidates != old.candidates, "camp refresh advances actual distinct offer")
		_check(offer.valid_offer(result.offer), "refreshed offer validates")
	_check(meta.gold == 725 and meta.z2_opening_offer.paid_gold == 275, "candidate meta contains exactly275 gold payment")
	_check(not _execute(meta, "refresh", {"offer_id": result.offer.offer_id}).get("ok", true), "refresh11 rejected")
	var current: Dictionary = offer.public_state(meta)
	result = _execute(meta, "choose", {"offer_id": current.offer_id, "effect_id": current.candidates[0]})
	_check(result.get("ok", false) and result.offer.status == "selected" and result.offer.selected == current.candidates[0], "camp chooses one offered ID")
	meta = result.meta
	_check(not _execute(meta, "refresh", {"offer_id": current.offer_id}).get("ok", true), "chosen offer cannot refresh")
	_check(_execute(meta, "prepare").offer == offer.public_state(meta), "chosen state survives reopening")
	meta.run_count = 1
	result = _execute(meta, "prepare")
	_check(result.get("ok", false) and result.offer.refresh_count == 0 and result.offer.offer_key != current.offer_key and result.meta.gold == 725, "next completed-run epoch creates fresh offer without charge")
	result = _execute(result.meta, "skip")
	_check(result.get("ok", false) and result.offer.status == "skipped" and result.offer.selected == "", "camp skip")
	_check(not _execute(result.meta, "choose", {"offer_id": result.offer.offer_id, "effect_id": result.offer.candidates[0]}).get("ok", true), "skip terminal for that departure")


func _test_failure_and_reload() -> void:
	var meta: Dictionary = _execute(_meta(), "prepare").meta
	var key := str(meta.z2_opening_offer.offer_id)
	var no_gold := meta.duplicate(true)
	no_gold.gold = 4
	var result := _execute(no_gold, "refresh", {"offer_id": key})
	_check(not result.get("ok", true) and result.meta == no_gold and result.expense.amount == 0, "insufficient meta gold no mutation/expense")
	_check(not _execute(meta, "refresh", {"offer_id": "stale"}).get("ok", true), "stale offer rejected")
	_check(not _execute(meta, "choose", {"offer_id": key, "effect_id": "future_batch2_fake"}).get("ok", true), "no fabricated future effect")
	var locked := _meta()
	locked.talent_flags = ["z2_talent_29", "z2_talent_39"]
	_check(not _execute(locked, "prepare").get("ok", true), "node29/39 cannot substitute for15")
	meta.admission = {"phase": "active", "run_id": "other"}
	_check(not _execute(meta, "refresh", {"offer_id": key}).get("ok", true), "active departure blocks camp spend")
	meta.admission = {}
	var authoritative := meta.duplicate(true)
	var p := {"request_id": "refresh-once", "offer_id": key}
	result = _execute(meta, "refresh", p)
	_check(authoritative == meta and result.meta.gold == meta.gold - 5, "unsaved candidate is not published")
	# Simulate caller refusing a failed save, then retry from the same authoritative input.
	var retry := _execute(authoritative, "refresh", p)
	_check(retry.meta == result.meta and retry.offer == result.offer, "failed-save retry yields same candidate and expense")
	meta = result.meta
	var restored: Dictionary = JSON.parse_string(JSON.stringify(meta))
	result = _execute(restored, "refresh", p)
	_check(result.get("ok", false) and result.get("duplicate", false) and result.expense.amount == 0 and result.meta.gold == 995, "JSON reload replay never recharges/redraws")
	_check(not _execute(restored, "skip", {"request_id": "refresh-once"}).get("ok", true), "request identity conflict rejected")
	var corrupt := restored.duplicate(true)
	corrupt.z2_opening_offer.candidates[0] = corrupt.z2_opening_offer.candidates[1]
	_check(not _execute(corrupt, "prepare").get("ok", true), "corrupted duplicate candidates rejected")
	corrupt = restored.duplicate(true)
	corrupt.z2_opening_offer.paid_gold = 0
	_check(not offer.valid_offer(corrupt.z2_opening_offer), "tampered payment history rejected")


func _context(chosen: Dictionary) -> RunContext:
	var c := Context.new()
	c.start_run({"id": "offer-admission", "mode": &"standard", "seed": 31, "width": 3, "height": 3,
		"power": 10, "max_hp": 100, "profile_fields": {"ruleset_id": "z2", "z2_progression_version": 1},
		"active_talent_effects": [Talents.definition("z2_talent_15"), Talents.definition("z2_talent_03")],
		"manual_map": {"spawn": Vector2i.ZERO, "mines": [], "monsters": [], "events": [], "chests": [], "exits": []}})
	c.run_start_config["z2_opening_offer"] = chosen.duplicate(true)
	c.power += 30 # Actual equipment contribution installed before admission.
	return c


func _chosen(id: String) -> Dictionary:
	for seed_value in range(1, 100):
		var prepared := _execute(_meta(), "prepare", {}, seed_value)
		if prepared.offer.candidates.has(id):
			return _execute(prepared.meta, "choose", {"offer_id": prepared.offer.offer_id, "effect_id": id}).offer
	return {}


func _test_admission() -> void:
	var empty_context := _context({})
	empty_context.active_talent_effects.clear()
	var empty_result: Dictionary = Runtime.admit_departure(empty_context, {})
	_check(empty_result.get("ok", false) and empty_result.get("noop", false) and not empty_context.z1_event_flags.has("z2_opening"), "absent offer is legitimate no-effect departure without node15")
	var chosen := _chosen("power_life")
	var c := _context(chosen)
	_check(c.power == 42, "actual talent2 and equipment30 installed before opening")
	var before_black := c.asset_ledger.get_currency(&"black_coin")
	var admitted: Dictionary = Runtime.admit_departure(c, chosen)
	_check(admitted.get("ok", false) and Runtime.public_state(c).initial_power == 42 and c.max_hp == 121 and c.power == 38, "formal admission freezes actual42 then activates")
	_check(c.asset_ledger.get_currency(&"black_coin") == before_black and Runtime.public_state(c).candidates == chosen.candidates, "formal admission never charges or redraws")
	admitted = Runtime.admit_departure(c, chosen)
	_check(admitted.get("duplicate", false) and c.max_hp == 121 and c.power == 38, "formal admission once only")
	var changed := chosen.duplicate(true)
	changed.selected = "rebate"
	_check(not Runtime.admit_departure(c, changed).get("ok", true), "UI cannot replace trusted admitted choice")
	c = _context(chosen)
	c.run_start_config.erase("z2_opening_offer")
	_check(not Runtime.admit_departure(c, chosen).get("ok", true), "unfrozen UI offer rejected")
	c = _context(chosen)
	c.active_talent_effects.clear()
	_check(not Runtime.admit_departure(c, chosen).get("ok", true), "actual context qualification required")
	var prepared: Dictionary = _execute(_meta(), "prepare").offer
	c = _context(prepared)
	_check(Runtime.admit_departure(c, prepared).get("ok", false) and Runtime.public_state(c).status == "offered", "unfinished original offer preserved in spawn")
	var skipped: Dictionary = _execute(_execute(_meta(), "prepare").meta, "skip").offer
	c = _context(skipped)
	_check(Runtime.admit_departure(c, skipped).get("ok", false) and c.power == 42 and Runtime.public_state(c).status == "skipped", "skip admits without activation")
	chosen = _chosen("rebate")
	c = _context(chosen)
	_check(Runtime.admit_departure(c, chosen).get("ok", false) and Runtime.public_state(c).effect_state.policy == Runtime.D06_POLICY, "formal cashback stores approved engineering policy")
