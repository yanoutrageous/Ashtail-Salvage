extends SceneTree

const Snapshot := preload("res://scripts/core/run/run_state_snapshot.gd")
const Eligibility := preload("res://scripts/core/content/z2_content_eligibility.gd")
const Items := preload("res://scripts/core/content/z2_item_catalog.gd")
const ORIGIN := Vector2i(1, 2)
const TARGET := Vector2i(2, 2)
const ENTRY_ERROR := "injected_room_prepare_failure"

# Isolated failure injection, never a change to catalog eligibility. Run the real
# entry first so exploration, vitals, room binding and facts have actually changed,
# then simulate a late preparation consumer which has partially delivered assets.
class RejectingResolver extends RoomResolver:
	var reject_target := Vector2i(-1, -1)
	var attempted: Dictionary = {}
	func enter_room(candidate: RunContext) -> Dictionary:
		var result := super.enter_room(candidate)
		if not result.get("ok", false) or candidate.get_current_pos() != reject_target:
			return result
		candidate.asset_ledger.add_currency(&"black_coin", 17, "entry_failure_fixture")
		candidate.asset_ledger.create_item_instance(Items.definition("col_01"), &"room_floor", candidate.get_current_pos())
		candidate.asset_ledger.sync_compat_fields(candidate)
		candidate.last_reward = {"fixture_partial_reward": true}
		attempted = Snapshot.capture_context(candidate)
		return {"ok": false, "status": &"room_prepare_rejected", "reason": ENTRY_ERROR,
			"blocked_reason": ENTRY_ERROR, "message": "Fixture room preparation rejected.",
			"definition_id": "fixture.invalid_room_definition"}

class ObservedRuntime extends RunRuntimeController:
	var transition_syncs := 0
	var invalid_shop_pool := false
	func sync_room_transition(direction: Vector2i, preferred_entry: Vector2 = Vector2(-1, -1)) -> void:
		transition_syncs += 1
		super.sync_room_transition(direction, preferred_entry)
	func z2_event_hooks(candidate: RunContext, pos: Vector2i, event_id: String) -> Dictionary:
		var hooks := super.z2_event_hooks(candidate, pos, event_id)
		if invalid_shop_pool and event_id == "shop":
			hooks["economy_catalog"] = {"shop_pool": "fixture.invalid_pool"}
		return hooks

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for command in [&"move_by", &"attempt_room_transition", &"teleport_to_explored", &"debug_teleport_to"]:
		_test_command_entry_failure(command)
	_test_flag_confirmation_failure()
	_test_real_prepare_failure()
	for command in [&"select_event_option", &"interact_current_room", &"interact"]:
		_test_legacy_shortcut_failure(command)
	_test_z2_shortcut_failure()
	_test_flee_then_entry_failure(true)
	_test_flee_then_entry_failure(false)
	_test_recovered_entry_save_failure()
	for failure in failures:
		print("Z2_ROOM_ENTRY_ATOMICITY_FAIL " + failure)
	print("Z2_ROOM_ENTRY_ATOMICITY=%s checks=%d" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)


func _runtime(z2: bool = true) -> ObservedRuntime:
	var runtime := ObservedRuntime.new()
	var profile := {"ruleset_id": "z2", "z2_progression_version": 1, "flag_unlocked": true,
		"content_eligibility": Eligibility.freeze_profile({"profile_level": 50})} if z2 else {}
	runtime.context.start_run({"id": "room_entry_atomicity_fixture", "seed": 348,
		"width": 5, "height": 5, "max_hp": 100, "power": 20, "protocol_level": 1,
		"profile_fields": profile,
		"run_start_config": {"profile_fields": profile.duplicate(true), "map_config_id": "classic_13x13_normal", "difficulty": &"standard"},
		"manual_map": {"spawn": ORIGIN, "exits": [{"pos": Vector2i(4, 4), "exit_id": "fixture_exit"}]}})
	var resolver := RejectingResolver.new()
	runtime.command_bus.room_resolver = resolver
	resolver.bind_runtime_controller(runtime)
	_check(resolver.enter_room(runtime.context).get("ok", false), "fixture source entry succeeds")
	runtime.context.pressure = 80
	runtime.context.asset_ledger.add_currency(&"black_coin", 100, "fixture_initial_balance")
	runtime.context.asset_ledger.create_item_instance(Items.definition("col_01"), &"inventory")
	runtime.context.asset_ledger.sync_compat_fields(runtime.context)
	runtime.update_player_location(Vector2(0.83, 0.47))
	runtime.in_run_runtime.sync_room(Vector2(0.83, 0.47))
	return runtime


func _observe(runtime: ObservedRuntime) -> Dictionary:
	var observed := {"writes": [], "states": [], "results": [], "requests": [], "fail_writes": false}
	runtime.checkpoint_writer = func(state: Dictionary) -> Dictionary:
		observed.writes.append(state.duplicate(true))
		return {"ok": not bool(observed.fail_writes), "reason": "fixture_checkpoint_failure" if observed.fail_writes else ""}
	runtime.command_bus.command_requested.connect(func(_command: StringName, request: Dictionary) -> void: observed.requests.append(request.duplicate(true)))
	runtime.command_bus.state_changed.connect(func(state: Dictionary) -> void: observed.states.append(state.duplicate(true)))
	runtime.command_bus.result_available.connect(func(result: Dictionary) -> void: observed.results.append(result.duplicate(true)))
	return observed


func _request(command: StringName) -> Dictionary:
	match command:
		&"move_by": return {"delta": Vector2i.RIGHT}
		&"attempt_room_transition": return {"direction": Vector2i.RIGHT, "entry_position": Vector2(0.16, 0.47)}
		_: return {"pos": TARGET, "enter_room": true, "source": "room_entry_fixture"}


func _assert_rejected(runtime: ObservedRuntime, before: Dictionary, observed: Dictionary, result: Dictionary, reason: String, label: String) -> void:
	_check(not bool(result.get("ok", true)) and not bool(result.get("accepted", true)), label + ": outer command rejects entry failure")
	_check(str(result.get("reason", "")) == reason and str(result.get("action_result", {}).get("reason", "")) == reason, label + ": original business rejection reaches caller")
	_check(runtime.capture_authoritative_state() == before, label + ": full authority, coordinates/type, bridge, vitals, assets, RNG, logs and receipts roll back")
	_check(runtime.context.current_pos == ORIGIN and runtime.context.player_pos == ORIGIN and runtime.context.current_room_type == runtime.context.truth_map.get_room_type(ORIGIN), label + ": no new-coordinate/old-room hybrid")
	_check(observed.writes.is_empty() and observed.states.is_empty() and observed.results.is_empty(), label + ": no checkpoint or successful state/result publication")
	_check(observed.requests.size() == 1, label + ": rejected input intent may be published once")
	_check(runtime.transition_syncs == 0, label + ": rejected entry never synchronizes a successful room transition")
	_check(runtime.persistence_error.is_empty(), label + ": business failure is not a storage failure barrier")
	_check(result.get("produced_events", []).is_empty() and result.get("produced_transactions", []).is_empty(), label + ": no uncommitted exploration/reward facts escape")


func _test_command_entry_failure(command: StringName) -> void:
	var runtime := _runtime()
	var resolver := runtime.command_bus.room_resolver as RejectingResolver
	resolver.reject_target = TARGET
	if command == &"teleport_to_explored":
		runtime.context.intel_map.reveal_cell(TARGET, runtime.context.truth_map)
	var observed := _observe(runtime)
	var before := runtime.capture_authoritative_state()
	var context_binding = runtime.context
	var ledger_binding = runtime.context.asset_ledger
	var truth_binding = runtime.context.truth_map
	var intel_binding = runtime.context.intel_map
	var request := _request(command)
	request["action_id"] = "entry_failure_" + str(command)
	var result: Dictionary = runtime.command_bus.dispatch(command, request)
	_assert_rejected(runtime, before, observed, result, ENTRY_ERROR, str(command))
	_check(not resolver.attempted.is_empty() and resolver.attempted.data.current_pos == TARGET and resolver.attempted.data.hp < before.context.data.hp, str(command) + ": real first-entry cost occurred before injected rejection")
	_check(not resolver.attempted.is_empty() and resolver.attempted.components.asset_ledger.item_instances.size() > before.context.components.asset_ledger.item_instances.size(), str(command) + ": partial reward delivered before rejection is included in rollback")
	_check(runtime.context == context_binding and runtime.context.asset_ledger == ledger_binding and runtime.context.truth_map == truth_binding and runtime.context.intel_map == intel_binding, str(command) + ": restore preserves authoritative component bindings")
	_check(result.get("action_result", {}).get("definition_id", "") == "fixture.invalid_room_definition", str(command) + ": detailed preparation error is not replaced with moved/teleported")
	_check(result.get("action_result", {}).get("message", "") == "Fixture room preparation rejected.", str(command) + ": failure message is not overwritten by candidate entry/teleport success text")
	resolver.reject_target = Vector2i(-1, -1)
	var retried: Dictionary = runtime.command_bus.dispatch(command, request)
	_check(retried.get("ok", false) and runtime.context.get_current_pos() == TARGET, str(command) + ": same action can continue after dependency recovers")
	_check(observed.writes.size() == 1 and observed.states.size() == 1 and observed.results.is_empty(), str(command) + ": recovered action commits and publishes once")
	var committed := runtime.capture_authoritative_state()
	var duplicate: Dictionary = runtime.command_bus.dispatch(command, request)
	_check(duplicate.get("ok", false) and duplicate.get("duplicate", false) and runtime.capture_authoritative_state() == committed and observed.writes.size() == 1 and observed.states.size() == 1, str(command) + ": existing receipt authority prevents duplicate entry/cost/save")
	_release(runtime)


func _test_flag_confirmation_failure() -> void:
	var runtime := _runtime()
	var resolver := runtime.command_bus.room_resolver as RejectingResolver
	runtime.context.intel_map.toggle_flag(TARGET)
	var prompted: Dictionary = runtime.command_bus.dispatch(&"move_by", {"delta": Vector2i.RIGHT})
	_check(prompted.get("ok", false) and runtime.context.tutorial_popup.get("id", &"") == &"flag_entry_confirm" and runtime.context.current_pos == ORIGIN, "flag entry first requests confirmation without moving")
	resolver.reject_target = TARGET
	var observed := _observe(runtime)
	var before := runtime.capture_authoritative_state()
	var request := {"action_id": "flag_entry_failure"}
	var result: Dictionary = runtime.command_bus.dispatch(&"confirm_tutorial_popup", request)
	_assert_rejected(runtime, before, observed, result, ENTRY_ERROR, "flag confirmation indirect move")
	_check(runtime.context.intel_map.is_flagged(TARGET) and runtime.context.tutorial_popup == before.context.data.tutorial_popup, "failed confirmed move restores pending confirmation and keeps original flag")
	resolver.reject_target = Vector2i(-1, -1)
	var accepted: Dictionary = runtime.command_bus.dispatch(&"confirm_tutorial_popup", request)
	_check(accepted.get("ok", false) and runtime.context.current_pos == TARGET and runtime.context.intel_map.is_flagged(TARGET) and runtime.context.tutorial_popup.is_empty(), "confirmed flag entry can retry without consuming its flag")
	_release(runtime)


func _test_real_prepare_failure() -> void:
	var runtime := _runtime()
	runtime.context.truth_map.set_room_type(TARGET, &"Event")
	runtime.context.z1_event_rooms[runtime.context.cell_key(TARGET)] = {"event_type": &"shop"}
	runtime.invalid_shop_pool = true
	var observed := _observe(runtime)
	var before := runtime.capture_authoritative_state()
	var result: Dictionary = runtime.command_bus.dispatch(&"move_by", {"delta": Vector2i.RIGHT, "action_id": "real_prepare_failure"})
	_assert_rejected(runtime, before, observed, result, "invalid_pool", "real EventService prepare failure")
	runtime.invalid_shop_pool = false
	var recovered: Dictionary = runtime.command_bus.dispatch(&"move_by", {"delta": Vector2i.RIGHT, "action_id": "real_prepare_failure"})
	_check(recovered.get("ok", false) and runtime.context.current_pos == TARGET and runtime.context.current_room_type == &"Event", "unchanged lawful shop catalog still admits normal entry after bad fixture dependency removed")
	_check(EventService.get_event_state(runtime.context, TARGET).get("offers", []).size() == 3 and observed.writes.size() == 1, "normal shop preparation and single durable commit remain available")
	_release(runtime)


func _set_source_event(runtime: ObservedRuntime, event_id: StringName) -> void:
	runtime.context.truth_map.set_room_type(ORIGIN, &"Event")
	runtime.context.z1_event_rooms[runtime.context.cell_key(ORIGIN)] = {"event_type": event_id}
	_check(runtime.command_bus.room_resolver.enter_room(runtime.context).get("ok", false), "shortcut fixture source event entry succeeds")


func _test_legacy_shortcut_failure(command: StringName) -> void:
	var runtime := _runtime(false)
	_set_source_event(runtime, &"z1_event_e16")
	var options: Array = EventService.get_event_state(runtime.context, ORIGIN).get("options", [])
	if options.is_empty():
		_check(false, "legacy shortcut exposes its actual travel target")
		_release(runtime)
		return
	var target: Vector2i = options[0].get("payload", {}).get("target_pos", Vector2i(-1, -1))
	var resolver := runtime.command_bus.room_resolver as RejectingResolver
	resolver.reject_target = target
	var observed := _observe(runtime)
	var before := runtime.capture_authoritative_state()
	var request := {"option_id": &"travel", "target_pos": target, "action_id": "legacy_shortcut_failure_" + str(command)}
	var result: Dictionary = runtime.command_bus.dispatch(command, request)
	var label := "legacy shortcut " + str(command)
	_assert_rejected(runtime, before, observed, result, ENTRY_ERROR, label)
	_check(result.get("action_result", {}).get("definition_id", "") == "fixture.invalid_room_definition", label + ": _finish_event_result preserves detailed target entry error")
	_check(result.get("action_result", {}).get("message", "") == "Fixture room preparation rejected.", label + ": failed entry does not show source shortcut's provisional success message")
	_check(not resolver.attempted.is_empty() and resolver.attempted.components.truth_map.rooms[runtime.context.cell_key(ORIGIN)].cleared, label + ": source completion and fee were candidates before rejected target entry")
	resolver.reject_target = Vector2i(-1, -1)
	var accepted: Dictionary = runtime.command_bus.dispatch(command, request)
	_check(accepted.get("ok", false) and runtime.context.get_current_pos() == target and runtime.context.player_pos == target, label + ": recovered shortcut reaches actual target")
	_check(runtime.context.asset_ledger.get_currency(&"black_coin") == 94 and runtime.context.truth_map.is_cleared(ORIGIN), label + ": original six-coin fee/completion commits exactly once")
	_check(observed.writes.size() == 1 and observed.states.size() == 1 and runtime.in_run_runtime.current_room_key == runtime.context.cell_key(target), label + ": target binding is in original durable candidate")
	var committed := runtime.capture_authoritative_state()
	var duplicate: Dictionary = runtime.command_bus.dispatch(command, request)
	_check(duplicate.get("duplicate", false) and runtime.capture_authoritative_state() == committed and observed.writes.size() == 1, label + ": successful receipt replay does not repay/reenter")
	_release(runtime)


func _test_z2_shortcut_failure() -> void:
	var runtime := _runtime()
	_set_source_event(runtime, &"shortcut")
	var state := EventService.get_event_state(runtime.context, ORIGIN)
	var targets: Array = state.get("targets", [])
	if targets.is_empty():
		_check(false, "Z2 shortcut prepares its real eligible targets")
		_release(runtime)
		return
	var target: Vector2i = targets[0]
	var preview: Dictionary = runtime.command_bus.dispatch(&"select_event_option", {"option_id": &"preview_target", "target_pos": target, "quote_id": state.get("quote_id", "")})
	_check(preview.get("ok", false), "Z2 shortcut preview established through actual command")
	state = EventService.get_event_state(runtime.context, ORIGIN)
	var request := {"option_id": &"travel", "target_pos": target, "quote_id": state.get("quote_id", ""),
		"preview_id": state.get("preview", {}).get("preview_id", ""), "action_id": "z2_shortcut_entry_failure"}
	var resolver := runtime.command_bus.room_resolver as RejectingResolver
	resolver.reject_target = target
	var observed := _observe(runtime)
	var before := runtime.capture_authoritative_state()
	var result: Dictionary = runtime.command_bus.dispatch(&"select_event_option", request)
	_assert_rejected(runtime, before, observed, result, ENTRY_ERROR, "Z2 trusted shortcut entry callback")
	_check(runtime.context.z1_event_rooms == before.context.data.z1_event_rooms, "Z2 shortcut failed entry preserves quote/preview, event bindings and unawarded stages")
	resolver.reject_target = Vector2i(-1, -1)
	var accepted: Dictionary = runtime.command_bus.dispatch(&"select_event_option", request)
	_check(accepted.get("ok", false) and runtime.context.current_pos == target and runtime.context.asset_ledger.get_currency(&"black_coin") == 94, "Z2 trusted shortcut can continue with original quote and fee")
	_check(runtime.context.interacted_cells.has(runtime.context.cell_key(ORIGIN)) and observed.writes.size() == 1 and observed.states.size() == 1, "Z2 shortcut growth/completion and real entry share one successful commit")
	_release(runtime)


func _test_flee_then_entry_failure(z2: bool) -> void:
	var runtime := _runtime(z2)
	var label := "Z2 retreat" if z2 else "legacy retreat"
	runtime.context.truth_map.set_room_type(ORIGIN, &"Monster")
	_check(runtime.command_bus.room_resolver.enter_room(runtime.context).get("ok", false), label + ": real monster entry succeeds")
	runtime.in_run_runtime.sync_room(Vector2(0.83, 0.47))
	_check(runtime.in_run_runtime.has_active_combat(), label + ": source encounter is genuinely active")
	var fled: Dictionary = runtime.in_run_runtime.request_flee()
	_check(fled.get("ok", false) and runtime.in_run_runtime.flee_authorized and not runtime.in_run_runtime.has_active_combat(), label + ": original flee action durably authorizes departure")
	_check(runtime.context.asset_ledger.get_currency(&"black_coin") == (100 if z2 else 90), label + ": existing version-specific economics unchanged")
	var resolver := runtime.command_bus.room_resolver as RejectingResolver
	resolver.reject_target = TARGET
	var observed := _observe(runtime)
	var before := runtime.capture_authoritative_state()
	var request := {"direction": Vector2i.RIGHT, "entry_position": Vector2(0.16, 0.47), "action_id": label + "_entry_failure"}
	var result: Dictionary = runtime.command_bus.dispatch(&"attempt_room_transition", request)
	_assert_rejected(runtime, before, observed, result, ENTRY_ERROR, label + " following crossing")
	_check(runtime.in_run_runtime.flee_authorized and not runtime.in_run_runtime.has_active_combat() and not runtime.context.truth_map.is_cleared(ORIGIN), label + ": rejected target entry cannot restart encounter or consume flee authorization")
	var repeated: Dictionary = runtime.command_bus.dispatch(&"flee_runtime_combat", {"source": "g41_in_run_runtime"})
	_check(repeated.get("ok", false) and runtime.context.asset_ledger.currency_balances == before.context.components.asset_ledger.currency_balances and runtime.context.asset_ledger.item_instances == before.context.components.asset_ledger.item_instances, label + ": repeat authorization cannot repeat losses")
	resolver.reject_target = Vector2i(-1, -1)
	var crossed: Dictionary = runtime.command_bus.dispatch(&"attempt_room_transition", request)
	_check(crossed.get("ok", false) and runtime.context.current_pos == TARGET and not runtime.in_run_runtime.flee_authorized, label + ": recovered crossing consumes only room-specific authorization")
	_check(runtime.context.asset_ledger.currency_balances == before.context.components.asset_ledger.currency_balances and runtime.context.asset_ledger.item_instances == before.context.components.asset_ledger.item_instances and runtime.context.asset_ledger.room_floor_items == before.context.components.asset_ledger.room_floor_items, label + ": recovered crossing preserves exact post-flee resources and floor bindings")
	_release(runtime)


func _test_recovered_entry_save_failure() -> void:
	var runtime := _runtime()
	var resolver := runtime.command_bus.room_resolver as RejectingResolver
	resolver.reject_target = TARGET
	var observed := _observe(runtime)
	var before := runtime.capture_authoritative_state()
	var request := {"delta": Vector2i.RIGHT, "action_id": "entry_then_storage_failure"}
	var rejected: Dictionary = runtime.command_bus.dispatch(&"move_by", request)
	_assert_rejected(runtime, before, observed, rejected, ENTRY_ERROR, "business failure before storage")
	resolver.reject_target = Vector2i(-1, -1)
	observed.fail_writes = true
	var failed_save: Dictionary = runtime.command_bus.dispatch(&"move_by", request)
	_check(not failed_save.get("ok", true) and str(failed_save.get("status", "")) == "save_failed" and str(failed_save.get("reason", "")) == "fixture_checkpoint_failure", "recovered entry still honors the original checkpoint failure boundary")
	_check(runtime.capture_authoritative_state() == before and observed.writes.size() == 1 and observed.states.is_empty() and observed.results.is_empty(), "failed checkpoint restores full pre-move authority without successful publication")
	var blocked: Dictionary = runtime.command_bus.dispatch(&"move_by", request)
	_check(not blocked.get("ok", true) and str(blocked.get("reason", "")) == "persistence_retry_required" and observed.writes.size() == 1, "save failure retains existing write barrier; business failure never bypasses it")
	observed.fail_writes = false
	_check(runtime.retry_persistence().get("ok", false) and runtime.capture_authoritative_state() == before, "original persistence retry restores readiness without moving")
	var continued: Dictionary = runtime.command_bus.dispatch(&"move_by", request)
	_check(continued.get("ok", false) and runtime.context.current_pos == TARGET and observed.states.size() == 1, "same request commits once after both business and storage recovery")
	_release(runtime)


func _release(runtime: ObservedRuntime) -> void:
	runtime.checkpoint_writer = Callable()
	runtime.command_bus.item_command_handler.combat_active_query = Callable()
	runtime.command_bus.bind_runtime_controller(null)
	runtime.in_run_runtime.bind(null)


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
