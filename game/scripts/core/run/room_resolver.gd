extends RefCounted
class_name RoomResolver

# Room behavior goes through RoomResolver. UI reads emitted snapshots only.
# G6 replaces the G4 text "Event placeholder resolved" with EventService outcomes.

const RunStateMachineScript := preload("res://scripts/core/run/run_state_machine.gd")
const RunBalanceCatalogScript := preload("res://scripts/core/run/run_balance_catalog.gd")
const RunEffectApplierScript := preload("res://scripts/core/run/run_effect_applier.gd")
const RunTextCatalogScript := preload("res://scripts/core/run/run_text_catalog.gd")
const Z1EventRuntimeScript := preload("res://scripts/core/run/z1_event_runtime.gd")
const StateSnapshotScript := preload("res://scripts/core/run/run_state_snapshot.gd")
const Z2Events := preload("res://scripts/core/run/z2_event_runtime.gd")
const Z2Hooks := preload("res://scripts/core/run/z2_run_hooks.gd")


class EntryFailure extends RefCounted:
	var reason: String = ""

	func fail_run(next_reason: String) -> Dictionary:
		if reason.is_empty():
			reason = next_reason
		return {"ok": true, "deferred": true, "reason": reason}

var runtime_controller


func bind_runtime_controller(next_controller) -> void:
	runtime_controller = next_controller


func resolve_entry(_room_id: StringName, _context: Variant = null) -> Dictionary:
	return {}


func enter_room(context: RunContext) -> Dictionary:
	if context == null or context.truth_map == null or context.intel_map == null:
		return {"ok": false, "message": "No active run."}

	var pos := context.get_current_pos()
	var before := StateSnapshotScript.capture_context(context)
	var entry_failure := EntryFailure.new()
	var difficulty := StringName(context.run_start_config.get("difficulty", context.run_start_config.get("selected_difficulty", &"standard")))
	if context.mode == &"tutorial":
		difficulty = &"tutorial"
	var entry_protocol := context.protocol_level
	var z2 := Z2Hooks.applies_to(context)
	var first_visit := not context.visited_cells.has(context.cell_key(pos))
	if not z2:
		Z1EventRuntimeScript.record_entry(context, pos)
	if context.reveal_on_move:
		context.intel_map.reveal_cell(pos, context.truth_map)
	context.truth_map.mark_explored(pos)
	context.current_room_type = context.truth_map.get_room_type(pos)
	context.current_adjacent_mines = context.minefield_service.count_adjacent_mines(context.truth_map, pos)
	context.exit_id = context.truth_map.get_exit_id(pos)
	context.visited_cells[context.cell_key(pos)] = true
	context.event_state = {}
	context.enemy_state = {}
	context.blocked_reason = ""
	var encounter := RunRuleService.encounter_for_room(context, context.current_room_type, pos)
	context.encounter_type = StringName(encounter.get("encounter_type", &"none"))
	context.encounter_tags = encounter.get("encounter_tags", []).duplicate(true)
	_record_room_event(context, RunEventLog.EVENT_ROOM_ENTERED, {"position": pos, "room_type": context.current_room_type, "encounter_type": context.encounter_type, "first_visit": first_visit})

	var first_explore := not context.explored_cells.has(context.cell_key(pos))
	var exploration_cost := ProtocolService.exploration_cost(difficulty, entry_protocol, first_explore)
	if first_explore:
		var entry_effects: Array = [RunEffectApplierScript.effect_room_mark_explored(pos)]
		if exploration_cost > 0:
			entry_effects.append(RunEffectApplierScript.effect(RunEffectApplierScript.EFFECT_HP_DELTA, "room_exploration", {"amount": -exploration_cost, "damage_type": "exploration", "reason": "room_exploration"}))
		entry_effects.append(RunEffectApplierScript.effect_protocol_pressure_delta(RunBalanceCatalogScript.EXPLORE_PRESSURE_DELTA, "room_explore"))
		var applied := RunEffectApplierScript.apply_effects(context, entry_effects, entry_failure)
		if not bool(applied.ok):
			StateSnapshotScript.install_context(context, before)
			return applied
	if z2:
		var opening := Z2Hooks.opening_hook(context, {"kind": "room_entered", "fact_id": "room:" + context.cell_key(pos), "actual": true, "pos": pos, "first_visit": first_visit})
		if not opening.get("ok", false):
			StateSnapshotScript.install_context(context, before)
			return opening
		var event_id := ""
		if context.current_room_type == &"Event":
			var selected := EventService.select_z2_event(context, pos)
			if not selected.get("ok", false):
				StateSnapshotScript.install_context(context, before)
				return selected
			event_id = str(selected.event_type)
		var hooks := Z2Events.hooks_for(runtime_controller, context, pos, event_id)
		var continued := Z2Events.on_room_entered(context, pos, event_id, hooks)
		if not continued.get("ok", false):
			StateSnapshotScript.install_context(context, before)
			return continued
		if not event_id.is_empty() and Z2Events.canonical(event_id) != "cage":
			var state := EventService.get_event_state(context, pos)
			if not state.get("completed", false) and state.get("requires_prepare", true):
				var prepared := EventService.prepare_z2_event(context, pos, event_id, runtime_controller)
				if not prepared.get("ok", false):
					StateSnapshotScript.install_context(context, before)
					return prepared

	if context.current_room_type == &"Mine":
		var mine_result := _enter_mine(context, pos, entry_failure)
		if not bool(mine_result.ok):
			StateSnapshotScript.install_context(context, before)
			return mine_result
		var mine_entry: Dictionary = mine_result.get("room_entry_result", {})
		mine_entry["first_explore"] = first_explore
		mine_entry["exploration_cost"] = exploration_cost
		mine_result["room_entry_result"] = mine_entry
		_maybe_trigger_tutorial(context, pos)
		_finish_entry(context, entry_failure)
		mine_entry["fatal"] = context.failed or context.hp <= 0 or not entry_failure.reason.is_empty()
		return mine_result

	if context.current_room_type == &"Exit":
		_record_room_event(context, RunEventLog.EVENT_EXTRACTION_FOUND, {"position": pos, "exit_id": context.exit_id})
		context.last_message = RunTextCatalogScript.exit_ready()
	elif context.current_room_type == &"Monster" and not context.truth_map.is_cleared(pos):
		context.enemy_state = CombatState.build_enemy_state(context, pos, context.current_adjacent_mines)
		context.last_message = RunTextCatalogScript.monster_available()
	elif context.current_room_type == &"Event" and (z2 or not context.interacted_cells.has(context.cell_key(pos)) or EventService.get_event_type(context, pos) == &"z1_event_e25"):
		context.event_state = EventService.get_event_state(context, pos)
		context.last_message = RunTextCatalogScript.event_available(context.event_state.get("event_type", &"event"))
	elif context.current_room_type == &"Chest" and not context.searched_cells.has(context.cell_key(pos)):
		context.last_message = RunTextCatalogScript.chest_searchable()
	else:
		context.last_message = RunTextCatalogScript.entered_room(context.current_room_type, context.current_adjacent_mines)
	_maybe_trigger_tutorial(context, pos)
	_finish_entry(context, entry_failure)
	return {
		"ok": true,
		"message": context.last_message,
		"room_entry_result": {
			"room_type": context.current_room_type,
			"position": pos,
			"first_explore": first_explore,
			"exploration_cost": exploration_cost,
		},
	}


func search_current_room(context: RunContext, completed_timer: bool = false) -> Dictionary:
	if context == null or not context.run_active:
		return {"ok": false, "reason": "run_not_active", "blocked_reason": "run_not_active", "message": "Run is not active."}
	var pos := context.get_current_pos()
	var key := context.cell_key(pos)
	if context.searched_cells.has(key):
		context.last_message = "This room was already searched."
		return {"ok": true, "message": context.last_message}
	if not context.intel_map.is_revealed(pos):
		context.last_message = "Cannot search unrevealed room."
		return {"ok": false, "reason": "room_unrevealed", "blocked_reason": "room_unrevealed", "message": context.last_message}
	if not (context.current_room_type in [&"Normal", &"Chest"]):
		context.last_message = "This room cannot be searched."
		return {"ok": false, "reason": "room_not_searchable", "blocked_reason": "room_not_searchable", "message": context.last_message}
	if pos == context.truth_map.spawn_pos:
		context.last_message = "Spawn cannot be searched."
		return {"ok": false, "reason": "spawn_not_searchable", "blocked_reason": "spawn_not_searchable", "message": context.last_message}

	var is_chest := context.current_room_type == &"Chest"
	if Z2Hooks.applies_to(context) and not completed_timer:
		if runtime_controller == null:
			return {"ok": false, "reason": "search_runtime_unavailable"}
		return runtime_controller.begin_z2_search()
	var reward := RunInventory.add_search_reward(context, pos, context.current_adjacent_mines, is_chest)
	if not reward.get("ok", false):
		return reward
	context.searched_cells[key] = true
	context.last_reward = reward
	context.blocked_reason = String(reward.get("blocked_reason", ""))
	if is_chest:
		context.truth_map.mark_cleared(pos)
	context.intel_map.refresh_revealed_cell(pos, context.truth_map)
	_record_room_event(context, RunEventLog.EVENT_ROOM_SEARCHED, {"position": pos, "is_chest": is_chest, "reward": reward.duplicate(true)})
	if Z2Hooks.applies_to(context) and not is_chest:
		var receipt := {"room_type": "normal", "complete": true, "search_id": str(context.run_id) + ":search:" + key, "room_id": key}
		var linked := Z2Events.on_normal_search_completed(context, pos, receipt, Z2Events.hooks_for(runtime_controller, context, pos, "coil"))
		if not linked.get("ok", false):
			return linked
	var reward_items: Array = reward.get("items", [])
	var floor_items: Array = reward.get("ground_items", [])
	context.last_message = RunTextCatalogScript.search_complete(int(reward.get("gold", 0)), reward_items.size(), floor_items.size(), context.blocked_reason)
	return {"ok": true, "message": context.last_message}


func interact_current_room(context: RunContext) -> Dictionary:
	if context == null or not context.run_active:
		return {"ok": false, "reason": "run_not_active", "blocked_reason": "run_not_active", "message": "Run is not active."}
	var pos := context.get_current_pos()
	var key := context.cell_key(pos)
	match context.current_room_type:
		&"Chest":
			return search_current_room(context)
		&"Normal":
			return search_current_room(context)
		&"Event":
			var result := EventService.execute_default(context, pos, runtime_controller)
			return _finish_event_result(context, pos, result)
		&"Monster":
			context.last_message = "Monster requires fight command."
		&"Exit":
			context.last_message = "Exit ready. Request extraction."
		&"Mine":
			context.last_message = "Mine room has no safe interaction."
		_:
			context.last_message = "Nothing to interact with here."
	return {"ok": true, "message": context.last_message}


func select_event_option(context: RunContext, option_id: StringName, payload: Dictionary = {}) -> Dictionary:
	if context == null or not context.run_active:
		return {"ok": false, "reason": "run_not_active", "blocked_reason": "run_not_active", "message": "Run is not active."}
	var pos := context.get_current_pos()
	if context.current_room_type != &"Event":
		context.last_message = "No event option is available here."
		return {"ok": false, "reason": "event_option_unavailable", "blocked_reason": "event_option_unavailable", "message": context.last_message}
	var event_type := EventService.get_event_type(context, pos)
	var result := EventService.execute_option(context, pos, option_id, runtime_controller, payload)
	_record_room_event(context, RunEventLog.EVENT_EVENT_OPTION_SELECTED, {"position": pos, "event_type": event_type, "option_id": option_id, "result": result.duplicate(true)})
	return _finish_event_result(context, pos, result)


func _finish_event_result(context: RunContext, pos: Vector2i, result: Dictionary) -> Dictionary:
	if bool(result.get("completed", false)):
		context.truth_map.mark_cleared(pos)
		context.intel_map.refresh_revealed_cell(pos, context.truth_map)
	if bool(result.get("ok", false)) and result.has("shortcut_target"):
		context.player_pos = result["shortcut_target"]
		context.current_pos = context.player_pos
		RunInventory.record_move(context)
		var entered := enter_room(context)
		if not bool(entered.get("ok", false)):
			# Keep the preparation error authoritative so the outer action also
			# rolls back the shortcut fee, completion, movement and entry costs.
			return entered
		result["room_entry_result"] = entered.get("room_entry_result", {})
		result["position"] = context.get_current_pos()
	return result


func fight_current_enemy(context: RunContext) -> Dictionary:
	if context == null or not context.run_active:
		return {"ok": false, "reason": "run_not_active", "blocked_reason": "run_not_active", "message": "Run is not active."}
	var pos := context.get_current_pos()
	if context.current_room_type != &"Monster":
		context.last_message = "No monster to fight here."
		return {"ok": false, "reason": "combat_unavailable", "blocked_reason": "combat_unavailable", "message": context.last_message}
	if context.truth_map.is_cleared(pos):
		context.last_message = "Monster already cleared."
		return {"ok": true, "message": context.last_message}
	var result := CombatState.fight_enemy(context, pos, context.current_adjacent_mines, runtime_controller)
	if bool(result.get("cleared", false)):
		context.truth_map.mark_cleared(pos)
		context.intel_map.refresh_revealed_cell(pos, context.truth_map)
	context.last_reward = result
	context.blocked_reason = String(result.get("blocked_reason", ""))
	context.enemy_state = result.duplicate(true)
	context.last_message = RunTextCatalogScript.monster_cleared(int(result.get("damage", 0)), int(result.get("reward_gold", 0)))
	_record_room_event(context, RunEventLog.EVENT_COMBAT_RESOLVED, {"position": pos, "result": result.duplicate(true)})
	return result


func apply_runtime_combat_damage(context: RunContext, payload: Dictionary) -> Dictionary:
	if context == null or not context.run_active:
		return {"ok": false, "reason": "run_not_active", "blocked_reason": "run_not_active"}
	var cage_active := context.current_room_type == &"Event" and bool(EventService.cage_state(context, context.get_current_pos()).get("active", false))
	if (context.current_room_type != &"Monster" and not cage_active) or context.truth_map == null or context.truth_map.is_cleared(context.get_current_pos()):
		return {"ok": false, "reason": "runtime_combat_unavailable", "blocked_reason": "runtime_combat_unavailable"}
	var damage := maxi(0, int(payload.get("damage", 0)))
	var pressure_delta := maxi(0, int(payload.get("pressure_delta", 0)))
	if damage <= 0 and pressure_delta <= 0:
		return {"ok": true, "status": &"runtime_combat_damage_ignored", "damage": 0, "hp": context.hp}
	var pressure_before := context.pressure
	var effects: Array = []
	if pressure_delta > 0:
		effects.append(RunEffectApplierScript.effect_protocol_pressure_delta(pressure_delta, "combat"))
	if damage > 0:
		effects.append(RunEffectApplierScript.effect_hp_delta(-damage, "runtime_combat_%s" % String(payload.get("damage_kind", &"damage"))))
	var deferred_failure := EntryFailure.new()
	var applied := RunEffectApplierScript.apply_effects(context, effects, deferred_failure)
	if not bool(applied.ok):
		return applied
	var actual_damage := 0
	for fact in applied.get("facts", []):
		actual_damage += int(fact.get("actual_hp_loss", 0))
	context.run_stats["combat_damage"] = int(context.run_stats.get("combat_damage", 0)) + actual_damage
	context.enemy_state["runtime_combat_tick"] = int(payload.get("combat_tick", 0))
	context.last_message = "Combat hit: -%d HP." % actual_damage
	_record_room_event(context, &"runtime_combat_damage", {
		"position": context.get_current_pos(),
		"damage": actual_damage,
		"nominal_damage": damage,
		"damage_kind": payload.get("damage_kind", &"damage"),
		"source_id": payload.get("source_id", ""),
		"combat_tick": payload.get("combat_tick", 0),
		"pressure_delta": context.pressure - pressure_before,
	})
	_finish_entry(context, deferred_failure)
	return {
		"ok": bool(applied.get("ok", false)),
		"status": &"runtime_combat_damage_applied",
		"damage": actual_damage,
		"hp": context.hp,
		"failed": context.failed,
		"pressure_delta": context.pressure - pressure_before,
		"effect_results": applied.get("effect_results", []),
	}


func resolve_runtime_combat(context: RunContext, payload: Dictionary) -> Dictionary:
	if context == null or not context.run_active:
		return {"ok": false, "reason": "run_not_active", "blocked_reason": "run_not_active"}
	var pos := context.get_current_pos()
	if context.current_room_type == &"Event" and not EventService.cage_state(context, pos).is_empty():
		return _resolve_cage_combat(context, pos, payload)
	if context.current_room_type != &"Monster" or context.truth_map == null:
		return {"ok": false, "reason": "runtime_combat_unavailable", "blocked_reason": "runtime_combat_unavailable"}
	if context.truth_map.is_cleared(pos):
		return {"ok": true, "status": &"runtime_combat_already_resolved", "reward_committed": false}
	var combat_snapshot: Dictionary = payload.get("combat_snapshot", {})
	if not bool(combat_snapshot.get("cleared", false)):
		return {"ok": false, "reason": "combat_not_cleared", "blocked_reason": "combat_not_cleared"}
	var encounter_profile: Dictionary = combat_snapshot.get("encounter_profile", {})
	var enemy_power := int(encounter_profile.get(
		"enemy_power",
		CombatState.build_enemy_state(context, pos, context.current_adjacent_mines).get("enemy_power", 0)
	))
	var reward_gold := CombatState.reward_gold_for_enemy_power(enemy_power)
	var reward_result := RunRuleService.apply_combat_reward(context, pos, reward_gold)
	if not reward_result.get("ok", false):
		return reward_result
	RunEffectApplierScript.apply_effects(context, [RunEffectApplierScript.effect(RunEffectApplierScript.EFFECT_MONSTER_MARK_DEFEATED, "runtime_combat_cleared", {"position": pos}, pos)], runtime_controller)
	var power_gain := CombatState.grant_monster_clear_progress(context)
	if Z2Hooks.applies_to(context):
		var supplied := Z2SupplyRuntime.on_event(context, context.asset_ledger.get_items_by_location(&"equipped"), {"kind": "ordinary_clear", "room_id": context.cell_key(pos), "actual": true})
		if not supplied.get("ok", false):
			return supplied
		var opened := Z2Hooks.opening_hook(context, {"kind": "ordinary_combat_cleared", "fact_id": "combat:" + context.cell_key(pos), "combat_id": str(context.run_id) + ":combat:" + context.cell_key(pos), "pos": pos, "actual": true, "automatic": false})
		if not opened.get("ok", false):
			return opened
	context.last_reward = reward_result.duplicate(true)
	context.blocked_reason = String(reward_result.get("blocked_reason", ""))
	context.enemy_state = encounter_profile.duplicate(true)
	context.enemy_state["combat_snapshot"] = combat_snapshot.duplicate(true)
	context.enemy_state["reward_committed"] = true
	context.enemy_state["combat_seed"] = int(payload.get("combat_seed", 0))
	context.last_message = RunTextCatalogScript.monster_cleared(0, reward_gold)
	var monster_types: Array[String] = []
	for raw_enemy in combat_snapshot.get("enemies", []):
		var enemy: Dictionary = raw_enemy if raw_enemy is Dictionary else {}
		var monster_type := str(enemy.get("monster_type", ""))
		if monster_type != "" and not monster_types.has(monster_type):
			monster_types.append(monster_type)
	_record_room_event(context, RunEventLog.EVENT_COMBAT_RESOLVED, {
		"position": pos,
		"runtime": true,
		"combat_tick": payload.get("combat_tick", 0),
		"combat_seed": payload.get("combat_seed", 0),
		"monster_types": monster_types,
		"reward": reward_result.duplicate(true),
	})
	return {
		"ok": true,
		"status": &"runtime_combat_resolved",
		"reward_committed": true,
		"reward_gold": reward_gold,
		"enemy_power": enemy_power,
		"power_gain": power_gain,
		"reward": reward_result,
		"ground_items": reward_result.get("ground_items", []),
	}


func _resolve_cage_combat(context: RunContext, pos: Vector2i, payload: Dictionary) -> Dictionary:
	if context.truth_map.is_cleared(pos):
		return {"ok": true, "status": &"runtime_combat_already_resolved", "reward_committed": false}
	var combat_snapshot: Dictionary = payload.get("combat_snapshot", {})
	if not bool(combat_snapshot.get("cleared", false)):
		return {"ok": false, "reason": "combat_not_cleared", "blocked_reason": "combat_not_cleared"}
	var cage_before := EventService.cage_state(context, pos)
	var result: Dictionary
	if Z2Hooks.applies_to(context):
		var receipt := {"encounter_id": str(cage_before.get("combat_request", {}).get("encounter_id", "")), "room_id": context.cell_key(pos), "actual_combat": true, "outcome": "win"}
		result = Z2Events.on_cage_combat_completed(context, pos, receipt, Z2Events.hooks_for(runtime_controller, context, pos, "cage"))
	else:
		result = EventService.resolve_cage(context, pos, true)
	if not bool(result.get("ok", false)):
		return result
	context.truth_map.mark_cleared(pos)
	context.intel_map.refresh_revealed_cell(pos, context.truth_map)
	context.enemy_state["combat_snapshot"] = combat_snapshot.duplicate(true)
	context.enemy_state["reward_committed"] = true
	var cage := EventService.cage_state(context, pos)
	_record_room_event(context, RunEventLog.EVENT_COMBAT_RESOLVED, {
		"position": pos, "runtime": true, "cage": true, "won": true,
		"stage_authority": "z2_event_runtime" if Z2Hooks.applies_to(context) else "legacy",
		"combat_tick": payload.get("combat_tick", 0), "combat_seed": payload.get("combat_seed", 0),
		"monster_types": [String(cage.get("monster_type", "slime"))], "reward": result.duplicate(true),
	})
	return {"ok": true, "status": &"cage_combat_resolved", "reward_committed": true, "power_gain": int(result.get("power_delta", 0)), "reward": result, "ground_items": []}


func resolve_runtime_combat_defeat(context: RunContext, payload: Dictionary) -> Dictionary:
	if context == null:
		return {"ok": false, "reason": "run_not_active"}
	if context.failed:
		return {"ok": true, "status": &"runtime_combat_defeat_already_resolved"}
	if Z2Hooks.applies_to(context) and context.current_room_type == &"Event":
		var cage := EventService.cage_state(context, context.get_current_pos())
		if cage.get("active", false):
			var receipt := {"encounter_id": str(cage.get("combat_request", {}).get("encounter_id", "")), "room_id": context.cell_key(context.get_current_pos()), "actual_combat": true, "outcome": "loss"}
			var resolved := Z2Events.on_cage_combat_completed(context, context.get_current_pos(), receipt, Z2Events.hooks_for(runtime_controller, context, context.get_current_pos(), "cage"))
			if not resolved.get("ok", false):
				return resolved
	if context.hp > 0:
		var applied := RunEffectApplierScript.apply_damage_packet(context, {"amount": context.hp, "damage_type": "dot", "survivals": [], "source_id": "runtime_combat_defeat"})
		if not bool(applied.ok):
			return applied
	var result := _fail_run(context, "runtime_combat_defeat")
	result["combat_tick"] = int(payload.get("combat_tick", 0))
	return result


func flee_runtime_combat(context: RunContext, _payload: Dictionary = {}) -> Dictionary:
	if context == null or not context.run_active:
		return {"ok": false, "reason": "run_not_active", "blocked_reason": "run_not_active"}
	var pos := context.get_current_pos()
	if context.current_room_type == &"Event" and bool(EventService.cage_state(context, pos).get("active", false)):
		return {"ok": false, "reason": "cage_locked", "blocked_reason": "cage_locked", "message": "围笼战斗结束前无法离开。"}
	if context.current_room_type != &"Monster" or context.truth_map == null or context.truth_map.is_cleared(pos):
		return {"ok": false, "reason": "runtime_combat_unavailable", "blocked_reason": "runtime_combat_unavailable"}
	var result := RunRuleService.apply_combat_flee(context, pos)
	context.last_reward = result.duplicate(true)
	context.blocked_reason = String(result.get("blocked_reason", ""))
	context.enemy_state = {"fled": true, "room_uncleared": true}
	context.last_message = "Fled combat: lost %d pending black coin; %d item(s) left on this room floor." % [
		int(result.get("black_coin_loss", 0)),
		int(result.get("items_moved_to_room_floor", 0)),
	]
	_record_room_event(context, &"runtime_combat_fled", {
		"position": pos,
		"black_coin_loss": result.get("black_coin_loss", 0),
		"dropped_instance_ids": result.get("dropped_instance_ids", []),
	})
	return result


func can_extract(context: RunContext) -> bool:
	if context == null or context.truth_map == null:
		return false
	return context.current_room_type == &"Exit" and context.truth_map.get_exit_id(context.get_current_pos()) != &""


func _enter_mine(context: RunContext, pos: Vector2i, entry_failure: EntryFailure) -> Dictionary:
	var key := context.cell_key(pos)
	var remote_mines: Dictionary = context.z1_event_flags.get("remote_mines", {})
	var first_trigger := not context.entered_cells.has(key) and not bool(remote_mines.get(key, false))
	var hp_before := context.hp
	var pressure_before := context.pressure
	if first_trigger:
		context.entered_cells[key] = true
		RunEffectApplierScript.apply_effects(context, [RunEffectApplierScript.effect_mine_mark_triggered(pos)], entry_failure)
		var mine_hit := CombatState.apply_mine_hit(context, entry_failure)
		if not bool(mine_hit.ok):
			return mine_hit
		var damage := int(mine_hit.facts.actual_hp_loss)
		var opening := Z2Hooks.opening_hook(context, {"kind": "mine_hit", "fact_id": "mine:" + key, "actual": true, "pos": pos})
		if not opening.get("ok", false):
			return opening
		var mine_pressure := 0 if opening.get("facts", {}).get("replace_mine_pressure", false) else RunBalanceCatalogScript.MINE_PRESSURE_DELTA
		var applied := RunEffectApplierScript.apply_effects(context, [RunEffectApplierScript.effect_protocol_pressure_delta(mine_pressure, "mine_triggered")], entry_failure)
		if not bool(applied.ok):
			return applied
		context.run_stats["mine_hits"] = int(context.run_stats.get("mine_hits", 0)) + 1
		_record_room_event(context, &"mine_triggered", {"position": pos, "actual_hp_loss": damage})
		context.intel_map.refresh_revealed_cell(pos, context.truth_map)
		context.last_message = RunTextCatalogScript.mine_triggered(damage, context.pressure - pressure_before)
		if context.mine_hits_are_fatal and not context.failed:
			entry_failure.fail_run("fatal_mine")
	else:
		context.last_message = RunTextCatalogScript.mine_reentered()
	return {
		"ok": true,
		"message": context.last_message,
		"room_entry_result": {
			"room_type": &"Mine",
			"position": pos,
			"cause": &"mine_triggered" if first_trigger else &"mine_inactive",
			"first_trigger": first_trigger,
			"hp_delta": context.hp - hp_before,
			"pressure_delta": context.pressure - pressure_before,
			"fatal": context.failed,
		},
	}


func _finish_entry(context: RunContext, deferred_failure: EntryFailure) -> void:
	if context.run_active and not context.failed and (context.hp <= 0 or not deferred_failure.reason.is_empty()):
		_fail_run(context, deferred_failure.reason if not deferred_failure.reason.is_empty() else "hp_depleted")


func _maybe_trigger_tutorial(context: RunContext, pos: Vector2i) -> void:
	# The tutorial panel already presents the lesson. Keep the ordinary room
	# result in the feedback band instead of leaking the internal trigger id.
	TutorialService.trigger_for(context, pos)


func _record_room_event(context: RunContext, event_type: StringName, payload: Dictionary) -> void:
	if context == null:
		return
	var command := context.active_command
	context.record_event(event_type, String(command.get("command_id", "")), StringName(command.get("actor_id", &"player")), String(command.get("source", "room_resolver")), payload)


func _fail_run(context: RunContext, reason: String) -> Dictionary:
	if runtime_controller != null and runtime_controller.has_method("fail_run"):
		return runtime_controller.fail_run(reason)
	var fallback_state_machine = RunStateMachineScript.new()
	return fallback_state_machine.fail_run(context, reason)
