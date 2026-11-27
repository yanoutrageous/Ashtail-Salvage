extends SceneTree

const Runtime := preload("res://scripts/core/run/run_runtime_controller.gd")
const Context := preload("res://scripts/core/run/run_context.gd")
const Effects := preload("res://scripts/core/run/run_effect_applier.gd")
const Supplies := preload("res://scripts/core/run/z2_supply_runtime.gd")
const Items := preload("res://scripts/core/content/z2_item_catalog.gd")
const Eligibility := preload("res://scripts/core/content/z2_content_eligibility.gd")
const Talents := preload("res://scripts/core/progression/z2_talent_catalog.gd")
const Combat := preload("res://scripts/core/run/combat_state.gd")
const Snapshot := preload("res://scripts/core/run/run_state_snapshot.gd")
const ROOM := Vector2i(2, 2)
const STEP := 1.0 / 60.0

var checks := 0
var failures: Array[String] = []
var fixture_failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for test in [_test_playtest_mines_and_teaching_rooms, _test_typed_composition, _test_pressure_and_legacy_isolation, _test_actual_hit_and_periodic_healing,
		_test_countdown_real_attack_and_clock, _test_retreat_and_terminal_lifecycle, _test_lifecycle_save_rollback,
		_test_external_terminal_cleanup, _test_periodic_rollback_and_cancelled_attack]:
		test.call()
		if fixture_failed:
			break
	for failure in failures:
		print("ASSERT_FAIL: " + failure)
	print("Z2_SUPPLY_COMBAT_INTEGRATION=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _context(nodes: Array = [], z2: bool = true) -> RunContext:
	var run := Context.new()
	var effects: Array = []
	for node in nodes:
		effects.append(Talents.definition("z2_talent_%02d" % int(node)))
	run.start_run({
		"id": "supply_combat", "mode": &"standard", "seed": 348, "width": 5, "height": 5,
		"max_hp": 100, "power": 20, "active_talent_effects": effects,
		"profile_fields": {"ruleset_id": "z2", "z2_progression_version": 1, "content_eligibility": Eligibility.freeze_profile({"profile_level": 30})} if z2 else {},
		"manual_map": {"spawn": Vector2i.ZERO, "monsters": [ROOM], "exits": [{"pos": Vector2i(4, 4), "exit_id": "test_exit"}]},
	})
	if z2:
		run.run_start_config["profile_fields"] = run.profile_fields.duplicate(true)
		run.run_start_config["map_config_id"] = "classic_13x13_normal"
	return run


func _item(id: String) -> Dictionary:
	var item := Items.definition(id)
	item["instance_id"] = id + "_fixture"
	return item


func _equip(run: RunContext, ids: Array) -> Array:
	var equipped: Array = []
	for id in ids:
		equipped.append(_item(id))
	_check(Supplies.apply_equipment_change(run, [], equipped).get("ok") == true, "equipment admission " + str(ids))
	return equipped


func _use(run: RunContext, id: String) -> void:
	_check(Supplies.apply_consumable(run, _item(id)).get("ok") == true, "supply admission " + id)


func _status(run: RunContext, item_id: String) -> Dictionary:
	for status in run.temporary_statuses:
		if status.get("item_id") == item_id:
			return status
	return {}


func _test_playtest_mines_and_teaching_rooms() -> void:
	var mine_damage := {
		"tutorial_5x5": 15, "classic_7x7_simple": 20, "classic_7x7_normal": 25,
		"classic_10x10_easy": 20, "classic_10x10_standard": 25, "classic_10x10_hard": 30,
		"classic_13x13_normal": 25, "classic_13x13_hard": 30, "classic_13x13_hell": 35,
	}
	for map_id in mine_damage:
		var run := _context()
		run.run_start_config["map_config_id"] = map_id
		if map_id == "tutorial_5x5":
			run.mode = &"tutorial"
		var result := Combat.apply_mine_hit(run)
		_check(result.get("ok", false) and int(result.get("facts", {}).get("actual_hp_loss", -1)) == int(mine_damage[map_id]), "mine damage follows formal map: " + map_id)
	var lessons := {
		Vector2i(2, 2): ["慢速近战", 30], Vector2i(0, 4): ["原地冲击波", 40],
		Vector2i(1, 3): ["慢速远程", 25], Vector2i(3, 1): ["挡板工偶", 40],
		Vector2i(4, 0): ["刹不住的搬运车", 35],
	}
	for pos in lessons:
		var run := _context()
		run.mode = &"tutorial"
		run.run_start_config["map_config_id"] = "tutorial_5x5"
		run.player_pos = pos
		run.current_room_type = &"Monster"
		var bridge := G41InRunRuntime.new()
		bridge.context = run
		bridge.sync_room(Vector2(0.21, 0.5))
		var enemy: Dictionary = bridge.simulation.enemies[0]
		_check(bridge.simulation.enemies.size() == 1 and enemy.get("enemy_name") == lessons[pos][0], "fixed teaching encounter identity: " + str(pos))
		_check(int(enemy.max_hp) == int(lessons[pos][1]) and int(enemy.damage) == 1 and int(enemy.enemy_power) == 2, "teaching HP, damage and power: " + str(pos))
		_check_teaching_attack(bridge.simulation, lessons[pos][0])
	var teaching_clear := _context()
	teaching_clear.mode = &"tutorial"
	teaching_clear.run_start_config["map_config_id"] = "tutorial_5x5"
	teaching_clear.run_start_config.profile_fields["content_eligibility"] = Eligibility.freeze_profile({"profile_level": 0})
	var reward := RunRuleService.apply_combat_reward(teaching_clear, ROOM, 2)
	_check(reward.get("ok", false) and reward.get("items", []).is_empty() and teaching_clear.asset_ledger.get_currency(RunAssetLedger.CURRENCY_BLACK) == 2, "Lv0 teaching battle awards practice currency without a formal loot pool")


func _check_teaching_attack(sim: G41CombatSimulation, lesson: String) -> void:
	sim.set_arena_obstacles([])
	var origin := Vector2(sim.enemies[0].pos)
	match lesson:
		"慢速近战":
			sim.player["pos"] = origin + Vector2(-0.11, 0)
			sim.advance_ticks(75)
			_check(sim.enemies[0].state == &"warning" and int(sim.player.hp) == 100, "tutorial melee clearly warns before impact")
			sim.advance_ticks(75)
			_check(int(sim.player.hp) == 99, "tutorial melee hits once for one damage")
		"原地冲击波":
			sim.player["pos"] = origin + Vector2(-0.13, 0)
			sim.advance_ticks(70)
			_check(not sim.hazards.is_empty() and sim.hazards[0].shape == &"circle" and int(sim.player.hp) == 100, "tutorial shockwave warns with a visible circle")
			sim.advance_ticks(100)
			_check(int(sim.player.hp) == 99 and sim.enemies[0].pos == origin, "tutorial shockwave stands still and hits once")
		"慢速远程":
			sim.player["pos"] = origin + Vector2(-0.36, 0)
			sim.advance_ticks(94)
			_check(sim.projectiles.size() == 1 and Vector2(sim.projectiles[0].velocity).length() < 0.24, "tutorial ranged fires a single slow projectile")
		"挡板工偶":
			sim.player["pos"] = origin + Vector2(-0.12, 0)
			sim.call("_damage_enemy", 0, 10)
			_check(int(sim.enemies[0].hp) == 35, "the front of the teaching shield takes half damage")
			sim.player["pos"] = origin + Vector2(0.12, 0)
			sim.call("_damage_enemy", 0, 10)
			_check(int(sim.enemies[0].hp) == 25, "the exposed side of the teaching shield takes full damage")
		"刹不住的搬运车":
			sim.player["pos"] = Vector2(0.94, origin.y)
			sim.advance_ticks(155)
			_check(sim.enemies[0].state == &"cooldown" and float(sim.enemies[0].state_timer) > 2.4, "the teaching cart is stunned after its charge hits the wall")


func _test_typed_composition() -> void:
	var run := _context([9, 20])
	_equip(run, ["eq_debris_brow_guard"])
	var hit := Effects.apply_damage_packet(run, {"amount": 20, "damage_type": "physical", "source_id": "typed_fixture"})
	_check(hit.get("ok") == true and run.hp == 85, "public damage combines talent5/10% and equipment10% before one floor")
	_check(run.vitals_counters.get("z2_supply:eq_debris_brow_guard_fixture") == 9, "limited equipment is consumed once for the real benefit")
	for kind in ["mine", "dot", "exploration", "hp_payment"]:
		run.hp = 100
		run.shield = 0
		var before: int = run.vitals_counters["z2_supply:eq_debris_brow_guard_fixture"]
		hit = Effects.apply_damage_packet(run, {"amount": 20, "damage_type": kind})
		_check(hit.get("ok") == true and run.hp == 80 and hit.get("facts", {}).get("damage_type") == kind, "typed damage stays " + kind)
		_check(run.vitals_counters["z2_supply:eq_debris_brow_guard_fixture"] == before, "nonphysical packet cannot spend brow guard: " + kind)
	var before := Snapshot.capture_context(run)
	for invalid in [{"amount": -1}, {"amount": 5, "percent_reductions": "bad"}, {"amount": 5, "flat_blocks": [2]}]:
		_check(Effects.apply_damage_packet(run, invalid).get("ok") == false and Snapshot.capture_context(run) == before, "malformed raw packet fails before equipment composition")
	var mine := _context()
	_equip(mine, ["eq_buffer_buckle"])
	mine.mine_dmg_reduce = 99
	mine.mine_immunity = 1
	var mined := Combat.apply_mine_hit(mine)
	_check(mined.get("ok") == true and int(mined.get("facts", {}).get("actual_hp_loss", -1)) == 20, "13×13 ordinary mine applies Z2 buckle to 25 base damage")
	_check(mine.vitals_counters.get("z2_supply:eq_buffer_buckle_fixture") == 2 and mine.mine_immunity == 1, "mine spends exactly the Z2 instance counter")


func _test_pressure_and_legacy_isolation() -> void:
	var run := _context([5])
	var equipped := _equip(run, ["eq_pressure_relief_wrench", "eq_insulated_sleeve"])
	_use(run, "con_calm_candy")
	run.protocol_pressure_reduce = 3
	for item: Dictionary in equipped:
		run.asset_ledger.create_item_instance(item, RunAssetLedger.LOCATION_EQUIPPED)
	var pressure := Effects.apply_pressure_packet(run, {"amount": 20, "reason": "combat"})
	_check(pressure.get("ok") == true and run.pressure == 8, "public pressure composes20-floor(25%)-5-2 once, without legacy extras")
	_check(run.vitals_counters.get("z2_supply:eq_pressure_relief_wrench_fixture") == 9 and run.vitals_counters.get("z2_supply:eq_insulated_sleeve_fixture") == 4 and run.vitals_counters.get("z2_supply:con_calm_candy_fixture") == 1, "pressure benefit spends each equipment/status counter once")
	_check(run.vitals_counters.get("z2_talent_05") == 1, "post-reduction8 cannot consume first10-pressure immunity")
	var counters := run.vitals_counters.duplicate(true)
	Effects.apply_pressure_packet(run, {"amount": -4, "reason": "combat"})
	_check(run.pressure == 4 and run.vitals_counters == counters, "negative pressure does not spend mitigations")
	var legacy := _context([], false)
	legacy.protocol_pressure_reduce = 3
	legacy.asset_ledger.create_item_instance(_item("eq_pressure_relief_wrench"), RunAssetLedger.LOCATION_EQUIPPED)
	Effects.apply_pressure_packet(legacy, {"amount": 20, "reason": "combat"})
	_check(legacy.pressure == 12 and not legacy.z1_event_flags.has("z2_supply_runtime"), "unversioned pressure retains its original Z1 path")


func _runtime(nodes: Array = []):
	var runtime = Runtime.new()
	runtime.context = _context(nodes)
	runtime.context.run_id = &"supply_combat_fixture"
	runtime.command_bus.bind_runtime_controller(runtime)
	runtime.in_run_runtime.bind(runtime)
	runtime.checkpoint_writer = func(_state: Dictionary) -> Dictionary: return {"ok": true}
	return runtime


func _enter(runtime) -> bool:
	runtime.context.player_pos = ROOM
	runtime.context.current_pos = ROOM
	var entered: Dictionary = runtime.command_bus.room_resolver.enter_room(runtime.context)
	if not entered.get("ok", false):
		fixture_failed = true
		_check(false, "fixture room entry rejected: " + str(entered))
		return false
	var bridge = runtime.in_run_runtime
	bridge.sync_room(Vector2(0.5, 0.5))
	if bridge.simulation == null:
		fixture_failed = true
		_check(false, "fixture room entry produced no combat simulation: " + str(entered))
		return false
	bridge.simulation.set_arena_obstacles([])
	bridge.simulation.place_player_from_room_entry(Vector2(0.5, 0.5), Vector2.RIGHT)
	bridge.simulation.enemies[0].pos = Vector2(0.66, 0.5)
	bridge.simulation.enemies[0].facing = Vector2.RIGHT
	bridge.simulation.enemies[0].entry_grace_remaining = 100.0
	return true


func _step(runtime, count: int = 1) -> void:
	for tick in range(count):
		runtime.in_run_runtime.advance_frame(STEP, Vector2.ZERO, Vector2.RIGHT)


func _test_actual_hit_and_periodic_healing() -> void:
	var runtime = _runtime([9, 20, 35])
	var run: RunContext = runtime.context
	_equip(run, ["eq_debris_brow_guard"])
	_use(run, "con_waiver_medicine")
	if not _enter(runtime):
		_release(runtime)
		return
	_step(runtime)
	_check(_status(run, "con_waiver_medicine").get("phase") == "active", "actual combat start activates waiting waiver")
	var simulation = runtime.in_run_runtime.simulation
	simulation.call("_spawn_projectile", String(simulation.enemies[0].enemy_id), simulation.player.pos, Vector2.LEFT, 20, {"velocity": Vector2.ZERO})
	_step(runtime)
	_check(run.hp == 93 and simulation.player.hp == 93, "real projectile consumes combined talent/equipment/waiver damage once")
	_check(_status(run, "con_waiver_medicine").get("hits_left") == 3, "one physical collision consumes one waiver hit despite generic hit hook")
	run.hp = 20
	var healed := Effects.apply_heal_packet(run, {"amount": 10})
	_check(healed.get("ok") == true and run.hp == 26, "public healing applies low-HP talent before waiver half-healing")
	run.hp = 20
	run.temporary_statuses.append({"id": "periodic_heal", "type": "temporary_buff", "temporary_type": "heal", "phase": "active", "remaining": STEP, "heal_per_second": 600.0})
	_step(runtime)
	_check(run.hp == 26, "real fixed-step periodic healing uses the same supply/talent composition")
	_check(is_equal_approx(float(_status(run, "con_waiver_medicine").get("remaining", -1)), 20.0 - 3.0 * STEP), "waiver advances on existing60Hz clock exactly once per step")
	_release(runtime)


func _test_countdown_real_attack_and_clock() -> void:
	var runtime = _runtime()
	var run: RunContext = runtime.context
	_use(run, "con_countdown_pill")
	if not _enter(runtime):
		_release(runtime)
		return
	var simulation = runtime.in_run_runtime.simulation
	simulation.enemies[0].hp = 1000
	simulation.enemies[0].max_hp = 1000
	_step(runtime, 30)
	_check(_status(run, "con_countdown_pill").get("phase") == "waiting" and _status(run, "con_countdown_pill").get("remaining") == 12.0, "waiting pill consumes no combat time before actual attack")
	runtime.in_run_runtime.request_attack(Vector2.RIGHT)
	_step(runtime)
	_check(_status(run, "con_countdown_pill").get("phase") == "active" and _status(run, "con_countdown_pill").get("remaining") == 12.0, "actual attack start activates pill after the existing time step")
	_step(runtime, 10)
	_check(simulation.enemies[0].hp == 975, "actual direct hit uses floor(20*125%)=25")
	_step(runtime, 50)
	_check(is_equal_approx(float(_status(run, "con_countdown_pill").get("remaining", -1)), 11.0), "60 further steps consume exactly one second")
	_step(runtime, 660)
	_check(_status(run, "con_countdown_pill").get("phase") == "ended", "pill expires at12 actual simulation seconds")
	runtime.in_run_runtime.request_attack(Vector2.RIGHT)
	_step(runtime, 11)
	_check(simulation.enemies[0].hp == 955 and run.power == 20, "expired pill restores unmodified actual attacks without baking power")
	_release(runtime)


func _test_retreat_and_terminal_lifecycle() -> void:
	var runtime = _runtime()
	var run: RunContext = runtime.context
	_use(run, "con_waiver_medicine")
	if not _enter(runtime):
		_release(runtime)
		return
	_step(runtime)
	var saved: Array = []
	runtime.checkpoint_writer = func(candidate: Dictionary) -> Dictionary:
		saved.append(candidate.duplicate(true))
		return {"ok": true}
	var fled: Dictionary = runtime.in_run_runtime.request_flee()
	_check(fled.get("ok") == true and _status(run, "con_waiver_medicine").get("phase") == "ended", "authorized retreat ends drug in the actual command")
	_check(not bool(Supplies.snapshot(run).state.combat_active), "retreat releases supply equipment combat lock")
	var saved_ended := false
	if not saved.is_empty():
		for status in saved[0].get("context", {}).get("data", {}).get("temporary_statuses", []):
			saved_ended = saved_ended or (status.get("item_id") == "con_waiver_medicine" and status.get("phase") == "ended")
	_check(saved_ended, "retreat checkpoint includes ended drug before success publication")
	_release(runtime)
	var dying = _runtime()
	_use(dying.context, "con_waiver_medicine")
	if not _enter(dying):
		_release(dying)
		return
	_step(dying)
	dying.context.hp = 1
	var simulation = dying.in_run_runtime.simulation
	simulation.call("_spawn_projectile", String(simulation.enemies[0].enemy_id), simulation.player.pos, Vector2.LEFT, 1000, {"velocity": Vector2.ZERO})
	_step(dying)
	_check(dying.context.failed and _status(dying.context, "con_waiver_medicine").get("phase") == "ended", "real lethal combat ends drug before terminal snapshot")
	_release(dying)
	var winning = _runtime()
	_use(winning.context, "con_waiver_medicine")
	if not _enter(winning):
		_release(winning)
		return
	winning.context.power = 500
	for tick in range(600):
		if not winning.in_run_runtime.has_active_combat():
			break
		var sim = winning.in_run_runtime.simulation
		var target := {}
		for enemy in sim.enemies:
			if enemy.hp > 0:
				target = enemy
				break
		if target.is_empty():
			break
		var offset: Vector2 = Vector2(target.pos) - Vector2(sim.player.pos)
		var aim := offset.normalized()
		winning.in_run_runtime.request_attack(aim)
		var stepped: Dictionary = winning.in_run_runtime.advance_frame(STEP, aim if offset.length() > 0.15 else Vector2.ZERO, aim)
		if not stepped.get("step_result", {}).get("ok", false):
			_check(false, "actual clear step rejected: " + str(stepped.get("step_result", {})))
			_release(winning)
			return
	_check(winning.context.truth_map.is_cleared(ROOM) and _status(winning.context, "con_waiver_medicine").get("phase") == "ended", "actual clear ends drug, preserving ordinary reward path")
	_release(winning)


func _test_lifecycle_save_rollback() -> void:
	var runtime = _runtime()
	_use(runtime.context, "con_waiver_medicine")
	if not _enter(runtime):
		_release(runtime)
		return
	var before: Dictionary = Snapshot.capture_context(runtime.context)
	runtime.checkpoint_writer = func(_candidate: Dictionary) -> Dictionary: return {"ok": false, "reason": "injected_save_failure"}
	_step(runtime)
	_check(not runtime.persistence_error.is_empty() and Snapshot.capture_context(runtime.context) == before and runtime.in_run_runtime.simulation.tick_index == 0, "failed first-step save rolls back activation, counters, time and combat together")
	_release(runtime)


func _test_external_terminal_cleanup() -> void:
	for terminal in ["failure", "abandon"]:
		var runtime = _runtime()
		_use(runtime.context, "con_waiver_medicine")
		if not _enter(runtime):
			_release(runtime)
			return
		_step(runtime)
		if terminal == "failure":
			runtime.fail_run("external_failure")
		else:
			runtime.abandon_run()
		_check(not runtime.context.run_active and _status(runtime.context, "con_waiver_medicine").get("phase") == "ended" and not bool(Supplies.snapshot(runtime.context).state.combat_active), "runtime terminal reset also ends real combat drug: " + terminal)
		_release(runtime)


func _test_periodic_rollback_and_cancelled_attack() -> void:
	var run := _context()
	run.hp = 50
	run.temporary_statuses.append({"id": "mixed_periodic", "type": "temporary_buff", "temporary_type": "mixed", "phase": "active", "remaining": 1.0, "dot_per_second": 60.0, "heal_per_second": 60.0})
	run.vitals_modifiers["heal"] = {"bonus_rate": -1.0}
	var before := Snapshot.capture_context(run)
	_check(Effects.advance_statuses(run, STEP, {}).get("ok") == false and Snapshot.capture_context(run) == before, "periodic healing rejection rolls back preceding damage, status time and events")
	var runtime = _runtime()
	_use(runtime.context, "con_countdown_pill")
	if not _enter(runtime):
		_release(runtime)
		return
	runtime.context.hp = 1
	runtime.context.temporary_statuses.append({"id": "fatal_dot", "type": "temporary_debuff", "temporary_type": "poison", "phase": "active", "remaining": 1.0, "dot_per_second": 60.0})
	runtime.in_run_runtime.request_attack(Vector2.RIGHT)
	_step(runtime)
	_check(runtime.context.failed and float(_status(runtime.context, "con_countdown_pill").get("elapsed", -1)) == 0.0, "fatal pre-physics status cannot activate pill for an attack that never started")
	_release(runtime)


func _release(runtime) -> void:
	runtime.in_run_runtime.bind(null)
	runtime.command_bus.item_command_handler.combat_active_query = Callable()
	runtime.command_bus.bind_runtime_controller(null)
	runtime.context = null
	runtime.in_run_runtime = null
	runtime.command_bus = null


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
