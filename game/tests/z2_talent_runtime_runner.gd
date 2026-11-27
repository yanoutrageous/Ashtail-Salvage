extends SceneTree

const Catalog := preload("res://scripts/core/progression/z2_talent_catalog.gd")
const Effects := preload("res://scripts/core/run/run_effect_applier.gd")
const Combat := preload("res://scripts/core/run/combat_state.gd")
const Context := preload("res://scripts/core/run/run_context.gd")
const Bridge := preload("res://scripts/core/run/g41_in_run_runtime.gd")
const Snapshot := preload("res://scripts/core/run/run_state_snapshot.gd")

var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_initial_power_and_growth()
	_test_physical_damage_and_survival()
	_test_pressure_and_healing()
	_test_combat_movement_and_attack_speed()
	_test_real_critical_hits_and_replay()
	_test_scope_and_checkpoint()
	_test_tutorial_flag_and_snapshot_rejection()
	_test_tutorial_profile_scrub()
	for failure in failures:
		print("ASSERT_FAIL: " + failure)
	print("Z2_TALENT_RUNTIME=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _effects(numbers: Array) -> Array:
	var result: Array = []
	for number in numbers:
		result.append(Catalog.definition("z2_talent_%02d" % int(number)))
	return result


func _context(numbers: Array = [], z2: bool = true, tutorial: bool = false, tutorial_flag_only: bool = false) -> RunContext:
	var context := Context.new()
	context.start_run({
		"id": "talent_runtime", "mode": &"tutorial" if tutorial else &"standard",
		"seed": 13, "width": 3, "height": 3, "power": 10, "max_hp": 100,
		"tutorial_map": tutorial_flag_only,
		"profile_fields": {"ruleset_id": "z2", "z2_progression_version": 1} if z2 else {},
		"active_talent_effects": _effects(numbers),
		"manual_map": {"spawn": Vector2i.ZERO, "mines": [], "monsters": [Vector2i(1, 1)], "events": [], "chests": [], "exits": []},
	})
	return context


func _test_initial_power_and_growth() -> void:
	var context := _context([3, 27, 7, 22])
	_check(context.power == 15, "initial power adds 2+3 once at actual run start")
	for index in range(20):
		Combat.grant_monster_clear_progress(context)
	_check(context.power == 28 and context.run_stats.get("monster_power_bonus") == 13, "normal combat growth cap is base5+3+5")
	_check(Combat.grant_monster_clear_progress(context) == 0, "normal growth never exceeds cap")
	var plain := _context()
	for index in range(10):
		Combat.grant_monster_clear_progress(plain)
	_check(plain.power == 15, "new profile without growth nodes keeps base cap5")
	var preview := _context([7])
	preview.run_stats["monster_power_bonus"] = 5
	_check(Combat.build_monster_summary(preview, Vector2i(1, 1), 0).get("reward_preview", {}).get("power_gain") == 1, "reward preview uses expanded growth cap")


func _test_physical_damage_and_survival() -> void:
	var context := _context([9, 20])
	var hit := Effects.apply_damage_packet(context, {"amount": 100, "damage_type": "physical", "source_id": "enemy"})
	_check(hit.get("ok") == true and context.hp == 15, "two physical percentages multiply and floor once")
	context.hp = 100
	hit = Effects.apply_damage_packet(context, {"amount": 5, "damage_type": "physical"})
	_check(context.hp == 97, "minimum physical block uses strongest tier2, not sum3")
	context.hp = 100
	Effects.apply_damage_packet(context, {"amount": 1, "damage_type": "physical"})
	_check(context.hp == 99, "positive physical damage remains at least1 before shield")
	for kind in ["mine", "dot", "hp_payment"]:
		context.hp = 100
		Effects.apply_damage_packet(context, {"amount": 20, "damage_type": kind})
		_check(context.hp == 80, "physical reduction excludes " + kind)
	var guarded := _context([10, 32])
	guarded.hp = 5
	guarded.vitals_counters["item_guard"] = 1
	var packet := {"amount": 100, "damage_type": "physical", "survivals": [{"kind": "item", "source_id": "item_guard", "counter_key": "item_guard", "hp": 40}]}
	hit = Effects.apply_damage_packet(guarded, packet)
	_check(guarded.hp == 15 and hit.get("facts", {}).get("survival_source") == "z2_talent_10", "talent wins before item and enhanced guard keeps15")
	_check(guarded.vitals_counters.get("z2_talent_10") == 0 and guarded.vitals_counters.item_guard == 1, "only the talent charge is consumed")
	hit = Effects.apply_damage_packet(guarded, packet)
	_check(guarded.hp == 40 and guarded.vitals_counters.item_guard == 0, "spent talent falls through to item on next lethal hit")
	var base_guard := _context([10])
	base_guard.hp = 5
	Effects.apply_damage_packet(base_guard, {"amount": 100, "damage_type": "dot"})
	_check(base_guard.hp == 1, "base guard retains1 for a lethal nonpayment hit")
	Effects.apply_damage_packet(base_guard, {"amount": 100, "damage_type": "mine"})
	_check(base_guard.hp == 0, "one talent survival per run")
	var capped := _context([10, 32])
	capped.max_hp = 8
	capped.hp = 5
	Effects.apply_damage_packet(capped, {"amount": 100, "damage_type": "mine"})
	_check(capped.hp == 8, "enhanced guard clamps to current maximum health")
	var payment := _context([10])
	payment.hp = 5
	hit = Effects.apply_damage_packet(payment, {"amount": 5, "damage_type": "hp_payment"})
	_check(not bool(hit.get("ok", true)) and payment.hp == 5 and payment.vitals_counters.get("z2_talent_10") == 1, "unaffordable life payment cannot consume survival")
	var no_base := _context([32])
	Effects.apply_damage_packet(no_base, {"amount": 100, "damage_type": "mine"})
	_check(no_base.hp == 0, "enhancement alone does not grant survival")
	var shielded := _context([10])
	shielded.shield = 100
	Effects.apply_damage_packet(shielded, {"amount": 100, "damage_type": "physical"})
	_check(shielded.hp == 100 and shielded.vitals_counters.get("z2_talent_10") == 1, "fully shielded damage cannot consume survival")


func _test_pressure_and_healing() -> void:
	var plain := _context()
	Effects.apply_pressure_packet(plain, {"amount": 25})
	_check(plain.pressure == 25, "Z2 without node36 does not receive free cap15")
	var capped := _context([36])
	Effects.apply_pressure_packet(capped, {"amount": 25})
	_check(capped.pressure == 15, "node36 caps one positive pressure packet at15")
	var immune := _context([5])
	Effects.apply_pressure_packet(immune, {"amount": 9})
	_check(immune.pressure == 9 and immune.vitals_counters.get("z2_talent_05") == 1, "pressure below10 leaves first exemption intact")
	Effects.apply_pressure_packet(immune, {"amount": 10})
	_check(immune.pressure == 9 and immune.vitals_counters.get("z2_talent_05") == 0, "first threshold10 packet is waived once")
	Effects.apply_pressure_packet(immune, {"amount": 25})
	_check(immune.pressure == 34, "following packet is neither waived nor capped without36")
	var full := _context([5, 36])
	full.pressure = 100
	Effects.apply_pressure_packet(full, {"amount": 30})
	_check(full.pressure == 100 and full.vitals_counters.get("z2_talent_05") == 1, "no effective pressure benefit consumes no exemption")
	full.pressure = 0
	Effects.apply_pressure_packet(full, {"amount": 30})
	_check(full.pressure == 0, "exemption composes with per-packet cap")
	var reduced := _context([5])
	Effects.apply_pressure_packet(reduced, {"amount": 10, "flat_reductions": [{"amount": 2}]})
	_check(reduced.pressure == 8 and reduced.vitals_counters.get("z2_talent_05") == 1, "sub-threshold adjusted pressure preserves charge")
	var healed := _context([35])
	healed.hp = 30
	Effects.apply_heal_packet(healed, {"amount": 10, "bonus_rate": 0.3, "reduction_multiplier": 0.5})
	_check(healed.hp == 37, "low-health20% adds to same base, then healing penalty, then floor")
	healed.hp = 31
	Effects.apply_heal_packet(healed, {"amount": 10})
	_check(healed.hp == 41, "above30% gets no low-health healing bonus")
	healed.hp = 30
	Effects.apply_heal_packet(healed, {"amount": 10})
	_check(healed.hp == 42, "exactly30% receives healing bonus")


func _simulation(context: RunContext) -> G41CombatSimulation:
	context.player_pos = Vector2i(1, 1)
	context.current_pos = context.player_pos
	context.current_room_type = &"Monster"
	var bridge := Bridge.new()
	bridge.context = context
	bridge.sync_room(Vector2(0.30, 0.50))
	var simulation: G41CombatSimulation = bridge.simulation
	simulation.set_arena_obstacles([])
	for enemy in simulation.enemies:
		enemy.pos = Vector2(0.42, 0.50)
		enemy.hp = 1000
		enemy.max_hp = 1000
		enemy.entry_grace_remaining = 100.0
		enemy.behavior_id = &""
	simulation.rng.state = 1
	return simulation


func _test_combat_movement_and_attack_speed() -> void:
	var plain := _simulation(_context())
	var fast := _simulation(_context([11, 21, 13, 17]))
	for simulation in [plain, fast]:
		simulation.set_player_input(Vector2.UP, Vector2.RIGHT)
		simulation.advance_ticks(20)
	_check(fast.player.pos.y < plain.player.pos.y, "movement nodes increase actual fixed-step displacement")
	_check(is_equal_approx(fast.player.velocity.length() / plain.player.velocity.length(), 1.05), "movement bonuses add to5%")
	for simulation in [plain, fast]:
		simulation.set_player_input(Vector2.ZERO, Vector2.RIGHT)
		simulation.queue_player_attack(Vector2.RIGHT)
		simulation.advance_ticks(1)
	_check(is_equal_approx(float(fast.player.attack_cooldown), 0.85 / 1.07), "attack nodes shorten real cooldown by combined7% speed")
	_check(float(fast.player.state_timer) < float(plain.player.state_timer), "attack windup follows speed")
	_check(is_equal_approx(float(fast.build_snapshot().get("attack_input", {}).get("cooldown_maximum_seconds", -1)), 0.85 / 1.07), "visible cooldown maximum matches actual cooldown")


func _attack_damage(simulation: G41CombatSimulation) -> int:
	var before := int(simulation.enemies[0].hp)
	simulation.queue_player_attack(Vector2.RIGHT)
	simulation.advance_ticks(20)
	return before - int(simulation.enemies[0].hp)


func _test_real_critical_hits_and_replay() -> void:
	var plain := _simulation(_context())
	_check(_attack_damage(plain) == 10, "ordinary direct attack deals unmodified power")
	var critical := _simulation(_context([25, 31, 34]))
	var before := critical.export_transaction_state()
	_check(critical.validate_transaction_state(before), "talent combat snapshot validates")
	_check(_attack_damage(critical) == 17, "actual direct hit uses crit chance and150%+20% damage")
	var after := critical.export_transaction_state()
	critical.import_transaction_state(before)
	_check(_attack_damage(critical) == 17 and critical.export_transaction_state() == after, "checkpoint replay preserves critical RNG and outcome")
	var disabled := _simulation(_context([31, 34, 37]))
	_check(_attack_damage(disabled) == 10, "crit upgrades without unlock cannot crit")
	var five_percent := _simulation(_context([25]))
	five_percent.rng.state = 4448 # Next roll is just below10%, above5%.
	_check(_attack_damage(five_percent) == 10, "base5% chance does not crit on10% roll")
	var fifteen_percent := _simulation(_context([25, 31]))
	fifteen_percent.rng.state = 4448
	_check(_attack_damage(fifteen_percent) == 15, "chance upgrade makes the same10% roll a real critical hit")
	var overflow_context := _context([25, 31, 34, 37])
	# An explicit boundary fixture exercises future combined chance above100%.
	for effect in overflow_context.active_talent_effects:
		if effect.effect_kind == &"critical_chance_percent":
			effect.effect_amount = 110
	var overflow := _simulation(overflow_context)
	overflow.player.power = 100
	_check(_attack_damage(overflow) == 185, "chance115% converts15 excess points to damage185%")
	var no_overflow := _context([25, 31, 34])
	for effect in no_overflow.active_talent_effects:
		if effect.effect_kind == &"critical_chance_percent":
			effect.effect_amount = 110
	var capped_chance := _simulation(no_overflow)
	capped_chance.player.power = 100
	_check(_attack_damage(capped_chance) == 170, "excess chance gives no free damage without overflow node")


func _test_scope_and_checkpoint() -> void:
	for scope in [[false, false], [true, true]]:
		var context := _context([3, 27, 9, 10, 35, 36], scope[0], scope[1])
		_check(context.power == 10, "legacy/tutorial cannot receive Z2 stat bonuses")
		context.hp = 30
		Effects.apply_heal_packet(context, {"amount": 10})
		_check(context.hp == 40, "legacy/tutorial cannot receive Z2 healing bonus")
		Effects.apply_pressure_packet(context, {"amount": 25})
		_check(context.pressure == (15 if not scope[0] else 25), "legacy cap is preserved; tutorial has no purchased cap")
	var context := _context([5, 10])
	var before := Snapshot.capture_context(context)
	Effects.apply_pressure_packet(context, {"amount": 20})
	Effects.apply_damage_packet(context, {"amount": 1000, "damage_type": "physical"})
	var after := Snapshot.capture_context(context)
	_check(context.hp == 1 and context.pressure == 0, "both finite consumers executed")
	_check(Snapshot.install_context(context, before).get("ok") == true, "existing snapshot restores talent state")
	Effects.apply_pressure_packet(context, {"amount": 20})
	Effects.apply_damage_packet(context, {"amount": 1000, "damage_type": "physical"})
	_check(Snapshot.capture_context(context) == after, "rollback/retry restores counters and facts exactly")
	var restored := Context.new()
	Snapshot.install_context(restored, after)
	Effects.apply_pressure_packet(restored, {"amount": 20})
	Effects.apply_damage_packet(restored, {"amount": 100, "damage_type": "physical"})
	_check(restored.hp == 0 and restored.pressure == 20, "restored run cannot regain spent charges")


func _test_tutorial_flag_and_snapshot_rejection() -> void:
	var tutorial := _context([3, 9, 10, 11, 13, 25, 35, 36], true, false, true)
	_check(tutorial.power == 10, "top-level tutorial_map also strips talent power")
	tutorial.hp = 30
	Effects.apply_heal_packet(tutorial, {"amount": 10})
	_check(tutorial.hp == 40, "top-level tutorial_map strips healing bonus")
	Effects.apply_pressure_packet(tutorial, {"amount": 25})
	_check(tutorial.pressure == 25, "top-level tutorial_map strips pressure cap")
	var simulation := _simulation(tutorial)
	_check(_attack_damage(simulation) == 10, "top-level tutorial_map strips critical and initial power in real combat")
	var valid := _simulation(_context([13, 25]))
	for malformed in [123, {"enabled": true, "effects": "bad"}, {"enabled": true, "effects": [{"effect_amount": -100}]}]:
		var state := valid.export_transaction_state()
		state.player["z2_talents"] = malformed
		_check(not valid.validate_transaction_state(state), "malformed combat talent snapshot is rejected before restore")


func _test_tutorial_profile_scrub() -> void:
	var profile := {"ruleset_id": "z2", "z2_progression_version": 1, "flag_unlocked": true,
		"max_hp": 135, "equipment_capacity": 103, "consumable_weight_reduce": 2}
	var config := {"mode": &"tutorial", "seed": 13, "width": 3, "height": 3,
		"max_hp": 135, "profile_fields": profile, "active_talent_effects": _effects([1, 3, 4]),
		"run_start_config": {"profile_fields": profile.duplicate(true), "max_hp": 135, "active_talent_effects": _effects([1, 3, 4])}}
	var before := config.duplicate(true)
	var context := Context.new()
	context.start_run(config)
	_check(context.max_hp == 100 and context.hp == 100, "teaching always starts at baseline100 health")
	_check(context.profile_fields == {"ruleset_id": "z2", "z2_progression_version": 1, "flag_unlocked": true,
		"tutorial_chest_learning": true, "content_eligibility": Z2ContentEligibility.freeze_profile({"profile_level": 0})},
		"teaching profile only keeps required capabilities and frozen Lv0 content")
	_check(context.active_talent_effects.is_empty(), "teaching capability uses flag field, not passive effect descriptors")
	_check(context.run_start_config.get("profile_fields") == context.profile_fields and context.run_start_config.get("active_talent_effects") == [] and context.run_start_config.get("max_hp") == 100, "frozen teaching config has the same sanitized profile")
	_check(config == before, "teaching scrub does not mutate caller's profile/config")


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
