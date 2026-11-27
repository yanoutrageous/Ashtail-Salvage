extends RefCounted
class_name RunRuntimeController

const CommandBusScript := preload("res://scripts/core/command/command_bus.gd")
const G41InRunRuntimeScript := preload("res://scripts/core/run/g41_in_run_runtime.gd")
const RunContextScript := preload("res://scripts/core/run/run_context.gd")
const RunStartConfigScript := preload("res://scripts/core/run/run_start_config.gd")
const RunStateMachineScript := preload("res://scripts/core/run/run_state_machine.gd")
const CheckpointServiceScript := preload("res://scripts/core/save/run_checkpoint_service.gd")
const VitalsEffects := preload("res://scripts/core/run/run_effect_applier.gd")
const BreakableCombat := preload("res://scripts/gameplay/combat/voxel_breakable_combat.gd")
const Z2_CONTENT_VERSION := "z2-system-20261116"
# These builds use the same Z2 snapshot schema. Keep the regular save integrity
# and state validation while opening checkpoints from known compatible builds.
const Z2_COMPATIBLE_CHECKPOINT_HASHES := [
	"05aa08d5835587eda620ae96076e7ad7fc494f6fc7b98c6d6285accf7650d5bc", # Base game 698beba
	"377e072c167f0875e79401a355187f9add35881dc1427f5b3fba05e093481e51", # Local merge 66fece5
	"0912e4179d706121a3d9a93c0ffa4ff72ba9cf5367876489bbeac67c90b1ccc9", # Voxel polish cd37cc1
	"6dab75d62f73388b7bebe59ad2c88edb9c7078bc6caf2d8de3c3fa595ac6fd15", # UI handoff
	"6e997f32b5f01ef7b5a2d763b383cdf8282174eca42b572b44f77b231dc9366c", # UI integration repair
	"a36740400ce1e113950c77e52e16356901b001cf47aab1e5c69634fb762e0adc", # Local polish preview
	"ee33ae31752e35257774dbd41ed67e8a79ececd19d6abc1ef36a4dea177de768", # Local polish checkpoint verification
	"0efc9ea1d03d5043127a321bf6e19c5d8fbe06d8a4aedc2d47226854ff9ede34", # Scene and combat polish
	"df69a96e0a6f336b709e1c57a16a8b866d2392723e79340e2171bc278f86adb0", # First-combat hitch fix
	"cccf3429daad2f9790292b136b7423e4c09c06091dee8389e6d3b4bd731371e7", # Combat impact and lobby door polish
	"57a9a08ee1e2bc704a73d7a27098c8d79ccb374cd6aa5bc751c3415dca636c01", # Background hit checkpoints
	"776a7d6badc69d0955e88d0c3e1fe8e688458e81bc5ffc5f6d864ebebc21617d", # Boss and weapon playtest
	"27d51a3cd84fd84c3f412d299ac99dcb68a5f2b6cb535cb41a466b90e2bcc6f6", # M1 (05cc370)
	"0ca4ce2a700db0f94082fc0b00445d242c34afbbd69a0e9555cddb2234238446", # A2 input hotfix (2026-11-17)
]
const StateSnapshotScript := preload("res://scripts/core/run/run_state_snapshot.gd")
const ActionTransactionScript := preload("res://scripts/core/run/run_action_transaction.gd")
const Z2Hooks := preload("res://scripts/core/run/z2_run_hooks.gd")
const Z2Search := preload("res://scripts/core/run/z2_search_runtime.gd")
const Z2Opening := preload("res://scripts/core/run/z2_opening_runtime.gd")
const Z2_SEARCH_BASE_SECONDS := {"Normal": 2.0, "Chest": 3.0}
const TutorialServiceScript := preload("res://scripts/core/run/tutorial_service.gd")
const TutorialTalentCatalog := preload("res://scripts/core/progression/m7_talent_catalog.gd")

const META_ACTION_PURCHASE := &"purchase"
const META_ACTION_SELL := &"sell_collectible"
const META_ACTION_SELL_BATCH := &"sell_collectibles_batch"
const META_ACTION_UNLOCK_TALENT := &"unlock_talent"
const META_ACTION_RESEARCH := &"complete_research"
const META_ACTION_CLAIM := &"claim_goal"
const META_ACTION_CLAIM_INITIAL := &"claim_initial_supplies"
const META_ACTION_MARK_VIEWED := &"mark_viewed"
const TERMINAL_COMMIT_PENDING_STATUSES := [
	&"awaiting_salvage_confirmation",
	&"awaiting_salvage_selection",
	&"save_failed",
	&"write_blocked",
	&"meta_progress_adapter_missing",
]
const TERMINAL_COMMIT_DISCARDABLE_STATUSES := [
	&"save_failed",
	&"write_blocked",
	&"meta_progress_adapter_missing",
]
const TERMINAL_COMMIT_DISCARDED_STATUS := &"discarded_unsaved"

var context
var command_bus
var in_run_runtime
var state_machine
var meta_progress_adapter
var last_meta_commit: Dictionary = {}
var _meta_action_cache: Dictionary = {}
var transaction_revision: int = 0
var action_receipts: Dictionary = {}
var checkpoint_writer: Callable = Callable()
var checkpoint_service
var background_axe_checkpoints := false
var _combat_save_thread: Thread
var _pending_combat_save: Dictionary = {}
var _planning_action: bool = false
var _pending_terminal_reason: String = ""
var persistence_error: Dictionary = {}
var _persistence_manager
var _content_hash: String = ""
var _local_position := Vector2.ZERO
var _has_local_position := false
var _checkpoint_elapsed := 0.0
var _idle_accumulator := 0.0
var _pending_change_scope: StringName = &""
var _pending_commands: Array[Dictionary] = []
var _combat_hit_receipts: Dictionary = {}
var _active_action_id: String = ""


func _init() -> void:
	context = RunContextScript.new()
	state_machine = RunStateMachineScript.new()
	command_bus = CommandBusScript.new()
	command_bus.bind_runtime_controller(self)
	command_bus.result_available.connect(_on_terminal_result_available)
	in_run_runtime = G41InRunRuntimeScript.new()
	in_run_runtime.bind(self)
	command_bus.item_command_handler.combat_active_query = Callable(in_run_runtime, "has_active_combat")


func describe_ownership() -> Dictionary:
	return {
		"runtime_owner": "RunRuntimeController",
		"context_owner": "RunRuntimeController",
		"command_bus_owner": "RunRuntimeController",
		"lifecycle_owner": "RunStateMachine",
		"active_combat_owner": "G41CombatSimulation through G41InRunRuntime",
		"world_item_owner": "RunAssetLedger; room entities are read-only projections",
		"scene_owner": "RunScene orchestration only",
		"writable_context_instances": 1,
		"read_only": false,
	}


func z2_event_hooks(_context: RunContext, _pos: Vector2i, _event_id: String) -> Dictionary:
	return Z2Hooks.event_hooks(_context, _active_action_id, Callable(self, "_enter_z2_shortcut"))


func _enter_z2_shortcut(request: Dictionary) -> Dictionary:
	if not _planning_action or not context.run_active or in_run_runtime.has_active_combat():
		return {"ok": false, "reason": "room_transition_locked"}
	var target: Vector2i = request.get("target_pos", Vector2i(-1, -1))
	if not context.is_inside(target):
		return {"ok": false, "reason": "invalid_target"}
	var previous: Vector2i = context.get_current_pos()
	context.player_pos = target
	context.current_pos = target
	RunInventory.record_move(context)
	var entered: Dictionary = command_bus.room_resolver.enter_room(context)
	if entered.get("ok", false):
		sync_room_transition(target - previous)
	return entered


func spawn_opening_pending() -> bool:
	return context != null and context.run_active and context.z1_event_flags.get("z2_opening", {}).get("status") == "offered"


func spawn_opening_offer() -> Dictionary:
	if not spawn_opening_pending():
		return {}
	var initial: Dictionary = context.z1_event_flags.z2_opening.admitted_offer
	# A paid redraw and its fee are committed together in the profile. Final
	# selection copies this journal into the run checkpoint with its effect.
	if meta_progress_adapter != null:
		var latest: Dictionary = meta_progress_adapter.data.get("z2_opening_offer", {})
		if latest.get("offer_key") == initial.offer_key:
			return latest.duplicate(true)
	return initial.duplicate(true)


func execute_z2_opening_action(action: String, payload: Dictionary) -> Dictionary:
	if not _planning_action or not context.run_active or not Z2Hooks.applies_to(context):
		return {"ok": false, "reason": "opening_action_unavailable"}
	if action != "end" and in_run_runtime.has_active_combat():
		return {"ok": false, "reason": "combat_locked"}
	var request := {"action_id": _active_action_id, "instance_id": str(payload.get("instance_id", "")), "tool": str(payload.get("tool", ""))}
	return Z2Opening.execute(context, action, request, {"resolve_tool": Callable(self, "_resolve_z2_opening_tool"), "trap_threshold": Callable(self, "_z2_trap_threshold")})


func _z2_trap_threshold(candidate: RunContext) -> float:
	var state := EventService.get_event_state(candidate, candidate.get_current_pos())
	if str(state.get("event_type", "")) != "mechanism" or state.get("variant", "") != "mechanical" or state.get("completed", false) or not state.get("prepared", false):
		return -1.0
	return float(state.get("threshold", -1))


func _resolve_z2_opening_tool(candidate: RunContext, request: Dictionary) -> Dictionary:
	if request.tool == "scan":
		var before := candidate.intel_map.known_rooms.duplicate(true)
		for direction in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var pos: Vector2i = candidate.get_current_pos() + direction
			if candidate.is_inside(pos) and not candidate.intel_map.is_revealed(pos):
				candidate.intel_map.scan_cell(pos, candidate.truth_map, &"room_type", 1.0)
		return {"ok": true, "applied": before != candidate.intel_map.known_rooms}
	if request.tool != "trap" or not is_equal_approx(_z2_trap_threshold(candidate), float(request.get("base_threshold", -1))):
		return {"ok": false, "reason": "stale_mechanism"}
	var key := candidate.cell_key(candidate.get_current_pos())
	var room: Dictionary = candidate.z1_event_rooms[key]
	room.z2_process.mechanism.threshold = float(request.threshold)
	var state := EventService.get_event_state(candidate, candidate.get_current_pos())
	var result := EventService.execute_option(candidate, candidate.get_current_pos(), &"attempt", self, {"revision": int(state.get("revision", 0))})
	if result.get("ok", false):
		result["applied"] = true
		result["threshold"] = request.threshold
		result = command_bus.room_resolver._finish_event_result(candidate, candidate.get_current_pos(), result)
	return result


func start_demo_run(room_resolver: RoomResolver) -> Dictionary:
	var result: Dictionary = state_machine.start_demo_run(context)
	_finalize_start(result, room_resolver)
	return _with_actor(result)


func start_standard_run(room_resolver: RoomResolver, run_start_config: Dictionary = {}) -> Dictionary:
	var authorized_config := run_start_config.duplicate(true)
	if meta_progress_adapter != null and meta_progress_adapter.has_method("get_summary"):
		var summary_variant: Variant = meta_progress_adapter.get_summary()
		if not summary_variant is Dictionary:
			return _with_actor({
				"ok": false,
				"status": &"invalid_meta_progress_summary",
				"reason_code": "invalid_meta_progress_summary",
			})
		var authorization := RunStartConfigScript.authorize_with_meta(
			run_start_config,
			summary_variant as Dictionary
		)
		if not bool(authorization.get("ok", false)):
			return _with_actor({
				"ok": false,
				"status": &"invalid_run_start_authority",
				"reason_code": "invalid_run_start_authority",
				"issues": _array_copy(authorization.get("issues", [])),
			})
		authorized_config = _dictionary_copy(authorization.get("config", {}))
	var result: Dictionary = state_machine.start_standard_run(context, authorized_config)
	_finalize_start(result, room_resolver)
	return _with_actor(result)


func is_tutorial_learning_required() -> bool:
	if context == null or context.mode != &"tutorial" or context.profile_fields.get("z2_progression_version") != 1:
		return false
	return not bool(context.profile_fields.get("flag_unlocked", false)) or meta_progress_adapter == null or not meta_progress_adapter.data.get("talent_flags", []).has("z2_talent_01")


func _tutorial_learning_rejection() -> Dictionary:
	return _with_actor({"ok": false, "status": &"teaching_purchase_required", "reason": "teaching_purchase_required", "reason_code": "teaching_purchase_required", "message": "请先通过教学目标中的“100点 · 学习插旗”完成学习，再完成训练。收起说明不会扣点，你仍可继续探索或暂停。"})


func request_extract(room_resolver: RoomResolver, command_id: String, actor_id: StringName) -> Dictionary:
	if room_resolver != null and room_resolver.can_extract(context) and is_tutorial_learning_required():
		return _tutorial_learning_rejection()
	var result: Dictionary = state_machine.request_extract(context, room_resolver != null and room_resolver.can_extract(context), command_id, actor_id)
	return _with_actor(result)


func confirm_extract(room_resolver: RoomResolver) -> Dictionary:
	if is_tutorial_learning_required():
		return _tutorial_learning_rejection()
	var result: Dictionary = state_machine.confirm_extract(context, room_resolver != null and room_resolver.can_extract(context))
	if bool(result.get("ok", false)) and context != null and not context.run_active:
		in_run_runtime.reset()
	return _with_actor(result)


func cancel_extract() -> Dictionary:
	return _with_actor(state_machine.cancel_extract(context))


func extract(room_resolver: RoomResolver, command_id: String, actor_id: StringName) -> Dictionary:
	var request_result := request_extract(room_resolver, command_id, actor_id)
	if context != null and context.phase == &"confirm_extract":
		return confirm_extract(room_resolver)
	return request_result


func restart_run(room_resolver: RoomResolver) -> Dictionary:
	if context == null:
		return _with_actor({"ok": false, "status": &"not_ready", "reason_code": "not_ready"})
	var result: Dictionary
	match context.mode:
		&"standard":
			result = state_machine.restart_standard_run(context, context.run_start_config.duplicate(true))
		&"tutorial":
			# Tutorial is a map mode on the standard route. Reuse the exact
			# admitted start configuration instead of exposing a parallel
			# tutorial lifecycle interface.
			result = state_machine.restart_standard_run(context, context.run_start_config.duplicate(true))
		&"demo":
			result = state_machine.restart_demo_run(context)
		_:
			return _with_actor({"ok": false, "status": &"restart_mode_unsupported", "reason_code": "restart_mode_unsupported"})
	_finalize_start(result, room_resolver)
	return _with_actor(result)


func bind_meta_progress_adapter(adapter) -> void:
	var adapter_changed: bool = meta_progress_adapter != adapter
	meta_progress_adapter = adapter
	last_meta_commit.clear()
	if adapter_changed:
		_clear_meta_action_cache()


func execute_meta_action(action: Dictionary) -> Dictionary:
	if has_pending_combat_save():
		return _combat_save_pending()
	var request_id := _exact_meta_id(action.get("request_id", ""))
	var source_page := _exact_meta_id(action.get("source_page", ""))
	var action_id := StringName(_exact_meta_id(action.get("action", "")))
	if request_id.is_empty():
		return _meta_action_error("", source_page, action_id, "", &"missing_request_id")
	if source_page.is_empty():
		return _meta_action_error(request_id, "", action_id, "", &"missing_source_page")
	if action_id == &"":
		return _meta_action_error(request_id, source_page, &"", "", &"missing_action")
	var normalized := _normalize_meta_action(source_page, action_id, action)
	if not bool(normalized.get("ok", false)):
		return _meta_action_error(
			request_id,
			source_page,
			action_id,
			str(normalized.get("target_id", "")),
			StringName(normalized.get("status", &"invalid_meta_action"))
		)
	var payload: Dictionary = normalized.get("payload", {})
	if String(action_id).begins_with("opening_"):
		payload["request_id"] = request_id
	var identity_payload := _meta_action_identity_payload(payload)
	var target_id := str(normalized.get("target_id", ""))
	if _meta_action_cache.has(request_id):
		var cached_entry: Dictionary = _meta_action_cache.get(request_id, {})
		if cached_entry.get("payload", {}) == identity_payload:
			var duplicate_envelope: Dictionary = cached_entry.get("envelope", {}).duplicate(true)
			if bool(cached_entry.get("shared_summary", false)):
				duplicate_envelope["result"]["summary"] = duplicate_envelope.get("meta_progress_summary", {}).duplicate(true)
			duplicate_envelope["duplicate"] = true
			return duplicate_envelope
		var cached_envelope: Dictionary = cached_entry.get("envelope", {})
		var conflict_summary: Dictionary = _dictionary_copy(cached_envelope.get("meta_progress_summary", {}))
		return _meta_action_error(request_id, source_page, action_id, target_id, &"request_id_conflict", conflict_summary)
	if meta_progress_adapter == null:
		return _meta_action_error(request_id, source_page, action_id, target_id, &"meta_progress_adapter_missing")
	var adapter_result: Dictionary
	var persisted_duplicate := false
	if meta_progress_adapter.has_method("execute_idempotent_meta_action"):
		var transaction_variant: Variant = meta_progress_adapter.call(
			"execute_idempotent_meta_action",
			request_id,
			identity_payload,
			Callable(self, "_dispatch_meta_action").bind(payload)
		)
		if not transaction_variant is Dictionary:
			return _meta_action_error(
				request_id,
				source_page,
				action_id,
				target_id,
				&"invalid_meta_action_transaction",
				_meta_summary_after_action({})
			)
		var transaction := transaction_variant as Dictionary
		var idempotency_status := StringName(transaction.get("idempotency_status", &""))
		if idempotency_status == &"request_id_conflict":
			return _meta_action_error(
				request_id,
				source_page,
				action_id,
				target_id,
				&"request_id_conflict",
				_meta_summary_after_action({})
			)
		if idempotency_status not in [&"executed", &"duplicate", &"persistence_failed", &"write_blocked", &"invalid_result"]:
			return _meta_action_error(
				request_id,
				source_page,
				action_id,
				target_id,
				idempotency_status if idempotency_status != &"" else &"invalid_meta_action_transaction",
				_meta_summary_after_action({})
			)
		adapter_result = _dictionary_copy(transaction.get("adapter_result", {}))
		if adapter_result.is_empty():
			adapter_result = {
				"ok": false,
				"status": &"invalid_meta_action_result",
			}
		persisted_duplicate = idempotency_status == &"duplicate"
	else:
		adapter_result = _dispatch_meta_action(payload)
	var summary := _meta_summary_after_action(adapter_result)
	var envelope := {
		"request_id": request_id,
		"source_page": source_page,
		"action": action_id,
		"target_id": target_id,
		"ok": bool(adapter_result.get("ok", false)),
		"status": StringName(adapter_result.get("status", &"ok" if bool(adapter_result.get("ok", false)) else &"failed")),
		"duplicate": persisted_duplicate,
		"result": adapter_result.duplicate(true),
		"meta_progress_summary": summary,
	}
	_store_meta_action_result(request_id, identity_payload, envelope)
	return envelope.duplicate(true)


func meta_progress_summary() -> Dictionary:
	if meta_progress_adapter == null:
		return {}
	return meta_progress_adapter.get_summary()


func _normalize_meta_action(source_page: String, action_id: StringName, action: Dictionary) -> Dictionary:
	var payload := {
		"source_page": source_page,
		"action": action_id,
	}
	var target_id := ""
	match action_id:
		&"opening_refresh":
			target_id = "opening_offer"
			payload["run_id"] = _exact_meta_id(action.get("run_id", ""))
			payload["offer_id"] = _exact_meta_id(action.get("offer_id", ""))
			payload["effect_id"] = _exact_meta_id(action.get("effect_id", ""))
		META_ACTION_CLAIM_INITIAL:
			target_id = "initial_supplies"
		META_ACTION_PURCHASE:
			target_id = _exact_meta_id(action.get("item_id", ""))
			if target_id.is_empty():
				return {"ok": false, "status": &"missing_target_id"}
			payload["item_id"] = target_id
			var quantity := int(action.get("quantity", 1))
			if quantity < 1 or quantity > 99:
				return {
					"ok": false,
					"status": &"invalid_quantity",
					"target_id": target_id,
				}
			payload["quantity"] = quantity
		META_ACTION_SELL:
			target_id = _exact_meta_id(action.get("instance_id", ""))
			if target_id.is_empty():
				return {"ok": false, "status": &"missing_target_id"}
			payload["instance_id"] = target_id
			payload["blocked_instance_ids"] = _normalized_blocked_instance_ids(action)
		META_ACTION_SELL_BATCH:
			var instance_ids := _normalized_instance_id_list(action.get("instance_ids", []))
			if instance_ids.is_empty():
				return {"ok": false, "status": &"missing_target_id"}
			target_id = "batch:%s" % ",".join(instance_ids)
			payload["instance_ids"] = instance_ids
			payload["blocked_instance_ids"] = _normalized_blocked_instance_ids(action)
		META_ACTION_UNLOCK_TALENT:
			target_id = _exact_meta_id(action.get("talent_id", ""))
			if target_id.is_empty():
				return {"ok": false, "status": &"missing_target_id"}
			payload["talent_id"] = target_id
		META_ACTION_RESEARCH:
			target_id = _exact_meta_id(action.get("research_id", ""))
			if target_id.is_empty():
				return {"ok": false, "status": &"missing_target_id"}
			payload["research_id"] = target_id
			payload["blocked_instance_ids"] = _normalized_blocked_instance_ids(action)
		META_ACTION_CLAIM:
			var goal_kind := _exact_meta_id(action.get("goal_kind", ""))
			var goal_id := _exact_meta_id(action.get("goal_id", ""))
			if goal_kind.is_empty() or goal_id.is_empty():
				return {"ok": false, "status": &"missing_target_id"}
			if goal_kind not in ["task", "achievement"]:
				return {"ok": false, "status": &"invalid_goal_kind"}
			target_id = "%s:%s" % [goal_kind, goal_id]
			payload["goal_kind"] = goal_kind
			payload["goal_id"] = goal_id
			var tier_value: Variant = action.get("tier", 1)
			if not (tier_value is int or tier_value is float) or not is_finite(float(tier_value)) or float(tier_value) != floor(float(tier_value)) or int(tier_value) < 1:
				return {"ok": false, "status": &"invalid_goal_tier"}
			payload["tier"] = int(tier_value)
			target_id += ":%d" % int(tier_value)
		META_ACTION_MARK_VIEWED:
			target_id = _exact_meta_id(action.get("view_kind", ""))
			if target_id.is_empty():
				return {"ok": false, "status": &"missing_target_id"}
			payload["view_kind"] = target_id
		_:
			return {"ok": false, "status": &"unknown_meta_action"}
	return {
		"ok": true,
		"target_id": target_id,
		"payload": payload,
	}


func _dispatch_meta_action(payload: Dictionary) -> Dictionary:
	var action_id := StringName(payload.get("action", &""))
	var result: Variant
	match action_id:
		&"opening_refresh":
			result = meta_progress_adapter.refresh_spawn_opening_offer(spawn_opening_offer(), payload)
		META_ACTION_CLAIM_INITIAL:
			result = meta_progress_adapter.claim_initial_supplies()
		META_ACTION_PURCHASE:
			var quantity := int(payload.get("quantity", 1))
			if meta_progress_adapter.has_method("purchase_items"):
				result = meta_progress_adapter.purchase_items(
					str(payload.get("item_id", "")),
					quantity
				)
			elif quantity == 1 and meta_progress_adapter.has_method("purchase_item"):
				result = meta_progress_adapter.purchase_item(str(payload.get("item_id", "")))
			else:
				result = {
					"ok": false,
					"status": &"batch_purchase_unsupported",
					"quantity": quantity,
				}
		META_ACTION_SELL:
			result = meta_progress_adapter.sell_collectible(
				str(payload.get("instance_id", "")),
				_array_copy(payload.get("blocked_instance_ids", []))
			)
		META_ACTION_SELL_BATCH:
			result = meta_progress_adapter.sell_collectibles_batch(
				_array_copy(payload.get("instance_ids", [])),
				_array_copy(payload.get("blocked_instance_ids", []))
			)
		META_ACTION_UNLOCK_TALENT:
			result = meta_progress_adapter.unlock_talent(str(payload.get("talent_id", "")))
		META_ACTION_RESEARCH:
			result = meta_progress_adapter.complete_research(
				str(payload.get("research_id", "")),
				_array_copy(payload.get("blocked_instance_ids", []))
			)
		META_ACTION_CLAIM:
			result = meta_progress_adapter.claim_goal_reward(
				str(payload.get("goal_kind", "")),
				str(payload.get("goal_id", "")),
				int(payload.get("tier", 1))
			)
		META_ACTION_MARK_VIEWED:
			result = meta_progress_adapter.mark_long_term_viewed(str(payload.get("view_kind", "")))
		_:
			return {"ok": false, "status": &"unknown_meta_action"}
	if result is Dictionary:
		return (result as Dictionary).duplicate(true)
	return {"ok": false, "status": &"invalid_meta_action_result"}


func _meta_summary_after_action(result: Dictionary) -> Dictionary:
	var result_summary := _dictionary_copy(result.get("summary", {}))
	if not result_summary.is_empty():
		return result_summary
	if meta_progress_adapter != null and meta_progress_adapter.has_method("get_summary"):
		var adapter_summary: Variant = meta_progress_adapter.get_summary()
		if adapter_summary is Dictionary:
			return (adapter_summary as Dictionary).duplicate(true)
	return {}


func _store_meta_action_result(request_id: String, payload: Dictionary, envelope: Dictionary) -> void:
	# Active-run redraws already have atomic profile receipts. Avoid copying the
	# admission's initial checkpoint into the run again for every refresh.
	if payload.get("action") == &"opening_refresh":
		return
	if str(envelope.get("status", "")) in ["save_failed", "write_blocked", "persistence_failed"]:
		# No durable receipt exists for a failed save. The same request must be
		# allowed to retry after storage recovers, without reopening the game.
		return
	var cached_envelope := envelope.duplicate(true)
	var shared_summary: bool = cached_envelope.get("result", {}).get("summary", {}) is Dictionary and not cached_envelope.get("meta_progress_summary", {}).is_empty() and cached_envelope.get("result", {}).get("summary", {}) == cached_envelope.get("meta_progress_summary", {})
	if shared_summary:
		cached_envelope["result"].erase("summary")
	_meta_action_cache[request_id] = {
		"payload": payload.duplicate(true),
		"envelope": cached_envelope,
		"shared_summary": shared_summary,
	}


func _clear_meta_action_cache() -> void:
	_meta_action_cache.clear()


func _meta_action_error(
	request_id: String,
	source_page: String,
	action_id: StringName,
	target_id: String,
	status: StringName,
	summary: Dictionary = {}
) -> Dictionary:
	return {
		"request_id": request_id,
		"source_page": source_page,
		"action": action_id,
		"target_id": target_id,
		"ok": false,
		"status": status,
		"duplicate": false,
		"result": {"ok": false, "status": status},
		"meta_progress_summary": summary.duplicate(true),
	}


func _normalized_blocked_instance_ids(action: Dictionary) -> Array[String]:
	var unique: Dictionary = {}
	for key in ["blocked_instance_ids", "selected_equipment_ids", "selected_consumable_ids"]:
		var raw_values: Variant = action.get(key, [])
		if not raw_values is Array:
			continue
		for raw_value in raw_values as Array:
			var instance_id := _exact_meta_id(raw_value)
			if not instance_id.is_empty():
				unique[instance_id] = true
	for active_instance_id in _active_run_protected_instance_ids():
		unique[active_instance_id] = true
	var normalized: Array[String] = []
	for raw_instance_id in unique.keys():
		normalized.append(str(raw_instance_id))
	normalized.sort()
	return normalized


func _active_run_protected_instance_ids() -> Array[String]:
	var protected: Dictionary = {}
	if (
		context == null
		or (
			not bool(context.run_active)
			and StringName(context.phase) != &"failure_salvage"
			and not _terminal_commit_requires_instance_protection()
		)
	):
		return []
	var run_start := _dictionary_copy(context.run_start_config)
	for key in ["selected_equipment_ids", "selected_consumable_ids", "selected_loadout", "carried_consumables"]:
		for raw_id in _array_copy(run_start.get(key, [])):
			var instance_id := _exact_meta_id(raw_id)
			if not instance_id.is_empty():
				protected[instance_id] = true
	for key in ["selected_equipment_items", "selected_consumable_items"]:
		for raw_item in _array_copy(run_start.get(key, [])):
			var item := _dictionary_copy(raw_item)
			var instance_id := _exact_meta_id(item.get("instance_id", ""))
			if not instance_id.is_empty():
				protected[instance_id] = true
	var normalized: Array[String] = []
	for raw_id in protected.keys():
		normalized.append(str(raw_id))
	normalized.sort()
	return normalized


func _terminal_commit_requires_instance_protection() -> bool:
	if context == null or context.result_snapshot.is_empty():
		return false
	return StringName(last_meta_commit.get("status", &"")) in TERMINAL_COMMIT_PENDING_STATUSES


func _meta_action_identity_payload(payload: Dictionary) -> Dictionary:
	var identity := payload.duplicate(true)
	identity.erase("blocked_instance_ids")
	return identity


func _normalized_instance_id_list(value: Variant) -> Array[String]:
	var unique: Dictionary = {}
	if value is Array:
		for raw_value in value as Array:
			var instance_id := _exact_meta_id(raw_value)
			if not instance_id.is_empty():
				unique[instance_id] = true
	var normalized: Array[String] = []
	for raw_instance_id in unique.keys():
		normalized.append(str(raw_instance_id))
	normalized.sort()
	return normalized


func _exact_meta_id(value: Variant) -> String:
	if not (value is String or value is StringName):
		return ""
	return str(value).strip_edges()


func _array_copy(value: Variant) -> Array:
	return (value as Array).duplicate(true) if value is Array else []


func _dictionary_copy(value: Variant) -> Dictionary:
	return (value as Dictionary).duplicate(true) if value is Dictionary else {}


func _on_terminal_result_available(result_snapshot: Dictionary) -> void:
	var settlement: Dictionary = result_snapshot.get("settlement", {})
	var awaiting_salvage := bool(settlement.get("requires_salvage_selection", false)) and not bool(settlement.get("finalized", false))
	if awaiting_salvage:
		last_meta_commit = {
			"ok": false,
			"status": &"awaiting_salvage_confirmation",
			"committed": false,
		}
		return
	if meta_progress_adapter == null:
		last_meta_commit = {
			"ok": false,
			"status": &"meta_progress_adapter_missing",
			"committed": false,
		}
		return
	last_meta_commit = _commit_terminal_snapshot(result_snapshot)


func retry_terminal_commit() -> Dictionary:
	if StringName(last_meta_commit.get("status", &"")) == TERMINAL_COMMIT_DISCARDED_STATUS:
		return _with_actor({
			"ok": false,
			"status": &"terminal_commit_discarded",
			"committed": false,
			"result_id": String(last_meta_commit.get("result_id", "")),
		})
	if context == null or context.result_snapshot.is_empty():
		last_meta_commit = {
			"ok": false,
			"status": &"terminal_result_missing",
			"committed": false,
		}
		return _with_actor(last_meta_commit)
	var result_snapshot: Dictionary = context.result_snapshot.duplicate(true)
	var settlement: Dictionary = result_snapshot.get("settlement", {}) if result_snapshot.get("settlement", {}) is Dictionary else {}
	var outcome := String(result_snapshot.get("outcome", ""))
	var terminal := outcome in ["Extracted", "Training Complete", "Failed", "Abandoned"]
	var finalized := bool(settlement.get("finalized", false)) and not bool(settlement.get("requires_salvage_selection", false))
	if not terminal or not finalized:
		last_meta_commit = {
			"ok": false,
			"status": &"terminal_result_not_finalized",
			"committed": false,
			"result_id": String(result_snapshot.get("result_id", "")),
		}
		return _with_actor(last_meta_commit)
	if meta_progress_adapter == null:
		last_meta_commit = {
			"ok": false,
			"status": &"meta_progress_adapter_missing",
			"committed": false,
			"result_id": String(result_snapshot.get("result_id", "")),
		}
		return _with_actor(last_meta_commit)
	last_meta_commit = _commit_terminal_snapshot(result_snapshot)
	return _with_actor(last_meta_commit)


func _commit_terminal_snapshot(result_snapshot: Dictionary) -> Dictionary:
	var result: Dictionary = checkpoint_service.apply_settlement(result_snapshot) if checkpoint_service != null else meta_progress_adapter.apply_settlement(result_snapshot)
	if checkpoint_service != null:
		result["durable_checkpoint"] = true
	return result


func discard_unsaved_terminal_commit(confirmed: bool = false) -> Dictionary:
	if checkpoint_service != null:
		return _atomic_error("durable_terminal_retry_required")
	if not confirmed:
		return _with_actor({
			"ok": false,
			"status": &"discard_confirmation_required",
			"committed": false,
		})
	if StringName(last_meta_commit.get("status", &"")) == TERMINAL_COMMIT_DISCARDED_STATUS:
		return _with_actor({
			"ok": false,
			"status": &"terminal_commit_already_discarded",
			"committed": false,
			"result_id": String(last_meta_commit.get("result_id", "")),
		})
	if context == null or context.result_snapshot.is_empty():
		return _with_actor({
			"ok": false,
			"status": &"terminal_result_missing",
			"committed": false,
		})
	var result_snapshot: Dictionary = context.result_snapshot.duplicate(true)
	var settlement: Dictionary = result_snapshot.get("settlement", {}) if result_snapshot.get("settlement", {}) is Dictionary else {}
	var outcome := String(result_snapshot.get("outcome", ""))
	var terminal := outcome in ["Extracted", "Training Complete", "Failed", "Abandoned"]
	var finalized := bool(settlement.get("finalized", false)) and not bool(settlement.get("requires_salvage_selection", false))
	if not terminal or not finalized:
		return _with_actor({
			"ok": false,
			"status": &"terminal_result_not_finalized",
			"committed": false,
			"result_id": String(result_snapshot.get("result_id", "")),
		})
	var current_status := StringName(last_meta_commit.get("status", &""))
	if current_status not in TERMINAL_COMMIT_DISCARDABLE_STATUSES:
		return _with_actor({
			"ok": false,
			"status": &"terminal_commit_discard_not_pending",
			"committed": bool(last_meta_commit.get("committed", false)),
			"result_id": String(result_snapshot.get("result_id", "")),
		})
	last_meta_commit = {
		"ok": false,
		"status": TERMINAL_COMMIT_DISCARDED_STATUS,
		"committed": false,
		"discarded": true,
		"result_id": String(result_snapshot.get("result_id", "")),
	}
	var transition_result := last_meta_commit.duplicate(true)
	transition_result["ok"] = true
	return _with_actor(transition_result)


func debug_force_extract() -> Dictionary:
	var result := _with_actor(state_machine.force_extract(context))
	in_run_runtime.reset()
	return result


func fail_run(reason: String = "forced_failure") -> Dictionary:
	if _planning_action:
		if _pending_terminal_reason.is_empty():
			_pending_terminal_reason = reason
		return _with_actor({"ok": true, "status": &"failure_pending"})
	var result := _with_actor(state_machine.fail_run(context, reason))
	in_run_runtime.reset()
	return result


func confirm_failure_salvage(selected_instance_ids: Array) -> Dictionary:
	var result := _with_actor(state_machine.confirm_failure_salvage(context, selected_instance_ids))
	in_run_runtime.reset()
	return result


func terminal_selection_state(selected_instance_ids: Array) -> Dictionary:
	if not RunSettlementService.applies_to(context) or context.phase != &"failure_salvage":
		return {}
	return RunSettlementService.selection_state(context, str(context.settlement_result.get("outcome", "failure")), selected_instance_ids)


func abandon_run(reason: String = "player_abandoned") -> Dictionary:
	var result := _with_actor(state_machine.abandon_run(context, reason))
	in_run_runtime.reset()
	return result


func debug_force_fail(reason: String = "debug_forced_failure") -> Dictionary:
	var result: Dictionary = fail_run(reason)
	if context != null:
		context.last_message = "Debug forced failure through RunStateMachine."
	return result


func _enter_room_after_start(room_resolver: RoomResolver) -> Dictionary:
	if room_resolver != null and context != null:
		return room_resolver.enter_room(context)
	return {"ok": true}


func _finalize_start(result: Dictionary, room_resolver: RoomResolver) -> void:
	if not bool(result.get("ok", false)):
		return
	last_meta_commit.clear()
	_combat_hit_receipts.clear()
	_checkpoint_elapsed = 0.0
	_idle_accumulator = 0.0
	_has_local_position = false
	if RunSettlementService.applies_to(context):
		var supplied := Z2SupplyRuntime.on_departure(context, context.asset_ledger.get_items_by_location(RunAssetLedger.LOCATION_EQUIPPED))
		if not supplied.get("ok", false):
			result.merge(supplied, true)
			return
		var opening := Z2Opening.admit_departure(context, context.run_start_config.get("z2_opening_offer", {}))
		if not opening.get("ok", false):
			result.merge(opening, true)
			return
		context.z1_event_flags["z2_income_cursor"] = context.asset_ledger.settlement_log.size()
		context.run_start_config["starting_power"] = context.power
		context.run_start_config["starting_pressure"] = context.pressure
		var actual_opening: Dictionary = Z2Opening.public_state(context)
		context.run_start_config["opening_effect"] = {"id": actual_opening.get("selected", ""), "batch": 1} if actual_opening.get("status", "") == "selected" else {}
		var hidden: Array[Vector2i] = []
		var visible: Array = context.truth_map.get_visible_exits(null)
		for exit_pos in context.truth_map.exits:
			if not visible.has(exit_pos):
				hidden.append(exit_pos)
		context.run_start_config["hidden_exits_at_start"] = hidden
	else:
		context.shield += RunInventory.claim_departure_shield(context.asset_ledger, str(context.run_id))
	in_run_runtime.reset()
	var entered := _enter_room_after_start(room_resolver)
	if not entered.get("ok", false):
		result.merge(entered, true)


func _with_actor(result: Dictionary) -> Dictionary:
	var output := result.duplicate(true)
	if not output.has("actor_id"):
		output["actor_id"] = &"player"
	output["runtime_authority"] = "RunRuntimeController"
	return output

func capture_authoritative_state() -> Dictionary:
	var bridge: Dictionary = {}
	if in_run_runtime.has_method("export_transaction_state"):
		bridge = in_run_runtime.export_transaction_state()
	else:
		bridge = StateSnapshotScript.capture_data(in_run_runtime, ["context", "runtime_controller", "command_bus", "simulation"])
	return {
		"schema_version": 1, "run_id": str(context.run_id), "revision": transaction_revision,
		"context": StateSnapshotScript.capture_context(context), "bridge": bridge,
		"command_sequence": command_bus.command_sequence, "receipts": action_receipts.duplicate(true),
		"last_meta_commit": last_meta_commit.duplicate(true), "meta_action_cache": _meta_action_cache.duplicate(true),
		"local_position": _local_position, "has_local_position": _has_local_position,
		"checkpoint_elapsed": _checkpoint_elapsed, "combat_hit_receipts": _combat_hit_receipts.duplicate(true),
		"idle_accumulator": _idle_accumulator,
		"pending_terminal": {"phase": str(context.phase), "reason": _pending_terminal_reason} if context.run_started and not context.run_active else {},
	}

func install_authoritative_state(snapshot: Dictionary, installed_snapshot: Dictionary = {}) -> Dictionary:
	if int(snapshot.get("schema_version", 0)) != 1 or not snapshot.get("context") is Dictionary:
		return {"ok": false, "reason": "invalid_runtime_snapshot"}
	var installed := StateSnapshotScript.install_context(context, snapshot["context"], installed_snapshot.get("context", {}))
	if not bool(installed.get("ok", false)):
		return installed
	transaction_revision = int(snapshot.get("revision", 0))
	action_receipts = snapshot.get("receipts", {}).duplicate(true)
	command_bus.command_sequence = int(snapshot.get("command_sequence", 0))
	last_meta_commit = snapshot.get("last_meta_commit", {}).duplicate(true)
	_meta_action_cache = snapshot.get("meta_action_cache", {}).duplicate(true)
	_local_position = snapshot.get("local_position", Vector2.ZERO)
	_has_local_position = bool(snapshot.get("has_local_position", false))
	_checkpoint_elapsed = float(snapshot.get("checkpoint_elapsed", 0.0))
	_idle_accumulator = float(snapshot.get("idle_accumulator", 0.0))
	_combat_hit_receipts = snapshot.get("combat_hit_receipts", {}).duplicate(true)
	_pending_terminal_reason = ""
	if in_run_runtime.has_method("import_transaction_state"):
		in_run_runtime.import_transaction_state(snapshot.get("bridge", {}))
	else:
		StateSnapshotScript.install_data(in_run_runtime, snapshot.get("bridge", {}))
	return {"ok": true}

func encode_checkpoint_state(snapshot: Dictionary) -> Variant:
	return StateSnapshotScript.pack_checkpoint(snapshot)

func decode_checkpoint_state(encoded: Variant) -> Dictionary:
	return StateSnapshotScript.unpack_checkpoint(encoded)

func restore_checkpoint_state(encoded: Variant, envelope: Dictionary = {}, install: bool = true) -> Dictionary:
	var unpacked := decode_checkpoint_state(encoded)
	if not bool(unpacked.get("ok", false)):
		return _atomic_error("invalid_encoded_snapshot")
	var decoded: Variant = unpacked["state"]
	if not decoded is Dictionary:
		return {"ok": false, "reason": "invalid_encoded_snapshot"}
	if not _valid_runtime_snapshot(decoded):
		return _atomic_error("invalid_runtime_snapshot")
	for field in ["schema_version", "run_id", "revision"]:
		if not envelope.is_empty() and decoded[field] != envelope.get(field):
			return _atomic_error("checkpoint_state_mismatch")
	if not StateSnapshotScript.valid_context(decoded.get("context", {})):
		return _atomic_error("invalid_context_snapshot")
	if str(decoded.get("run_id", "")) != str(decoded["context"]["data"]["run_id"]):
		return _atomic_error("snapshot_run_mismatch")
	if not in_run_runtime.validate_transaction_state(decoded["bridge"]):
		return _atomic_error("invalid_combat_snapshot")
	return install_authoritative_state(decoded) if install else {"ok": true, "validated": true}

func _valid_runtime_snapshot(snapshot: Dictionary) -> bool:
	var template := capture_authoritative_state()
	if snapshot.size() != template.size():
		return false
	for key in template:
		if not snapshot.has(key) or typeof(snapshot[key]) != typeof(template[key]):
			return false
	if snapshot.schema_version != 1 or snapshot.revision < 0 or snapshot.command_sequence < 0 or snapshot.checkpoint_elapsed < 0.0 or snapshot.idle_accumulator < 0.0 or snapshot.idle_accumulator >= 1.0 / 60.0:
		return false
	for field in ["receipts", "combat_hit_receipts"]:
		for id in snapshot[field]:
			var receipt: Variant = snapshot[field][id]
			if not id is String or id.is_empty() or not receipt is Dictionary or receipt.size() != 2 or not receipt.get("fingerprint") is String or str(receipt.fingerprint).length() != 64 or not receipt.get("result") is Dictionary:
				return false
			if field == "receipts" and (receipt.result.get("action_id") != id or not receipt.result.get("revision") is int or receipt.result.revision < 0 or receipt.result.revision > snapshot.revision):
				return false
	for id in snapshot.meta_action_cache:
		var entry: Variant = snapshot.meta_action_cache[id]
		if not id is String or not entry is Dictionary or not entry.get("payload") is Dictionary or not entry.get("envelope") is Dictionary:
			return false
		if entry.has("shared_summary") and (not entry.shared_summary is bool or (entry.shared_summary and (not entry.envelope.get("meta_progress_summary") is Dictionary or not entry.envelope.get("result") is Dictionary or entry.envelope.result.has("summary")))):
			return false
	return true

func persist_candidate_state(snapshot: Dictionary) -> Dictionary:
	if checkpoint_writer.is_valid():
		var written: Variant = checkpoint_writer.call(snapshot.duplicate(true))
		return written if written is Dictionary else {"ok": false, "reason": "invalid_persistence_response"}
	if checkpoint_service != null:
		return _persist_checkpoint(snapshot)
	return {"ok": true, "memory_only": true}

func _persist_checkpoint(snapshot: Dictionary, encoded_state: Variant = null) -> Dictionary:
	if not bool(snapshot["context"]["data"].get("run_started", false)):
		return {"ok": true, "status": "no_run"}
	var checkpoint := _checkpoint_header(snapshot)
	checkpoint["state"] = encode_checkpoint_state(snapshot) if encoded_state == null else encoded_state
	var admission: Dictionary = meta_progress_adapter.data.get("admission", {})
	if admission.is_empty() or str(admission.get("run_id", "")) != str(snapshot["run_id"]):
		var reserved: Array = []
		var config: Dictionary = snapshot["context"]["data"].get("run_start_config", {})
		for field in ["selected_equipment_items", "selected_consumable_items"]:
			for item in config.get(field, []):
				reserved.append(str(item.get("instance_id", "")))
		return checkpoint_service.begin_admission(checkpoint, reserved)
	return checkpoint_service.save_checkpoint(checkpoint)


func _checkpoint_header(snapshot: Dictionary) -> Dictionary:
	return {
		"schema_version": 1, "profile_id": checkpoint_service.profile_id,
		"run_id": str(snapshot["run_id"]), "ruleset_id": "z2", "content_version": Z2_CONTENT_VERSION,
		"content_hash": _content_hash, "revision": int(snapshot["revision"]),
	}

func execute_atomic_command(command_name: StringName, payload: Dictionary) -> Dictionary:
	if spawn_opening_pending() and command_name not in [&"opening_choose", &"opening_skip"]:
		return _atomic_error("opening_selection_required")
	if has_pending_combat_save():
		return _combat_save_pending()
	if command_name == &"retry_terminal_commit":
		# Settlement owns its durable receipt and removes the run checkpoint.
		# It must never execute inside a speculative run-state candidate.
		if bool(payload.get("preview", false)):
			return {"ok": true, "preview": true, "status": &"terminal_retry_preview"}
		if not persistence_error.is_empty():
			return _atomic_error("persistence_retry_required")
		_planning_action = true
		var retried: Dictionary = command_bus.dispatch(command_name, payload)
		_planning_action = false
		return retried
	return execute_atomic_operation(command_name, payload, Callable(command_bus, "dispatch").bind(command_name, payload), str(payload.get("action_id", "")))

func defer_state_change(change_scope: StringName) -> void:
	if _pending_change_scope != &"all":
		_pending_change_scope = change_scope

func defer_command_request(command: Dictionary) -> void:
	_pending_commands.append(command.duplicate(true))

func _publish_command_requests(commands: Array[Dictionary]) -> void:
	for command in commands:
		command_bus.command_requested.emit(StringName(command["command_name"]), command)

func _action_identity_payload(payload: Dictionary) -> Dictionary:
	var identity := payload.duplicate(true)
	for key in ["action_id", "expected_revision", "expected_conditions", "preview", "durability_required"]:
		identity.erase(key)
	return identity

func action_condition_fingerprint(kind: StringName, payload: Dictionary) -> String:
	# Economic/eligibility state is independent of checkpoint revisions, local
	# movement, simulation clocks and presentation bookkeeping. Expiry, costs,
	# capacity, exact item ownership and room/target eligibility still invalidate.
	var data := StateSnapshotScript.capture_data(context, StateSnapshotScript.CONTEXT_BINDINGS + [
		"active_command", "last_message", "last_reward", "event_state", "enemy_state",
		"result_snapshot", "settlement_result", "failure_salvage",
		"tutorial_triggers", "tutorial_shown", "tutorial_popup", "debug_commands",
	])
	for status in data.get("temporary_statuses", []):
		status.erase("remaining")
		status.erase("elapsed")
		status.erase("dot_remainder")
		status.erase("heal_remainder")
	var ledger := {}
	if context.asset_ledger != null:
		ledger = {"capacity": context.asset_ledger.get_capacity_snapshot(),
			"balances": context.asset_ledger.currency_balances,
			"instances": context.asset_ledger.item_instances,
			"statuses": context.asset_ledger.status_effects}
	return StateSnapshotScript.fingerprint({"kind": kind, "payload": _action_identity_payload(payload),
		"context": data, "assets": ledger,
		"intel": StateSnapshotScript.capture_data(context.intel_map),
		"modifiers": [] if context.rule_pipeline == null else context.rule_pipeline.modifiers})

func guarded_event_display(event_state: Dictionary) -> Dictionary:
	var display := event_state.duplicate(true)
	for option in display.get("options", []):
		var payload: Dictionary = option.get("payload", {}).duplicate(true)
		payload["option_id"] = StringName(option.get("id", &""))
		payload["source"] = "ui"
		payload["expected_conditions"] = action_condition_fingerprint(&"select_event_option", payload)
		option["payload"] = payload
	return display

func execute_atomic_operation(kind: StringName, payload: Dictionary, operation: Callable, action_id: String = "") -> Dictionary:
	if has_pending_combat_save():
		return _combat_save_pending()
	if _planning_action:
		return operation.call()
	if not persistence_error.is_empty():
		return _atomic_error("persistence_retry_required")
	var identity_payload := _action_identity_payload(payload)
	var fingerprint := StateSnapshotScript.fingerprint({"kind": kind, "payload": identity_payload})
	if not action_id.is_empty() and action_receipts.has(action_id):
		var receipt: Dictionary = action_receipts[action_id]
		if str(receipt.get("fingerprint", "")) != fingerprint:
			return _atomic_error("action_id_conflict")
		var duplicate: Dictionary = receipt["result"].duplicate(true)
		duplicate["duplicate"] = true
		duplicate["action_id"] = action_id
		return duplicate
	if payload.has("expected_revision") and int(payload["expected_revision"]) != transaction_revision:
		return _atomic_error("stale_revision")
	var conditions := action_condition_fingerprint(kind, payload) if bool(payload.get("preview", false)) or payload.has("expected_conditions") else ""
	if payload.has("expected_conditions") and payload["expected_conditions"] != conditions:
		var stale := _atomic_error("stale_preview")
		stale["message"] = "选项条件已变化，请重新确认。"
		stale["action_result"] = stale.duplicate(true)
		return stale
	if kind == &"learn_tutorial_flag":
		# This explicit business action remains reachable in every tutorial room.
		# Validate before the durable purchase; closing a lesson never gets here.
		if context == null or context.mode != &"tutorial" or context.profile_fields.get("z2_progression_version") != 1 or not context.can_accept_command() or context.phase != &"running":
			return _atomic_error("teaching_action_unavailable")
		if meta_progress_adapter == null:
			return _atomic_error("meta_progress_adapter_missing")
		var already_learned: bool = meta_progress_adapter.data.get("talent_flags", []).has("z2_talent_01")
		if not already_learned:
			# purchase_tutorial_flag opens the teaching-only entitlement itself.
			# Mirror that precondition in a disposable preview, not in live meta.
			var eligibility_candidate: Dictionary = meta_progress_adapter.data.duplicate(true)
			eligibility_candidate["tutorial_purchase_available"] = true
			var eligibility: Dictionary = TutorialTalentCatalog.unlock_evaluation(eligibility_candidate, "z2_talent_01")
			if not eligibility.get("ok", false):
				return eligibility
		if bool(payload.get("preview", false)):
			return {"ok": true, "preview": true, "condition_fingerprint": conditions, "cost": 0 if already_learned else 100, "already_learned": already_learned}
		if not already_learned:
			# If the subsequent checkpoint fails, retries reuse the durable talent
			# entitlement instead of spending the 100 points for a second time.
			var learned: Dictionary = meta_progress_adapter.purchase_tutorial_flag()
			if not learned.get("ok", false):
				return learned
	if action_id.is_empty():
		action_id = "action:" + Crypto.new().generate_random_bytes(16).hex_encode()
	var before := capture_authoritative_state()
	var was_blocking: bool = command_bus.is_blocking_signals()
	command_bus.set_block_signals(true)
	_planning_action = true
	_active_action_id = action_id
	_pending_change_scope = &""
	_pending_commands.clear()
	_pending_terminal_reason = ""
	var returned: Variant = operation.call()
	var result: Dictionary = returned if returned is Dictionary else _atomic_error("invalid_action_result")
	if kind == &"combat_fixed_step" and bool(result.get("ok", false)):
		_apply_combat_breakable_facts(result)
	if result.get("ok", false):
		var triggered := Z2Hooks.after_action(context, before["context"], action_id)
		if not triggered.get("ok", false):
			result = triggered
	if not bool(result.get("ok", false)):
		var nested_message := str(result.get("action_result", {}).get("message", "")) if result.get("action_result") is Dictionary else ""
		var rejection_message := str(result.get("message", nested_message))
		if rejection_message.is_empty() and context.last_message != str(before["context"]["data"].get("last_message", "")):
			rejection_message = context.last_message
		if not rejection_message.is_empty():
			# A room resolver's explicit failure must not be replaced by an earlier
			# speculative "teleported"/"shortcut used" message from the candidate.
			result["message"] = rejection_message
			if result.get("action_result") is Dictionary:
				result["action_result"]["message"] = rejection_message
	if bool(result.get("ok", false)) and context.run_active and (context.hp <= 0 or not _pending_terminal_reason.is_empty()):
		state_machine.fail_run(context, _pending_terminal_reason if not _pending_terminal_reason.is_empty() else "hp_depleted")
		# Preserve the complete combat step in the candidate; presentation stops after commit.
	var durability := bool(result.get("durability_required", payload.get("durability_required", true)))
	durability = durability or (bool(before["context"]["data"]["run_active"]) and not context.run_active)
	if bool(result.get("ok", false)) and not durability and not bool(payload.get("preview", false)):
		# Motion/timer-only steps commit in memory. No receipt, encoding or disk
		# candidate is needed; the pre-step image still covers operation failure.
		_planning_action = false
		_active_action_id = ""
		_pending_terminal_reason = ""
		command_bus.set_block_signals(was_blocking)
		result["revision"] = transaction_revision
		result["action_id"] = action_id
		return result
	var change_scope := _pending_change_scope
	var requested_commands := _pending_commands.duplicate(true)
	var after := capture_authoritative_state()
	var preview := bool(payload.get("preview", false))
	var keep_combat_candidate: bool = (
		kind == &"combat_fixed_step" and bool(result.get("ok", false)) and durability and not preview
		and context.run_active and before["run_id"] == after["run_id"]
		and not checkpoint_writer.is_valid() and checkpoint_service != null
		and checkpoint_service.get_script() == CheckpointServiceScript
		and checkpoint_service.save_adapter.get_script() == CheckpointServiceScript.SaveAdapterScript
	)
	_planning_action = false
	_active_action_id = ""
	_pending_terminal_reason = ""
	if not keep_combat_candidate:
		install_authoritative_state(before)
		command_bus.set_block_signals(was_blocking)
	if not bool(result.get("ok", false)):
		if not preview:
			_publish_command_requests(requested_commands)
		return _without_uncommitted_facts(result)
	if preview:
		result["preview"] = true
		result["condition_fingerprint"] = conditions
		return result
	if action_id.is_empty():
		action_id = "%s:%d:%d:%s" % [str(after.get("run_id", "")), int(after.get("command_sequence", 0)), transaction_revision, str(kind)]
	if durability:
		# This candidate already saves the entire run at this tick. Start the
		# next periodic interval at this checkpoint rather than writing again
		# just after a room entry, hit, or explicitly saved action.
		after["checkpoint_elapsed"] = 0.0
	var committed: Dictionary
	if keep_combat_candidate:
		if background_axe_checkpoints and _has_landed_axe(result.get("facts", [])):
			if _start_combat_save(before, after, result, action_id, fingerprint, change_scope, requested_commands):
				install_authoritative_state(before, after)
				command_bus.set_block_signals(was_blocking)
				return _combat_save_pending()
		committed = _commit_live_combat_candidate(after, result, action_id, fingerprint)
	else:
		var planned := ActionTransactionScript.plan(before, {
			"kind": kind, "action_id": action_id, "payload": identity_payload,
			"expected_revision": before["revision"], "computed_state": after,
			"result": result, "durability_required": durability,
			"record_receipt": kind not in [&"checkpoint", &"idle_time"],
		})
		if not bool(planned.get("ok", false)):
			return _atomic_error(str(planned.get("reason", "invalid_plan")))
		committed = ActionTransactionScript.commit(self, planned["plan"])
	if not bool(committed.get("ok", false)):
		install_authoritative_state(before)
		command_bus.set_block_signals(was_blocking)
		if str(committed.get("status", "")) == "save_failed":
			persistence_error = committed.duplicate(true)
		_publish_command_requests(requested_commands)
		return committed
	command_bus.set_block_signals(was_blocking)
	_publish_command_requests(requested_commands)
	if durability and kind != &"checkpoint":
		command_bus._emit_state(change_scope if change_scope != &"" else (&"combat" if kind in [&"combat_fixed_step", &"idle_time", &"combat_hit"] else &"all"))
		var previous_result: Dictionary = before["context"]["data"].get("result_snapshot", {})
		if not context.result_snapshot.is_empty() and not context.run_active and context.result_snapshot != previous_result:
			command_bus.result_available.emit(context.result_snapshot.duplicate(true))
	return committed


func _commit_live_combat_candidate(
	candidate: Dictionary, result: Dictionary, action_id: String, fingerprint: String
) -> Dictionary:
	# The default writer is synchronous and has no game callbacks. Keep the
	# speculative state installed with signals blocked until its snapshot is
	# validated and saved. The caller restores the complete pre-step state on error.
	var committed := _prepare_combat_receipt(candidate, result, action_id, fingerprint)
	var encoded := StateSnapshotScript.pack_checkpoint(candidate)
	if encoded.is_empty():
		return _atomic_error("invalid_candidate_state")
	var saved := _persist_checkpoint(candidate, encoded)
	if not bool(saved.get("ok", false)):
		return {"ok": false, "reason": str(saved.get("reason", saved.get("error", "checkpoint_save_failed"))),
			"status": &"save_failed", "storage_error": saved}
	transaction_revision = candidate["revision"]
	action_receipts = candidate["receipts"]
	_checkpoint_elapsed = candidate["checkpoint_elapsed"]
	return committed


func _prepare_combat_receipt(candidate: Dictionary, result: Dictionary, action_id: String, fingerprint: String) -> Dictionary:
	var committed := result.duplicate(true)
	candidate["revision"] = transaction_revision + 1
	committed["revision"] = candidate["revision"]
	committed["action_id"] = action_id
	candidate["receipts"][action_id] = {"fingerprint": fingerprint, "result": committed.duplicate(true)}
	return committed


func _has_landed_axe(facts: Array) -> bool:
	for fact: Dictionary in facts:
		if fact.get("event_type") == &"player_attack_resolved" and fact.get("weapon", &"axe") == &"axe" and (int(fact.get("hit_count", 0)) > 0 or fact.has("hit_breakable_ids")):
			return true
	return false


func _apply_combat_breakable_facts(result: Dictionary) -> void:
	for fact: Dictionary in result.get("facts", []):
		if fact.get("event_type") != &"player_attack_resolved":
			continue
		var simulation = in_run_runtime.simulation
		var obstacles: Array = simulation.arena_obstacles if simulation != null else []
		var hits := BreakableCombat.breakable_hits(context, fact, obstacles)
		if not hits.is_empty():
			BreakableCombat.install_hits(context, hits)
			fact["hit_breakable_ids"] = hits.keys()
			result["durability_required"] = true


func commit_field_attack(fact: Dictionary, mutate_weapon: Callable = Callable()) -> Dictionary:
	if not context.run_active or in_run_runtime.has_active_combat():
		return _atomic_error("field_attack_unavailable")
	var impacted := BreakableCombat.breakable_hits(context, fact, fact.get("arena_obstacles", []))
	if impacted.is_empty() and not mutate_weapon.is_valid():
		return {"ok": true, "status": &"field_swing", "field_attack": fact}
	return execute_atomic_operation(&"field_attack", fact, func() -> Dictionary:
		if mutate_weapon.is_valid():
			mutate_weapon.call()
		BreakableCombat.install_hits(context, impacted)
		_pending_change_scope = &"combat"
		return {"ok": true, "status": &"field_attack", "field_attack": fact, "hit_breakable_ids": impacted.keys()}
	)


func _start_combat_save(
	before: Dictionary, candidate: Dictionary, result: Dictionary, action_id: String, fingerprint: String,
	change_scope: StringName, requested_commands: Array[Dictionary]
) -> bool:
	var admission: Dictionary = meta_progress_adapter.data.get("admission", {})
	if admission.get("phase") != "active" or admission.get("run_id") != candidate["run_id"]:
		return false
	if not meta_progress_adapter.can_write_persistence():
		return false
	var committed := _prepare_combat_receipt(candidate, result, action_id, fingerprint)
	# The worker receives only detached data. It never accesses game objects or
	# the live save adapters, and uses the same validated atomic writer.
	var profile := {
		"id": meta_progress_adapter.active_profile_id,
		"path": meta_progress_adapter.active_meta_progress_path,
		"data": meta_progress_adapter.data.duplicate(true),
	}
	var thread := Thread.new()
	if thread.start(_write_combat_save.bind(candidate, _checkpoint_header(candidate), profile)) != OK:
		return false
	_pending_combat_save = {
		"before": before, "candidate": candidate, "result": committed, "scope": change_scope, "commands": requested_commands,
	}
	_combat_save_thread = thread
	return true


static func _write_combat_save(candidate: Dictionary, checkpoint: Dictionary, profile: Dictionary) -> Dictionary:
	var encoded := StateSnapshotScript.pack_checkpoint(candidate)
	if encoded.is_empty():
		return {"ok": false, "reason": "invalid_candidate_state"}
	checkpoint["state"] = encoded
	var meta := MetaProgressAdapter.new()
	meta.active_profile_id = profile["id"]
	meta.active_meta_progress_path = profile["path"]
	meta.data = profile["data"]
	var writer := CheckpointServiceScript.new()
	var configured := writer.configure(meta, "z2", Z2_CONTENT_VERSION)
	return writer.save_checkpoint(checkpoint) if bool(configured.get("ok", false)) else configured


func has_pending_combat_save() -> bool:
	return _combat_save_thread != null


func _combat_save_pending() -> Dictionary:
	return {"ok": false, "status": &"checkpoint_pending", "reason": "checkpoint_pending"}


func finish_pending_combat_save(wait := false, publish := true) -> Dictionary:
	if not has_pending_combat_save():
		return {"ok": true}
	if not wait and _combat_save_thread.is_alive():
		return _combat_save_pending()
	var saved: Dictionary = _combat_save_thread.wait_to_finish()
	var pending := _pending_combat_save
	_combat_save_thread = null
	_pending_combat_save = {}
	if not bool(saved.get("ok", false)):
		var failed := {"ok": false, "reason": str(saved.get("reason", "checkpoint_save_failed")),
			"status": &"save_failed", "storage_error": saved}
		persistence_error = failed.duplicate(true)
		return failed
	var installed := install_authoritative_state(pending["candidate"], pending["before"])
	if not bool(installed.get("ok", false)):
		return _storage_error(installed)
	if publish:
		_publish_command_requests(pending["commands"])
		command_bus._emit_state(pending["scope"] if pending["scope"] != &"" else &"combat")
	return pending["result"]

func retry_persistence() -> Dictionary:
	if persistence_error.is_empty():
		return {"ok": true, "status": &"ready"}
	var result: Dictionary
	if checkpoint_writer.is_valid():
		result = persist_candidate_state(capture_authoritative_state())
	elif checkpoint_service == null and _persistence_manager != null:
		return initialize_z2_session(_persistence_manager)
	elif checkpoint_service != null:
		result = _restore_durable_checkpoint(false)
	else:
		result = {"ok": true}
	if bool(result.get("ok", false)):
		persistence_error.clear()
	return result

func initialize_z2_session(manager) -> Dictionary:
	_persistence_manager = manager
	if meta_progress_adapter == null:
		return _storage_error(_atomic_error("meta_progress_adapter_missing"))
	var reset: Dictionary = manager.reset_outdated_profiles_for_z2()
	if not bool(reset.get("ok", false)):
		return _storage_error(reset)
	manager.configure_meta_adapter(meta_progress_adapter)
	if not meta_progress_adapter.can_write_persistence():
		return _storage_error(_atomic_error(meta_progress_adapter.write_block_reason))
	if meta_progress_adapter.last_load_status == "missing":
		var initialized: Dictionary = meta_progress_adapter.initialize_z2_profile(Z2_CONTENT_VERSION)
		if not bool(initialized.get("ok", false)):
			return _storage_error(initialized)
	if str(meta_progress_adapter.data.get("ruleset_id", "")) != "z2":
		return _storage_error(_atomic_error("z2_profile_required"))
	var manifest_saved: Dictionary = manager.save_manifest()
	if not bool(manifest_saved.get("ok", false)):
		return _storage_error(manifest_saved)
	var registry := ContentDefRegistry.new()
	var registered := registry.setup_z2()
	if not registered.get("ok", false):
		return _storage_error(registered)
	_content_hash = StateSnapshotScript.fingerprint(registry.snapshot())
	checkpoint_service = CheckpointServiceScript.new()
	var configured: Dictionary = manager.configure_checkpoint_service(checkpoint_service, meta_progress_adapter, "z2", Z2_CONTENT_VERSION)
	if not bool(configured.get("ok", false)):
		checkpoint_service = null
		return _storage_error(configured)
	var restored := _restore_durable_checkpoint(true)
	if bool(restored.get("ok", false)):
		persistence_error.clear()
	return restored

func _restore_durable_checkpoint(force_install: bool) -> Dictionary:
	var loaded: Dictionary = checkpoint_service.recover_admission()
	if str(loaded.get("status", "")) == "no_admission":
		return {"ok": true, "status": "ready"}
	if not bool(loaded.get("ok", false)):
		return _storage_error(loaded)
	if not loaded.has("snapshot"):
		return loaded
	var checkpoint: Dictionary = loaded["snapshot"]
	var checkpoint_hash := str(checkpoint.get("content_hash", ""))
	if checkpoint_hash != _content_hash and (
		str(checkpoint.get("content_version", "")) != Z2_CONTENT_VERSION
		or checkpoint_hash not in Z2_COMPATIBLE_CHECKPOINT_HASHES
	):
		return _storage_error(_atomic_error("checkpoint_content_mismatch"))
	# Validate even at the same revision. Retain unsaved motion when the primary
	# is valid and current; a recovered backup must install before repair.
	var install := force_install or str(loaded.get("status", "")) == "recovered_backup" or str(checkpoint["run_id"]) != str(context.run_id) or int(checkpoint["revision"]) != transaction_revision
	var restored := restore_checkpoint_state(checkpoint["state"], checkpoint, install)
	if not bool(restored.get("ok", false)):
		return _storage_error(restored)
	if install:
		# Only presentation metadata is normalized after full original validation.
		# Keep all receipts/resources/history and write the current identity on
		# the next ordinary durable action; never rewrite the old admission.
		context.tutorial_popup = TutorialServiceScript.normalized_popup(context.tutorial_popup)
	if str(loaded.get("status", "")) == "recovered_backup":
		var recovered: Dictionary = checkpoint_service.confirm_checkpoint_recovery(int(loaded["generation"]), str(loaded["snapshot_hash"]))
		if not bool(recovered.get("ok", false)):
			return _storage_error(recovered)
	if not bool(loaded.get("can_simulate", false)):
		return _storage_error(_atomic_error("admission_not_active"))
	if not context.run_active and not context.result_snapshot.is_empty():
		_on_terminal_result_available(context.result_snapshot)
	return {"ok": true, "status": "restored", "run_id": str(context.run_id), "revision": transaction_revision}

func _storage_error(result: Dictionary) -> Dictionary:
	persistence_error = result.duplicate(true)
	return result

func save_current_checkpoint() -> Dictionary:
	if has_pending_combat_save():
		return finish_pending_combat_save(true)
	if not context.run_started or checkpoint_service == null:
		return {"ok": persistence_error.is_empty(), "status": "no_active_checkpoint"}
	if not persistence_error.is_empty():
		return _atomic_error("persistence_retry_required")
	if not context.run_active and meta_progress_adapter != null and meta_progress_adapter.data.get("run_receipts", {}).has(str(context.run_id)):
		return {"ok": true, "status": "settled"}
	return execute_atomic_operation(&"checkpoint", {}, func() -> Dictionary:
		_checkpoint_elapsed = 0.0
		return {"ok": true}
	)

func is_combat_flee_authorized() -> bool:
	return in_run_runtime.flee_authorized and in_run_runtime.current_room_key == context.cell_key(context.get_current_pos())


func authorize_combat_flee() -> void:
	update_player_location(in_run_runtime.get_player_local_position(_local_position))
	in_run_runtime.current_room_key = context.cell_key(context.get_current_pos())
	in_run_runtime.flee_authorized = true
	in_run_runtime.simulation = null


func sync_room_transition(direction: Vector2i, preferred_entry: Vector2 = Vector2(-1, -1)) -> void:
	# Called by the room-changing command while its candidate is still mutable.
	# The Scene supplies its read-only sprite clearance; room solids and combat
	# initialization are resolved here, before the original checkpoint is saved.
	var inset := G41RuntimeLayout.PLAYER_BODY_RADIUS + 0.005
	var floor_rect := G41WorldObjectProjection.room_floor_interior().grow(-inset)
	var landing := preferred_entry
	if not landing.is_finite() or landing.x < 0.0 or landing.y < 0.0:
		landing = Vector2(0.30, 0.50)
		if direction.x != 0:
			landing = Vector2(floor_rect.position.x if direction.x > 0 else floor_rect.end.x, 0.5)
		elif direction.y != 0:
			landing = Vector2(0.5, floor_rect.position.y if direction.y > 0 else floor_rect.end.y)
	landing = landing.clamp(floor_rect.position, floor_rect.end)
	var event_type := EventService.get_event_type(context, context.get_current_pos()) if context.current_room_type == &"Event" else &""
	var solids := G41WorldObjectProjection.room_solid_rects(context.current_room_type, event_type, Z1EventCatalog.number(event_type) > 0)
	for point: Vector2 in [landing, Vector2(0.50, 0.72), Vector2(0.50, 0.28), Vector2(0.28, 0.72), Vector2(0.72, 0.72)]:
		if not solids.any(func(rect: Rect2) -> bool: return rect.grow(G41RuntimeLayout.PLAYER_BODY_RADIUS).has_point(point)):
			landing = point
			break
	update_player_location(landing)
	in_run_runtime.sync_room(landing)
	var placed: Dictionary = in_run_runtime.place_player_from_room_entry(landing, direction)
	if bool(placed.get("applied", false)):
		update_player_location(Vector2(placed["position"]))


func update_player_location(position: Vector2) -> void:
	if persistence_error.is_empty() and is_finite(position.x) and is_finite(position.y):
		_local_position = position
		_has_local_position = true

func get_restored_local_position(fallback: Vector2) -> Vector2:
	if in_run_runtime.has_active_combat():
		return in_run_runtime.get_player_local_position(fallback)
	return _local_position if _has_local_position else fallback

func advance_simulation_time(delta: float, trigger: Dictionary = {}) -> Dictionary:
	if not context.run_active or not is_finite(delta) or delta < 0.0:
		return {"ok": false, "reason": "invalid_simulation_time"}
	var result: Dictionary = VitalsEffects.advance_statuses(context, delta, trigger)
	if not bool(result.get("ok", false)):
		return result
	if Z2Hooks.applies_to(context) and context.hp > 0 and not in_run_runtime.has_active_combat():
		var search := _advance_z2_search(delta)
		if not search.get("ok", false):
			return search
		if search.get("completed_now", false):
			result["durability_required"] = true
	_checkpoint_elapsed += delta
	if _checkpoint_elapsed >= 1.0:
		result["durability_required"] = true
		_checkpoint_elapsed = fmod(_checkpoint_elapsed, 1.0)
	return result


func can_advance_transient_combat_time(delta: float) -> bool:
	if _planning_action or not persistence_error.is_empty() or not context.run_active or context.hp <= 0:
		return false
	if _checkpoint_elapsed + delta >= 1.0 or not context.temporary_statuses.is_empty():
		return false
	return not Z2Hooks.applies_to(context) or (
		int(context.z1_event_flags.get("z2_income_cursor", 0)) == context.asset_ledger.settlement_log.size()
	)


func advance_transient_combat_time(delta: float) -> void:
	_checkpoint_elapsed += delta


func begin_z2_search() -> Dictionary:
	var search := Z2Search.new()
	var saved: Dictionary = context.z1_event_flags.get("z2_search", {})
	if not saved.is_empty() and not search.import_transaction_state(saved).get("ok", false):
		return {"ok": false, "reason": "invalid_search_snapshot"}
	var result := search.begin(str(context.run_id), context.cell_key(context.get_current_pos()), context.current_room_type,
		Z2_SEARCH_BASE_SECONDS, Z2TalentRuntime.from_context(context), _z2_search_gates())
	if result.get("ok", false):
		context.z1_event_flags["z2_search"] = search.export_transaction_state()
		context.last_message = "搜索中：%d%%" % roundi(float(result.progress) * 100.0)
		result["message"] = context.last_message
	return result


func _z2_search_gates() -> Dictionary:
	return {"run_active": context.run_active, "online": true, "paused": false, "combat_active": in_run_runtime.has_active_combat()}


func _advance_z2_search(delta: float) -> Dictionary:
	var saved: Dictionary = context.z1_event_flags.get("z2_search", {})
	var room: String = context.cell_key(context.get_current_pos())
	if saved.is_empty() or not saved.get("rooms", {}).has(room) or context.searched_cells.has(room):
		return {"ok": true}
	var search := Z2Search.new()
	var restored := search.import_transaction_state(saved)
	if not restored.get("ok", false):
		return restored
	var result := search.advance(delta, str(context.run_id), room, _z2_search_gates())
	if not result.get("ok", false):
		return result
	context.z1_event_flags["z2_search"] = search.export_transaction_state()
	context.last_message = "搜索中：%d%%" % roundi(float(result.progress) * 100.0)
	if result.phase == "ready":
		var completed := search.complete(str(context.run_id), room, _z2_search_gates())
		if not completed.get("ok", false):
			return completed
		if completed.get("completed_now", false):
			var reward: Dictionary = command_bus.room_resolver.search_current_room(context, true)
			if not reward.get("ok", false):
				return reward
			context.z1_event_flags["z2_search"] = search.export_transaction_state()
			# Timed search changes world objects and exact floor contents. Publish
			# that full projection only after this atomic idle step is persisted.
			defer_state_change(&"all")
			return {"ok": true, "completed_now": true}
	return {"ok": true}

func advance_idle_frame(delta: float) -> Dictionary:
	if not context.run_active or not persistence_error.is_empty():
		return {"ok": false, "reason": "simulation_blocked"}
	if not is_finite(delta) or delta < 0.0:
		return _atomic_error("invalid_simulation_time")
	return execute_atomic_operation(&"idle_time", {"durability_required": false}, func() -> Dictionary:
		_idle_accumulator += minf(delta, 0.25)
		var durable := false
		while _idle_accumulator + 0.000000001 >= 1.0 / 60.0:
			_idle_accumulator = maxf(0.0, _idle_accumulator - 1.0 / 60.0)
			if in_run_runtime != null:
				in_run_runtime.advance_field_reload(1.0 / 60.0)
			var advanced := advance_simulation_time(1.0 / 60.0)
			if not bool(advanced.get("ok", false)):
				return advanced
			durable = durable or bool(advanced.get("durability_required", false))
			if context.hp <= 0:
				_idle_accumulator = 0.0
				break
		return {"ok": true, "durability_required": durable}
	)

func apply_combat_hit(packet: Dictionary) -> Dictionary:
	if not _planning_action:
		return execute_atomic_operation(&"combat_hit", packet, Callable(self, "_apply_combat_hit").bind(packet), str(packet.get("hit_id", "")))
	return _apply_combat_hit(packet)

func _apply_combat_hit(packet: Dictionary) -> Dictionary:
	var hit_id := str(packet.get("hit_id", ""))
	var fingerprint := StateSnapshotScript.fingerprint(packet)
	if not hit_id.is_empty() and _combat_hit_receipts.has(hit_id):
		var previous: Dictionary = _combat_hit_receipts[hit_id]
		return previous["result"].duplicate(true) if previous["fingerprint"] == fingerprint else _atomic_error("hit_id_conflict")
	var source_id := str(packet.get("source_id", "combat"))
	var damage: Dictionary = VitalsEffects.apply_damage_packet(context, {"amount": maxi(0, int(packet.get("damage", 0))), "damage_type": "physical", "source_id": source_id})
	if not bool(damage.get("ok", false)):
		return damage
	var pressure := int(packet.get("pressure_delta", 0))
	if pressure != 0:
		var pressure_result: Dictionary = VitalsEffects.apply_pressure_packet(context, {"amount": pressure, "source_id": source_id, "reason": "combat"})
		if not bool(pressure_result.get("ok", false)):
			return pressure_result
	var triggered := advance_simulation_time(0.0, {"kind": "hit", "hit_id": hit_id})
	if not bool(triggered.get("ok", false)):
		return triggered
	var facts: Dictionary = damage.get("facts", {})
	context.run_stats["combat_damage"] = int(context.run_stats.get("combat_damage", 0)) + int(facts.get("actual_hp_loss", 0))
	context.enemy_state["runtime_combat_tick"] = int(packet.get("combat_tick", 0))
	context.record_event(&"runtime_combat_damage", str(context.active_command.get("command_id", "")), &"player", source_id, {"hit_id": hit_id, "facts": facts.duplicate(true), "combat_tick": int(packet.get("combat_tick", 0))})
	var result := {"ok": true, "hp": context.hp, "max_hp": context.max_hp, "power": context.power, "shield": context.shield, "actual_hp_loss": int(facts.get("actual_hp_loss", 0)), "absorbed": int(facts.get("absorbed", 0)), "dead": context.hp <= 0, "facts": facts}
	if not hit_id.is_empty():
		_combat_hit_receipts[hit_id] = {"fingerprint": fingerprint, "result": result.duplicate(true)}
	return result

func _atomic_error(reason: String) -> Dictionary:
	return {"ok": false, "accepted": false, "status": StringName(reason), "reason": reason, "reason_code": reason, "blocked_reason": reason}

func _without_uncommitted_facts(value: Variant) -> Variant:
	if value is Array:
		var clean_array: Array = []
		for entry in value:
			clean_array.append(_without_uncommitted_facts(entry))
		return clean_array
	if value is Dictionary:
		var clean: Dictionary = {}
		for key in value:
			if str(key) in ["produced_events", "produced_transactions", "transactions", "facts"]:
				clean[key] = [] if value[key] is Array else {}
			elif str(key) == "transaction":
				clean[key] = {}
			else:
				clean[key] = _without_uncommitted_facts(value[key])
		return clean
	return value
