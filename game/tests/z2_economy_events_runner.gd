extends SceneTree

const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
const Economy = preload("res://scripts/core/run/z2_economy_events.gd")
const Items = preload("res://scripts/core/content/z2_item_catalog.gd")
const Eligibility = preload("res://scripts/core/content/z2_content_eligibility.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_shop()
	_test_savings()
	_test_seal()
	_test_relief()
	_test_first_aid()
	_test_consign()
	_test_expand()
	_test_compression()
	_test_trader()
	_test_pawn()
	_test_atomic_and_resume()
	_test_empty_pools()
	_test_all_duplicate_receipts()
	_test_stale_conditions()
	_test_pending_resume()
	_test_integer_savings()
	_test_seal_weights()
	for failure in failures:
		print("Z2_ECONOMY_CASE_FAIL " + failure)
	print("Z2_ECONOMY_EVENTS=%s checks=%d" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _runtime():
	var runtime = Runtime.new()
	runtime.command_bus.dispatch(&"start_demo_run", {})
	var context: RunContext = runtime.context
	context.run_start_config["profile_fields"] = {"ruleset_id": "z2", "z2_progression_version": 1,
		"content_eligibility": Eligibility.freeze_profile({"profile_level": 50})}
	context.profile_fields = context.run_start_config.profile_fields.duplicate(true)
	context.run_start_config["map_config_id"] = "classic_13x13_normal"
	context.asset_ledger.setup({"run_id": str(context.run_id), "backpack_capacity": 100, "equipment_capacity": 100})
	context.asset_ledger.add_currency(&"black_coin", 300, "test_setup")
	context.pressure = 0
	context.protocol_level = 0
	context.protocol_pressure_reduce = 0
	context.z1_event_rooms.clear()
	context.z1_event_flags.clear()
	_room(runtime, Vector2i(2, 2))
	return runtime

func _room(runtime, pos: Vector2i) -> void:
	runtime.context.player_pos = pos
	runtime.context.current_pos = pos

func _dispose(runtime) -> void:
	runtime.checkpoint_writer = Callable()
	runtime.command_bus.runtime_controller = null
	runtime.command_bus.room_resolver.bind_runtime_controller(null)
	runtime.in_run_runtime.bind(null)

func _call(runtime, event: String, action: String, payload: Dictionary = {}, catalog: Dictionary = {}, action_id: String = "") -> Dictionary:
	var pos: Vector2i = runtime.context.get_current_pos()
	# Explicit test pools, never installed into official runtime callers.
	var pools := catalog.duplicate(true)
	if event == "shop" and not pools.has("shop_pool"):
		pools["shop_pool"] = Items.supplies()
	if event == "compress" and not pools.has("compression_pool"):
		pools["compression_pool"] = Items.collectibles()
	return runtime.execute_atomic_operation(&"z2_economy", {"event": event, "pos": pos, "option_id": action, "payload": payload},
		func() -> Dictionary: return Economy.choose(runtime.context, pos, event, action, payload, pools), action_id)

func _state(runtime, event: String, catalog: Dictionary = {}) -> Dictionary:
	return Economy.public_state(runtime.context, runtime.context.get_current_pos(), event, catalog)

func _prepare(runtime, event: String, selection: Dictionary = {}, catalog: Dictionary = {}) -> bool:
	var result := _call(runtime, event, "prepare", selection, catalog)
	_check(bool(result.get("ok", false)), event + ": prepare delivers a quote (" + str(result.get("reason", "")) + ")")
	return bool(result.get("ok", false))

func _act(runtime, event: String, action: String, payload: Dictionary = {}, catalog: Dictionary = {}, action_id: String = "") -> Dictionary:
	var request := payload.duplicate(true)
	request["quote_id"] = _state(runtime, event, catalog).get("quote_id", "missing")
	return _call(runtime, event, action, request, catalog, action_id)

func _item(runtime, id: String, overrides: Dictionary = {}) -> String:
	# Overrides are synthetic edge fixtures, never production pools or definitions.
	var definition: Dictionary = Items.definition(id)
	definition.merge(overrides, true)
	return str(runtime.context.asset_ledger.create_item_instance(definition, &"inventory").instance_id)

func _black(runtime) -> int:
	return runtime.context.asset_ledger.get_currency(&"black_coin")

func _safe(runtime) -> int:
	return runtime.context.asset_ledger.get_currency(&"gold_coin")

func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)

func _reject_unchanged(runtime, event: String, action: String, payload: Dictionary = {}, catalog: Dictionary = {}, reason: String = "") -> Dictionary:
	var before: Dictionary = runtime.capture_authoritative_state()
	var result := _act(runtime, event, action, payload, catalog)
	_check(not bool(result.get("ok", true)), event + ": rejects " + action + " " + str(result.get("reason", "")))
	_check(runtime.capture_authoritative_state() == before, event + ": rejected action has no cost/state/publication")
	if not reason.is_empty():
		_check(str(result.get("reason", "")) == reason, event + ": reason " + reason)
	return result

func _test_shop() -> void:
	var r = _runtime()
	var catalog := {"shop_pool": [["con_calm_candy", 3], {"item_id": "con_scan_pin", "roll_weight": 2}]}
	if not _prepare(r, "shop", {}, catalog):
		_dispose(r)
		return
	var initial := _state(r, "shop", catalog)
	_check(initial.offers.size() == 3, "shop: three shelves")
	for offer: Dictionary in initial.offers:
		_check(int(offer.price) == ceili(float(offer.item.purchase_price) * 1.3), "shop: ceil 1.3 source price")
	var before: Dictionary = r.capture_authoritative_state()
	for index in range(20):
		_check(_state(r, "shop", catalog) == initial, "shop: reopen stable %d" % index)
	_check(r.capture_authoritative_state() == before, "public_state never mutates")
	var balance := _black(r)
	var first := _act(r, "shop", "buy", {"slot": 0}, catalog)
	_check(bool(first.get("ok", false)) and _black(r) == balance - int(initial.offers[0].price), "shop: quoted purchase")
	_check(first.get("stage_completed", false) and first.get("first_room_completion", false), "shop: first purchase stage and XP facts")
	_reject_unchanged(r, "shop", "buy", {"slot": 0}, catalog)
	var second := _act(r, "shop", "buy", {"slot": 1}, catalog)
	_check(bool(second.get("ok", false)) and not second.get("stage_completed", true) and not second.get("first_room_completion", true), "shop: second purchase no duplicate growth")
	for price in [5, 10]:
		balance = _black(r)
		var refreshed := _act(r, "shop", "refresh", {}, catalog)
		_check(bool(refreshed.get("ok", false)) and _black(r) == balance - price, "shop: refresh fee %d" % price)
		_check(not refreshed.get("stage_completed", true), "shop: refresh no stage")
	r.context.asset_ledger.spend_currency(&"black_coin", _black(r))
	_prepare(r, "shop", {}, catalog)
	_reject_unchanged(r, "shop", "buy", {"slot": 0}, catalog, "insufficient_black")
	_reject_unchanged(r, "shop", "refresh", {}, catalog, "insufficient_black")
	_dispose(r)

func _test_savings() -> void:
	var r = _runtime()
	if not _prepare(r, "savings", {"amount": 3}):
		_dispose(r)
		return
	var result := _act(r, "savings", "deposit", {"amount": 3})
	_check(result.get("ok", false) and _black(r) == 297 and _safe(r) == 1, "savings: floor50% P3 guarantee")
	_check(result.get("stage_completed", false), "savings: delivered deposit stage")
	_reject_unchanged(r, "savings", "withdraw")
	_room(r, Vector2i(3, 2))
	_prepare(r, "savings", {"amount": 10})
	_reject_unchanged(r, "savings", "deposit", {"amount": 10})
	result = _act(r, "savings", "withdraw")
	_check(result.get("ok", false) and _black(r) == 300 and _safe(r) == 0, "savings: floor120%, revoke exact guarantee")
	_check(result.get("stage_completed", false) and result.get("first_room_completion", false), "savings: other room withdrawal stage/XP")
	_check(int(result.get("facts", {}).get("black_income_gross", -1)) == 3, "savings: gross includes principal")
	_reject_unchanged(r, "savings", "deposit", {"amount": 1})
	_room(r, Vector2i(4, 2))
	_prepare(r, "savings", {"amount": 100})
	result = _act(r, "savings", "deposit", {"amount": 100})
	_check(result.get("ok", false) and _safe(r) == 50, "savings: next room may deposit again")
	_room(r, Vector2i(5, 2))
	_prepare(r, "savings")
	result = _act(r, "savings", "withdraw")
	_check(result.get("ok", false) and _black(r) == 320 and _safe(r) == 0, "savings: 100 returns total120")
	_room(r, Vector2i(6, 2))
	_prepare(r, "savings", {"amount": 321})
	_reject_unchanged(r, "savings", "deposit", {"amount": 321}, {}, "insufficient_black")
	for invalid in [0, -1, 1.5, "5"]:
		var snap: Dictionary = r.capture_authoritative_state()
		result = _call(r, "savings", "prepare", {"amount": invalid})
		_check(not result.get("ok", true) and r.capture_authoritative_state() == snap, "savings: invalid principal " + str(invalid))
	_dispose(r)

func _test_seal() -> void:
	var r = _runtime()
	if not _prepare(r, "seal"):
		_dispose(r)
		return
	var instance := _item(r, "col_22")
	_prepare(r, "seal")
	var capacity: int = r.context.asset_ledger.failure_salvage_capacity
	var result := _act(r, "seal", "use")
	_check(result.get("ok", false) and _black(r) == 280 and r.context.asset_ledger.failure_salvage_capacity == capacity + 20, "seal: 20 buys immediate20 capacity")
	_check(r.context.z1_event_flags.get("z2_salvage_seal_used", false), "seal: shared once flag")
	_check(int(r.context.asset_ledger.item_instances[instance].weight) == 8, "seal: physical weight unchanged")
	_check(r.context.asset_ledger.status_effects.any(func(effect: Dictionary) -> bool: return effect.get("id", "") == "z2_salvage_seal" and effect.get("weight_reduction", 0) == 10 and effect.get("min_weight", 0) == 1), "seal: complete settlement weight rule saved")
	_room(r, Vector2i(3, 2))
	_prepare(r, "seal")
	_reject_unchanged(r, "seal", "use")
	_dispose(r)
	r = _runtime()
	r.context.z1_event_flags["z2_evacuation_service_done"] = true
	_prepare(r, "seal")
	result = _act(r, "seal", "use")
	_check(result.get("ok", false) and _black(r) == 290, "seal: evacuation service discount10")
	_dispose(r)
	r = _runtime()
	r.context.z1_event_flags["z2_salvage_seal_used"] = true
	_prepare(r, "seal")
	_reject_unchanged(r, "seal", "use")
	_dispose(r)

func _test_relief() -> void:
	for row in [["flat", 3, 5, 0], ["ten_percent", 39, 10, 36], ["thirty_percent", 39, 30, 28]]:
		var r = _runtime()
		r.context.pressure = row[1]
		if _prepare(r, "relief"):
			var result := _act(r, "relief", row[0])
			_check(result.get("ok", false) and _black(r) == 300 - row[2] and r.context.pressure == row[3], "relief: actual reduction " + row[0])
			_reject_unchanged(r, "relief", row[0])
		_dispose(r)
	for row in [["flat", 0], ["ten_percent", 9], ["thirty_percent", 3]]:
		var r = _runtime()
		r.context.pressure = row[1]
		if _prepare(r, "relief"):
			_reject_unchanged(r, "relief", row[0], {}, {}, "no_effect")
		_dispose(r)

func _test_first_aid() -> void:
	var tutorial = _runtime()
	tutorial.context.run_start_config.map_config_id = "tutorial_5x5"
	tutorial.context.run_start_config.profile_fields.content_eligibility = Eligibility.freeze_profile({"profile_level": 0})
	var official := Z2LootCatalog.economy_catalog(tutorial.context)
	if _prepare(tutorial, "first_aid", {}, official):
		_check(_black(tutorial) == 300, "Lv0 teaching aid prepares without paying")
		var purchase := _act(tutorial, "first_aid", "buy", {}, official)
		var delivery: Dictionary = purchase.get("facts", {}).get("delivery", {})
		_check(purchase.get("ok", false) and _black(tutorial) == 291 and delivery.get("item_id", "") == "con_med_patch", "Lv0 buys the official patch for nine black coins")
	_dispose(tutorial)
	for pressure in [39, 40]:
		var r = _runtime()
		r.context.pressure = pressure
		r.context.asset_ledger.equipment_capacity = 0
		if _prepare(r, "first_aid"):
			var result := _act(r, "first_aid", "buy")
			_check(result.get("ok", false) and _black(r) == (291 if pressure == 39 else 296), "aid: price boundary %d" % pressure)
			_check(r.context.pressure == (39 if pressure == 39 else 45), "aid: base pressure only emergency branch")
			var floor_items: Array = r.context.asset_ledger.get_room_floor_items(r.context.get_current_pos())
			_check(floor_items.size() == 1 and str(floor_items[0].item_id) == "con_med_patch", "aid: full bag delivers patch to this floor")
			_reject_unchanged(r, "first_aid", "buy")
		_dispose(r)
	var r = _runtime()
	r.context.pressure = 40
	r.context.protocol_pressure_reduce = 2
	# Z2 composes actual vitals modifiers, without the legacy scalar reduction.
	r.context.vitals_modifiers["pressure"] = {"flat_reductions": [{"amount": 2}]}
	if _prepare(r, "first_aid"):
		var result := _act(r, "first_aid", "buy")
		_check(result.get("ok", false) and r.context.pressure == 43, "aid: +5 base uses pressure pipeline")
	_dispose(r)
	r = _runtime()
	r.context.pressure = 40
	r.context.protocol_pressure_reduce = 2
	if _prepare(r, "first_aid"):
		var result := _act(r, "first_aid", "buy")
		_check(result.get("ok", false) and r.context.pressure == 45 and _black(r) == 296, "aid: legacy scalar alone cannot reduce Z2 base pressure")
	_dispose(r)

func _test_consign() -> void:
	var r = _runtime()
	var id := _item(r, "col_22")
	if not _prepare(r, "consign"):
		_dispose(r)
		return
	var result := _act(r, "consign", "consign", {"instance_id": id})
	_check(result.get("ok", false) and _black(r) == 292, "consign: max8 ceil((32+5*8)/10)")
	_check(r.context.asset_ledger.item_instances[id].location_state == &"consigned", "consign: exact instance transferred")
	_reject_unchanged(r, "consign", "consign", {"instance_id": id})
	_room(r, Vector2i(3, 2))
	var edge := _item(r, "col_22", {"weight": 20, "base_value": 101})
	_prepare(r, "consign")
	result = _act(r, "consign", "consign", {"instance_id": edge})
	_check(result.get("ok", false) and _black(r) == 271, "consign: weight20 accepted / ceil201/10=21")
	_room(r, Vector2i(4, 2))
	for overrides in [{"weight": 21}, {"is_unique": true}, {"item_type": "equipment"}]:
		var bad := _item(r, "col_22", overrides)
		_prepare(r, "consign")
		_reject_unchanged(r, "consign", "consign", {"instance_id": bad})
	for bad in [id, "foreign_missing"]:
		_prepare(r, "consign")
		_reject_unchanged(r, "consign", "consign", {"instance_id": bad})
	_dispose(r)

func _test_expand() -> void:
	var r = _runtime()
	if not _prepare(r, "expand"):
		_dispose(r)
		return
	var result := _act(r, "expand", "expand")
	_check(result.get("ok", false) and _black(r) == 292 and r.context.asset_ledger.backpack_capacity == 120, "expand: price8 capacity20")
	_reject_unchanged(r, "expand", "expand")
	_room(r, Vector2i(3, 2))
	_prepare(r, "expand")
	result = _act(r, "expand", "expand")
	_check(result.get("ok", false) and r.context.asset_ledger.backpack_capacity == 140, "expand: different rooms stack")
	_dispose(r)

func _test_compression() -> void:
	var r = _runtime()
	var a := _item(r, "col_01")
	var b := _item(r, "col_03")
	var catalog := {"compression_pool": [Items.definition("col_22")]}
	if not _prepare(r, "compress", {}, catalog):
		_dispose(r)
		return
	_reject_unchanged(r, "compress", "compress", {"instance_ids": [a, a]}, catalog)
	_reject_unchanged(r, "compress", "compress", {"instance_ids": [a, "foreign_missing"]}, catalog)
	var tier_two := _item(r, "col_09")
	_prepare(r, "compress", {}, catalog)
	_reject_unchanged(r, "compress", "compress", {"instance_ids": [a, tier_two]}, catalog)
	r.context.asset_ledger.item_instances[b].location_state = &"equipped"
	_prepare(r, "compress", {}, catalog)
	_reject_unchanged(r, "compress", "compress", {"instance_ids": [a, b]}, catalog)
	r.context.asset_ledger.item_instances[b].location_state = &"inventory"
	r.context.asset_ledger.backpack_capacity = 8
	_prepare(r, "compress", {}, catalog)
	var result := _act(r, "compress", "compress", {"instance_ids": [a, b]}, catalog)
	_check(result.get("ok", false) and _black(r) == 300, "compress: no invented fee")
	_check(r.context.asset_ledger.item_instances[a].location_state == &"consumed" and r.context.asset_ledger.item_instances[b].location_state == &"consumed", "compress: two exact inputs consumed together")
	var ground: Array = r.context.asset_ledger.get_room_floor_items(r.context.get_current_pos())
	_check(ground.size() == 1 and str(ground[0].item_id) == "col_22", "compress: qualified saved tier2 output / overflow floor")
	_dispose(r)

func _test_trader() -> void:
	for row in [["col_22", 24, "safe"], ["con_ration", 3, "black"], ["con_med_patch", 6, "black"], ["eq_old_vest", 7, "black"]]:
		var r = _runtime()
		var id := _item(r, row[0])
		if _prepare(r, "trader"):
			var result := _act(r, "trader", "sell", {"instance_id": id})
			_check(result.get("ok", false), "trader: accepts " + row[0])
			_check(_safe(r) == (row[1] if row[2] == "safe" else 0) and _black(r) == (300 + row[1] if row[2] == "black" else 300), "trader: exact fixed quote " + row[0])
			_check(r.context.asset_ledger.item_instances[id].location_state == &"consumed", "trader: no copy/resell " + row[0])
			_reject_unchanged(r, "trader", "sell", {"instance_id": id})
		_dispose(r)
	for overrides in [{"counters": {"uses": 1}}, {"is_unique": true}, {"location_state": "equipped"}, {"item_type": "unknown"}, {"purchase_price": 1}]:
		var r = _runtime()
		var id := _item(r, "eq_old_vest", overrides)
		if overrides.has("location_state"):
			r.context.asset_ledger.item_instances[id].location_state = overrides.location_state
		if _prepare(r, "trader"):
			_reject_unchanged(r, "trader", "sell", {"instance_id": id})
		_dispose(r)

func _test_pawn() -> void:
	var r = _runtime()
	var good := _item(r, "col_22", {"base_value": 21})
	var low := _item(r, "col_09", {"base_value": 20})
	if not _prepare(r, "pawn"):
		_dispose(r)
		return
	_reject_unchanged(r, "pawn", "pawn", {"instance_id": low})
	var result := _act(r, "pawn", "pawn", {"instance_id": good})
	_check(result.get("ok", false) and _black(r) == 312, "pawn: value21 grants12")
	_check(r.context.asset_ledger.item_instances[good].location_state == &"pledged", "pawn: preserves instance for T14")
	_check(int(result.get("facts", {}).get("redeem_cost", 0)) == 16, "pawn: T14 success redemption16 fact")
	_room(r, Vector2i(3, 2))
	var another := _item(r, "col_22")
	_prepare(r, "pawn")
	_reject_unchanged(r, "pawn", "pawn", {"instance_id": another})
	_dispose(r)

func _test_atomic_and_resume() -> void:
	var r = _runtime()
	r.context.pressure = 39
	if not _prepare(r, "first_aid"):
		_dispose(r)
		return
	r.context.pressure = 40
	_reject_unchanged(r, "first_aid", "buy", {}, {}, "stale_quote")
	_prepare(r, "first_aid")
	var before: Dictionary = r.capture_authoritative_state()
	var request := {"quote_id": _state(r, "first_aid").quote_id}
	r.checkpoint_writer = func(_state_data: Dictionary) -> Dictionary: return {"ok": false, "reason": "injected_disk_failure"}
	var result := _call(r, "first_aid", "buy", request, {}, "durable_aid")
	_check(not result.get("ok", true) and r.capture_authoritative_state() == before, "atomic: disk failure restores price, item, stage, pressure and RNG")
	r.checkpoint_writer = func(_state_data: Dictionary) -> Dictionary: return {"ok": true}
	r.retry_persistence()
	result = _call(r, "first_aid", "buy", request, {}, "durable_aid")
	_check(result.get("ok", false), "atomic: same failed action can retry")
	before = r.capture_authoritative_state()
	result = _call(r, "first_aid", "buy", request, {}, "durable_aid")
	_check(result.get("duplicate", false) and r.capture_authoritative_state() == before, "atomic: receipt deduplicates before stale quote")
	_dispose(r)
	r = _runtime()
	_prepare(r, "shop")
	var public_before := _state(r, "shop")
	var checkpoint: Dictionary = r.encode_checkpoint_state(r.capture_authoritative_state())
	result = r.restore_checkpoint_state(checkpoint)
	_check(result.get("ok", false) and _state(r, "shop") == public_before, "resume: exact saved offers/full quote survives checkpoint")
	_prepare(r, "shop")
	_check(_state(r, "shop") == public_before, "resume: prepare does not reroll or alter quote")
	r.context.asset_ledger.backpack_capacity = 0
	r.context.asset_ledger.equipment_capacity = 0
	_prepare(r, "shop")
	result = _act(r, "shop", "buy", {"slot": 0})
	_check(result.get("ok", false) and r.context.asset_ledger.get_room_floor_items(r.context.get_current_pos()).size() == 1, "shop: any reward overflow lands in current room")
	_dispose(r)
	for event in ["seal", "relief", "first_aid", "consign", "expand"]:
		r = _runtime()
		r.context.pressure = 50
		var id := _item(r, "col_22")
		r.context.asset_ledger.spend_currency(&"black_coin", 300)
		if _prepare(r, event):
			var action: String = {"seal": "use", "relief": "flat", "first_aid": "buy", "consign": "consign", "expand": "expand"}[event]
			_reject_unchanged(r, event, action, {"instance_id": id}, {}, "insufficient_black")
		_dispose(r)

func _test_empty_pools() -> void:
	for event in ["shop", "compress", "first_aid", "seal"]:
		var r = _runtime()
		var key: String = {"shop": "shop_pool", "compress": "compression_pool", "first_aid": "first_aid_pool", "seal": "seal_pool"}[event]
		var catalog := {key: []}
		var before: Dictionary = r.capture_authoritative_state()
		var result := _call(r, event, "prepare", {}, catalog)
		_check(not result.get("ok", true) and result.get("reason", "") == "empty_eligible_pool", event + ": empty pool rejected before draw/cost")
		_check(r.capture_authoritative_state() == before, event + ": empty pool leaves no state or stage")
		_dispose(r)
	var r = _runtime()
	var catalog := {"shop_pool": [Items.definition("con_red_battery")]}
	var before: Dictionary = r.capture_authoritative_state()
	var result := _call(r, "shop", "prepare", {}, catalog)
	_check(not result.get("ok", true) and r.capture_authoritative_state() == before, "shop: research/channel forbidden candidates never fallback")
	_dispose(r)
	r = _runtime()
	if _prepare(r, "shop"):
		_reject_unchanged(r, "shop", "refresh", {}, {"shop_pool": []}, "empty_eligible_pool")
	_dispose(r)
	for event in ["shop", "compress"]:
		r = _runtime()
		before = r.capture_authoritative_state()
		result = r.execute_atomic_operation(&"missing_pool", {}, func() -> Dictionary:
			return Economy.choose(r.context, r.context.get_current_pos(), event, "prepare"))
		_check(result.get("reason", "") == "missing_pool" and r.capture_authoritative_state() == before, event + ": no official fallback from fixture")
		_dispose(r)
	for event in ["shop", "seal"]:
		r = _runtime()
		r.context.run_start_config.profile_fields.content_eligibility = Eligibility.freeze_profile({"profile_level": 0})
		before = r.capture_authoritative_state()
		result = _call(r, event, "prepare")
		_check(result.get("reason", "") == "empty_eligible_pool" and r.capture_authoritative_state() == before, event + ": frozen level0 cannot acquire")
		_dispose(r)

func _test_all_duplicate_receipts() -> void:
	for event in ["shop", "savings", "seal", "relief", "first_aid", "consign", "expand", "compress", "trader", "pawn"]:
		var r = _runtime()
		r.context.pressure = 50
		var a := _item(r, "col_01")
		var b := _item(r, "col_03")
		var valuable := _item(r, "col_22")
		var action: String = {"shop": "buy", "savings": "deposit", "seal": "use", "relief": "flat", "first_aid": "buy", "consign": "consign", "expand": "expand", "compress": "compress", "trader": "sell", "pawn": "pawn"}[event]
		if _prepare(r, event, {"amount": 5} if event == "savings" else {}):
			var payload := {"quote_id": _state(r, event).quote_id, "slot": 0, "amount": 5, "instance_id": valuable, "instance_ids": [a, b]}
			var writes := [0]
			r.checkpoint_writer = func(_state_data: Dictionary) -> Dictionary:
				writes[0] += 1
				return {"ok": true}
			var first := _call(r, event, action, payload, {}, "duplicate_" + event)
			_check(first.get("ok", false), event + ": first receipt succeeds")
			var before: Dictionary = r.capture_authoritative_state()
			var duplicate := _call(r, event, action, payload, {}, "duplicate_" + event)
			_check(duplicate.get("duplicate", false) and r.capture_authoritative_state() == before and writes[0] == 1, event + ": duplicate publishes/saves/pays/delivers once")
		_dispose(r)

func _test_stale_conditions() -> void:
	for condition in ["capacity", "ownership", "frozen", "balance", "source_price", "once_flag"]:
		var r = _runtime()
		var id := _item(r, "col_22")
		if _prepare(r, "consign"):
			match condition:
				"capacity": r.context.asset_ledger.backpack_capacity += 1
				"ownership": r.context.asset_ledger.item_instances[id].location_state = &"consigned"
				"frozen": r.context.run_start_config.profile_fields.content_eligibility.profile_level = 1
				"balance": r.context.asset_ledger.add_currency(&"black_coin", 1)
				"source_price": r.context.asset_ledger.item_instances[id].base_value += 1
				"once_flag": r.context.z1_event_rooms[r.context.cell_key(r.context.get_current_pos())].z2_economy.consign.completed = true
			_check(_state(r, "consign").requires_prepare, condition + ": projection marks stale")
			_reject_unchanged(r, "consign", "consign", {"instance_id": id}, {}, "stale_quote")
		_dispose(r)

func _test_pending_resume() -> void:
	var r = _runtime()
	if not _prepare(r, "savings", {"amount": 20}):
		_dispose(r)
		return
	_act(r, "savings", "deposit", {"amount": 20})
	_room(r, Vector2i(3, 2))
	var consigned := _item(r, "col_22")
	_prepare(r, "consign")
	_act(r, "consign", "consign", {"instance_id": consigned})
	_room(r, Vector2i(4, 2))
	var pledged := _item(r, "col_22")
	_prepare(r, "pawn")
	_act(r, "pawn", "pawn", {"instance_id": pledged})
	_room(r, Vector2i(5, 2))
	_prepare(r, "seal")
	_act(r, "seal", "use")
	var saved: Dictionary = r.capture_authoritative_state()
	var encoded: Dictionary = r.encode_checkpoint_state(saved)
	var restored := r.restore_checkpoint_state(encoded)
	_check(restored.get("ok", false) and r.capture_authoritative_state() == saved, "resume: savings/consign/pawn/seal/quotes/instances exact roundtrip")
	_check(_safe(r) == 10 and r.context.asset_ledger.item_instances[consigned].location_state == &"consigned" and r.context.asset_ledger.item_instances[pledged].location_state == &"pledged", "resume: pending assets remain distinct for T14")
	_room(r, Vector2i(6, 2))
	_prepare(r, "savings")
	var result := _act(r, "savings", "withdraw")
	_check(result.get("ok", false) and _safe(r) == 0 and int(result.get("facts", {}).get("black_income_gross", 0)) == 24, "resume: pending20 withdraws24 exactly once")
	_dispose(r)

func _test_integer_savings() -> void:
	# Exact integer floor, including values beyond the float integer precision limit.
	for row in [[1, 0, 1], [5, 2, 6], [2147483649, 1073741824, 2576980378], [9007199254740993, 4503599627370496, 10808639105689191]]:
		var r = _runtime()
		r.context.asset_ledger.spend_currency(&"black_coin", 300)
		r.context.asset_ledger.add_currency(&"black_coin", row[0])
		if _prepare(r, "savings", {"amount": row[0]}):
			var result := _act(r, "savings", "deposit", {"amount": row[0]})
			_check(result.get("ok", false) and _black(r) == 0 and _safe(r) == row[1], "savings: exact integer guarantee %d" % row[0])
			_room(r, Vector2i(3, 2))
			_prepare(r, "savings")
			result = _act(r, "savings", "withdraw")
			_check(result.get("ok", false) and _black(r) == row[2] and _safe(r) == 0, "savings: exact integer 120%% %d" % row[0])
		_dispose(r)

func _test_seal_weights() -> void:
	var r = _runtime()
	var heavy := _item(r, "col_22", {"weight": 20})
	var light := _item(r, "col_03")
	var unique := _item(r, "col_22", {"weight": 30, "is_unique": true})
	var equipment := _item(r, "eq_old_vest")
	var selection := [heavy, light, unique, equipment]
	var result: Dictionary = Economy.salvage_weights(r.context, "failure", selection)
	_check(result.get("ok", false) and result.get("selected_weight", -1) == 64, "seal weight: no seal no reduction")
	_prepare(r, "seal")
	_act(r, "seal", "use")
	var before: Dictionary = r.capture_authoritative_state()
	for ending in ["failure", "abandon"]:
		result = Economy.salvage_weights(r.context, ending, selection)
		_check(result.get("ok", false) and result.get("selected_weight", -1) == 54 and result.get("discounted_instance_id", "") == heavy, "seal weight: " + ending + " targets heaviest ordinary only")
	result = Economy.salvage_weights(r.context, "failure", [light])
	_check(result.get("ok", false) and result.get("selected_weight", -1) == 1, "seal weight: minimum1, actual saving3")
	result = Economy.salvage_weights(r.context, "success", selection)
	_check(result.get("ok", false) and result.get("selected_weight", -1) == 64, "seal weight: success unchanged")
	result = Economy.salvage_weights(r.context, "failure", [heavy, heavy])
	_check(not result.get("ok", true), "seal weight: duplicate ID rejected")
	result = Economy.salvage_weights(r.context, "failure", ["foreign_missing"])
	_check(not result.get("ok", true), "seal weight: foreign ID rejected")
	_check(r.capture_authoritative_state() == before and r.context.asset_ledger.item_instances[heavy].weight == 20, "seal weight: calculation read-only, physical weight preserved")
	_dispose(r)
