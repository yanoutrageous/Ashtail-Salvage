extends SceneTree

const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
const Meta = preload("res://scripts/core/save/meta_progress_adapter.gd")
const Rules = preload("res://scripts/core/progression/z2_progression_rules.gd")
const Offer = preload("res://scripts/core/progression/z2_opening_offer.gd")
const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
var checks := 0
var failures: Array[String] = []

class CutSave extends SaveAdapter:
	var cut := false
	func save_json(payload: Dictionary, path: String = "", pretty: bool = true) -> bool:
		if cut:
			last_error = "injected_opening_save_failure"
			return false
		return super.save_json(payload, path, pretty)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var meta := Meta.new()
	meta.set_active_profile_path("user://z2_opening_integration_%d/meta.json" % Time.get_ticks_usec(), "opening-integration")
	meta.initialize_z2_profile(Rules.CONTENT_VERSION)
	meta.data.tutorial_completed = true
	meta.data.profile_level = Rules.level_for_exp(12650)
	meta.data.profile_exp = 12650
	meta.data.talent_flags = []
	for number in range(1, 16):
		meta.data.talent_flags.append("z2_talent_%02d" % number)
	meta.data.talent_earned = 2000
	meta.data.talent_spent = 1500
	meta.data.talent_points = 500
	meta.data.gold = 1000
	meta.save()
	var r := Runtime.new()
	r.bind_meta_progress_adapter(meta)
	r.checkpoint_service = RunCheckpointService.new()
	r.checkpoint_service.configure(meta, "z2", Rules.CONTENT_VERSION)
	var commission: Dictionary = M7ContentCatalog.commission_offer_candidates("classic_7x7_simple", 0, 3)[0]
	var started: Dictionary = r.command_bus.dispatch(&"start_standard_run", {"run_start_config": {"map_config_id": "classic_7x7_simple", "difficulty": "simple", "seed_value": 20261116, "selected_objective_id": commission.id, "z2_opening_offer": {"selected": "avoidance"}}})
	_check(started.get("ok", false), "qualified profile starts normally, ignoring injected effect")
	var pending: Dictionary = r.context.z1_event_flags.get("z2_opening", {})
	_check(pending.get("status") == "offered" and pending.get("candidates", []).size() == 3, "spawn checkpoint holds three free candidates before first action")
	_check(not r.execute_meta_action(_request("prepare", "old-camp")).get("ok", true), "camp can no longer prepare an offer")
	for action: StringName in [&"move_by", &"interact_current_room", &"select_event_option", &"search_current_room"]:
		var blocked: Dictionary = r.command_bus.dispatch(action, {"delta": Vector2i.UP})
		_check(str(blocked.get("reason", "")) == "opening_selection_required", "pending selection blocks direct " + str(action))
	if not pending.is_empty():
		_test_paid_choices(r, meta)
	_finish(r)

func _test_paid_choices(r, meta) -> void:
	var first: Dictionary = r.spawn_opening_offer()
	var refresh := _request("refresh", "refresh-1", {"offer_id": first.offer_id, "run_id": str(r.context.run_id)})
	var snapshot: Dictionary = meta.data.duplicate(true)
	var before_hash := FileAccess.get_sha256(meta.active_meta_progress_path)
	var writer := CutSave.new()
	meta.save_adapter = writer
	writer.cut = true
	_check(not r.execute_meta_action(refresh).get("ok", true), "injected meta write fails")
	_check(meta.data == snapshot and FileAccess.get_sha256(meta.active_meta_progress_path) == before_hash and r.spawn_opening_offer() == first, "failure rolls back offer, balance and disk")
	writer.cut = false
	var paid: Dictionary = r.execute_meta_action(refresh)
	_check(paid.get("ok", false) and int(meta.data.gold) == 995, "retry pays exactly 5 " + str(paid.get("status")))
	if not paid.get("ok", false): return
	var offer: Dictionary = r.spawn_opening_offer()
	_check(offer.refresh_count == 1 and offer.receipts.has("refresh-1") and offer.candidates != first.candidates, "payment, draw and receipt commit together")
	_check(r.execute_meta_action(refresh).get("duplicate", false) and int(meta.data.gold) == 995, "retry cannot charge twice")
	var conflict := refresh.duplicate(true)
	conflict.offer_id = offer.offer_id
	_check(not r.execute_meta_action(conflict).get("ok", true), "changed payload under old id rejected")
	var disk := Meta.new()
	disk.set_active_profile_path(meta.active_meta_progress_path, meta.active_profile_id)
	disk.load_or_create_default()
	var restored := Runtime.new()
	restored.bind_meta_progress_adapter(disk)
	restored.checkpoint_service = RunCheckpointService.new()
	restored.checkpoint_service.configure(disk, "z2", Rules.CONTENT_VERSION)
	_check(restored._restore_durable_checkpoint(true).get("ok", false) and restored.spawn_opening_offer() == JSON.parse_string(JSON.stringify(offer)), "independent restore reads exactly the paid offer and receipt")
	_check(restored.execute_meta_action(refresh).get("duplicate", false) and int(disk.data.gold) == 995, "restored request replays durably")
	_check(not restored.command_bus.dispatch(&"opening_choose", {"offer_id": first.offer_id, "effect_id": first.candidates[0], "action_id": "stale"}).get("ok", true), "old candidate set rejected")
	for count in range(2, 11):
		var request := _request("refresh", "refresh-%d" % count, {"offer_id": offer.offer_id, "run_id": str(restored.context.run_id)})
		var old_gold := int(disk.data.gold)
		_check(restored.execute_meta_action(request).get("ok", false), "refresh %d" % count)
		offer = restored.spawn_opening_offer()
		_check(offer.refresh_count == count and int(disk.data.gold) == old_gold - 5 * count and offer.candidates.count(offer.candidates[0]) == 1 and offer.candidates[1] != offer.candidates[2], "price and distinct candidates %d" % count)
	var excess := _request("refresh", "refresh-11", {"offer_id": offer.offer_id, "run_id": str(restored.context.run_id)})
	_check(not restored.execute_meta_action(excess).get("ok", true) and int(disk.data.gold) == 725, "cap at ten, total cost 275")
	var choose := {"offer_id": offer.offer_id, "effect_id": offer.candidates[0], "action_id": "choose-final"}
	var cut_checkpoint := CutSave.new()
	restored.checkpoint_service.save_adapter = cut_checkpoint
	cut_checkpoint.cut = true
	_check(not restored.command_bus.dispatch(&"opening_choose", choose).get("ok", true) and restored.spawn_opening_pending(), "checkpoint failure rolls back activation")
	cut_checkpoint.cut = false
	_check(restored.retry_persistence().get("ok", false), "recover failed checkpoint")
	var chosen: Dictionary = restored.command_bus.dispatch(&"opening_choose", choose)
	_check(chosen.get("ok", false) and restored.context.run_start_config.opening_effect.get("id") == choose.effect_id, "choice and actual effect commit together")
	_check(restored.command_bus.dispatch(&"opening_choose", choose).get("duplicate", false), "replay does not reapply effect")
	_check(restored._restore_durable_checkpoint(true).get("ok", false) and not restored.spawn_opening_pending(), "selected result survives restore")
	var state: Dictionary = restored.context.z1_event_flags.z2_opening
	_check(state.selected == choose.effect_id and state.paid_gold == 275 and state.admitted_offer.receipts.size() == 10, "selected checkpoint contains every paid receipt")
	var room: Vector2i = restored.context.get_current_pos()
	var direction := Vector2i.RIGHT if room.x == 0 else Vector2i.LEFT
	var moved: Dictionary = restored.command_bus.dispatch(&"move_by", {"delta": direction})
	_check(moved.get("ok", false) and restored.context.get_current_pos() == room + direction, "first ordinary move accepted after selection: " + str(moved.get("reason", "")))
	restored.command_bus.bind_runtime_controller(null)
	restored.in_run_runtime.bind(null)

func _request(action: String, request_id: String, fields: Dictionary = {}) -> Dictionary:
	var request := {"source_page": "spawn_room", "action": "opening_" + action, "request_id": request_id}
	request.merge(fields)
	return request

func _finish(r) -> void:
	r.command_bus.runtime_controller = null
	r.command_bus.room_resolver.bind_runtime_controller(null)
	r.in_run_runtime.bind(null)
	for failure in failures:
		print("Z2_OPENING_INTEGRATION_FAIL " + failure)
	print("Z2_OPENING_INTEGRATION=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
