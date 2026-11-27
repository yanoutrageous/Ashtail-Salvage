extends RefCounted
class_name MetaProgressAdapter

const SaveAdapterScript := preload("res://scripts/core/save/save_adapter.gd")
const SaveProfileManifestScript := preload("res://scripts/core/save/save_profile_manifest.gd")
const RunStateSnapshotScript := preload("res://scripts/core/run/run_state_snapshot.gd")
const M7ContentCatalogScript := preload("res://scripts/core/content/m7_content_catalog.gd")
const M7ProgressionServiceScript := preload("res://scripts/core/progression/m7_progression_service.gd")
const M7TalentCatalogScript := preload("res://scripts/core/progression/m7_talent_catalog.gd")
const Z2Rules := preload("res://scripts/core/progression/z2_progression_rules.gd")
const Z2OpeningOfferScript := preload("res://scripts/core/progression/z2_opening_offer.gd")

const META_ACTION_RECEIPTS_KEY := "meta_action_receipts"
const META_ACTION_RECEIPT_SCHEMA_VERSION := 1
const META_ACTION_RECEIPT_LIMIT := 512
const MAX_BATCH_PURCHASE_QUANTITY := 99

var save_adapter: SaveAdapter = SaveAdapterScript.new()
var data: Dictionary = {}
var last_commit: Dictionary = {}
var last_error: String = ""
var last_load_status: String = ""
var last_load_result: Dictionary = {}
var active_profile_id: String = SaveProfileManifestScript.DEFAULT_PROFILE_ID
var active_meta_progress_path: String = SaveProfileManifestScript.default_meta_progress_path()
var write_blocked: bool = false
var write_block_reason: String = ""
var _meta_action_transaction_active: bool = false
var _meta_action_deferred_save_requested: bool = false
var _debug_fail_next_save := false


func _init() -> void:
	load_or_create_default()


func build_settlement_export(result_snapshot: Dictionary) -> Dictionary:
	return {
		"adapter_id": &"meta_progress_adapter_m1",
		"schema_version": 1,
		"writes_storage": true,
		"settlement": result_snapshot.get("settlement", {}),
		"warehouse_lite": result_snapshot.get("warehouse_lite", []),
		"gold_coin": result_snapshot.get("gold_coin", 0),
		"black_coin": result_snapshot.get("black_coin", 0),
	}


func can_write_persistence() -> bool:
	return not write_blocked


func is_debug_sandbox_profile() -> bool:
	return active_profile_id == SaveProfileManifestScript.DEBUG_SANDBOX_PROFILE_ID


func describe_boundary() -> Dictionary:
	return {
		"adapter_id": &"meta_progress_adapter_m1",
		"writes_storage": can_write_persistence(),
		"scope": &"m1_minimal_meta_progress",
		"profile_id": active_profile_id,
		"path": active_meta_progress_path,
		"legacy_path": SaveAdapter.M1_META_PROGRESS_PATH,
		"write_blocked": write_blocked,
		"write_block_reason": write_block_reason,
	}

func set_active_profile_path(path: String, profile_id: String = SaveProfileManifestScript.DEFAULT_PROFILE_ID) -> void:
	active_profile_id = SaveProfileManifestScript.sanitize_profile_id(profile_id)
	active_meta_progress_path = path if path != "" else SaveProfileManifestScript.profile_paths(active_profile_id).get("meta_progress", SaveProfileManifestScript.default_meta_progress_path())
	# A debug failure injection is scoped to one sandbox profile admission.  A
	# profile switch must clear it before any production path can save.
	_debug_fail_next_save = false
	load_or_create_default()


func debug_inject_next_save_failure() -> Dictionary:
	if not _ensure_debug_sandbox("inject_next_save_failure"):
		return {
			"ok": false,
			"status": &"debug_sandbox_profile_required",
			"reason": last_error,
		}
	_debug_fail_next_save = true
	return {
		"ok": true,
		"status": &"debug_next_save_failure_armed",
		"profile_id": active_profile_id,
	}


func debug_save_failure_armed() -> bool:
	return _debug_fail_next_save and is_debug_sandbox_profile()


func load_or_create_default() -> Dictionary:
	last_error = ""
	var result := save_adapter.load_json_result(active_meta_progress_path, save_adapter.default_meta_progress())
	last_load_result = result.duplicate(true)
	last_load_status = str(result.get("status", ""))
	data = _dictionary_from(result.get("data", save_adapter.default_meta_progress()))
	data[META_ACTION_RECEIPTS_KEY] = _validated_meta_action_receipts(
		data.get(META_ACTION_RECEIPTS_KEY, {})
	)
	write_blocked = bool(result.get("read_only_fallback", false))
	write_block_reason = "meta_progress_read_only_fallback" if write_blocked else ""
	var format_error := SaveAdapterScript.z2_meta_error(data)
	if format_error.is_empty() and data.get("ruleset_id", "") == "z2" and not _restore_terminal_storage():
		format_error = "invalid_terminal_storage"
	if format_error.is_empty() and data.has("ruleset_id") and data.get("profile_id") != active_profile_id:
		format_error = "meta_profile_mismatch"
	if not format_error.is_empty():
		write_blocked = true
		write_block_reason = format_error
	if not bool(result.get("ok", false)):
		last_error = str(result.get("error", save_adapter.last_error))
	return data.duplicate(true)


func initialize_z2_profile(content_version: String = "z2") -> Dictionary:
	if not _ensure_writable("initialize_z2_profile") or content_version.is_empty():
		return {"ok": false, "status": "write_blocked", "error": last_error}
	# An existing file is never guessed to be pristine. The caller selects a new profile.
	for suffix in ["", SaveAdapterScript.LAST_VALID_BACKUP_SUFFIX, SaveAdapterScript.ATOMIC_TEMP_SUFFIX, SaveAdapterScript.CORRUPT_RECOVERY_SUFFIX]:
		if FileAccess.file_exists(active_meta_progress_path + str(suffix)):
			return {"ok": false, "status": "existing_profile_requires_explicit_migration"}
	if last_load_status != "missing":
		return {"ok": false, "status": "profile_not_missing"}
	var previous := data.duplicate(true)
	data = save_adapter.default_meta_progress()
	data.merge({
		"ruleset_id": "z2", "profile_id": active_profile_id, "content_version": content_version,
		"admission": {}, "run_receipts": {}, "checkpoint_cleanup_run_id": "",
	}, true)
	if content_version == Z2Rules.CONTENT_VERSION:
		data.merge(Z2Rules.default_fields(), true)
		M7ProgressionServiceScript.sync_z2_quests(data)
	if not save():
		data = previous
		return {"ok": false, "status": "save_failed", "error": last_error}
	last_load_status = "loaded"
	return {"ok": true, "status": "initialized", "profile_id": active_profile_id}


func reset_as_current_z2_profile() -> Dictionary:
	# Explicitly authorized reset for old game profiles; never reinterpret their old balances.
	if not _ensure_writable("reset_z2_profile") or _meta_action_transaction_active:
		return {"ok": false, "status": "write_blocked"}
	if Z2Rules.applies_to(data):
		return {"ok": true, "status": "already_current"}
	var previous := data.duplicate(true)
	data = save_adapter.default_meta_progress()
	data.merge({"ruleset_id": "z2", "profile_id": active_profile_id, "content_version": Z2Rules.CONTENT_VERSION,
		"admission": {}, "run_receipts": {}, "checkpoint_cleanup_run_id": ""}, true)
	data.merge(Z2Rules.default_fields(), true)
	M7ProgressionServiceScript.sync_z2_quests(data)
	data["reset_checkpoint_pending"] = true
	if not save():
		data = previous
		return {"ok": false, "status": "save_failed", "error": last_error}
	last_load_status = "loaded"
	return {"ok": true, "status": "reset_as_new_profile"}


func begin_tutorial_training() -> Dictionary:
	if not _ensure_writable("begin_tutorial_training") or not Z2Rules.applies_to(data):
		return {"ok": false, "status": "current_profile_required"}
	if data.get("tutorial_completed", false) or data.get("tutorial_purchase_available", false):
		return {"ok": true, "status": "already_started"}
	var previous := data.duplicate(true)
	data["tutorial_purchase_available"] = true
	if not save():
		data = previous
		return {"ok": false, "status": "save_failed", "error": last_error}
	return {"ok": true, "status": "teaching_purchase_available"}


func purchase_tutorial_flag() -> Dictionary:
	if not Z2Rules.applies_to(data) or data.get("tutorial_completed", false):
		return {"ok": false, "status": "teaching_profile_required"}
	var previous := data.duplicate(true)
	data["tutorial_purchase_available"] = true
	var result := unlock_talent("z2_talent_01")
	if not result.get("ok", false):
		data = previous
	return result


func initial_supply_items() -> Array[Dictionary]:
	# S4 rows 21/22; user selected the two cheapest tier-1 supplies on 2026-11-16.
	var items: Array[Dictionary] = []
	for item_id in ["con_ration", "con_tape_roll"]:
		var item := Z2ItemCatalog.definition(item_id)
		item["quantity"] = 1
		items.append(item)
	return items


func claim_initial_supplies() -> Dictionary:
	if not _ensure_writable("claim_initial_supplies") or not Z2Rules.applies_to(data):
		return {"ok": false, "status": "current_profile_required"}
	if not data.get("tutorial_completed", false) or int(data.get("profile_level", 0)) < 1:
		return {"ok": false, "status": "tutorial_required"}
	if not data.get("admission", {}).is_empty():
		return {"ok": false, "status": "active_run_locked"}
	if not data.get("initial_supply_receipt", {}).is_empty():
		return {"ok": true, "status": "already_claimed", "duplicate": true}
	var previous := data.duplicate(true)
	var instance_ids: Array[String] = []
	for definition in initial_supply_items():
		var item := definition.duplicate(true)
		item["instance_id"] = "z2_initial:%s:%s" % [active_profile_id, item.item_id]
		item["source"] = "z2_initial_supplies"
		item["source_label"] = "首次申领"
		item["location_state"] = "warehouse"
		(data.warehouse_items as Array).append(item)
		instance_ids.append(item.instance_id)
	data["initial_supply_receipt"] = {"id": "z2_initial_supplies", "instance_ids": instance_ids}
	if not save():
		data = previous
		return {"ok": false, "status": "save_failed", "error": last_error, "rolled_back": true}
	return {"ok": true, "status": "claimed", "instance_ids": instance_ids}


func reserved_instance_ids() -> Array:
	var admission := _dictionary_from(data.get("admission", {}))
	return _array_from(admission.get("reserved_instance_ids", []))


func commit_admission(admission: Dictionary) -> Dictionary:
	if not _ensure_writable("commit_admission") or data.get("ruleset_id", "") != "z2" or _meta_action_transaction_active:
		return {"ok": false, "status": "write_blocked", "error": last_error}
	var previous := data.duplicate(true)
	var prepared := prepare_run_admission(admission)
	if not prepared.get("ok", false):
		return prepared
	data = prepared.meta
	data["admission"] = admission.duplicate(true)
	data["checkpoint_cleanup_run_id"] = ""
	if not save():
		data = previous
		return {"ok": false, "status": "save_failed", "error": last_error}
	return {"ok": true, "status": str(admission.get("phase", "")),
		"departure_sequence": int(prepared.get("departure_sequence", 0)), "z2_fact_sequence_base": int(prepared.get("base", 0))}


# Candidate only; commit_admission persists reservation and admission in one write.
func prepare_run_admission(admission: Dictionary) -> Dictionary:
	var candidate := data.duplicate(true)
	if not Z2Rules.applies_to(data):
		return {"ok": true, "meta": candidate}
	var run_id := str(admission.get("run_id", ""))
	var reservations: Dictionary = candidate.get("z2_quest_departures", {})
	if reservations.has(run_id):
		var prior: Dictionary = reservations[run_id]
		if prior.get("initial_snapshot_hash", "") != admission.get("initial_snapshot_hash", ""):
			return {"ok": false, "status": "quest_departure_receipt_conflict"}
		return {"ok": true, "meta": candidate, "base": int(prior.base), "departure_sequence": int(prior.departure_sequence)}
	var unpacked := RunStateSnapshotScript.unpack_checkpoint(admission.get("initial_snapshot", {}).get("state", {}))
	if not unpacked.get("ok", false):
		return {"ok": false, "status": "quest_departure_snapshot_missing"}
	var context := _dictionary_from(unpacked.get("state", {}).get("context", {}).get("data", {}))
	var start := _dictionary_from(context.get("run_start_config", {}))
	if start.get("map_config_id", "") == "tutorial_5x5" or context.get("mode", "") == "tutorial":
		return {"ok": true, "meta": candidate}
	if run_id.is_empty() or admission.get("phase", "") != "prepared" or not data.get("admission", {}).is_empty():
		return {"ok": false, "status": "quest_departure_admission_conflict"}
	var profile := _dictionary_from(start.get("profile_fields", {}))
	var base := int(data.get("z2_fact_sequence", 0))
	if not profile.has("z2_fact_sequence_base") or int(profile.z2_fact_sequence_base) != base:
		return {"ok": false, "status": "quest_departure_sequence_base_missing_or_stale"}
	if start.has("departure_sequence") and int(start.departure_sequence) != base + 1:
		return {"ok": false, "status": "quest_departure_sequence_conflict"}
	reservations[run_id] = {"base": base, "departure_sequence": base + 1, "initial_snapshot_hash": str(admission.get("initial_snapshot_hash", ""))}
	candidate["z2_quest_departures"] = reservations
	candidate["z2_fact_sequence"] = base + 1
	candidate["z2_goals"]["fact_sequence"] = base + 1
	return {"ok": true, "meta": candidate, "base": base, "departure_sequence": base + 1}


func save() -> bool:
	if not _ensure_writable("save"):
		return false
	if _meta_action_transaction_active:
		_meta_action_deferred_save_requested = true
		last_error = ""
		return true
	var ok := _save_now()
	last_error = save_adapter.last_error
	return ok


func execute_idempotent_meta_action(
	request_id: String,
	payload: Dictionary,
	operation: Callable
) -> Dictionary:
	if data.is_empty():
		load_or_create_default()
	var exact_request_id := request_id.strip_edges()
	if exact_request_id.is_empty():
		return _meta_action_transaction_result(&"invalid_request_id")
	if not operation.is_valid():
		return _meta_action_transaction_result(&"invalid_operation")
	var fingerprint := _meta_action_fingerprint(payload)
	if fingerprint.is_empty():
		return _meta_action_transaction_result(&"invalid_payload")
	var receipts := _validated_meta_action_receipts(data.get(META_ACTION_RECEIPTS_KEY, {}))
	if receipts.has(exact_request_id):
		var receipt := _dictionary_from(receipts.get(exact_request_id, {}))
		if str(receipt.get("fingerprint", "")) != fingerprint:
			return _meta_action_transaction_result(&"request_id_conflict")
		var duplicate_result := _dictionary_from(receipt.get("result", {}))
		duplicate_result["summary"] = get_summary()
		return _meta_action_transaction_result(&"duplicate", duplicate_result)
	if _meta_action_transaction_active:
		return _meta_action_transaction_result(&"transaction_in_progress")
	if not _ensure_writable("execute_idempotent_meta_action"):
		return _meta_action_transaction_result(
			&"write_blocked",
			{"ok": false, "status": &"write_blocked", "reason": write_block_reason}
		)

	var previous_data := data.duplicate(true)
	_meta_action_transaction_active = true
	_meta_action_deferred_save_requested = false
	var raw_result: Variant = operation.call()
	_meta_action_transaction_active = false
	var adapter_result := _dictionary_from(raw_result)
	if adapter_result.is_empty():
		data = previous_data
		_meta_action_deferred_save_requested = false
		return _meta_action_transaction_result(
			&"invalid_result",
			{"ok": false, "status": &"invalid_meta_action_result"}
		)
	if not _meta_action_deferred_save_requested:
		return _meta_action_transaction_result(&"executed", adapter_result)

	receipts = _validated_meta_action_receipts(data.get(META_ACTION_RECEIPTS_KEY, {}))
	receipts[exact_request_id] = {
		"schema_version": META_ACTION_RECEIPT_SCHEMA_VERSION,
		"committed_sequence": _next_meta_action_receipt_sequence(receipts),
		"fingerprint": fingerprint,
		"result": _meta_action_receipt_result(adapter_result),
	}
	data[META_ACTION_RECEIPTS_KEY] = _validated_meta_action_receipts(receipts)
	_meta_action_deferred_save_requested = false
	if _save_now():
		last_error = save_adapter.last_error
		adapter_result["summary"] = get_summary()
		return _meta_action_transaction_result(&"executed", adapter_result)

	data = previous_data
	last_error = save_adapter.last_error
	var failed_result := adapter_result.duplicate(true)
	failed_result["ok"] = false
	failed_result["status"] = &"save_failed"
	failed_result["rolled_back"] = true
	failed_result["error"] = last_error
	failed_result["summary"] = get_summary()
	return _meta_action_transaction_result(&"persistence_failed", failed_result)


func clear() -> Dictionary:
	if data.has("ruleset_id"):
		last_error = "z2_profile_clear_requires_explicit_migration"
		return get_summary()
	if not _ensure_writable("clear"):
		return get_summary()
	data = save_adapter.default_meta_progress()
	save()
	return get_summary()


func apply_settlement(result_snapshot: Dictionary) -> Dictionary:
	if data.get("ruleset_id", "") == "z2":
		return _quest_action_result(_apply_z2_settlement(result_snapshot))
	return _apply_legacy_settlement(result_snapshot)


func _apply_z2_settlement(result_snapshot: Dictionary) -> Dictionary:
	if not _ensure_writable("apply_settlement") or _meta_action_transaction_active:
		return {"ok": false, "status": "write_blocked", "error": last_error}
	var run_id := str(result_snapshot.get("run_id", ""))
	if run_id.is_empty() or str(result_snapshot.get("profile_id", active_profile_id)) != active_profile_id:
		return {"ok": false, "status": "settlement_reference_mismatch"}
	var payload: Variant = _json_safe(result_snapshot)
	var fingerprint := SaveAdapterScript.json_fingerprint(payload)
	var fingerprint_encoding := "json"
	if fingerprint.is_empty() and _is_lossless_terminal_payload(payload):
		fingerprint = SaveAdapterScript.json_fingerprint(RunStateSnapshotScript.encode(payload))
		fingerprint_encoding = "run_state_snapshot_v1"
	if fingerprint.is_empty():
		return {"ok": false, "status": "invalid_settlement_payload"}
	var receipts := _dictionary_from(data.get("run_receipts", {}))
	if receipts.has(run_id):
		var receipt := _dictionary_from(receipts[run_id])
		if receipt.get("fingerprint", "") != fingerprint or receipt.get("fingerprint_encoding", "json") != fingerprint_encoding:
			return {"ok": false, "status": "run_receipt_conflict", "run_id": run_id}
		return _dictionary_from(receipt.get("result", {}))
	var admission := _dictionary_from(data.get("admission", {}))
	if admission.get("phase", "") != "active" or admission.get("run_id", "") != run_id:
		return {"ok": false, "status": "active_admission_required"}
	var settlement := _dictionary_from(result_snapshot.get("settlement", {}))
	if bool(settlement.get("requires_salvage_selection", false)) and not bool(settlement.get("finalized", false)):
		return {"ok": false, "status": "awaiting_salvage_selection", "run_id": run_id}
	var outcome := str(result_snapshot.get("outcome", settlement.get("outcome", "")))
	if outcome not in ["Extracted", "Training Complete", "Failed", "Abandoned"] and settlement.get("outcome", "") not in ["success", "failure", "abandon"]:
		return {"ok": false, "status": "terminal_outcome_required"}
	var previous := data.duplicate(true)
	# Reuse legacy reward logic, but defer its save until the receipt and release are included.
	_meta_action_transaction_active = true
	_meta_action_deferred_save_requested = false
	var result := _apply_legacy_settlement(result_snapshot)
	_meta_action_transaction_active = false
	_meta_action_deferred_save_requested = false
	if not bool(result.get("ok", false)):
		data = previous
		return result
	data["admission"] = {}
	data["checkpoint_cleanup_run_id"] = run_id
	result.erase("summary")
	result = _dictionary_from(_json_safe(result))
	receipts[run_id] = {
		"schema_version": 1, "profile_id": active_profile_id, "run_id": run_id,
		"fingerprint": fingerprint, "result": result.duplicate(true),
	}
	if fingerprint_encoding != "json":
		receipts[run_id]["fingerprint_encoding"] = fingerprint_encoding
	data["run_receipts"] = receipts
	if not _save_now():
		data = previous
		return {"ok": false, "status": "save_failed", "error": last_error, "rolled_back": true}
	last_commit = result.duplicate(true)
	return result.duplicate(true)


func _is_lossless_terminal_payload(value: Variant, depth: int = 0) -> bool:
	if depth > 96:
		return false
	if value is int:
		return true
	if value is Dictionary:
		for key in value:
			if not key is String or not _is_lossless_terminal_payload(value[key], depth + 1):
				return false
		return true
	if value is Array:
		for entry in value:
			if not _is_lossless_terminal_payload(entry, depth + 1):
				return false
		return true
	return SaveAdapterScript.is_json_safe(value)


func _apply_legacy_settlement(result_snapshot: Dictionary) -> Dictionary:
	if data.is_empty():
		load_or_create_default()
	if (
		_result_uses_debug(result_snapshot)
		and active_profile_id != SaveProfileManifestScript.DEBUG_SANDBOX_PROFILE_ID
	):
		last_commit = {
			"ok": false,
			"status": "debug_tainted_production_profile_blocked",
			"reason": "debug_tainted_production_profile_blocked",
			"result_id": _result_id(result_snapshot),
			"profile_id": active_profile_id,
			"required_profile_id": SaveProfileManifestScript.DEBUG_SANDBOX_PROFILE_ID,
			"summary": get_summary(),
		}
		return last_commit.duplicate(true)
	if not _ensure_writable("apply_settlement"):
		last_commit = {
			"ok": false,
			"status": "write_blocked",
			"reason": write_block_reason,
			"result_id": _result_id(result_snapshot),
			"summary": get_summary(),
			"error": last_error,
		}
		return last_commit.duplicate(true)
	var result_id := _result_id(result_snapshot)
	if _is_tutorial_result(result_snapshot):
		return _apply_tutorial_settlement(result_snapshot, result_id)
	var committed_ids: Array = _array_from(data.get("committed_result_ids", []))
	if result_id in committed_ids and data.get("ruleset_id", "") != "z2":
		last_commit = {
			"ok": true,
			"status": "duplicate_ignored",
			"duplicate": true,
			"result_id": result_id,
			"summary": get_summary(),
		}
		return last_commit.duplicate(true)

	var previous_data := data.duplicate(true)
	var settlement: Dictionary = _dictionary_from(result_snapshot.get("settlement", {}))
	if bool(settlement.get("requires_salvage_selection", false)) and not bool(settlement.get("finalized", false)):
		last_commit = {
			"ok": false,
			"status": "awaiting_salvage_selection",
			"reason": "failure_settlement_not_finalized",
			"result_id": result_id,
			"summary": get_summary(),
		}
		return last_commit.duplicate(true)
	var outcome := str(result_snapshot.get("outcome", settlement.get("outcome", "")))
	var settlement_outcome := str(settlement.get("outcome", ""))
	var is_success := outcome == "Extracted" or outcome == "Training Complete" or settlement_outcome == "success"
	var is_failure := outcome == "Failed" or settlement_outcome == "failure"
	var is_abandon := outcome == "Abandoned" or settlement_outcome == "abandon"
	var warehouse_items: Array = _array_from(data.get("warehouse_items", []))
	warehouse_items = _remove_carry_in_items(warehouse_items, result_snapshot)

	data["run_count"] = int(data.get("run_count", 0)) + 1
	if is_success:
		data["extract_count"] = int(data.get("extract_count", 0)) + 1
		data["gold"] = int(data.get("gold", 0)) + _settlement_gold(result_snapshot, settlement)
		for item in _array_from(settlement.get("warehouse_lite", result_snapshot.get("warehouse_lite", []))):
			_upsert_warehouse_item(warehouse_items, _minimal_item_record(item))
		data["warehouse_items"] = warehouse_items
	elif is_failure:
		data["fail_count"] = int(data.get("fail_count", 0)) + 1
		data["gold"] = int(data.get("gold", 0)) + _settlement_gold(result_snapshot, settlement)
		var salvage: Array = _array_from(settlement.get("salvaged_items", []))
		if salvage.is_empty():
			var failure_salvage: Dictionary = _dictionary_from(result_snapshot.get("failure_salvage", {}))
			salvage = _array_from(failure_salvage.get("salvaged_items", []))
		if not salvage.is_empty():
			for item in salvage:
				_upsert_warehouse_item(warehouse_items, _minimal_item_record(item))
			data["warehouse_items"] = warehouse_items
		else:
			data["warehouse_items"] = warehouse_items
	elif is_abandon:
		data["abandon_count"] = int(data.get("abandon_count", 0)) + 1
		data["gold"] = int(data.get("gold", 0)) + _settlement_gold(result_snapshot, settlement)
		var event_delivery := _dictionary_from(settlement.get("event_item_delivery", {}))
		var delivered: Array = _array_from(settlement.get("warehouse_items", [])) if Z2Rules.applies_to(data) else _array_from(event_delivery.get("delivered", settlement.get("warehouse_items", [])))
		for item in delivered:
			_upsert_warehouse_item(warehouse_items, _minimal_item_record(item))
		data["warehouse_items"] = warehouse_items
	if is_success or is_failure or is_abandon:
		var history_records: Array = _array_from(data.get("history_records", []))
		history_records.append(_history_record(result_id, outcome, result_snapshot, settlement))
		while history_records.size() > 50:
			history_records.pop_front()
		data["history_records"] = history_records
	var m7_progression_delta := M7ProgressionServiceScript.apply_settlement(data, result_snapshot) if is_success or is_failure or is_abandon else {}
	if Z2Rules.applies_to(data) and m7_progression_delta.has("ok") and not bool(m7_progression_delta.ok):
		data = previous_data
		return {"ok": false, "status": "quest_progression_rejected", "reason": str(m7_progression_delta.get("reason", "")), "rolled_back": true}
	var run_debug_commands: Array = _array_from(result_snapshot.get("debug_commands", []))
	if not run_debug_commands.is_empty():
		for debug_entry in run_debug_commands:
			var debug_record: Dictionary = _dictionary_from(debug_entry)
			_record_debug_marker("run_%s" % str(debug_record.get("command", "debug_command")), _dictionary_from(debug_record.get("payload", debug_record)))
	elif bool(result_snapshot.get("debug_command_used", false)):
		var command: Dictionary = _dictionary_from(result_snapshot.get("result_source_command", {}))
		_record_debug_marker(str(command.get("command_name", "debug_result")), _dictionary_from(command.get("payload", {})))
	committed_ids.append(result_id)
	data["committed_result_ids"] = committed_ids
	var saved := save()
	if not saved:
		data = previous_data
	last_commit = {
		"ok": saved,
		"status": "committed" if saved else "save_failed",
		"duplicate": false,
		"result_id": result_id,
		"outcome": outcome,
		"m7_progression_delta": m7_progression_delta.duplicate(true),
		"summary": get_summary(),
		"error": last_error,
	}
	return last_commit.duplicate(true)


func get_summary() -> Dictionary:
	if data.is_empty():
		load_or_create_default()
	M7ProgressionServiceScript.sync_z2_quests(data)
	var warehouse_items: Array = _array_from(data.get("warehouse_items", []))
	var reserved_ids := reserved_instance_ids()
	var reserved_items: Array = []
	var available_items: Array = []
	for raw_item in warehouse_items:
		if reserved_ids.has(str(_dictionary_from(raw_item).get("instance_id", ""))):
			reserved_items.append(raw_item)
		else:
			available_items.append(raw_item)
	warehouse_items = available_items
	var summary := {
		"schema_version": int(data.get("schema_version", 1)),
		"gold": int(data.get("gold", 0)),
		"long_term_gold": int(data.get("gold", 0)),
		"warehouse_items_count": warehouse_items.size(),
		"warehouse_items": warehouse_items.duplicate(true),
		"reserved_instance_ids": reserved_ids,
		"reserved_warehouse_items": reserved_items,
		"admission": _dictionary_from(data.get("admission", {})),
		"ruleset_id": str(data.get("ruleset_id", "")),
		"content_version": str(data.get("content_version", "")),
		"history_records": _array_from(data.get("history_records", [])),
		"history_record_count": _array_from(data.get("history_records", [])).size(),
		"profile_level": maxi(0 if Z2Rules.applies_to(data) else 1, int(data.get("profile_level", 1))),
		"profile_exp": maxi(0, int(data.get("profile_exp", 0))),
		"permit_level": maxi(1, int(data.get("permit_level", 1))),
		"protocol_difficulty": maxi(1, int(data.get("protocol_difficulty", 5))),
		"talent_points": maxi(0, int(data.get("talent_points", 0))),
		"talent_flags": _array_from(data.get("talent_flags", [])),
		"talent_budget_granted": maxi(0, int(data.get("talent_budget_granted", 0))),
		"talent_catalog_version": maxi(0, int(data.get("talent_catalog_version", 0))),
		"tutorial_completed": bool(data.get("tutorial_completed", false)),
		"tutorial_completion_receipt": _dictionary_from(data.get("tutorial_completion_receipt", {})),
		"run_count": int(data.get("run_count", 0)),
		"extract_count": int(data.get("extract_count", 0)),
		"fail_count": int(data.get("fail_count", 0)),
		"abandon_count": int(data.get("abandon_count", 0)),
		"debug_used": bool(data.get("debug_used", false)),
		"debug_commands": _array_from(data.get("debug_commands", [])),
		"last_commit": last_commit.duplicate(true),
		"last_load_status": last_load_status,
		"write_blocked": write_blocked,
		"write_block_reason": write_block_reason,
		"profile_id": active_profile_id,
		"last_error": last_error,
		"path": active_meta_progress_path,
	}
	for key in [
		"unlocked_map_ids", "map_success_counts", "commission_history", "task_states", "achievement_states",
		"research_completed_ids", "codex_discoveries", "unread_codex_ids", "collection_discoveries",
		"completed_collection_set_ids", "unread_collection_set_ids", "unread_history_ids", "event_completion_counts",
		"purchased_instance_ids", "claimed_reward_ids", "granted_reward_ids", "titles", "badges", "red_dot_state",
		"player_appearance",
	]:
		var value: Variant = data.get(key, [])
		summary[key] = value.duplicate(true) if value is Array or value is Dictionary else value
	for key in ["z2_progression_version", "talent_earned", "talent_spent"]:
		summary[key] = int(data.get(key, 0))
	summary["tutorial_purchase_available"] = bool(data.get("tutorial_purchase_available", false))
	summary["initial_supply_receipt"] = _dictionary_from(data.get("initial_supply_receipt", {}))
	summary["map_catalog"] = _m7_map_catalog()
	summary["shop_catalog"] = _m7_shop_catalog()
	summary["research_catalog"] = _m7_research_catalog()
	summary["talent_catalog"] = M7TalentCatalogScript.projection(data)
	summary["talent_summary"] = M7TalentCatalogScript.summary(data)
	summary["task_definitions"] = M7ContentCatalogScript.task_definitions(data) + M7ContentCatalogScript.optional_task_definitions(data)
	summary["achievement_definitions"] = M7ContentCatalogScript.achievement_definitions(data)
	summary["collection_sets"] = M7ContentCatalogScript.collection_sets()
	if Z2Rules.applies_to(data):
		summary["initial_supply_items"] = initial_supply_items()
		summary["z2_fact_sequence"] = int(data.get("z2_fact_sequence", 0))
		summary["z2_fact_sequence_base"] = int(data.get("z2_fact_sequence", 0))
		summary["z2_quest_fact_cursor"] = int(data.get("z2_goals", {}).get("fact_sequence", 0))
		summary["z2_opening_offer"] = _dictionary_from(data.get("z2_opening_offer", {})).duplicate(true)
	return summary


func purchase_item(item_id: String, source: String = "m7_base_shop") -> Dictionary:
	var result := purchase_items(item_id, 1, source)
	if bool(result.get("ok", false)):
		var items: Array = _array_from(result.get("items", []))
		result["status"] = "purchased"
		result["item"] = _dictionary_from(items[0]) if not items.is_empty() else {}
		result["price"] = int(result.get("unit_price", 0))
	return result


func purchase_items(
	item_id: String,
	quantity: int,
	source: String = "m7_base_shop"
) -> Dictionary:
	if not _ensure_writable("purchase_items"):
		return {"ok": false, "status": "write_blocked", "reason": write_block_reason}
	if _z2_quest_lobby_blocked():
		return {"ok": false, "status": "active_run_lobby_action_blocked"}
	if quantity < 1 or quantity > MAX_BATCH_PURCHASE_QUANTITY:
		return {
			"ok": false,
			"status": "invalid_quantity",
			"item_id": item_id,
			"quantity": quantity,
			"minimum": 1,
			"maximum": MAX_BATCH_PURCHASE_QUANTITY,
		}
	var normalized := M7ProgressionServiceScript.normalize_meta(data)
	var shop := M7ContentCatalogScript.shop_definition(item_id, normalized)
	if shop.is_empty():
		return {"ok": false, "status": "unknown_shop_item", "item_id": item_id}
	if not M7ContentCatalogScript.is_shop_unlocked(shop, normalized):
		return {"ok": false, "status": "locked", "item_id": item_id}
	var unit_price := maxi(0, int(shop.get("price", 0)))
	var total_price := unit_price * quantity
	var gold_before := int(normalized.get("gold", 0))
	if gold_before < total_price:
		return {
			"ok": false,
			"status": "insufficient_gold",
			"item_id": item_id,
			"quantity": quantity,
			"unit_price": unit_price,
			"total_price": total_price,
			"gold_before": gold_before,
		}
	var previous_data := data.duplicate(true)
	data = normalized
	data["gold"] = gold_before - total_price
	var purchased: Array = data.get("purchased_instance_ids", [])
	var created_items: Array[Dictionary] = []
	var created_ids: Array[String] = []
	for _index in range(quantity):
		var item := M7ProgressionServiceScript.add_item_instance(data, item_id, source)
		if item.is_empty():
			data = previous_data
			return {
				"ok": false,
				"status": "item_definition_missing",
				"item_id": item_id,
				"quantity": quantity,
				"created_count": 0,
				"rolled_back": true,
			}
		var instance_id := str(item.get("instance_id", ""))
		var existing_id := false
		for existing in _array_from(previous_data.get("warehouse_items", [])):
			if str(_dictionary_from(existing).get("instance_id", "")) == instance_id:
				existing_id = true
				break
		if instance_id.is_empty() or created_ids.has(instance_id) or existing_id or reserved_instance_ids().has(instance_id):
			data = previous_data
			return {
				"ok": false,
				"status": "duplicate_generated_instance_id",
				"item_id": item_id,
				"quantity": quantity,
				"created_count": 0,
				"rolled_back": true,
			}
		created_items.append(item)
		created_ids.append(instance_id)
		if not purchased.has(instance_id):
			purchased.append(instance_id)
	data["purchased_instance_ids"] = purchased
	if Z2Rules.applies_to(data):
		var fact := M7ProgressionServiceScript.record_z2_lobby_fact(data, "item_purchased", {"items": created_items}, "purchase:" + str(created_ids[0]))
		if not bool(fact.ok):
			data = previous_data
			return fact
	M7ProgressionServiceScript.refresh_red_dots(data)
	if not save():
		data = previous_data
		return {
			"ok": false,
			"status": "save_failed",
			"item_id": item_id,
			"quantity": quantity,
			"created_count": 0,
			"rolled_back": true,
			"error": last_error,
			"summary": get_summary(),
		}
	var result := {
		"ok": true,
		"status": "purchased" if quantity == 1 else "batch_purchased",
		"atomicity": &"all_or_nothing",
		"item_id": item_id,
		"quantity": quantity,
		"created_count": created_items.size(),
		"items": created_items,
		"instance_ids": created_ids,
		"unit_price": unit_price,
		"total_price": total_price,
		"gold_before": gold_before,
		"gold_after": int(data.get("gold", 0)),
		"summary": get_summary(),
	}
	if quantity == 1:
		result["item"] = created_items[0].duplicate(true)
		result["price"] = unit_price
	return _quest_action_result(result, previous_data)


func sell_collectible(instance_id: String, blocked_instance_ids: Array = []) -> Dictionary:
	if not _ensure_writable("sell_collectible"):
		return {"ok": false, "status": "write_blocked", "reason": write_block_reason}
	if _z2_quest_lobby_blocked():
		return {"ok": false, "status": "active_run_lobby_action_blocked"}
	if blocked_instance_ids.has(instance_id) or reserved_instance_ids().has(instance_id):
		return {"ok": false, "status": "configured_item_blocked", "instance_id": instance_id}
	var items: Array = _array_from(data.get("warehouse_items", []))
	var index := -1
	var item := {}
	for item_index in range(items.size()):
		var candidate := _dictionary_from(items[item_index])
		if str(candidate.get("instance_id", "")) == instance_id:
			index = item_index
			item = candidate
			break
	if index < 0:
		return {"ok": false, "status": "instance_not_found", "instance_id": instance_id}
	if str(item.get("item_type", "")) != "collectible" or not bool(item.get("can_sell", false)) or bool(item.get("is_unique", false)):
		return {"ok": false, "status": "item_not_sellable", "instance_id": instance_id}
	var previous_data := data.duplicate(true)
	var value := maxi(0, int(item.get("base_value", item.get("value", 0))))
	items.remove_at(index)
	data["warehouse_items"] = items
	data["gold"] = int(data.get("gold", 0)) + value
	if Z2Rules.applies_to(data):
		var fact := M7ProgressionServiceScript.record_z2_lobby_fact(data, "item_sold", {"items": [item]}, "sale:" + instance_id)
		if not bool(fact.ok):
			data = previous_data
			return fact
	M7ProgressionServiceScript.refresh_red_dots(data)
	if not save():
		data = previous_data
		return {"ok": false, "status": "save_failed", "instance_id": instance_id, "error": last_error}
	return _quest_action_result({"ok": true, "status": "sold", "instance_id": instance_id, "gold_gained": value, "summary": get_summary()}, previous_data)


func sell_collectibles_batch(instance_ids: Array, blocked_instance_ids: Array = []) -> Dictionary:
	if _z2_quest_lobby_blocked():
		return {"ok": false, "status": "active_run_lobby_action_blocked"}
	if not _ensure_writable("sell_collectibles_batch"):
		return {
			"ok": false,
			"status": "write_blocked",
			"reason": write_block_reason,
			"atomicity": &"all_or_nothing",
		}
	var requested_ids := _normalized_instance_ids(instance_ids)
	if requested_ids.is_empty():
		return {
			"ok": false,
			"status": "empty_batch",
			"atomicity": &"all_or_nothing",
			"requested_instance_ids": [],
			"item_failures": [],
			"summary": get_summary(),
		}
	var blocked_lookup := {}
	for blocked_id in _normalized_instance_ids(blocked_instance_ids + reserved_instance_ids()):
		blocked_lookup[blocked_id] = true
	var items: Array = _array_from(data.get("warehouse_items", []))
	var item_by_id := {}
	var duplicate_ids := {}
	for raw_item in items:
		var warehouse_item := _dictionary_from(raw_item)
		var warehouse_instance_id := str(warehouse_item.get("instance_id", "")).strip_edges()
		if warehouse_instance_id.is_empty():
			continue
		if item_by_id.has(warehouse_instance_id):
			duplicate_ids[warehouse_instance_id] = true
			continue
		item_by_id[warehouse_instance_id] = warehouse_item
	var item_failures: Array[Dictionary] = []
	var sale_items: Array[Dictionary] = []
	for instance_id in requested_ids:
		var reason_code := &""
		var item := _dictionary_from(item_by_id.get(instance_id, {}))
		if item.is_empty():
			reason_code = &"instance_not_found"
		elif duplicate_ids.has(instance_id):
			reason_code = &"duplicate_instance_record"
		elif blocked_lookup.has(instance_id):
			reason_code = &"configured_item_blocked"
		elif (
			str(item.get("item_type", "")) != "collectible"
			or not bool(item.get("can_sell", false))
			or bool(item.get("is_unique", false))
		):
			reason_code = &"item_not_sellable"
		if reason_code != &"":
			item_failures.append({"instance_id": instance_id, "reason_code": reason_code})
			continue
		sale_items.append(item)
	if not item_failures.is_empty():
		return {
			"ok": false,
			"status": "batch_validation_failed",
			"atomicity": &"all_or_nothing",
			"requested_instance_ids": requested_ids,
			"validated_count": sale_items.size(),
			"item_failures": item_failures,
			"gold_gained": 0,
			"summary": get_summary(),
		}

	var previous_data := data.duplicate(true)
	var sold_lookup := {}
	var total_value := 0
	var item_results: Array[Dictionary] = []
	for sale_item in sale_items:
		var instance_id := str(sale_item.get("instance_id", ""))
		var value := maxi(0, int(sale_item.get("base_value", sale_item.get("value", 0))))
		sold_lookup[instance_id] = true
		total_value += value
		item_results.append({"instance_id": instance_id, "gold_gained": value})
	var remaining_items: Array = []
	for raw_item in items:
		var warehouse_item := _dictionary_from(raw_item)
		if not sold_lookup.has(str(warehouse_item.get("instance_id", ""))):
			remaining_items.append(warehouse_item)
	var gold_before := int(data.get("gold", 0))
	data["warehouse_items"] = remaining_items
	data["gold"] = gold_before + total_value
	if Z2Rules.applies_to(data):
		var fact := M7ProgressionServiceScript.record_z2_lobby_fact(data, "item_sold", {"items": sale_items}, "sale:" + ",".join(requested_ids))
		if not bool(fact.ok):
			data = previous_data
			return fact
	M7ProgressionServiceScript.refresh_red_dots(data)
	if not save():
		data = previous_data
		return {
			"ok": false,
			"status": "save_failed",
			"atomicity": &"all_or_nothing",
			"rolled_back": true,
			"requested_instance_ids": requested_ids,
			"sold_instance_ids": [],
			"gold_gained": 0,
			"error": last_error,
			"summary": get_summary(),
		}
	return _quest_action_result({
		"ok": true,
		"status": "batch_sold",
		"atomicity": &"all_or_nothing",
		"requested_instance_ids": requested_ids,
		"sold_instance_ids": requested_ids.duplicate(),
		"sold_count": requested_ids.size(),
		"gold_before": gold_before,
		"gold_after": int(data.get("gold", 0)),
		"gold_gained": total_value,
		"item_results": item_results,
		"summary": get_summary(),
	}, previous_data)


func unlock_talent(talent_id: String) -> Dictionary:
	if _z2_quest_lobby_blocked() and talent_id != "z2_talent_01":
		return {"ok": false, "status": "active_run_lobby_action_blocked", "talent_id": talent_id}
	if not _ensure_writable("unlock_talent"):
		return {"ok": false, "status": "write_blocked", "reason": write_block_reason, "talent_id": talent_id}
	var previous_data := data.duplicate(true)
	M7TalentCatalogScript.sync_progress(data)
	var evaluation := M7TalentCatalogScript.unlock_evaluation(data, talent_id)
	if not bool(evaluation.get("ok", false)):
		data = previous_data
		evaluation["summary"] = get_summary()
		return evaluation
	if StringName(evaluation.get("status", &"")) == &"talent_already_unlocked":
		data = previous_data
		evaluation["summary"] = get_summary()
		return evaluation
	var cost := maxi(1, int(evaluation.get("cost", 1)))
	var flags: Array = _array_from(data.get("talent_flags", []))
	data["talent_points"] = maxi(0, int(data.get("talent_points", 0)) - cost)
	if Z2Rules.applies_to(data):
		data["talent_spent"] = int(data.get("talent_spent", 0)) + cost
	if not flags.has(talent_id):
		flags.append(talent_id)
	data["talent_flags"] = flags
	M7TalentCatalogScript.sync_progress(data)
	if Z2Rules.applies_to(data) and talent_id != "z2_talent_01":
		var fact := M7ProgressionServiceScript.record_z2_lobby_fact(data, "talent_unlocked", {"talent_id": talent_id}, "talent:" + talent_id)
		if not bool(fact.ok):
			data = previous_data
			return fact
	M7ProgressionServiceScript.sync_z2_quests(data)
	M7ProgressionServiceScript.refresh_red_dots(data)
	if not save():
		data = previous_data
		return {
			"ok": false,
			"status": "save_failed",
			"talent_id": talent_id,
			"cost": cost,
			"rolled_back": true,
			"error": last_error,
			"summary": get_summary(),
		}
	return _quest_action_result({
		"ok": true,
		"status": "talent_unlocked",
		"talent_id": talent_id,
		"cost": cost,
		"talent_points_remaining": maxi(0, int(data.get("talent_points", 0))),
		"active_effects": M7TalentCatalogScript.active_effects(data),
		"summary": get_summary(),
	}, previous_data)


func complete_research(research_id: String, blocked_instance_ids: Array = []) -> Dictionary:
	if _z2_quest_lobby_blocked():
		return {"ok": false, "status": "active_run_lobby_action_blocked", "research_id": research_id}
	if not _ensure_writable("complete_research"):
		return {"ok": false, "status": "write_blocked", "reason": write_block_reason}
	var normalized := M7ProgressionServiceScript.normalize_meta(data)
	var definition := M7ContentCatalogScript.research_definition(research_id, normalized)
	if definition.is_empty():
		return {"ok": false, "status": "unknown_research", "research_id": research_id}
	var completed: Array = normalized.get("research_completed_ids", [])
	var repeatable := bool(definition.get("repeatable", false))
	if completed.has(research_id) and not repeatable:
		return {"ok": true, "status": "duplicate_ignored", "research_id": research_id}
	if Z2Rules.applies_to(data) and (int(data.get("profile_level", 0)) < 1 or not data.get("tutorial_completed", false)):
		return {"ok": false, "status": "tutorial_required"}
	var prerequisite := str(definition.get("prerequisite", ""))
	if prerequisite != "" and not completed.has(prerequisite):
		return {"ok": false, "status": "prerequisite_missing", "research_id": research_id, "prerequisite": prerequisite}
	var gold_cost := int(definition.get("gold_cost", 0))
	if int(data.get("gold", 0)) < gold_cost:
		return {"ok": false, "status": "insufficient_gold", "research_id": research_id, "gold_cost": gold_cost}
	var material_id := str(definition.get("material_item_id", ""))
	var items: Array = _array_from(data.get("warehouse_items", []))
	var material_index := -1
	var material_instance_id := ""
	for item_index in range(items.size()):
		var material := _dictionary_from(items[item_index])
		if str(material.get("item_id", "")) != material_id:
			continue
		var candidate_instance_id := str(material.get("instance_id", ""))
		if blocked_instance_ids.has(candidate_instance_id) or reserved_instance_ids().has(candidate_instance_id):
			continue
		material_index = item_index
		material_instance_id = candidate_instance_id
		break
	if material_index < 0:
		return {"ok": false, "status": "material_missing_or_configured", "research_id": research_id, "material_item_id": material_id}
	var previous_data := data.duplicate(true)
	data = normalized
	items.remove_at(material_index)
	data["warehouse_items"] = items
	data["gold"] = int(data.get("gold", 0)) - gold_cost
	if not completed.has(research_id):
		completed.append(research_id)
	var product: Dictionary = {}
	if Z2Rules.applies_to(data):
		product = M7ProgressionServiceScript.add_item_instance(data, str(definition.get("unlock_item_id", "")), "research_craft")
		if product.is_empty():
			data = previous_data
			return {"ok": false, "status": "invalid_research_product"}
		var counts: Dictionary = data.get("research_craft_counts", {}).duplicate(true)
		counts[research_id] = int(counts.get(research_id, 0)) + 1
		data["research_craft_counts"] = counts
	if research_id == "research_anomaly_structure":
		for monster_id in ["slime", "slimeling", "bat", "drone"]:
			_append_codex_discovery(data, "monster:%s" % monster_id)
	if research_id == "research_protocol_formula":
		_append_codex_discovery(data, "rule:protocol_pressure")
	if research_id == "research_extraction_signal":
		_append_codex_discovery(data, "rule:extraction_right")
	if Z2Rules.applies_to(data):
		var receipt_id := "research:%s:%s" % [research_id, str(product.get("instance_id", material_instance_id))]
		var fact := M7ProgressionServiceScript.record_z2_lobby_fact(data, "research_completed", {"research_id": research_id, "product_instance_id": str(product.get("instance_id", ""))}, receipt_id)
		if not bool(fact.ok):
			data = previous_data
			return fact
	M7ProgressionServiceScript.refresh_map_unlocks(data)
	M7ProgressionServiceScript.refresh_red_dots(data)
	if not save():
		data = previous_data
		return {"ok": false, "status": "save_failed", "research_id": research_id, "error": last_error}
	return _quest_action_result({"ok": true, "status": "crafted" if repeatable else "completed", "research_id": research_id, "gold_spent": gold_cost, "material_instance_id": material_instance_id, "crafted_item": product, "summary": get_summary()}, previous_data)


func claim_goal_reward(goal_kind: String, goal_id: String, tier: int = 1) -> Dictionary:
	if not _ensure_writable("claim_goal_reward"):
		return {"ok": false, "status": "write_blocked", "reason": write_block_reason, "goal_id": goal_id, "tier": tier}
	var previous_data := data.duplicate(true)
	var result := M7ProgressionServiceScript.claim_goal_reward(data, goal_kind, goal_id, tier)
	var identity := {"action": "claim_goal", "goal_kind": goal_kind, "goal_id": goal_id, "tier": tier}
	result["fingerprint"] = _meta_action_fingerprint(identity)
	result["request_payload"] = identity
	if not result.get("ok", false) or result.get("status", "") == "duplicate_ignored":
		return _quest_action_result(result)
	if not save():
		data = previous_data
		result.merge({"ok": false, "status": "save_failed", "reward": {}, "rolled_back": true, "error": last_error}, true)
		return _quest_action_result(result)
	result["summary"] = get_summary()
	return _quest_action_result(result, previous_data)


func refresh_spawn_opening_offer(offer: Dictionary, payload: Dictionary) -> Dictionary:
	if not _ensure_writable("refresh_spawn_opening_offer"):
		return {"ok": false, "status": "write_blocked", "reason": write_block_reason}
	if offer.is_empty():
		return {"ok": false, "status": "active_opening_required"}
	var previous := data.duplicate(true)
	var evaluation := Z2OpeningOfferScript.execute(data, "refresh", payload, 0, offer)
	var response := evaluation.duplicate(true)
	response.erase("meta")
	response["status"] = str(evaluation.get("reason", "duplicate_ignored" if evaluation.get("duplicate", false) else "applied"))
	if not evaluation.get("ok", false) or evaluation.get("duplicate", false):
		return response
	data = evaluation.meta
	# Candidate gold already includes the expense. Do not debit or draw again.
	if not save():
		data = previous
		return {"ok": false, "status": "save_failed", "rolled_back": true, "error": last_error}
	response["summary"] = get_summary()
	return response


# Called after the ordinary save, or after the outer meta transaction has saved.
# Candidate receipts remain uncommitted while save() is deferred.
func _quest_action_result(result: Dictionary, previous: Dictionary = {}) -> Dictionary:
	if not Z2Rules.applies_to(data):
		return result
	var response := result.duplicate(true)
	var committed := bool(response.get("ok", false)) and not _meta_action_transaction_active
	var notices: Array = _array_from(response.get("completions", response.get("m7_progression_delta", {}).get("completions", []))).duplicate(true)
	if not previous.is_empty() and response.get("ok", false):
		for key in data.get("z2_quest_notices", {}):
			if not previous.get("z2_quest_notices", {}).has(key):
				var notice: Dictionary = data.z2_quest_notices[key]
				if not notices.any(func(entry: Dictionary) -> bool: return entry.goal_id == notice.goal_id and int(entry.tier) == int(notice.tier)):
					notices.append(notice.duplicate(true))
	if not response.get("ok", false):
		notices.clear()
	var notifications: Array = []
	for notice: Dictionary in notices:
		notice["committed"] = committed
		notifications.append({"receipt": {"ok": committed, "committed": committed, "receipt_id": str(notice.receipt_id)}, "notice": notice.duplicate(true)})
	response["completions"] = notices
	response["quest_notifications"] = notifications
	response["quest_receipt"] = {"ok": committed, "committed": committed,
		"receipt_id": str(notices[0].receipt_id) if not notices.is_empty() else str(response.get("reward_id", response.get("result_id", "")))}
	return response


func _z2_quest_lobby_blocked() -> bool:
	# The active run owns base+local event sequences until its finalized settlement.
	# Lobby writers cannot allocate overlapping sequence IDs during that interval.
	return Z2Rules.applies_to(data) and not _dictionary_from(data.get("admission", {})).is_empty()


func mark_long_term_viewed(view_kind: String) -> Dictionary:
	if not _ensure_writable("mark_long_term_viewed"):
		return {"ok": false, "status": "write_blocked", "reason": write_block_reason}
	var previous_data := data.duplicate(true)
	match view_kind:
		"codex": data["unread_codex_ids"] = []
		"history": data["unread_history_ids"] = []
		"collection": data["unread_collection_set_ids"] = []
		"all":
			data["unread_codex_ids"] = []
			data["unread_history_ids"] = []
			data["unread_collection_set_ids"] = []
		_:
			return {"ok": false, "status": "unknown_view_kind", "view_kind": view_kind}
	M7ProgressionServiceScript.refresh_red_dots(data)
	var saved := save()
	if not saved:
		data = previous_data
	return {"ok": saved, "status": "viewed" if saved else "save_failed", "view_kind": view_kind, "summary": get_summary()}


func _append_codex_discovery(target: Dictionary, discovery_id: String) -> void:
	var discoveries: Array = target.get("codex_discoveries", [])
	if discoveries.has(discovery_id):
		return
	discoveries.append(discovery_id)
	_append_string(target.get("unread_codex_ids", []) as Array, discovery_id)


func mark_debug_command(command: String, payload: Dictionary = {}) -> Dictionary:
	if not _ensure_debug_sandbox("mark_debug_command"):
		return get_summary()
	if data.is_empty():
		load_or_create_default()
	if not _ensure_writable("mark_debug_command"):
		return get_summary()
	data["debug_used"] = true
	var commands: Array = _array_from(data.get("debug_commands", []))
	commands.append({
		"command": command,
		"payload": _json_safe(payload),
		"index": commands.size() + 1,
	})
	data["debug_commands"] = commands
	save()
	return get_summary()


func add_gold(amount: int, source: String = "debug") -> Dictionary:
	if not _ensure_debug_sandbox("add_gold"):
		return get_summary()
	if data.is_empty():
		load_or_create_default()
	if not _ensure_writable("add_gold"):
		return get_summary()
	data["gold"] = maxi(0, int(data.get("gold", 0)) + amount)
	mark_debug_command("meta_add_gold", {"amount": amount, "source": source})
	return get_summary()


func set_gold(amount: int, source: String = "debug") -> Dictionary:
	if not _ensure_debug_sandbox("set_gold"):
		return get_summary()
	if data.is_empty():
		load_or_create_default()
	if not _ensure_writable("set_gold"):
		return get_summary()
	data["gold"] = maxi(0, amount)
	mark_debug_command("meta_set_gold", {"amount": amount, "source": source})
	return get_summary()


func clear_gold() -> Dictionary:
	if not _ensure_debug_sandbox("clear_gold"):
		return get_summary()
	if data.is_empty():
		load_or_create_default()
	if not _ensure_writable("clear_gold"):
		return get_summary()
	data["gold"] = 0
	mark_debug_command("meta_clear_gold", {"source": "debug"})
	return get_summary()


func add_warehouse_item(item: Dictionary) -> Dictionary:
	if not _ensure_debug_sandbox("add_warehouse_item"):
		return get_summary()
	if data.is_empty():
		load_or_create_default()
	if not _ensure_writable("add_warehouse_item"):
		return get_summary()
	var items: Array = _array_from(data.get("warehouse_items", []))
	items.append(_minimal_item_record(item))
	data["warehouse_items"] = items
	mark_debug_command("meta_add_warehouse_item", item)
	return get_summary()


func clear_warehouse(source: String = "debug") -> Dictionary:
	if not _ensure_debug_sandbox("clear_warehouse"):
		return get_summary()
	if data.is_empty():
		load_or_create_default()
	if not _ensure_writable("clear_warehouse"):
		return get_summary()
	data["warehouse_items"] = []
	mark_debug_command("meta_clear_warehouse", {"source": source})
	return get_summary()


func _m7_map_catalog() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var unlocked: Array = data.get("unlocked_map_ids", [])
	var success_counts: Dictionary = data.get("map_success_counts", {})
	for raw_definition in M7ContentCatalogScript.map_definitions():
		var definition := raw_definition.duplicate(true)
		var map_id := str(definition.get("id", ""))
		if Z2Rules.applies_to(data):
			definition.merge(Z2Rules.map_overrides(map_id), true)
		definition["unlocked"] = unlocked.has(map_id)
		definition["lock_reason"] = "" if definition["unlocked"] else " · ".join(M7ProgressionServiceScript.map_unlock_blockers(data, definition))
		definition["success_count"] = 0 if map_id == "tutorial_5x5" else int(success_counts.get(map_id, 0))
		if map_id == "tutorial_5x5":
			definition["tutorial_completed"] = bool(data.get("tutorial_completed", false))
			definition["completion_label"] = "已完成 · 可重播" if bool(definition["tutorial_completed"]) else "未完成"
		result.append(definition)
	return result


func _m7_shop_catalog() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw_definition in M7ContentCatalogScript.shop_definitions(data):
		var definition := raw_definition.duplicate(true)
		definition["unlocked"] = M7ContentCatalogScript.is_shop_unlocked(definition, data)
		definition["affordable"] = int(data.get("gold", 0)) >= int(definition.get("price", 0))
		result.append(definition)
	return result


func _m7_research_catalog() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var completed: Array = data.get("research_completed_ids", [])
	var warehouse_items: Array = data.get("warehouse_items", [])
	for raw_definition in M7ContentCatalogScript.research_definitions(data):
		var definition := raw_definition.duplicate(true)
		var research_id := str(definition.get("id", ""))
		var prerequisite := str(definition.get("prerequisite", ""))
		var has_material := false
		for raw_item in warehouse_items:
			if str(_dictionary_from(raw_item).get("item_id", "")) == str(definition.get("material_item_id", "")):
				has_material = true
				break
		definition["completed"] = completed.has(research_id)
		definition["prerequisite_met"] = prerequisite == "" or completed.has(prerequisite)
		definition["has_material"] = has_material
		definition["affordable"] = int(data.get("gold", 0)) >= int(definition.get("gold_cost", 0))
		definition["can_complete"] = (not bool(definition["completed"]) or bool(definition.get("repeatable", false))) and bool(definition["prerequisite_met"]) and has_material and bool(definition["affordable"])
		result.append(definition)
	return result


func _append_string(target: Array, value: String) -> void:
	if value != "" and not target.has(value):
		target.append(value)


func _is_tutorial_result(result_snapshot: Dictionary) -> bool:
	if str(result_snapshot.get("mode", "")) == "tutorial":
		return true
	var run_start := _dictionary_from(result_snapshot.get("run_start_config", {}))
	if run_start.is_empty():
		var run_result := _dictionary_from(result_snapshot.get("RunResult", result_snapshot.get("run_result", {})))
		run_start = _dictionary_from(run_result.get("run_start_config", {}))
	return str(run_start.get("map_config_id", "")) == "tutorial_5x5"


func _apply_tutorial_settlement(result_snapshot: Dictionary, result_id: String) -> Dictionary:
	var settlement := _dictionary_from(result_snapshot.get("settlement", {}))
	var outcome := str(result_snapshot.get("outcome", settlement.get("outcome", "")))
	var completed := outcome == "Training Complete" or str(settlement.get("outcome", "")) == "success"
	if not completed:
		last_commit = {
			"ok": true,
			"status": "tutorial_incomplete_no_write",
			"result_id": result_id,
			"tutorial_completed": bool(data.get("tutorial_completed", false)),
			"summary": get_summary(),
		}
		return last_commit.duplicate(true)
	if bool(data.get("tutorial_completed", false)):
		last_commit = {
			"ok": true,
			"status": "tutorial_replay_complete",
			"result_id": result_id,
			"tutorial_completed": true,
			"summary": get_summary(),
		}
		return last_commit.duplicate(true)
	var previous_data := data.duplicate(true)
	data["tutorial_completed"] = true
	if Z2Rules.applies_to(data):
		if not data.get("talent_flags", []).has("z2_talent_01"):
			data = previous_data
			return {"ok": false, "status": "teaching_purchase_required"}
		data["profile_level"] = 1
		data["tutorial_purchase_available"] = false
		data["tutorial_completion_receipt"] = {"result_id": result_id, "visited_event_types": _visited_event_types(result_snapshot)}
	var new_unlocks := M7ProgressionServiceScript.refresh_map_unlocks(data)
	var saved := save()
	if not saved:
		data = previous_data
	last_commit = {
		"ok": saved,
		"status": "tutorial_completed" if saved else "save_failed",
		"result_id": result_id,
		"tutorial_completed": saved,
		"new_unlock_ids": new_unlocks if saved else [],
		"summary": get_summary(),
		"error": last_error,
	}
	return last_commit.duplicate(true)


func _result_id(result_snapshot: Dictionary) -> String:
	var explicit_id := str(result_snapshot.get("result_id", ""))
	if explicit_id != "":
		return explicit_id
	var run_id := str(result_snapshot.get("run_id", result_snapshot.get("mode", "run")))
	return "%s:%s:%s" % [run_id, str(result_snapshot.get("outcome", "")), int(result_snapshot.get("turn", 0))]


func _visited_event_types(result_snapshot: Dictionary) -> Array[String]:
	var seen: Array[String] = []
	var stats: Dictionary = result_snapshot.get("run_stats", result_snapshot.get("RunResult", {}).get("run_stats", {}))
	for event: String in Z2EventRuntime.EVENT_LEVELS:
		if stats.get("visited_event_" + event, false):
			seen.append(event)
	return seen


func _history_record(result_id: String, outcome: String, result_snapshot: Dictionary, settlement: Dictionary) -> Dictionary:
	var run_start := _dictionary_from(result_snapshot.get("run_start_config", {}))
	if run_start.is_empty():
		var run_result := _dictionary_from(result_snapshot.get("RunResult", result_snapshot.get("run_result", {})))
		run_start = _dictionary_from(run_result.get("run_start_config", {}))
	var recorded_seed := int(result_snapshot.get("seed", 0))
	if data.get("ruleset_id", "") == "z2":
		recorded_seed = int(result_snapshot.get("seed", run_start.get("seed_value", run_start.get("seed", 0))))
	var record := {
		"history_id": result_id,
		"result_id": result_id,
		"run_id": str(result_snapshot.get("run_id", "")),
		"outcome": outcome,
		"terminal_reason_code": StringName(result_snapshot.get("terminal_reason_code", &"")),
		"mode": str(result_snapshot.get("mode", "")),
		"map_config_id": str(run_start.get("map_config_id", run_start.get("config_id", ""))),
		"map_display_name": str(run_start.get("map_display_name", run_start.get("selected_map_summary", ""))),
		"difficulty": str(run_start.get("difficulty", "")),
		"difficulty_label": str(run_start.get("difficulty_label", "")),
		"commission_id": str(run_start.get("selected_objective_id", "")),
		"commission_label": str(run_start.get("selected_objective_label", "")),
		"seed": recorded_seed,
		"recorded_at_unix": int(Time.get_unix_time_from_system()),
		"visited_event_types": _visited_event_types(result_snapshot),
		"early_offered_events": _array_from(run_start.get("early_offered_events", [])),
		"carried_equipment": _array_from(run_start.get("selected_equipment_items", [])),
		"carried_consumables": _array_from(run_start.get("selected_consumable_items", [])),
		"extracted_items": _array_from(settlement.get("extracted_items", settlement.get("warehouse_items", []))),
		"salvaged_items": _array_from(settlement.get("salvaged_items", [])),
		"lost_items": _array_from(settlement.get("lost_items", [])),
		"room_floor_lost_items": _array_from(settlement.get("room_floor_lost_items", [])),
		"cleared_consumables": _array_from(settlement.get("cleared_consumables", [])),
		"black_coin_converted": int(settlement.get("black_coin_converted", 0)),
		"black_coin_lost": int(settlement.get("black_coin_lost", 0)),
		"safe_yield_retained": int(settlement.get("safe_yield_retained", settlement.get("safe_yield", 0))),
		"gold_delta": int(settlement.get("gold_coin_gained", 0)),
		"settlement_log": _array_from(settlement.get("settlement_log", [])),
	}
	return _dictionary_from(_json_safe(record))


func _settlement_gold(result_snapshot: Dictionary, settlement: Dictionary) -> int:
	if settlement.has("gold_coin_gained"):
		return maxi(0, int(settlement.get("gold_coin_gained", 0)))
	if result_snapshot.has("extracted_pending_gold"):
		return maxi(0, int(result_snapshot.get("extracted_pending_gold", 0)))
	return maxi(0, int(result_snapshot.get("gold_coin", 0)))


func _minimal_item_record(item: Variant) -> Dictionary:
	var source := _dictionary_from(item)
	if source.is_empty():
		return {}
	if str(source.get("content_version", "")) == Z2Rules.CONTENT_VERSION:
		# Z2 instances freeze the catalog values and instance counters. The legacy
		# projection omits those fields and would silently restore older effects.
		var frozen := _dictionary_from(_json_safe(source))
		frozen["location_state"] = "warehouse"
		if frozen.has("base_weight"):
			frozen["weight"] = int(frozen.base_weight)
		return frozen
	return {
		"instance_id": str(source.get("instance_id", source.get("item_id", "item"))),
		"item_id": str(source.get("item_id", source.get("id", "item"))),
		"display_name": str(source.get("display_name", source.get("item_id", "item"))),
		"short_description": str(source.get("short_description", "")),
		"item_type": str(source.get("item_type", "collectible")),
		"main_type": str(source.get("main_type", source.get("item_type", "collectible"))),
		"rarity": str(source.get("rarity", "common")),
		"collectible_level": int(source.get("collectible_level", 0)),
		"weight": maxi(0, int(source.get("weight", 0))),
		"base_value": maxi(0, int(source.get("base_value", source.get("value", 0)))),
		"source": str(source.get("source", "settlement")),
		"source_label": str(source.get("source_label", source.get("source", "settlement"))),
		"tags": _array_from(source.get("tags", [])),
		"can_sell": bool(source.get("can_sell", true)),
		"can_consume": bool(source.get("can_consume", false)),
		"can_equip": bool(source.get("can_equip", false)),
		"can_store": bool(source.get("can_store", true)),
		"can_carry": bool(source.get("can_equip", false)) or bool(source.get("can_consume", false)),
		"effect_kind": str(source.get("effect_kind", "")),
		"effect_amount": int(source.get("effect_amount", 0)),
		"equipment_slot": str(source.get("equipment_slot", "")),
	}


func _remove_carry_in_items(warehouse_items: Array, result_snapshot: Dictionary) -> Array:
	var run_start_config: Dictionary = _dictionary_from(result_snapshot.get("run_start_config", {}))
	if run_start_config.is_empty():
		var run_result: Dictionary = _dictionary_from(result_snapshot.get("run_result", result_snapshot.get("RunResult", {})))
		run_start_config = _dictionary_from(run_result.get("run_start_config", {}))
	var carry_ids: Dictionary = {}
	for reserved_id in reserved_instance_ids():
		carry_ids[str(reserved_id)] = true
	for raw_item in _array_from(run_start_config.get("selected_equipment_items", [])):
		var item := _dictionary_from(raw_item)
		var instance_id := str(item.get("instance_id", ""))
		if instance_id != "":
			carry_ids[instance_id] = true
	for raw_item in _array_from(run_start_config.get("selected_consumable_items", [])):
		var item := _dictionary_from(raw_item)
		var instance_id := str(item.get("instance_id", ""))
		if instance_id != "":
			carry_ids[instance_id] = true
	if carry_ids.is_empty():
		return warehouse_items
	var result: Array = []
	for raw_item in warehouse_items:
		var item := _dictionary_from(raw_item)
		if carry_ids.has(str(item.get("instance_id", ""))):
			continue
		result.append(item)
	return result


func _upsert_warehouse_item(warehouse_items: Array, item: Dictionary) -> void:
	var instance_id := str(item.get("instance_id", ""))
	if instance_id == "":
		warehouse_items.append(item)
		return
	for index in range(warehouse_items.size()):
		var existing := _dictionary_from(warehouse_items[index])
		if str(existing.get("instance_id", "")) == instance_id:
			warehouse_items[index] = item
			return
	warehouse_items.append(item)


func _record_debug_marker(command: String, payload: Dictionary = {}) -> void:
	if write_blocked:
		last_error = write_block_reason
		return
	data["debug_used"] = true
	var commands: Array = _array_from(data.get("debug_commands", []))
	commands.append({
		"command": command,
		"payload": _json_safe(payload),
		"index": commands.size() + 1,
	})
	data["debug_commands"] = commands


func _normalized_instance_ids(value: Variant) -> Array[String]:
	var unique := {}
	if value is Array:
		for raw_value in value as Array:
			if not (raw_value is String or raw_value is StringName):
				continue
			var instance_id := str(raw_value).strip_edges()
			if not instance_id.is_empty():
				unique[instance_id] = true
	var result: Array[String] = []
	for raw_instance_id in unique.keys():
		result.append(str(raw_instance_id))
	result.sort()
	return result


func _array_from(value: Variant) -> Array:
	if value is Array:
		return (value as Array).duplicate(true)
	return []


func _dictionary_from(value: Variant) -> Dictionary:
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return {}


func _ensure_writable(operation: String = "write") -> bool:
	if write_blocked:
		last_error = "%s:%s" % [write_block_reason, operation]
		return false
	return true


func _ensure_debug_sandbox(operation: String) -> bool:
	if active_profile_id == SaveProfileManifestScript.DEBUG_SANDBOX_PROFILE_ID:
		return true
	last_error = "debug_sandbox_profile_required:%s" % operation
	return false


func _result_uses_debug(result_snapshot: Dictionary) -> bool:
	return (
		bool(result_snapshot.get("debug_used", false))
		or bool(result_snapshot.get("debug_command_used", false))
		or not _array_from(result_snapshot.get("debug_commands", [])).is_empty()
	)


func _save_now() -> bool:
	if _debug_fail_next_save:
		_debug_fail_next_save = false
		last_error = "debug_injected_next_save_failure"
		save_adapter.last_error = last_error
		return false
	var output := data
	if data.get("ruleset_id", "") == "z2":
		output = data.duplicate(true)
		var history: Array = output.get("history_records", [])
		for index in range(history.size()):
			if not RunStateSnapshotScript.can_encode(history[index]):
				last_error = "invalid_terminal_storage"
				save_adapter.last_error = last_error
				return false
			history[index] = RunStateSnapshotScript.encode(history[index])
		for receipt in output.get("run_receipts", {}).values():
			if not RunStateSnapshotScript.can_encode(receipt.get("result")):
				last_error = "invalid_terminal_storage"
				save_adapter.last_error = last_error
				return false
			receipt["result"] = RunStateSnapshotScript.encode(receipt["result"])
		output["terminal_storage_version"] = 1
	var ok := save_adapter.save_json(output, active_meta_progress_path, false)
	last_error = save_adapter.last_error
	return ok


func _restore_terminal_storage() -> bool:
	if not data.has("terminal_storage_version"):
		return true
	var restored := data.duplicate(true)
	var history: Array = restored.get("history_records", [])
	for index in range(history.size()):
		if not RunStateSnapshotScript.valid_encoding(history[index]):
			return false
		var record: Variant = RunStateSnapshotScript.decode(history[index])
		if not record is Dictionary:
			return false
		history[index] = record
	for receipt in restored.get("run_receipts", {}).values():
		if not RunStateSnapshotScript.valid_encoding(receipt.get("result")):
			return false
		var result: Variant = RunStateSnapshotScript.decode(receipt["result"])
		if not result is Dictionary:
			return false
		receipt["result"] = result
	restored.erase("terminal_storage_version")
	data = restored
	return true


func _meta_action_transaction_result(
	idempotency_status: StringName,
	adapter_result: Dictionary = {}
) -> Dictionary:
	return {
		"idempotency_status": idempotency_status,
		"adapter_result": _quest_action_result(adapter_result) if idempotency_status in [&"executed", &"duplicate"] else adapter_result.duplicate(true),
	}


func _meta_action_fingerprint(payload: Dictionary) -> String:
	var identity_payload := payload.duplicate(true)
	identity_payload.erase("blocked_instance_ids")
	var canonical: Variant = _canonical_meta_action_value(identity_payload)
	if not canonical is Dictionary:
		return ""
	return JSON.stringify(canonical)


func _canonical_meta_action_value(value: Variant) -> Variant:
	if value is Dictionary:
		var source := value as Dictionary
		var key_lookup := {}
		var keys: Array[String] = []
		for raw_key in source.keys():
			var key := str(raw_key)
			if key_lookup.has(key):
				return {}
			key_lookup[key] = raw_key
			keys.append(key)
		keys.sort()
		var result := {}
		for key in keys:
			result[key] = _canonical_meta_action_value(source[key_lookup[key]])
		return result
	if value is Array:
		var result: Array = []
		for item in value as Array:
			result.append(_canonical_meta_action_value(item))
		return result
	return _json_safe(value)


func _meta_action_receipt_result(adapter_result: Dictionary) -> Dictionary:
	var result := adapter_result.duplicate(true)
	result.erase("summary")
	var json_safe_result: Variant = _json_safe(result)
	return json_safe_result as Dictionary if json_safe_result is Dictionary else {}


func _validated_meta_action_receipts(value: Variant) -> Dictionary:
	var source := _dictionary_from(value)
	var candidates: Array[Dictionary] = []
	var explicit_sequences := {}
	var can_sort_by_sequence := true
	for raw_request_id in source.keys():
		var request_id := str(raw_request_id).strip_edges()
		if request_id.is_empty():
			continue
		var receipt := _dictionary_from(source.get(raw_request_id, {}))
		if (
			int(receipt.get("schema_version", 0)) != META_ACTION_RECEIPT_SCHEMA_VERSION
			or str(receipt.get("fingerprint", "")).is_empty()
			or not receipt.get("result", {}) is Dictionary
		):
			continue
		var committed_sequence := int(receipt.get("committed_sequence", 0))
		if committed_sequence <= 0 or explicit_sequences.has(committed_sequence):
			can_sort_by_sequence = false
		else:
			explicit_sequences[committed_sequence] = true
		candidates.append({
			"request_id": request_id,
			"committed_sequence": committed_sequence,
			"schema_version": META_ACTION_RECEIPT_SCHEMA_VERSION,
			"fingerprint": str(receipt.get("fingerprint", "")),
			"result": _dictionary_from(receipt.get("result", {})),
		})
	if can_sort_by_sequence:
		candidates.sort_custom(
			func(a: Dictionary, b: Dictionary) -> bool:
				return int(a.get("committed_sequence", 0)) < int(b.get("committed_sequence", 0))
		)
	var first_retained := maxi(0, candidates.size() - META_ACTION_RECEIPT_LIMIT)
	var result := {}
	var normalized_sequence := 1
	for index in range(first_retained, candidates.size()):
		var candidate := candidates[index]
		result[str(candidate.get("request_id", ""))] = {
			"schema_version": META_ACTION_RECEIPT_SCHEMA_VERSION,
			"committed_sequence": normalized_sequence,
			"fingerprint": str(candidate.get("fingerprint", "")),
			"result": _dictionary_from(candidate.get("result", {})),
		}
		normalized_sequence += 1
	return result


func _next_meta_action_receipt_sequence(receipts: Dictionary) -> int:
	var next_sequence := 1
	for raw_receipt in receipts.values():
		var receipt := _dictionary_from(raw_receipt)
		next_sequence = maxi(next_sequence, int(receipt.get("committed_sequence", 0)) + 1)
	return next_sequence


func _json_safe(value: Variant) -> Variant:
	if value is Dictionary:
		var result := {}
		var dict_value := value as Dictionary
		for key in dict_value.keys():
			result[str(key)] = _json_safe(dict_value[key])
		return result
	if value is Array:
		var result: Array = []
		var array_value := value as Array
		for item in array_value:
			result.append(_json_safe(item))
		return result
	if value is Vector2i:
		var pos := value as Vector2i
		return {"x": pos.x, "y": pos.y}
	if value is Vector2:
		var vector := value as Vector2
		return {"x": vector.x, "y": vector.y}
	if value is StringName:
		return str(value)
	return value
