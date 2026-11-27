extends SceneTree

const Meta := preload("res://scripts/core/save/meta_progress_adapter.gd")
const Service := preload("res://scripts/core/progression/m7_progression_service.gd")
const Rules := preload("res://scripts/core/progression/z2_progression_rules.gd")
const Goals := preload("res://scripts/core/progression/z2_goals/goal_progression.gd")
const Catalog := preload("res://scripts/core/content/m7_content_catalog.gd")
const Context := preload("res://scripts/core/run/run_context.gd")
const Builder := preload("res://scripts/core/run/run_result_builder.gd")
const Checkpoints := preload("res://scripts/core/save/run_checkpoint_service.gd")
const Snapshot := preload("res://scripts/core/run/run_state_snapshot.gd")
const Runtime := preload("res://scripts/core/run/run_runtime_controller.gd")
const Manager := preload("res://scripts/core/save/save_manager.gd")
const StartConfig := preload("res://scripts/core/run/run_start_config.gd")

class CutSave extends SaveAdapter:
	var cut := false
	func _rename_file(source: String, target: String) -> bool:
		if cut and source.ends_with(ATOMIC_TEMP_SUFFIX):
			cut = false
			return false
		return super._rename_file(source, target)

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_teaching_and_endings()
	_tier_save_retry()
	_reinvestment()
	_admission_retry()
	_opening_save_retry()
	_runtime_tier_retry()
	_public_start_terminal()
	_stage_scores()
	for failure in failures:
		print("Z2_QUEST_INTEGRATION_FAIL " + failure)
	print("Z2_QUEST_INTEGRATION=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _new_meta(label: String):
	var meta := Meta.new()
	meta.set_active_profile_path("user://t13_unified_%s_%d/meta.json" % [label, Time.get_ticks_usec()], label)
	_check(meta.initialize_z2_profile(Rules.CONTENT_VERSION).get("ok", false), label + " creates actual profile")
	_check(meta.data.get("z2_goals", {}).get("states", {}).size() == 50, "one canonical ledger initializes all50")
	_check(meta.data.task_states.size() == 25 and meta.data.achievement_states.size() == 25, "compatibility views contain25+25")
	_check(not meta.data.task_states.has("task_first_survey"), "new profile removes legacy goals")
	_check(meta.begin_tutorial_training().get("ok", false), "tutorial purchase gate")
	_check(meta.purchase_tutorial_flag().get("ok", false), "actual tutorial purchase")
	_check(meta._apply_tutorial_settlement({"mode": "tutorial", "outcome": "Training Complete", "settlement": {"outcome": "success"}}, "tutorial-" + label).get("ok", false), "tutorial commits")
	_check(Goals.goal_state(meta.data, "M01").get("status") == "active", "tutorial activates canonical M01")
	return meta

func _context(meta, items: Array = [], admit: bool = true):
	var ids: Array = []
	for item: Dictionary in items:
		ids.append(str(item.instance_id))
	var profile := {"ruleset_id": "z2", "z2_progression_version": 1,
		"z2_fact_sequence_base": int(meta.data.get("z2_fact_sequence", 0))}
	var start := {"map_config_id": "classic_7x7_simple", "profile_fields": profile,
		"selected_equipment_items": [], "selected_equipment_ids": [],
		"selected_consumable_items": items, "selected_consumable_ids": ids}
	var config := Catalog.map_runtime_config("classic_7x7_simple", 71, start)
	config["profile_fields"] = profile
	config["selected_consumable_items"] = items
	var run := Context.new()
	run.start_run(config)
	if admit:
		var service := Checkpoints.new()
		service.configure(meta, "z2", Rules.CONTENT_VERSION)
		_check(service.begin_admission(_checkpoint(meta, run)).get("ok", false), "real prepared and active admission saves")
	return run

func _checkpoint(meta, run) -> Dictionary:
	return {"schema_version": 1, "profile_id": meta.active_profile_id, "run_id": str(run.run_id), "revision": 0,
		"ruleset_id": "z2", "content_version": Rules.CONTENT_VERSION, "state": Snapshot.pack_checkpoint({"context": Snapshot.capture_context(run)})}

func _finish(meta, run, ending: String) -> Dictionary:
	if ending == "success":
		run._apply_extract()
	elif ending == "failure":
		run.fail_run("integration_death")
	else:
		run.abandon_run()
	if not run.settlement_result.get("finalized", false):
		var before: Dictionary = meta.data.duplicate(true)
		var pending := Service.apply_settlement(meta.data, Builder.build(run, run.asset_ledger.get_public_snapshot(run.player_pos)))
		_check(not pending.get("ok", true) and meta.data == before, "pending selection does not consume goals or growth")
		run.confirm_failure_salvage([])
	var snapshot := Builder.build(run, run.asset_ledger.get_public_snapshot(run.player_pos))
	return {"snapshot": snapshot, "result": meta.apply_settlement(snapshot)}

func _teaching_and_endings() -> void:
	for ending in ["success", "failure", "abandon"]:
		var meta = _new_meta(ending)
		var run = _context(meta)
		var committed := _finish(meta, run, ending)
		_check(committed.result.get("ok", false), ending + " real terminal saves")
		_check(Goals.goal_state(meta.data, "M01").get("status") == "claimable", ending + " completes canonical M01")
		_check(meta.data.task_states.M02.status == "active" and meta.data.task_states.S01.status == "active", "completion opens next before claim")
		var notices: Array = committed.result.get("completions", [])
		_check(not notices.is_empty() and notices[0].get("committed", false), "only successful durable result publishes completion")
		_check(committed.result.get("quest_receipt", {}).get("committed", false), "notification receives committed receipt")
		var before: Dictionary = meta.data.duplicate(true)
		meta.apply_settlement(committed.snapshot)
		_check(meta.data == before, "real terminal receipt replay has no second growth or award")
		var claim: Dictionary = meta.claim_goal_reward("task", "M01")
		_check(claim.get("ok", false) and int(meta.data.gold) == int(before.gold) + 10 and int(meta.data.profile_exp) == int(before.profile_exp) + 10, "M01 grants independent10XP10gold once")
		meta.load_or_create_default()
		var after: Dictionary = meta.data.duplicate(true)
		meta.claim_goal_reward("task", "M01")
		_check(_same(meta, after), "M01 reload replay does not repay")

func _tier_save_retry() -> void:
	var meta = _new_meta("tier")
	var supports_tier := false
	for method: Dictionary in meta.get_method_list():
		if method.name == "claim_goal_reward":
			supports_tier = method.args.size() >= 3
	_check(supports_tier, "Meta claim exposes explicit tier")
	if not supports_tier:
		return
	var run = _context(meta)
	# Committed-journal fixture; actual Meta/RunResult/atomic disk path below.
	for index in range(110):
		run.record_event(&"room_entered", "entry-%d" % index, &"player", "acceptance_fixture", {"position": Vector2i(1 + index % 2, 1), "room_type": "Event"})
	var settled := _finish(meta, run, "abandon")
	_check(settled.result.get("ok", false), "tier journal saves through real Meta")
	_check(Goals.goal_state(meta.data, "A08").get("claimable_tiers") == [1, 2], "two milestones both await manual claim")
	var before: Dictionary = meta.data.duplicate(true)
	var cut := CutSave.new()
	cut.cut = true
	meta.save_adapter = cut
	var payload := {"action": "claim_goal", "goal_kind": "achievement", "goal_id": "A08", "tier": 2}
	var failed: Dictionary = meta.execute_idempotent_meta_action("claim-two", payload, Callable(meta, "claim_goal_reward").bind("achievement", "A08", 2))
	_check(not failed.get("adapter_result", {}).get("ok", true) and _same(meta, before), "atomic rename failure rolls back money tier and request receipt")
	_check(not failed.get("adapter_result", {}).get("quest_receipt", {}).get("committed", false), "save failure cannot publish committed notice")
	meta.load_or_create_default()
	_check(_same(meta, before), "failure preserves prior disk profile")
	var retry: Dictionary = meta.execute_idempotent_meta_action("claim-two", payload, Callable(meta, "claim_goal_reward").bind("achievement", "A08", 2))
	var claim: Dictionary = retry.get("adapter_result", {})
	_check(claim.get("ok", false) and claim.get("tier") == 2 and claim.get("reward_id") == "z2-goal:A08:2", "same request retries exact tier identity")
	_check(int(meta.data.gold) == int(before.gold) + 40, "tier2 pays40 exactly")
	_check(claim.get("fingerprint", "") == meta._meta_action_fingerprint(payload), "return fingerprint preserves tier payload")
	var tier_view: Dictionary = meta.get_summary().achievement_states.A08
	_check(tier_view.claimed_steps == [100] and tier_view.claimed_tiers == [2], "out-of-order tier claim projects all claimed thresholds")
	_check(tier_view.tier == 1 and tier_view.target == 50, "out-of-order claim keeps lowest unclaimed tier as panel target")
	meta.load_or_create_default()
	var saved: Dictionary = meta.data.duplicate(true)
	var duplicate: Dictionary = meta.execute_idempotent_meta_action("claim-two", payload, Callable(meta, "claim_goal_reward").bind("achievement", "A08", 2))
	_check(duplicate.idempotency_status == &"duplicate" and _same(meta, saved), "same request reload is durable no-op")
	meta.call("claim_goal_reward", "achievement", "A08", 2)
	_check(_same(meta, saved), "fresh call to same tier cannot claim a different tier")
	payload.tier = 1
	var conflict: Dictionary = meta.execute_idempotent_meta_action("claim-two", payload, Callable(meta, "claim_goal_reward").bind("achievement", "A08", 1))
	_check(conflict.idempotency_status == &"request_id_conflict" and _same(meta, saved), "same request with changed tier conflicts")
	var first: Dictionary = meta.call("claim_goal_reward", "achievement", "A08", 1)
	_check(first.get("ok", false) and int(meta.data.gold) == int(before.gold) + 60, "unclaimed tier1 still pays20")
	var panel: Array = meta.get_summary().achievement_definitions.filter(func(row: Dictionary) -> bool: return row.id == "A08")
	_check(panel[0].get("tier") == 3 and panel[0].get("target") == 200 and panel[0].reward.gold == 80, "panel advances to remaining tier3 with80gold")

func _reinvestment() -> void:
	var meta = _new_meta("reinvestment")
	meta.data.merge(Goals.initial_state(meta.data), true)
	# Explicit state setup only opens S03; sale, purchase, departure, settlement and save are real.
	for id in ["M01", "M02", "M03"]:
		meta.data.z2_goals.states[id].unlocked = true
		meta.data.z2_goals.states[id].progress = 1
	meta.data.profile_exp = 30
	meta.data.profile_level = 2
	meta.data.gold = 1000
	Service.sync_z2_quests(meta.data)
	var old: Dictionary = Service.add_item_instance(meta.data, "col_01", "fixture_setup")
	_check(meta.save(), "seeded S03 setup saves")
	var first_clock := int(meta.data.get("z2_fact_sequence", 0))
	var sold: Dictionary = meta.sell_collectible(str(old.instance_id))
	_check(sold.get("ok", false), "actual collection sale commits")
	_check(int(meta.data.z2_fact_sequence) == first_clock + 1, "sale allocates persistent clock once")
	var buy_id := ""
	for shop: Dictionary in Catalog.shop_definitions(meta.data):
		if Catalog.is_shop_unlocked(shop, meta.data):
			buy_id = str(shop.item_id)
			break
	var bought: Dictionary = meta.purchase_items(buy_id, 2)
	_check(bought.get("ok", false), "actual batch purchase commits")
	_check(int(meta.data.z2_fact_sequence) == first_clock + 2, "one purchase batch uses one fact sequence")
	meta.load_or_create_default()
	var purchase_clock := int(meta.data.z2_fact_sequence)
	var purchased: Array = bought.get("items", [])
	if purchased.is_empty():
		return
	var other: Dictionary = purchased[0].duplicate(true)
	other.instance_id = "same-definition-not-purchased"
	var first_run = _context(meta, [other])
	var first := _finish(meta, first_run, "abandon")
	_check(first.result.get("ok", false) and Goals.goal_state(meta.data, "S03").get("status") == "active", "same definition other instance cannot satisfy S03")
	_check(int(meta.data.z2_fact_sequence) > purchase_clock, "settlement advances beyond lobby clock")
	meta.load_or_create_default()
	var second_run = _context(meta, [purchased[1]])
	_check(int(second_run.run_event_log.snapshot()[0].sequence) == 1, "second run local journal resets1")
	var before: Dictionary = meta.data.duplicate(true)
	_check(not meta.purchase_item(buy_id).get("ok", true), "active run rejects competing lobby clock writer")
	meta.data = before
	var second := _finish(meta, second_run, "failure")
	_check(second.result.get("ok", false) and Goals.goal_state(meta.data, "S03").get("status") == "claimable", "sold then bought exact instance across runs completes S03 on death")
	var after: Dictionary = meta.data.duplicate(true)
	meta.apply_settlement(second.snapshot)
	_check(meta.data == after, "replay does not advance profile sequence")

func _admission_retry() -> void:
	var meta = _new_meta("admission")
	var run = _context(meta, [], false)
	var service := Checkpoints.new()
	service.configure(meta, "z2", Rules.CONTENT_VERSION)
	var checkpoint := _checkpoint(meta, run)
	var before: Dictionary = meta.data.duplicate(true)
	var cut := CutSave.new()
	cut.cut = true
	meta.save_adapter = cut
	_check(not service.begin_admission(checkpoint).get("ok", true), "failed admission cannot authorize gameplay")
	_check(_same(meta, before), "failed admission rolls back sequence and reservation")
	meta.load_or_create_default()
	_check(_same(meta, before), "admission failure preserves durable clock")
	_check(service.begin_admission(checkpoint).get("ok", false), "same initial snapshot retries admission")
	_check(int(meta.data.z2_fact_sequence) == int(before.z2_fact_sequence) + 1, "departure is reserved before any terminal")
	var reservation: Dictionary = meta.data.get("z2_quest_departures", {}).get(str(run.run_id), {})
	_check(reservation.get("departure_sequence") == 1 and reservation.get("base") == 0, "run owns persisted departure1 and base0")
	meta.load_or_create_default()
	var after: Dictionary = meta.data.duplicate(true)
	_check(service.begin_admission(checkpoint).get("ok", false) and _same(meta, after), "admission reload retry cannot allocate twice")

func _opening_save_retry() -> void:
	var meta = _new_meta("opening")
	meta.data.talent_flags.append("z2_talent_15")
	meta.data.gold = 100
	_check(meta.save(), "opening qualification setup saves")
	var run = _context(meta)
	var initial := Z2OpeningOffer.initial_offer(str(run.run_id) + ":opening", run.seed_value)
	var before: Dictionary = meta.data.duplicate(true)
	var cut := CutSave.new()
	cut.cut = true
	meta.save_adapter = cut
	var payload := {"request_id": "refresh", "offer_id": initial.offer_id, "run_id": str(run.run_id)}
	var operation := Callable(meta, "refresh_spawn_opening_offer").bind(initial, payload)
	var failed: Dictionary = meta.execute_idempotent_meta_action("refresh", payload, operation)
	_check(not failed.adapter_result.get("ok", true) and _same(meta, before), "opening deferred save failure rolls back fee and redraw")
	meta.load_or_create_default()
	var retried: Dictionary = meta.execute_idempotent_meta_action("refresh", payload, operation)
	_check(retried.adapter_result.get("ok", false) and int(meta.data.gold) == 95 and int(meta.data.z2_opening_offer.refresh_count) == 1, "retry charges once")
	meta.load_or_create_default()
	var after: Dictionary = meta.data.duplicate(true)
	var replay: Dictionary = meta.execute_idempotent_meta_action("refresh", payload, operation)
	_check(replay.idempotency_status == &"duplicate" and _same(meta, after), "replay after reload keeps balance and candidates")

func _stage_scores() -> void:
	var events: Array = []
	for stage in ["one", "two"]:
		events.append(_stage("altar-xp", "altar-" + stage, 5, 2))
		events.append(events.back().duplicate(true))
	events.append(_stage("cage-room", "cage-first", 10, 5))
	events.append(_stage("cage-room", "cage-repeat", 10, 5))
	events.append({"event_type": "event_option_selected", "payload": {"position": Vector2i(1, 1), "result": {"ok": true, "ruleset_id": "z2", "completed": true}}})
	events.append({"event_type": "combat_resolved", "payload": {"position": Vector2i(2, 1), "runtime": true, "cage": true, "stage_authority": "z2_event_runtime"}})
	events.append({"event_type": "combat_resolved", "payload": {"position": Vector2i(3, 1), "runtime": true}})
	var ineffective := _stage("bad", "bad", 500, 500)
	ineffective.payload.effective = false
	events.append(ineffective)
	var scored := Rules.score_events(events)
	_check(scored.experience == 20 and scored.talent_points == 17, "stage XP once per xp_key, talent per stage, no option or cage duplicate; ordinary5/3")
	_check(Rules.score_events(events + events).experience == 20 and Rules.score_events(events + events).talent_points == 17, "journal replay does not duplicate either independent score key")

func _runtime_tier_retry() -> void:
	var meta = _new_meta("runtime_tier")
	# Saved eligibility fixture; the public Runtime request, failure and retry are real.
	meta.data.z2_goals.states.A08.progress = 110
	Service.sync_z2_quests(meta.data)
	_check(meta.save(), "runtime tier eligibility saves")
	var runtime := Runtime.new()
	runtime.bind_meta_progress_adapter(meta)
	var request := {"request_id": "runtime-claim2", "source_page": "long_term", "action": "claim_goal", "goal_kind": "achievement", "goal_id": "A08", "tier": 2}
	var before: Dictionary = meta.data.duplicate(true)
	var cut := CutSave.new()
	cut.cut = true
	meta.save_adapter = cut
	var failed: Dictionary = runtime.execute_meta_action(request)
	_check(not failed.get("ok", true) and failed.get("status") == &"save_failed" and _same(meta, before), "Runtime tier save failure has no balance or claim effect")
	var retried: Dictionary = runtime.execute_meta_action(request)
	_check(retried.get("ok", false) and not retried.get("duplicate", true) and int(meta.data.gold) == int(before.gold) + 40, "same Runtime and request retry after failure is not poisoned by cache")
	_check(retried.get("result", {}).get("tier") == 2 and retried.get("result", {}).get("reward_id") == "z2-goal:A08:2", "Runtime carries explicit tier through Meta")
	meta.load_or_create_default()
	var fresh := Runtime.new()
	fresh.bind_meta_progress_adapter(meta)
	var after: Dictionary = meta.data.duplicate(true)
	var replay: Dictionary = fresh.execute_meta_action(request)
	_check(replay.get("ok", false) and replay.get("duplicate", false) and _same(meta, after), "fresh Runtime durable request replay never repays tier")
	request.tier = 1
	_check(fresh.execute_meta_action(request).get("status") == &"request_id_conflict" and _same(meta, after), "Runtime identity changes when tier changes")
	_release(runtime)
	_release(fresh)

func _public_start_terminal() -> void:
	var manager := Manager.new()
	manager.switch_profile("t13_public_%d" % Time.get_ticks_usec())
	var meta := Meta.new()
	manager.configure_meta_adapter(meta)
	_check(meta.initialize_z2_profile(Rules.CONTENT_VERSION).get("ok", false), "public profile creates")
	meta.begin_tutorial_training()
	meta.purchase_tutorial_flag()
	_check(meta._apply_tutorial_settlement({"mode": "tutorial", "outcome": "Training Complete", "settlement": {"outcome": "success"}}, "public-tutorial").get("ok", false), "public profile teaching saves legal level")
	var runtime := Runtime.new()
	runtime.bind_meta_progress_adapter(meta)
	_check(runtime.initialize_z2_session(manager).get("ok", false), "public runtime persistence session configures")
	var config := StartConfig.default_config()
	config.merge({"map_config_id": "classic_7x7_simple", "difficulty": &"simple", "seed_value": 9223372036854775806}, true)
	config.selected_objective_id = Catalog.commission_offer_candidates("classic_7x7_simple", 0)[0].id
	var started: Dictionary = runtime.command_bus.dispatch(&"start_standard_run", {"run_start_config": config})
	_check(started.get("ok", false), "public start freezes trusted sequence and admits: " + str(started.get("reason", started.get("status", ""))))
	if started.get("ok", false):
		_check(meta.data.z2_quest_departures.has(str(runtime.context.run_id)) and int(meta.data.z2_fact_sequence) == 1, "public initial checkpoint reserves departure before simulation")
		_check(runtime.context.seed_value == 9223372036854775806, "quest admission preserves exact int64 seed")
		runtime.command_bus.dispatch(&"abandon_run", {"confirmed": true})
		if runtime.context.phase == &"failure_salvage":
			runtime.command_bus.dispatch(&"confirm_failure_salvage", {"selected_instance_ids": []})
		_check(runtime.last_meta_commit.get("ok", false), "public terminal saves quest and receipt: " + str(runtime.last_meta_commit.get("reason", runtime.last_meta_commit.get("status", ""))))
		_check(Goals.goal_state(meta.data, "M01").get("status") == "claimable", "public formal abandon completes M01")
		var payload: Dictionary = runtime.context.result_snapshot.duplicate(true)
		meta.load_or_create_default()
		var before: Dictionary = meta.data.duplicate(true)
		_check(meta.apply_settlement(payload).get("ok", false) and _same(meta, before), "public int64 terminal replay after reload is unchanged")
	_release(runtime)

func _release(runtime) -> void:
	runtime.command_bus.runtime_controller = null
	runtime.command_bus.room_resolver.bind_runtime_controller(null)
	runtime.in_run_runtime.bind(null)

func _stage(xp_key: String, talent_key: String, xp: int, talent: int) -> Dictionary:
	return {"event_type": "event_stage_completed", "payload": {"position": Vector2i(1, 1), "event_type": "cage" if xp == 10 else "altar", "stage_id": talent_key,
		"xp_key": xp_key, "talent_key": talent_key, "equipment_key": "", "base_xp": xp, "base_talent": talent, "actual_combat": xp == 10, "equipment_eligible": false, "effective": true}}

func _same(meta, expected: Dictionary) -> bool:
	return SaveAdapter.json_fingerprint(meta._json_safe(meta.data)) == SaveAdapter.json_fingerprint(meta._json_safe(expected))

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
