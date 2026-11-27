extends SceneTree

# T16 legal-content journeys. Only level/prerequisite/wallet and room placement
# are staged. No target item injection, fabricated goal facts, custom hooks,
# replacement pools, or persistence stubs. This is not natural Lv0->50 evidence.
# Manifest: required + core/quick/full; set Z2_CONTENT_JOURNEY_QA_HOME to the
# absolute per-case isolated root. No production content/PCK dependency added.
const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
const Meta = preload("res://scripts/core/save/meta_progress_adapter.gd")
const Manager = preload("res://scripts/core/save/save_manager.gd")
const Rules = preload("res://scripts/core/progression/z2_progression_rules.gd")
const Goals = preload("res://scripts/core/progression/z2_goals/goal_progression.gd")
const Start = preload("res://scripts/core/run/run_start_config.gd")
const Items = preload("res://scripts/core/content/z2_item_catalog.gd")
const Loot = preload("res://scripts/core/content/z2_loot_catalog.gd")
const Eligibility = preload("res://scripts/core/content/z2_content_eligibility.gd")
const Content = preload("res://scripts/core/content/run_rule_content.gd")
const Process = preload("res://scripts/core/run/z2_process_events.gd")
const Service = preload("res://scripts/core/run/event_service.gd")
const DIRECTIONS := [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]
const NO_CELL := Vector2i(-1, -1)
var r: RunRuntimeController
var meta: MetaProgressAdapter
var manager: SaveManager
var serial := 0
var checks := 0
var failures: Array[String] = []
var evidence: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var home := OS.get_environment("Z2_CONTENT_JOURNEY_QA_HOME").simplify_path().replace("\\", "/").trim_suffix("/")
	var actual := OS.get_user_data_dir().simplify_path().replace("\\", "/")
	if not home.is_absolute_path() or not actual.to_lower().begins_with(home.to_lower() + "/") or FileAccess.file_exists("user://saves/manifest.json"):
		printerr("Z2_CONTENT_JOURNEY=FAIL fresh absolute isolated user data root required")
		quit(1)
		return
	_test_boundaries()
	_test_equipment_departure()
	_test_recycle_compression()
	_test_tier_six_return()
	_release()
	var record := {"checks": checks + 1, "failures": failures, "cases": evidence,
		"limits": "staged levels/prerequisites/wallet/room placement; actual acquisition and durable settlement; no natural leveling or random guarantee"}
	_check(SaveAdapter.new().save_json(record, "user://z2_content_journey_evidence.json", false), "persist journey evidence")
	for failure in failures:
		print("Z2_CONTENT_JOURNEY_FAIL " + failure)
	print("Z2_CONTENT_JOURNEY_EVIDENCE " + ProjectSettings.globalize_path("user://z2_content_journey_evidence.json"))
	print("Z2_CONTENT_JOURNEY=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _open(profile: String) -> bool:
	_release()
	manager = Manager.new()
	manager.load_manifest()
	if not _check(manager.switch_profile(profile).get("ok", false), "select isolated profile " + profile):
		return false
	meta = Meta.new()
	r = Runtime.new()
	r.bind_meta_progress_adapter(meta)
	var result := r.initialize_z2_session(manager)
	return _check(result.get("ok", false) and r.checkpoint_service != null and not r.checkpoint_writer.is_valid(), "real session/checkpoint service " + str(result.get("status", "")))

func _stage(level: int, predecessors: int, clears: Dictionary = {}) -> bool:
	var data: Dictionary = Goals.initial_state(meta.data)
	data.merge({"tutorial_completed": true, "profile_level": level, "profile_exp": Rules.exp_for_level(level),
		"talent_flags": ["z2_talent_01"], "talent_earned": 100, "talent_spent": 100, "talent_points": 0,
		"gold": 1000, "map_success_counts": clears.duplicate(true)}, true)
	for number in range(1, predecessors + 1):
		var id := "M%02d" % number
		data.z2_goals.states[id].unlocked = true
		data.z2_goals.states[id].progress = Goals.goal_state(data, id).target
	meta.data = Goals.initial_state(data)
	var valid := Rules.profile_error(meta.data).is_empty()
	return _check(valid and meta.save(), "legal stage profile saved Lv%d / preceding M%02d" % [level, predecessors])

func _disk() -> MetaProgressAdapter:
	var disk := Meta.new()
	disk.set_active_profile_path(meta.active_meta_progress_path, meta.active_profile_id)
	_check(disk.last_load_status == "loaded", "read actual Meta file")
	return disk

func _status(adapter: MetaProgressAdapter, id: String) -> String:
	return str(adapter.get_summary().get("task_states", {}).get(id, {}).get("status", ""))

func _config(map_id: String, seed: int, equipment: Array = []) -> Dictionary:
	var commission: Dictionary = M7ContentCatalog.commission_offer_candidates(map_id, int(meta.data.get("run_count", 0)), 3)[0]
	return {"map_config_id": map_id, "difficulty": "", "seed_value": seed, "selected_objective_id": commission.id,
		"selected_equipment_ids": equipment.duplicate()}

func _start(map_id: String, seed: int, equipment: Array = []) -> bool:
	if not _command(&"start_standard_run", {"run_start_config": _config(map_id, seed, equipment)}).get("ok", false):
		return false
	_check(meta.data.get("admission", {}).get("phase") == "active" and FileAccess.file_exists(r.checkpoint_service.checkpoint_path), "real durable departure admission")
	_check(r.context.run_start_config.profile_fields.content_eligibility.profile_level == meta.data.profile_level, "departure freezes legal content eligibility")
	return true

func _test_boundaries() -> void:
	if not _open("content_boundaries"):
		return
	var boundaries := {10: "classic_10x10_hard", 15: "classic_13x13_normal", 20: "classic_13x13_hard", 25: "classic_13x13_hell"}
	var clears := {"classic_10x10_standard": 1, "classic_13x13_normal": 1, "classic_13x13_hard": 1}
	for level: int in [10, 15, 20, 25, 28, 50]:
		for at: int in [level - 1, level]:
			if not _stage(at, 0, clears):
				return
			var disk := _disk()
			_check(disk.data.profile_level == at and disk.data.profile_exp == Rules.exp_for_level(at), "stage XP/level reread exactly Lv%d" % at)
			var frozen := Eligibility.freeze_profile(disk.data)
			var map_id: String = boundaries.get(level, "classic_13x13_hell")
			var admission := Start.authorize_with_meta(_config(map_id, 3141), disk.get_summary())
			_check(admission.get("ok", false) == (at == level or level >= 28), "actual admission boundary Lv%d -> %s" % [at, map_id])
			if admission.get("ok", false):
				_check(admission.config.profile_fields.content_eligibility.profile_level == at, "authorized config freezes exact stage")
			var pool := Loot.candidates("altar", frozen, map_id, 5)
			_check(not pool.is_empty(), "official stage5 pool at staged level")
			_check(pool.all(func(row: Dictionary) -> bool: return Eligibility.is_eligible(str(row.item_id), "altar", frozen, map_id)), "official pool enforces actual altar channel")
			if level == 28:
				_check(pool.any(func(row: Dictionary) -> bool: return row.item_id == "col_bottomless_ballast_canister") == (at == 28), "Lv28 collectible unlock in actual pool")
			if level == 50 and at == 50:
				_check(Rules.level_for_exp(int(disk.data.profile_exp) + 1000) == 50 and Rules.exp_for_level(51) == -1, "Lv50 cap without invented Lv51")
		evidence.append({"kind": "stage_boundary", "levels": [level - 1, level], "predecessor_clear_fixture": clears})

func _test_equipment_departure() -> void:
	if not _open("content_m05") or not _stage(10, 4):
		return
	_check(_status(meta, "M05") == "active", "M05 active before any purchases or departure")
	var bought: Array[String] = []
	var slots := {}
	var expected_cost := 0
	var before_gold: int = meta.data.gold
	for item_id: String in ["eq_old_vest", "eq_edge_opener", "eq_recovery_bag"]:
		var definition := Items.definition(item_id)
		_check(Eligibility.is_eligible(item_id, "camp_shop", Eligibility.freeze_profile(meta.data)), "legal camp purchase " + item_id)
		expected_cost += int(definition.purchase_price)
		slots[str(definition.equipment_slot)] = true
		var result := r.execute_meta_action({"request_id": _id("purchase"), "source_page": "camp_shop", "action": "purchase", "item_id": item_id, "quantity": 1})
		if not _check(result.get("ok", false), "real camp purchase " + item_id + " " + str(result.get("status", ""))):
			return
		for item: Dictionary in meta.data.warehouse_items:
			if str(item.item_id) == item_id:
				bought.append(str(item.instance_id))
	_check(slots.size() == 3 and bought.size() == 3 and meta.data.gold == before_gold - expected_cost, "three distinct slots / instances and actual purchase total")
	var disk := _disk()
	_check(disk.data.warehouse_items.size() == 3 and disk.data.gold == meta.data.gold, "purchases durably stored before admission")
	if not _start("classic_7x7_simple", 1101, bought):
		return
	for id in bought:
		_check(meta.data.admission.reserved_instance_ids.has(id) and r.context.asset_ledger.item_instances.has(id), "purchased identity really carried at departure")
	var profile := meta.active_profile_id
	if not _open(profile):
		return
	_check(r.context.run_active and r.context.run_start_config.selected_equipment_ids == bought, "real checkpoint restart retains departure equipment")
	var run_id := str(r.context.run_id)
	if _extract():
		disk = _disk()
		_check(_status(disk, "M05") == "claimable", "real successful return persists M05")
		_check(disk.data.run_receipts.has(run_id) and disk.data.z2_goals.run_receipts.has(run_id), "M05 shares real terminal and goal receipts")
		evidence.append({"kind": "M05", "level_fixture": 10, "predecessors": "M01-M04", "wallet_fixture": 1000,
			"map": "classic_7x7_simple", "seed": 1101, "run_id": run_id, "purchased_instance_ids": bought, "purchase_cost": expected_cost, "status": _status(disk, "M05")})

func _passable(pos: Vector2i) -> bool:
	var truth: TruthMap = r.context.truth_map
	if not truth.is_inside(pos) or truth.is_mine(pos):
		return false
	var kind := str(truth.get_room_type(pos))
	return kind in ["Normal", "Chest", "Exit"] or (kind == "Event" and r.context.z1_event_rooms.has(r.context.cell_key(pos)))

func _parents() -> Dictionary:
	var origin: Vector2i = r.context.get_current_pos()
	var parents := {origin: origin}
	var queue: Array[Vector2i] = [origin]
	while not queue.is_empty():
		var pos: Vector2i = queue.pop_front()
		for direction: Vector2i in DIRECTIONS:
			var next := pos + direction
			if not parents.has(next) and _passable(next):
				parents[next] = pos
				queue.append(next)
	return parents

func _normal_cells() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for pos: Vector2i in _parents():
		if r.context.truth_map.get_room_type(pos) == &"Normal" and pos != r.context.truth_map.spawn_pos:
			result.append(pos)
	return result

func _walk(target: Vector2i) -> bool:
	var parents := _parents()
	if not _check(parents.has(target), "safe actual movement path to " + str(target)):
		return false
	var route: Array[Vector2i] = []
	var pos := target
	while pos != r.context.get_current_pos():
		route.push_front(pos)
		pos = parents[pos]
	for next: Vector2i in route:
		if not _command(&"attempt_room_transition", {"direction": next - r.context.get_current_pos()}).get("ok", false):
			return false
	return _check(r.context.get_current_pos() == target, "RoomResolver actually reached " + str(target))

func _place_events(rooms: Dictionary) -> bool:
	# Explicit layout fixture changes only safe room kinds, never exits/mines,
	# ownership, generated rewards, event progress or quest facts.
	var result := r.execute_atomic_operation(&"content_journey_room_fixture", {}, func() -> Dictionary:
		for pos: Vector2i in rooms:
			if r.context.truth_map.get_room_type(pos) != &"Normal" or r.context.truth_map.is_mine(pos):
				return {"ok": false, "reason": "fixture_not_safe_normal"}
			r.context.truth_map.set_room_type(pos, &"Event")
			r.context.z1_event_rooms[r.context.cell_key(pos)] = {"event_type": StringName(rooms[pos])}
		return {"ok": true}, _id("layout"))
	return _check(result.get("ok", false), "isolated room layout saved by actual candidate")

func _state() -> Dictionary:
	return Service.get_event_state(r.context, r.context.get_current_pos())

func _choose(action: String, extra: Dictionary = {}) -> Dictionary:
	var request := {"option_id": action}
	for option: Dictionary in _state().get("options", []):
		if str(option.id) == action:
			request.merge(option.get("payload", {}).duplicate(true), true)
			break
	request.merge(extra, true)
	var result := _command(&"select_event_option", request)
	return result.get("action_result", result)

func _pickup(id: String, require_floor: bool = true) -> bool:
	var item: Dictionary = r.context.asset_ledger.item_instances.get(id, {})
	if not _check(not item.is_empty(), "reward instance exists " + id):
		return false
	if require_floor and str(item.location_state) == "inventory":
		# Some authoritative event grants go directly to the backpack. Exercise
		# real drop + pickup of that generated identity, not a fabricated floor item.
		if not _command(&"drop_inventory_item", {"instance_id": id}).get("ok", false):
			return false
		item = r.context.asset_ledger.item_instances[id]
	if require_floor and not _check(str(item.location_state) == "room_floor", "generated identity awaits actual ground pickup " + id):
		return false
	if str(item.location_state) == "room_floor" and not _command(&"pickup_ground_item", {"instance_id": id}).get("ok", false):
		return false
	return _check(str(r.context.asset_ledger.item_instances[id].location_state) == "inventory", "exact reward now in inventory")

func _test_recycle_compression() -> void:
	if not _open("content_recycle_compression") or not _stage(15, 9) or not _start("classic_13x13_normal", 3141):
		return
	_check(_status(meta, "S08") == "active" and _status(meta, "S09") == "active", "S08/S09 active before acquisition")
	var normals := _normal_cells()
	var searches: Array[Vector2i] = []
	for pos: Vector2i in normals:
		var adjacent: int = r.context.minefield_service.count_adjacent_mines(r.context.truth_map, pos)
		var gold := Content.default_search_black_coin(r.context, pos, adjacent, false)
		var drops := Content.default_search_items(pos, adjacent, false, gold, r.context)
		if drops.any(func(item: Dictionary) -> bool: return str(item.item_type) == "collectible" and int(item.tier) == 1):
			searches.append(pos)
			if searches.size() == 2:
				break
	var event_cells: Array[Vector2i] = []
	for pos: Vector2i in normals:
		if not searches.has(pos):
			event_cells.append(pos)
			if event_cells.size() == 3:
				break
	if not _check(searches.size() == 2 and event_cells.size() == 3, "seed3141 has reachable official tier1 inputs and safe event fixture cells"):
		return
	if not _place_events({event_cells[0]: "recycle", event_cells[1]: "recycle", event_cells[2]: "compress"}) or not _walk(event_cells[0]):
		return
	var taken := _choose("take")
	var material_id := str(taken.get("facts", {}).get("item_instance_id", ""))
	if not taken.get("ok", false) or not _pickup(material_id):
		return
	var material: Dictionary = r.context.asset_ledger.item_instances[material_id].duplicate(true)
	_check(Eligibility.is_eligible(str(material.item_id), "recycle", r.context.run_start_config.profile_fields.content_eligibility, "classic_13x13_normal"), "collected material belongs to actual recycle pool")
	var profile := meta.active_profile_id
	if not _open(profile) or not _walk(event_cells[1]):
		return
	var delivered := _choose("deliver", {"instance_id": material_id})
	_check(delivered.get("ok", false) and delivered.get("facts", {}).get("item_instance_id", "") == material_id and int(delivered.get("facts", {}).get("safe_income", 0)) > 0, "other real recycle point pays for same acquired instance after restart")
	var inputs: Array[String] = []
	for pos: Vector2i in searches:
		if not _walk(pos):
			return
		var previous: Array = r.context.asset_ledger.item_instances.keys()
		if not _command(&"search_current_room").get("ok", false):
			return
		for _tick in range(8):
			r.advance_idle_frame(0.25)
		_check(r.context.searched_cells.has(r.context.cell_key(pos)), "actual two-second normal search completed")
		for id: String in r.context.asset_ledger.item_instances:
			var item: Dictionary = r.context.asset_ledger.item_instances[id]
			if not previous.has(id) and str(item.item_type) == "collectible" and int(item.tier) == 1:
				_check(Eligibility.is_eligible(str(item.item_id), "search", r.context.run_start_config.profile_fields.content_eligibility, "classic_13x13_normal"), "real input uses opened search channel")
				if _pickup(id):
					inputs.append(id)
	if not _check(inputs.size() == 2 and inputs[0] != inputs[1], "two distinct legitimately searched compression inputs") or not _walk(event_cells[2]):
		return
	_choose("prepare", {"instance_ids": inputs})
	var compressed := _choose("compress", {"instance_ids": inputs})
	var output: Dictionary = compressed.get("facts", {}).get("output", {})
	if not _check(compressed.get("ok", false) and int(output.get("tier", 0)) == 2, "actual quoted compression produces tier2"):
		return
	for id in inputs:
		_check(str(r.context.asset_ledger.item_instances[id].location_state) == "consumed", "actual exact compression input consumed")
	_check(Eligibility.is_eligible(str(output.item_id), "compression", r.context.run_start_config.profile_fields.content_eligibility, "classic_13x13_normal"), "output comes from official qualified compression pool")
	if not _pickup(str(output.instance_id)):
		return
	var run_id := str(r.context.run_id)
	if _extract():
		var disk := _disk()
		_check(_status(disk, "S08") == "claimable" and _status(disk, "S09") == "claimable", "actual same-run recovery/compression facts persist both goals")
		_check(disk.data.warehouse_items.any(func(item: Dictionary) -> bool: return str(item.instance_id) == str(output.instance_id)), "exact compression output survives successful warehouse return")
		evidence.append({"kind": "S08/S09", "level_fixture": 15, "predecessors": "M01-M09", "seed": 3141,
			"run_id": run_id, "event_cells": event_cells, "searches": searches, "material": material,
			"input_instance_ids": inputs, "output": output, "S08": _status(disk, "S08"), "S09": _status(disk, "S09")})

func _find_altar(cells: Array[Vector2i]) -> Vector2i:
	# Read-only fixture locator calls the real weighted Process helpers; it never
	# changes RNG, prepared quotes or assets. The actual room then generates and
	# pays every stage. A chosen random outcome here is not a natural odds claim.
	var fourth := Process._pool(r.context, "altar", Loot.process_rules(r.context, 4))
	var fifth := Process._pool(r.context, "altar", Loot.process_rules(r.context, 5))
	for pos: Vector2i in cells:
		var a: Dictionary = Process._draw(fourth.items, 1, Process._rng(r.context, pos, "altar", 4))[0]
		var b: Dictionary = Process._draw(fifth.items, 1, Process._rng(r.context, pos, "altar", 5))[0]
		if int(a.get("tier", 0)) == 6 and int(b.get("tier", 0)) == 6 and int(a.weight) + int(b.weight) <= r.context.asset_ledger.backpack_capacity:
			return pos
	return NO_CELL

func _heal_at(pos: Vector2i, altar: Vector2i) -> bool:
	if not _walk(pos):
		return false
	var bought := _choose("buy")
	var item: Dictionary = bought.get("facts", {}).get("delivery", {})
	if not bought.get("ok", false) or not _pickup(str(item.get("instance_id", "")), false):
		return false
	var hp: int = r.context.hp
	if not _command(&"use_consumable", {"instance_id": str(item.instance_id)}).get("ok", false):
		return false
	_check(r.context.hp > hp, "purchased cabinet med patch actually restores health")
	return _walk(altar)

func _test_tier_six_return() -> void:
	if not _open("content_m15") or not _stage(20, 14) or not _start("classic_13x13_normal", 3141):
		return
	_check(_status(meta, "M15") == "active", "M15 active before any tier6 acquisition")
	var normals := _normal_cells()
	var altar := _find_altar(normals)
	var med_cells: Array[Vector2i] = []
	for pos: Vector2i in normals:
		if pos != altar:
			med_cells.append(pos)
			if med_cells.size() == 2:
				break
	if not _check(altar != NO_CELL and med_cells.size() == 2, "actual opened altar pools have a reachable reproducible two-tier6 fixture"):
		return
	if not _place_events({altar: "altar", med_cells[0]: "first_aid", med_cells[1]: "first_aid"}) or not _walk(altar):
		return
	var acquired: Array[Dictionary] = []
	var stages: Array[Dictionary] = []
	for stage in range(1, 6):
		if _state().get("requires_prepare", false):
			if not _choose("prepare").get("ok", false):
				return
		var quote := _state()
		_check(int(quote.get("tier", 0)) == stage, "actual ordered altar quote tier%d" % stage)
		var hp: int = r.context.hp
		var result := _choose("offer")
		if not result.get("ok", false):
			return
		_check(r.context.hp == hp - int(quote.hp_cost) and r.context.hp > 0, "actual stage%d HP payment preserves life" % stage)
		var items: Array = result.get("facts", {}).get("items", [])
		_check(items.size() == 1 and str(items[0].item_id) == str(quote.rewards[0].item_id), "actual generated item equals saved official quote")
		for item: Dictionary in items:
			_check(Eligibility.is_eligible(str(item.item_id), "altar", r.context.run_start_config.profile_fields.content_eligibility, "classic_13x13_normal"), "real altar output passes actual channel")
			if stage >= 4:
				if not _check(int(item.get("tier", 0)) == 6, "chosen fixture really generates tier6") or not _pickup(str(item.instance_id)):
					return
				acquired.append(r.context.asset_ledger.item_instances[str(item.instance_id)].duplicate(true))
		stages.append({"tier": stage, "hp_before": hp, "hp_after": r.context.hp, "cost": quote.hp_cost, "actual_items": items})
		if stage in [3, 4] and not _heal_at(med_cells[stage - 3], altar):
			return
	_check(acquired.size() == 2 and str(acquired[0].instance_id) != str(acquired[1].instance_id), "two distinct real tier6 instances carried")
	var run_id := str(r.context.run_id)
	var profile := meta.active_profile_id
	if not _open(profile):
		return
	for item in acquired:
		_check(r.context.asset_ledger.item_instances.has(str(item.instance_id)) and str(r.context.asset_ledger.item_instances[str(item.instance_id)].location_state) == "inventory", "disk checkpoint restores actual picked tier6 identity")
	if _extract():
		var disk := _disk()
		for item in acquired:
			_check(disk.data.warehouse_items.any(func(stored: Dictionary) -> bool: return str(stored.instance_id) == str(item.instance_id) and str(stored.item_id) == str(item.item_id) and int(stored.tier) == 6), "same generated tier6 actually arrives in persisted warehouse")
		_check(_status(disk, "M15") == "claimable", "real generated / picked / carried / successful M15 persists")
		evidence.append({"kind": "M15", "level_fixture": 20, "predecessors": "M01-M14", "map": "classic_13x13_normal", "seed": 3141,
			"run_id": run_id, "altar": altar, "healing_rooms": med_cells, "stages": stages, "tier6_instances": acquired, "status": _status(disk, "M15")})

func _extract() -> bool:
	var reachable := _parents()
	var exit_pos := NO_CELL
	for pos: Vector2i in r.context.truth_map.get_exits():
		if reachable.has(pos):
			exit_pos = pos
			break
	if not _check(exit_pos != NO_CELL, "generated exit is safely reachable") or not _walk(exit_pos):
		return false
	if not _command(&"request_extract").get("ok", false) or not _command(&"confirm_extract").get("ok", false):
		return false
	if r.context.settlement_result.get("requires_salvage_selection", false) and not r.context.settlement_result.get("finalized", false):
		var choice := r.terminal_selection_state([])
		if not _command(&"confirm_failure_salvage", {"selected_instance_ids": choice.get("default_selected_instance_ids", [])}).get("ok", false):
			return false
	return _check(r.context.extracted and r.context.settlement_result.get("finalized", false) and r.last_meta_commit.get("status", "") == "committed", "formal success and actual durable terminal commit")

func _command(command: StringName, payload: Dictionary = {}) -> Dictionary:
	var request := payload.duplicate(true)
	request["action_id"] = _id(str(command))
	var result: Dictionary = r.command_bus.dispatch(command, request)
	var detail: Dictionary = result.get("action_result", result)
	_check(result.get("ok", false), "actual command %s: %s %s" % [command, detail.get("reason", detail.get("status", "")), detail.get("issues", [])])
	return result

func _id(prefix: String) -> String:
	serial += 1
	return "content-journey:%s:%d" % [prefix, serial]

func _release() -> void:
	if r != null:
		r.command_bus.runtime_controller = null
		r.command_bus.room_resolver.bind_runtime_controller(null)
		r.in_run_runtime.bind(null)
		r = null

func _check(value: bool, label: String) -> bool:
	checks += 1
	if not value:
		failures.append(label)
	return value
