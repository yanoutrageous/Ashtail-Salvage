extends SceneTree

# Read-only profiling of production paths; all writes are isolated test saves.
const Baseline := preload("res://tests/z2_runtime_performance_runner.gd")
const Rules := preload("res://scripts/core/progression/z2_progression_rules.gd")
const Items := preload("res://scripts/core/content/z2_item_catalog.gd")
const Opening := preload("res://scripts/core/run/z2_opening_runtime.gd")
const Snapshot := preload("res://scripts/core/run/run_state_snapshot.gd")
const STEP := 1.0 / 60.0
var checks := 0
var failures: Array[String] = []
var points: Array = []
var actions: Array = []
var idle_windows: Array = []
var stop_reason := ""
var measured_runtime
var output_path := ""


func _initialize() -> void:
	Engine.physics_ticks_per_second = 60
	Engine.max_fps = 60
	output_path = OS.get_environment("T05_PERF_OUTPUT")
	if output_path.is_empty():
		output_path = "user://t05_load_profile_measurements_%d.json" % Time.get_ticks_usec()
	call_deferred("_run")


func _run() -> void:
	var r = _formal_runtime()
	measured_runtime = r
	if r != null:
		await _profile(r)
	_write()
	if r != null:
		_release(r)
	for failure in failures:
		print("LOAD_PROFILE_FAIL " + failure)
	print("Z2_RUNTIME_LOAD_PROFILE=%s checks=%d failures=%d stop=%s output=%s" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size(), stop_reason, ProjectSettings.globalize_path(output_path)])
	quit(0 if failures.is_empty() else 1)


func _formal_runtime():
	var r := Baseline.MeasuredRuntime.new()
	var meta := MetaProgressAdapter.new()
	var id := "load_%d" % Time.get_ticks_usec()
	meta.set_active_profile_path("user://t05_load_profile/" + id + "/meta.json", id)
	if not _ok(meta.initialize_z2_profile(Rules.CONTENT_VERSION), "real new profile"):
		_release(r)
		return null
	meta.data.tutorial_completed = true
	meta.data.profile_exp = 12650
	meta.data.profile_level = Rules.level_for_exp(12650)
	meta.data.talent_flags = []
	for number in range(1, 16):
		meta.data.talent_flags.append("z2_talent_%02d" % number)
	meta.data.talent_earned = 2000
	meta.data.talent_spent = 1500
	meta.data.talent_points = 500
	meta.data.gold = 1000
	if not _check(meta.save(), "qualified test profile saved: " + meta.last_error):
		_release(r)
		return null
	r.bind_meta_progress_adapter(meta)
	r.checkpoint_service = RunCheckpointService.new()
	if not _ok(r.checkpoint_service.configure(meta, "z2", Rules.CONTENT_VERSION), "real checkpoint configured"):
		_release(r)
		return null
	var commission: Dictionary = M7ContentCatalog.commission_offer_candidates("classic_13x13_normal", int(meta.data.run_count), 3)[0]
	var start: Dictionary = r.command_bus.dispatch(&"start_standard_run", {"run_start_config": {
		"map_config_id": "classic_13x13_normal", "difficulty": "normal", "seed_value": 3141, "selected_objective_id": commission.id}})
	if not _ok(start, "formal authorized departure"):
		_release(r)
		return null
	var offered: Dictionary = r.spawn_opening_offer()
	while not offered.candidates.has("status_clear") and int(offered.refresh_count) < 10:
		if not _ok(r.execute_meta_action(_offer_request("refresh", "refresh:%d" % int(offered.refresh_count), {"offer_id": offered.offer_id, "run_id": str(r.context.run_id)})), "legal opening refresh"):
			_release(r)
			return null
		offered = r.spawn_opening_offer()
	if not _check(offered.candidates.has("status_clear"), "fixture draws status_clear through legal offers"):
		_release(r)
		return null
	if not _ok(r.command_bus.dispatch(&"opening_choose", {"action_id": "choose", "offer_id": offered.offer_id, "effect_id": "status_clear"}), "formal opening choice"):
		_release(r)
		return null
	_check(Opening.public_state(r.context).get("selected") == "status_clear", "trusted opening reached live run")
	_check(r.context.run_start_config.profile_fields.has("z2_fact_sequence_base"), "formal departure freezes actual fact cursor")
	return r


func _offer_request(action: String, id: String, fields: Dictionary = {}) -> Dictionary:
	var request := {"source_page": "spawn_room", "action": "opening_" + action, "request_id": id}
	request.merge(fields)
	return request


func _profile(r) -> void:
	print("LOAD_PROFILE formal departure ready")
	await _idle(r, "formal_idle", 240)
	_point(r, "formal_idle", 0)
	var tape := Items.definition("con_tape_roll")
	tape["instance_id"] = "load_profile_tape"
	var supplied: Dictionary = r.execute_atomic_operation(&"profile_fixture_supply", {}, func() -> Dictionary:
		return r.context.asset_ledger.add_reward_items([tape], &"inventory", r.context.get_current_pos(), "load_profile_fixture"))
	if not _ok(supplied, "one real inventory supply fixture") or not _ok(r.command_bus.dispatch(&"use_consumable", {"instance_id": tape.instance_id}), "actual consumable command"):
		return
	await _idle(r, "one_active_status", 600)
	_check(int(Opening.public_state(r.context).effect_state.uses) == 0, "one status leaves clear effect unused")
	_point(r, "one_active_status", 0)
	var positions: Array[Vector2i] = []
	for y in range(1, 5):
		for x in range(1, 12):
			var pos := Vector2i(x, y)
			if pos != r.context.get_current_pos():
				positions.append(pos)
	for index in range(30):
		var pos := positions[index]
		r.lane = "event"
		var began := Time.get_ticks_usec()
		var entered: Dictionary = r.execute_atomic_operation(&"room_entry", {"position": pos}, func() -> Dictionary:
			r.context.truth_map.set_room_type(pos, &"Event")
			r.context.z1_event_rooms[r.context.cell_key(pos)] = {"event_type": &"information"}
			r.context.player_pos = pos
			r.context.current_pos = pos
			return r.command_bus.room_resolver.enter_room(r.context), "load-room:%d" % index)
		actions.append({"kind": "enter_information", "ordinal": index + 1, "us": Time.get_ticks_usec() - began})
		if not _ok(entered, "actual information entry %d" % index):
			stop_reason = "event_entry_failed"
			return
		var state: Dictionary = EventService.get_event_state(r.context, pos)
		var request := {}
		for option: Dictionary in state.get("options", []):
			if str(option.id) == "mine_count" and option.get("enabled", false):
				request = option.get("payload", {}).duplicate(true)
				request["option_id"] = "mine_count"
				request["action_id"] = "load-event:%d" % index
				break
		if not _check(not request.is_empty(), "real enabled information option"):
			return
		began = Time.get_ticks_usec()
		var resolved: Dictionary = r.command_bus.dispatch(&"select_event_option", request)
		actions.append({"kind": "resolve_information", "ordinal": index + 1, "us": Time.get_ticks_usec() - began})
		if not _ok(resolved, "actual information action %d" % index):
			stop_reason = "event_action_failed"
			return
		_check(r.context.run_active and EventService.get_event_state(r.context, pos).get("completed", false), "real event completed while alive")
		if index + 1 in [1, 5, 15, 30]:
			await _idle(r, "after_%d_events" % (index + 1), 120)
			_point(r, "after_%d_events" % (index + 1), index + 1)
			if int(points.back().snapshot_bytes) > Snapshot.MAX_CHECKPOINT_BYTES / 2:
				stop_reason = "profiling_guard_half_checkpoint_limit"
				return
		if not failures.is_empty():
			return
	var loaded: Dictionary = r.checkpoint_service.load_checkpoint()
	if _ok(loaded, "final actual disk load"):
		var resumed := RunRuntimeController.new()
		var restored := resumed.restore_checkpoint_state(loaded.snapshot.state, loaded.snapshot)
		_check(restored.get("ok", false) and resumed.context.run_event_log.size() == r.context.run_event_log.size(), "actual disk restart retains full accumulated events")
		_release(resumed)


func _idle(r, label: String, ticks: int) -> void:
	r.lane = label
	var before_receipts: int = r.context.z1_event_flags.z2_opening.get("receipts", {}).size()
	var before_bytes := var_to_bytes(r.context.z1_event_flags.z2_opening).size()
	var began := Time.get_ticks_usec()
	for tick in range(ticks):
		await physics_frame
		var start := Time.get_ticks_usec()
		var writes: int = r.writes
		var result: Dictionary = r.advance_idle_frame(STEP)
		var elapsed := Time.get_ticks_usec() - start
		r.record(label + "/total_us", elapsed)
		r.record(label + ("/save_us" if r.writes > writes else "/no_save_us"), elapsed)
		if not _ok(result, "real idle tick"):
			return
	var after_receipts: int = r.context.z1_event_flags.z2_opening.get("receipts", {}).size()
	var after_bytes := var_to_bytes(r.context.z1_event_flags.z2_opening).size()
	_check(after_receipts == before_receipts and after_bytes == before_bytes, label + ": no no-benefit opening receipt or byte growth")
	idle_windows.append({"label": label, "ticks": ticks, "wall_us": Time.get_ticks_usec() - began,
		"opening_receipts_before": before_receipts, "opening_receipts_after": after_receipts,
		"opening_bytes_before": before_bytes, "opening_bytes_after": after_bytes})


func _point(r, label: String, completed_events: int) -> void:
	r.lane = "analysis_" + label
	var samples: Array = []
	var snapshot: Dictionary = {}
	for index in range(50):
		var began := Time.get_ticks_usec()
		snapshot = r.capture_authoritative_state()
		samples.append(Time.get_ticks_usec() - began)
	var component_bytes := {}
	var component_capture := {}
	for component: String in Snapshot.COMPONENTS:
		component_bytes[component] = var_to_bytes(snapshot.context.components[component]).size()
		var captures: Array = []
		for index in range(50):
			var began := Time.get_ticks_usec()
			Snapshot.capture_data(r.context.get(component))
			captures.append(Time.get_ticks_usec() - began)
		component_capture[component] = _stats(captures)
	var log_types := {}
	for event: Dictionary in r.context.run_event_log.events:
		var type := str(event.event_type)
		var group: Dictionary = log_types.get(type, {"count": 0, "bytes": 0, "max_bytes": 0})
		var bytes := var_to_bytes(event).size()
		group.count += 1
		group.bytes += bytes
		group.max_bytes = maxi(int(group.max_bytes), bytes)
		log_types[type] = group
	points.append({"label": label, "completed_fixture_events": completed_events, "snapshot_bytes": var_to_bytes(snapshot).size(),
		"context_data_bytes": var_to_bytes(snapshot.context.data).size(), "component_bytes": component_bytes,
		"snapshot_us": _stats(samples), "component_capture_us": component_capture, "largest_paths": _largest(snapshot, "", 0),
		"event_types": log_types, "event_count": r.context.run_event_log.size(), "action_receipt_count": r.action_receipts.size(),
		"opening_receipts": r.context.z1_event_flags.z2_opening.get("receipts", {}).size(),
		"checkpoint_bytes": FileAccess.get_file_as_bytes(r.checkpoint_service.checkpoint_path).size(), "hp": r.context.hp})
	print("LOAD_POINT %s bytes=%d events=%d receipts=%d capture_p50_us=%d" % [label, points.back().snapshot_bytes, points.back().event_count, points.back().action_receipt_count, points.back().snapshot_us.p50_us])
	_write()


func _largest(value: Variant, path: String, depth: int) -> Array:
	var rows: Array = []
	if value is Dictionary:
		for key in value:
			rows.append({"path": path + "/" + str(key), "bytes": var_to_bytes(value[key]).size(), "key": key})
	elif value is Array:
		for index in range(value.size()):
			rows.append({"path": path + "/" + str(index), "bytes": var_to_bytes(value[index]).size(), "key": index})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.bytes) > int(b.bytes))
	rows = rows.slice(0, 5)
	var result: Array = []
	for row: Dictionary in rows:
		var record := {"path": row.path, "bytes": row.bytes}
		if depth < 4 and int(row.bytes) > 8192:
			record["children"] = _largest(value[row.key], str(row.path), depth + 1)
		result.append(record)
	return result


func _stats(values: Array) -> Dictionary:
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	var over := 0
	for value in values:
		total += value
		if value > 1000000.0 / 60.0:
			over += 1
	return {"n": values.size(), "mean_us": total / values.size(), "p50_us": sorted[ceili(values.size() * 0.5) - 1],
		"p95_us": sorted[ceili(values.size() * 0.95) - 1], "max_us": sorted.back(), "over_16_667ms": over}


func _write() -> void:
	var summaries := {}
	if measured_runtime != null:
		for label in measured_runtime.samples:
			summaries[label] = _stats(measured_runtime.samples[label])
	var data := {"version": 1, "godot": Engine.get_version_info(), "points": points, "actions": actions,
		"idle_windows": idle_windows, "summary": summaries, "checks": checks, "failures": failures, "stop_reason": stop_reason}
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()
	else:
		failures.append("cannot write measurement artifact: " + output_path)


func _ok(value: Dictionary, label: String) -> bool:
	return _check(bool(value.get("ok", false)), label + ": " + str(value))


func _check(ok: bool, label: String) -> bool:
	checks += 1
	if not ok:
		failures.append(label)
	return ok


func _release(r) -> void:
	r.in_run_runtime.bind(null)
	r.command_bus.item_command_handler.combat_active_query = Callable()
	r.command_bus.bind_runtime_controller(null)
	r.context = null
	r.in_run_runtime = null
	r.command_bus = null
