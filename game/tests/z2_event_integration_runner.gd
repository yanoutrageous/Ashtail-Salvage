extends SceneTree

const Events = preload("res://scripts/core/run/z2_event_runtime.gd")
const Service = preload("res://scripts/core/run/event_service.gd")
const Legacy = preload("res://scripts/core/run/z1_event_runtime.gd")
const Items = preload("res://scripts/core/content/z2_item_catalog.gd")
const Eligibility = preload("res://scripts/core/content/z2_content_eligibility.gd")
const Process = preload("res://scripts/core/run/z2_process_events.gd")
const Loot = preload("res://scripts/core/content/z2_loot_catalog.gd")
const Hooks = preload("res://scripts/core/run/z2_run_hooks.gd")
const DialogueScene = preload("res://scenes/components/z2_overlays/z2_event_dialogue.tscn")
const Snapshot = preload("res://scripts/core/run/run_state_snapshot.gd")
const EXPECTED := ["shop", "savings", "seal", "relief", "first_aid", "consign", "expand", "compress", "trader", "pawn", "information", "shortcut", "demine", "recon", "mechanism", "recycle", "coil", "clock_in", "rps", "cage", "dice", "altar"]

# Frozen S3 sheet 事件确认, SHA256 515F69FF5463A87AA427B669C5D987CF959B652A726294864E4FEC1E808035A2.
# Independent expected identities; anchors are verbatim literal spans, not generated values.
const EXPECTED_EVENT_SPEAKERS := {"information": "线报员", "shop": "店主", "savings": "储蓄机", "seal": "档案员", "mechanism": "机关", "recycle": "回收员", "relief": "老板", "first_aid": "播报", "consign": "接线员", "expand": "师傅", "compress": "屏幕", "trader": "旅商", "pawn": "放贷人", "shortcut": "检修工", "coil": "技师", "demine": "爆破手", "clock_in": "值班员", "recon": "侦察员", "rps": "闲客", "cage": "广播", "dice": "庄家", "altar": "祭坛"}
const EXPECTED_S3_RESPONSE_IDENTITIES := {
	16: ["information", [["就这么点东西了，别把我话", "线报员"]]],
	20: ["information", [["感谢老板，老板大气！", "线报员"]]],
	38: ["shop", [["好嘞好嘞，新东西来咯，你", "店主"]]],
	53: ["savings", [["蟹蟹喵！蟹蟹喵！蟹蟹喵！", "储蓄机"], ["（好像只会一直重复了）", "玩家"]]],
	54: ["savings", [["这储蓄机魔了。", "玩家"]]],
	69: ["seal", [["感谢您的到来，欢迎下次光", "档案员"], ["（就这一张，他还是等我点", "玩家"]]],
	84: ["mechanism", [["那张安全告示掉了下来。", ""]]],
	87: ["mechanism", [["啊哈，就是这个！", "玩家"]]],
	88: ["mechanism", [["（拉杆猛地弹回，夹住了手", ""], ["嘶——", "玩家"]]],
	103: ["recycle", [["好吧，那你自己拿稳咯，小", "回收员"]]],
	104: ["recycle", [["（老人翻看了一下材料，在", ""], ["，记上了，剩下的路你自己", "回收员"]]],
	119: ["relief", [["（老板沿着管道摸到漏气的", ""], ["这下清静了，你也不用跟着", "老板"]]],
	120: ["relief", [["（热水没过脚背，你往凳子", ""], ["水温还行吧？烫了你就说，", "老板"]]],
	121: ["relief", [["是这儿难受？", "老板"], ["哎哎哎轻点，疼！", "玩家"], ["好好好，我换个地方.你手", "老板"], ["（老板放轻了手，顺着肩背", ""]]],
	137: ["first_aid", [["（急救贴卡在出口晃了两下", ""], ["发放完成，请取走您的急救", "播报"]]],
	152: ["consign", [["（包裹被吸走，管道里紧接", ""], ["喂轻点啊，里面装着东西呢", "玩家"], ["知道，是管子拐弯的动静！", "接线员"]]],
	167: ["expand", [["（师傅缝好肩带，让你背上", ""], ["行了，这回能装下了，线头", "师傅"]]],
	182: ["compress", [["，机器里面接着咳了一声.", ""], ["……里面有人吗？", "玩家"], ["加工完成，请从出料口取物", "屏幕"]]],
	201: ["trader", [["（旅商对完账，把收来的东", ""], ["好嘞，收到了！你也看看账", "旅商"]]],
	216: ["pawn", [["押票请收好", "放贷人"]]],
	246: ["coil", [["（技师把扳手塞进抽屉，重", ""], ["好了，你下次把普通房搜仔", "技师"]]],
	262: ["demine", [["（爆破手示意你捂住耳朵，", ""], ["炸掉了，这颗我给你标上.", "爆破手"]]],
	263: ["demine", [["（隔壁只响了一声，爆破手", ""], ["没雷，你这旗插错了.", "爆破手"], ["嗯，刚跟你说过了.", "爆破手"]]],
	278: ["clock_in", [["（值班员盖上章，吹了吹没", ""]]],
	280: ["clock_in", [["数数吧，这单给你结了.", "办事人"]]],
	295: ["recon", [["（侦察员核对了一遍读数，", ""], ["内的雷都标出来了，扫到地", "侦察员"], ["（地图更新雷位，尚未实际", ""]]],
	310: ["rps", [["哎怎么又一样了！这把不算", "闲客"]]],
	311: ["rps", [["啧又猜着了……行，这分你", "闲客"], ["（他在你的分数下面添了一", ""]]],
	312: ["rps", [["哈哈这回抓着你了，这分归", "闲客"], ["（他在自己那边画下一道，", ""]]],
	313: ["rps", [["枚黑币递过来，嘴里还念叨", ""], ["拿去吧，我刚才真不该换…", "闲客"]]],
	314: ["rps", [["我去终于赢了！看见没这回", "闲客"], ["（他把记分纸拍到稻草人面", ""], ["钱你揣着就行，说好了不要", "闲客"]]],
	332: ["cage", [["（掌声又响了起来，出口的", ""], ["恭喜本场获胜选手，请从出", "广播"]]],
	333: ["cage", [["本场比赛结束，请工作人员", "广播"]]],
	349: ["dice", [["点啊，唉，这把差点运气.", "庄家"]]],
	350: ["dice", [["才坐热怎么就要走了，再玩", "庄家"]]],
	351: ["dice", [["哟中了啊！", "庄家"]]],
	352: ["dice", [["六点？拿来我看看……", "庄家"], ["（他拎起骰盅看了一眼，又", ""], ["你数数.", "庄家"]]],
	370: ["altar", [["（血顺着凹槽流进去，供品", ""]]],
}

var failures: Array[String] = []
var checks := 0

# Inherits the real atomic runtime and CommandBus; only parent-owned dependency
# callbacks are supplied here. The fixture pools are not official fallback data.
class HarnessRuntime extends RunRuntimeController:
	var fail_stage := false
	var fail_income := false
	var missing_stage := false
	var missing_income := false
	var pools: Dictionary = {}
	var process_rules: Dictionary = {}
	func z2_event_hooks(_context: RunContext, _pos: Vector2i, _event_id: String) -> Dictionary:
		return {"action_id": _active_action_id, "economy_catalog": pools, "process_rules": process_rules,
			"consume_stage": Callable() if missing_stage else _stage,
			"consume_income": Callable() if missing_income else _income,
			"consume_facts": _facts,
			"enter_room": _enter}
	func _facts(candidate: RunContext, fact: Dictionary) -> Dictionary:
		candidate.run_stats["integration_fact_calls"] = int(candidate.run_stats.get("integration_fact_calls", 0)) + 1
		candidate.run_stats["integration_last_facts"] = fact.duplicate(true)
		return {"ok": true}
	func _stage(candidate: RunContext, fact: Dictionary) -> Dictionary:
		candidate.run_stats["integration_stage_calls"] = int(candidate.run_stats.get("integration_stage_calls", 0)) + 1
		if fail_stage:
			return {"ok": false, "reason": "injected_stage_failure"}
		candidate.run_stats["integration_xp"] = int(candidate.run_stats.get("integration_xp", 0)) + int(fact.get("base_xp", 0))
		candidate.run_stats["integration_talent"] = int(candidate.run_stats.get("integration_talent", 0)) + int(fact.get("base_talent", 0))
		candidate.run_stats["integration_equipment"] = int(candidate.run_stats.get("integration_equipment", 0)) + int(bool(fact.get("equipment_eligible", false)))
		candidate.run_stats["integration_last_stage"] = fact.duplicate(true)
		return {"ok": true}
	func _income(candidate: RunContext, fact: Dictionary) -> Dictionary:
		candidate.run_stats["integration_gross"] = int(candidate.run_stats.get("integration_gross", 0)) + int(fact.get("gross_amount", 0))
		return {"ok": not fail_income, "reason": "injected_income_failure" if fail_income else ""}
	func _enter(request: Dictionary) -> Dictionary:
		context.run_stats["integration_entry_calls"] = int(context.run_stats.get("integration_entry_calls", 0)) + 1
		context.player_pos = request.target_pos
		context.current_pos = request.target_pos
		return command_bus.room_resolver.enter_room(context)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_registry_and_projection()
	_test_actual_event_selection()
	_test_placement()
	_test_command_purchase()
	_test_atomic_consumers()
	_test_savings_income()
	_test_information_route()
	_test_legacy_guards()
	_test_owner_process_available()
	_test_official_pool_defaults()
	_test_cage_type_projection()
	_test_voluntary_cage()
	_test_compression_facts()
	_test_economy_routes()
	_test_information_choices()
	_test_process_choices()
	_test_level_16_altar()
	_test_continuations()
	_test_clock_continuation()
	_test_all_player_projections()
	_test_settled_player_responses()
	_test_savings_input_projection()
	_test_legacy_mechanism_weights()
	_test_mechanism_selection_and_replay()
	_test_mechanism_saved_compatibility()
	for failure in failures:
		print("Z2_EVENT_INTEGRATION_FAIL " + failure)
	print("Z2_EVENT_INTEGRATION=%s checks=%d" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _runtime() -> HarnessRuntime:
	var r := HarnessRuntime.new()
	r.command_bus.dispatch(&"start_demo_run", {})
	r.context.run_start_config["profile_fields"] = {"ruleset_id": "z2", "z2_progression_version": 1,
		"content_eligibility": Eligibility.freeze_profile({"profile_level": 50})}
	r.context.profile_fields = r.context.run_start_config.profile_fields.duplicate(true)
	r.context.run_start_config["map_config_id"] = "classic_13x13_normal"
	r.context.asset_ledger.setup({"run_id": str(r.context.run_id)})
	r.context.asset_ledger.add_currency(&"black_coin", 300, "integration_setup")
	r.context.z1_event_rooms.clear()
	r.context.z1_event_flags.clear()
	r.context.interacted_cells.clear()
	r.context.run_stats.clear()
	r.context.pressure = 50
	r.context.power = 999
	r.pools = {"shop_pool": [["con_calm_candy", 3], ["con_scan_pin", 2]], "compression_pool": [["col_22", 1]]}
	_room(r, Vector2i(2, 2), "shop")
	return r

func _room(r: HarnessRuntime, pos: Vector2i, event_id: String) -> void:
	r.context.player_pos = pos
	r.context.current_pos = pos
	r.context.current_room_type = &"Event"
	r.context.z1_event_rooms[r.context.cell_key(pos)] = {"event_type": StringName(event_id)}

func _dispose(r: HarnessRuntime) -> void:
	r.checkpoint_writer = Callable()
	r.command_bus.runtime_controller = null
	r.command_bus.room_resolver.bind_runtime_controller(null)
	r.in_run_runtime.bind(null)

func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)

func _result(raw: Dictionary) -> Dictionary:
	var result: Dictionary = raw.get("action_result", raw).duplicate(true)
	if raw.get("duplicate", false):
		result["duplicate"] = true
	return result

func _prepare(r: HarnessRuntime, selection: Dictionary = {}) -> bool:
	var payload := selection.duplicate(true)
	payload["option_id"] = "prepare"
	var result := _result(r.command_bus.dispatch(&"select_event_option", payload))
	_check(result.get("ok", false), "CommandBus prepares " + str(Service.get_event_type(r.context, r.context.get_current_pos())) + ": " + str(result.get("reason", "")))
	return bool(result.get("ok", false))

func _state(r: HarnessRuntime) -> Dictionary:
	return Service.get_event_state(r.context, r.context.get_current_pos())

func _request(r: HarnessRuntime, action: String, selection: Dictionary = {}) -> Dictionary:
	var state := _state(r)
	var payload: Dictionary = {"option_id": action}
	for option: Dictionary in state.get("options", []):
		if str(option.get("id", "")) == action:
			var params: Dictionary = option.get("payload", {})
			var matches := true
			for key: Variant in selection:
				if params.has(key) and params[key] != selection[key]:
					matches = false
			if matches:
				payload.merge(params, true)
				break
	payload.merge(selection, true)
	return payload

func _choose(r: HarnessRuntime, action: String, selection: Dictionary = {}) -> Dictionary:
	var authoritative_view: Dictionary = _state(r)
	var result := _result(r.command_bus.dispatch(&"select_event_option", _request(r, action, selection)))
	if result.get("ok", false):
		_check_response(result, authoritative_view)
	return result

func _check_response(result: Dictionary, authoritative_view: Dictionary) -> void:
	var message := str(result.get("message", ""))
	var event := str(result.get("event_type", ""))
	_check(not message.is_empty() and message != "已完成本次操作。" and not result.get("response_lines", []).is_empty(), event + " actual settled response")
	_check(str(authoritative_view.get("speaker", "")) == str(EXPECTED_EVENT_SPEAKERS.get(event, "")), event + " authoritative source identity")
	for line: Dictionary in result.get("response_lines", []):
		if not line.has("source_row"):
			_check(not line.has("speaker") and str(line.get("text", "")) == message, event + " actual result inherits authoritative view speaker")
			continue
		var identity: Dictionary = _s3_response_identity(event, line)
		var expected_speaker: String = str(identity.get("speaker", ""))
		var matches: bool = not line.has("speaker") if expected_speaker.is_empty() else line.get("speaker") == expected_speaker
		_check(bool(identity.get("known", false)) and matches, "%s S3 B%d exact source speaker" % [event, int(line.get("source_row", 0))])
	var facts: Dictionary = result.get("facts", {})
	for key in ["fee_black", "black_income_gross"]:
		if int(facts.get(key, 0)) > 0:
			_check(message.contains("%d黑币" % int(facts[key])), event + " response includes actual " + key)
	var items: Array = facts.get("items", []).duplicate(true)
	if facts.has("delivery"):
		items.append(facts.delivery)
	for item: Dictionary in items:
		_check(message.contains(str(item.get("display_name", item.get("item_id", "")))), event + " response names exact delivered item")
		if str(item.get("location_state", "")) == "room_floor":
			_check(message.contains("地面"), event + " response retains overflow location")

func _s3_response_identity(event: String, line: Dictionary) -> Dictionary:
	var row: Array = EXPECTED_S3_RESPONSE_IDENTITIES.get(int(line.get("source_row", 0)), [])
	if not row.is_empty() and str(row[0]) == event:
		for expected: Array in row[1]:
			if str(line.get("text", "")).contains(str(expected[0])):
				return {"known": true, "speaker": str(expected[1])}
	return {"known": false, "speaker": ""}

func _black(r: HarnessRuntime) -> int:
	return r.context.asset_ledger.get_currency(&"black_coin")

func _test_registry_and_projection() -> void:
	_check(Events.event_ids().size() == 22, "exactly22 canonical events")
	var r := _runtime()
	for event in EXPECTED:
		_room(r, Vector2i(2, 2), event)
		var before: Dictionary = r.capture_authoritative_state()
		var projected := _state(r)
		_check(str(projected.get("event_type", "")) == event and str(projected.get("ruleset_id", "")) == "z2", event + ": EventService routes Z2 projection")
		_check(projected.has("owner") and projected.has("requires_prepare"), event + ": owner projection contract")
		_check(str(projected.get("speaker", "")) == str(EXPECTED_EVENT_SPEAKERS[event]), event + ": exact S3 view identity")
		_check(r.capture_authoritative_state() == before, event + ": projection is pure")
	for pair in [["z1_event_e01", "information"], ["z1_event_e04", "information"], ["z1_event_e17", "information"], ["z1_event_e02", "recycle"], ["z1_event_e07", "recycle"], ["z1_event_e08", "recycle"], ["z1_event_e06", "mechanism"], ["trap", "mechanism"], ["z1_event_e23", "relief"], ["z1_event_e25", "shop"]]:
		_check(Events.canonical(pair[0]) == pair[1], "legacy alias " + pair[0])
		_room(r, Vector2i(2, 2), pair[0])
		var projected := Legacy.public_state(r.context, r.context.get_current_pos(), StringName(pair[0]))
		_check(str(projected.get("event_type", "")) == pair[1] and projected.get("ruleset_id", "") == "z2", "Z1 direct API delegates " + pair[0])
	_dispose(r)

func _test_command_purchase() -> void:
	var r := _runtime()
	_room(r, Vector2i(2, 2), "z1_event_e25")
	if not _prepare(r):
		_dispose(r)
		return
	var state := _state(r)
	var quoted := _request(r, "buy", {"slot": 0})
	quoted["action_id"] = "integration_purchase"
	_check(not str(quoted.get("quote_id", "")).is_empty(), "UI payload carries saved quote")
	var price := int(state.get("offers", [])[0].price)
	var result := _result(r.command_bus.dispatch(&"select_event_option", quoted))
	_check(result.get("ok", false) and _black(r) == 300 - price, "CommandBus -> EventService -> economy: exact charge")
	_check(r.context.run_stats.get("integration_xp", 0) == 5 and r.context.run_stats.get("integration_talent", 0) == 2, "first service consumes actual growth callback once")
	_check(result.get("stage_facts", []).size() == 1 and _state(r).get("allow_after_completion", false), "unified stage / shop remains interactive")
	var before: Dictionary = r.capture_authoritative_state()
	result = _result(r.command_bus.dispatch(&"select_event_option", quoted))
	_check(result.get("duplicate", false) or result.get("duplicate_action", false), "outer duplicate returns receipt")
	_check(r.capture_authoritative_state() == before, "duplicate cannot award or deliver again")
	result = _choose(r, "buy", {"slot": 1})
	_check(result.get("ok", false) and r.context.run_stats.get("integration_stage_calls", 0) == 1, "second purchase no stage duplication")
	_check(r.context.run_stats.get("events_completed", 0) == 1, "event completion stats once independent of stock")
	_dispose(r)

func _test_atomic_consumers() -> void:
	for mode in ["stage_failure", "stage_missing", "durable_failure", "stale"]:
		var r := _runtime()
		_room(r, Vector2i(2, 2), "expand")
		if _prepare(r):
			var request := _request(r, "expand")
			r.fail_stage = mode == "stage_failure"
			r.missing_stage = mode == "stage_missing"
			if mode == "durable_failure":
				r.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary: return {"ok": false, "reason": "injected_checkpoint_failure"}
			if mode == "stale":
				r.context.asset_ledger.add_currency(&"black_coin", 1)
			var before: Dictionary = r.capture_authoritative_state()
			var result := _result(r.command_bus.dispatch(&"select_event_option", request))
			_check(not result.get("ok", true), mode + ": transaction rejected")
			_check(r.capture_authoritative_state() == before, mode + ": fee/capacity/owner stage/consumer/logs rollback together")
		_dispose(r)

func _test_savings_income() -> void:
	var r := _runtime()
	_room(r, Vector2i(2, 2), "savings")
	if not _prepare(r, {"amount": 100}):
		_dispose(r)
		return
	var result := _choose(r, "deposit", {"amount": 100})
	if bool(result.get("ok", false)):
		_test_response_nameplate(result, str(_state(r).get("speaker", "")))
	_check(result.get("ok", false) and r.context.asset_ledger.get_currency(&"gold_coin") == 50, "deposit delivered through production entry")
	_room(r, Vector2i(3, 2), "savings")
	_prepare(r)
	r.fail_income = true
	var before: Dictionary = r.capture_authoritative_state()
	result = _choose(r, "withdraw")
	_check(not result.get("ok", true) and r.capture_authoritative_state() == before, "income callback failure rolls back withdrawal and guarantee revoke")
	r.fail_income = false
	result = _choose(r, "withdraw")
	_check(result.get("ok", false) and _black(r) == 320 and r.context.run_stats.get("integration_gross", 0) == 120, "full120 gross trigger, ledger credited only once")
	_check(r.context.run_stats.get("integration_xp", 0) == 10 and r.context.run_stats.get("integration_talent", 0) == 4, "deposit and other-room withdrawal each stage")
	var observation: Dictionary = r.context.run_stats.get("integration_last_facts", {})
	_check(observation.get("position") == Vector2i(3, 2) and observation.get("canonical_type", "") == "savings" and observation.get("substage", "") == "withdraw", "T13 source position/canonical/substage")
	var withdrawal: Dictionary = observation.get("facts", {})
	_check(withdrawal.get("principal", 0) == 100 and withdrawal.get("withdrawn", 0) == 120 and not str(withdrawal.get("transaction_id", "")).is_empty(), "T13 exact savings transaction fields")
	_dispose(r)

func _test_information_route() -> void:
	var r := _runtime()
	_room(r, Vector2i(2, 2), "z1_event_e01")
	if _prepare(r):
		var before_visited: Dictionary = r.context.visited_cells.duplicate(true)
		var result := _choose(r, "mine_count")
		_check(result.get("ok", false) and _black(r) == 300, "legacy e01 delegates free5x5 information")
		_check(r.context.run_stats.get("integration_xp", 0) == 5 and result.get("stage_facts", []).size() == 1, "information consumes unified stage")
		_check(r.context.visited_cells == before_visited, "information does not counterfeit visits")
		var before: Dictionary = r.capture_authoritative_state()
		result = _choose(r, "mine_count")
		_check(not result.get("ok", true) and r.capture_authoritative_state() == before, "information completion cannot repeat")
	_dispose(r)

func _test_legacy_guards() -> void:
	var r := _runtime()
	_room(r, Vector2i(2, 2), "cage")
	var before: Dictionary = r.capture_authoritative_state()
	var forged := Service.resolve_cage(r.context, r.context.get_current_pos(), true)
	_check(not forged.get("ok", true) and r.capture_authoritative_state() == before, "legacy bool win cannot forge real cage completion")
	var state_before: Dictionary = r.capture_authoritative_state()
	Legacy.record_entry(r.context, Vector2i(3, 3))
	_check(r.capture_authoritative_state() == state_before, "old before-entry hook cannot process Z2 clock contract")
	r.context.run_start_config.profile_fields.ruleset_id = "z1"
	r.context.profile_fields.ruleset_id = "z1"
	_room(r, Vector2i(2, 2), "z1_event_e12")
	_check(not Events.applies_to(r.context) and not Service.get_event_state(r.context, r.context.get_current_pos()).has("ruleset_id"), "non-Z2 projection remains legacy")
	_dispose(r)

func _test_owner_process_available() -> void:
	_check(Process.supports("dice"), "T12 implementation available for targeted integration (not a helper-only signoff)")
	if not Process.supports("dice"):
		return
	var r := _runtime()
	_room(r, Vector2i(2, 2), "dice")
	if _prepare(r):
		var state := _state(r)
		_check(state.has("revision"), "process projection exposes saved revision")
		var request := _request(r, "roll")
		_check(request.has("revision"), "process option carries revision")
		var result := _result(r.command_bus.dispatch(&"select_event_option", request))
		_check(result.get("ok", false), "real process roll reached through EventService")
		_check(r.context.run_stats.get("integration_xp", 0) == 5 and r.context.run_stats.get("integration_talent", 0) == 2, "dice first settled stage growth")
		var before: Dictionary = r.capture_authoritative_state()
		result = _result(r.command_bus.dispatch(&"select_event_option", request))
		_check(not result.get("ok", true) and r.capture_authoritative_state() == before, "stale process revision rejected without extra draw or fee")
		result = _choose(r, "roll")
		var observation: Dictionary = r.context.run_stats.get("integration_last_facts", {})
		_check(result.get("ok", false) and r.context.run_stats.get("integration_fact_calls", 0) == 2 and r.context.run_stats.get("integration_stage_calls", 0) == 1, "dice later round emits actual facts without another growth stage")
		_check(observation.get("facts", {}).get("round", 0) == 2 and observation.get("facts", {}).has("won") and observation.get("position") == Vector2i(2, 2), "T13 later dice settled payload")
	_dispose(r)

func _test_official_pool_defaults() -> void:
	var r := _runtime()
	r.pools.clear()
	if _prepare(r):
		var ids := {}
		for entry: Dictionary in Loot.candidates("shop", r.context.run_start_config.profile_fields.content_eligibility, "classic_13x13_normal"):
			ids[entry.item_id] = true
		var offers: Array = _state(r).get("offers", [])
		_check(offers.size() == 3, "actual Loot.economy_catalog default gives3 offers")
		for offer: Dictionary in offers:
			_check(ids.has(str(offer.item.item_id)), "official channel supplies actual shop output")
	_dispose(r)

func _test_actual_event_selection() -> void:
	var r := _runtime()
	r.context.z1_event_rooms.clear()
	r.context.run_start_config.profile_fields.content_eligibility.profile_level = 1
	r.context.profile_fields.content_eligibility.profile_level = 1
	var observed := {}
	for index in range(60):
		var pos := Vector2i(2, 2)
		r.context.z1_event_rooms.clear()
		r.context.seed_value = index
		var result: Dictionary = r.execute_atomic_operation(&"event_assignment", {"pos": pos}, func() -> Dictionary:
			return Events.select_event(r.context, pos))
		_check(result.get("ok", false) and str(result.get("event_type", "")) in ["information", "relief", "first_aid", "recycle"], "Lv1 actual event type filter")
		if result.get("ok", false):
			observed[str(result.event_type)] = true
			var before: Dictionary = r.capture_authoritative_state()
			var repeated := Events.select_event(r.context, pos)
			_check(repeated.get("event_type", "") == result.event_type and r.capture_authoritative_state() == before, "event assignment persists / no reopen reroll")
	_check(observed.size() == 4, "Lv1 four approved types reachable")
	var full: Array = Events.event_pool({"profile_level": 50})
	var ids := {}
	var total := 0.0
	for entry: Dictionary in full:
		ids[entry.event_type] = true
		total += float(entry.roll_weight)
	_check(full.size() == 22 and ids.size() == 22 and is_equal_approx(total, 29.0), "unique22 / inherited total weight29")
	_check(Events.EVENT_LEVELS == {"information": 0, "first_aid": 0, "relief": 0, "recycle": 0, "demine": 6, "shop": 7, "clock_in": 8, "coil": 9, "compress": 9, "mechanism": 11, "expand": 13, "trader": 13, "consign": 13, "recon": 14, "shortcut": 14, "altar": 16, "rps": 17, "savings": 18, "pawn": 18, "seal": 21, "cage": 22, "dice": 26}, "exact 22 playtest event admissions")
	_check(Events.event_pool({"profile_level": 0}) == Events.event_pool({"profile_level": 1}) and Events.event_pool({"profile_level": 0}).size() == 4, "Lv0 and Lv1 share four full events")
	_dispose(r)

func _test_placement() -> void:
	var pairs := 0
	var choices := {}
	for size: int in [7, 10]:
		for seed_index in range(25):
			var ordinal := seed_index + 1
			var level := 1 if size == 7 and ordinal <= 5 else 18
			var profile := {"ruleset_id": "z2", "z2_progression_version": 1,
				"content_eligibility": Eligibility.freeze_profile({"profile_level": level}),
				"early_discovery_run": ordinal if ordinal <= 5 else 0, "visited_event_types": []}
			var context := RunContext.new()
			context.start_run({"mode": &"standard", "width": size, "height": size, "seed": seed_index + 11, "mine_count": size,
				"event_room_count": 7, "chest_room_count": 5, "profile_fields": profile,
				"run_start_config": {"profile_fields": profile, "map_config_id": "classic_7x7_simple" if size == 7 else "classic_10x10_simple"}})
			var savings := 0
			var rooms := 0
			var nearby: Array[String] = []
			for y in size:
				for x in size:
					var pos := Vector2i(x, y)
					var delta := pos - context.truth_map.spawn_pos
					var adjacent := absi(delta.x) + absi(delta.y) == 1
					if context.truth_map.get_room_type(pos) == &"Chest" and adjacent:
						nearby.append("chest")
					if context.truth_map.get_room_type(pos) != &"Event":
						continue
					rooms += 1
					var assigned := Events.select_event(context, pos)
					if adjacent:
						nearby.append(str(assigned.get("event_type", "")))
					if assigned.get("event_type") == "savings":
						savings += 1
			_check(rooms == 7 and savings in ([0] if size < 10 else [0, 2]), "intact quota / exactly paired savings: %d / %d" % [size, seed_index])
			if savings == 2:
				pairs += 1
			if size == 7 and ordinal <= 5:
				nearby.sort()
				_check(nearby.size() >= 2, "two usable neighboring route choices on early run %d" % ordinal)
				choices[str(nearby)] = true
	_check(pairs > 0, "paired savings occurs in actual 10x10 layouts")
	_check(choices.size() == 5, "five early admissions offer distinct neighboring choices")


func _test_cage_type_projection() -> void:
	for enemy in ["bat", "drone"]:
		var r := _runtime()
		_room(r, Vector2i(2, 2), "cage")
		r.context.visited_cells["2,2"] = true
		r.process_rules = {"enemy_pool": [{"enemy_id": enemy, "original_power": 13}]}
		var entered := r.execute_atomic_operation(&"cage_entry", {}, func() -> Dictionary:
			return Events.on_room_entered(r.context, Vector2i(2, 2), "cage", r.z2_event_hooks(r.context, Vector2i(2, 2), "cage")))
		_check(entered.get("ok", false), "actual cage request prepared: " + enemy)
		var before := r.capture_authoritative_state()
		var cage := Events.cage_state(r.context, Vector2i(2, 2))
		_check(str(cage.get("monster_type", "")) == enemy and cage.get("base_power") == 13, "cage preserves selected enemy type: " + enemy)
		_check(r.capture_authoritative_state() == before, "cage projection is pure")
		var receipt := {"actual_combat": true, "encounter_id": cage.get("combat_request", {}).get("encounter_id", ""), "room_id": "2,2", "outcome": "win" if enemy == "bat" else "loss"}
		var authoritative_view: Dictionary = _state(r)
		var settled := r.execute_atomic_operation(&"cage_receipt", receipt, func() -> Dictionary:
			return Events.on_cage_combat_completed(r.context, Vector2i(2, 2), receipt, r.z2_event_hooks(r.context, Vector2i(2, 2), "cage")))
		_check(settled.get("ok", false) and r.context.run_stats.get("integration_stage_calls", 0) == 1, "trusted cage actual outcome consumes one stage")
		_check_response(settled, authoritative_view)
		_check(str(settled.get("message", "")).contains("胜利" if enemy == "bat" else "落败") and r.context.run_stats.get("integration_equipment", 0) == 0, "cage outcome reply and no noncombat equipment growth")
		_dispose(r)

func _test_voluntary_cage() -> void:
	var runtime := _runtime()
	var pos := Vector2i(2, 2)
	_room(runtime, pos, "cage")
	runtime.context.profile_fields["cage_requires_acceptance"] = true
	runtime.process_rules = {"enemy_pool": [{"enemy_id": "bat", "original_power": 13}]}
	runtime.context.visited_cells[runtime.context.cell_key(pos)] = true
	var entered := runtime.execute_atomic_operation(&"cage_entry", {}, func() -> Dictionary:
		return Events.on_room_entered(runtime.context, pos, "cage", runtime.z2_event_hooks(runtime.context, pos, "cage")))
	_check(entered.get("ok", false) and Events.cage_state(runtime.context, pos).is_empty(), "new cage entry leaves room doors open")
	_check(runtime.command_bus.dispatch(&"select_event_option", {"option_id": "leave"}).get("ok", false), "unstarted cage challenge can be declined")
	var accepted := _choose(runtime, "challenge")
	_check(accepted.get("ok", false) and runtime.in_run_runtime.has_active_combat() and Events.cage_state(runtime.context, pos).get("active", false), "explicit cage challenge starts real combat and seals doors: " + str(accepted.get("reason", "")))
	_dispose(runtime)


func _test_compression_facts() -> void:
	var r := _runtime()
	r.pools.clear()
	_room(r, Vector2i(2, 2), "compress")
	var a: Dictionary = r.context.asset_ledger.create_item_instance(Items.definition("col_01"), &"inventory")
	var b: Dictionary = r.context.asset_ledger.create_item_instance(Items.definition("col_03"), &"inventory")
	if _prepare(r):
		var result := _choose(r, "compress", {"instance_ids": [a.instance_id, b.instance_id]})
		_check(result.get("ok", false), "compression actual command owns both inputs: " + str(result.get("reason", "")))
		var facts: Dictionary = result.get("facts", {})
		var inputs: Array = facts.get("inputs", [])
		var output: Dictionary = facts.get("output", {})
		_check(inputs.size() == 2 and facts.get("input_instance_ids", []).size() == 2, "compression facts preserve both actual input instances")
		_check(not output.is_empty() and output == facts.get("delivery", {}) and output.get("instance_id") != a.instance_id and output.get("instance_id") != b.instance_id, "compression facts preserve exact output instance")
		_check(facts.get("position") == Vector2i(2, 2) and facts.get("canonical_type") == "compress", "compression source facts")
	_dispose(r)

func _test_economy_routes() -> void:
	for row in [["seal", "use", 20], ["relief", "flat", 5], ["first_aid", "buy", 4], ["consign", "consign", 8], ["expand", "expand", 8], ["trader", "sell", 0], ["pawn", "pawn", -12]]:
		var r := _runtime()
		r.pools.clear()
		_room(r, Vector2i(2, 2), row[0])
		var item: Dictionary = r.context.asset_ledger.create_item_instance(Items.definition("col_22"), &"inventory")
		if _prepare(r):
			var params := {"instance_id": item.instance_id} if row[0] in ["consign", "trader", "pawn"] else {}
			var result := _choose(r, row[1], params)
			_check(result.get("ok", false), row[0] + " actual action: " + str(result.get("reason", "")))
			_check(_black(r) == 300 - row[2] and r.context.run_stats.get("integration_stage_calls", 0) == 1, row[0] + " exact fee/one delivery stage")
			match row[0]:
				"seal": _check(r.context.asset_ledger.failure_salvage_capacity >= 20, "seal changes real rescue capacity")
				"relief": _check(r.context.pressure == 45, "relief changes actual pressure")
				"first_aid": _check(result.get("facts", {}).get("delivery", {}).get("item_id") == "con_med_patch", "aid actual delivered patch")
				"consign": _check(r.context.asset_ledger.item_instances[item.instance_id].location_state == &"consigned", "consign keeps same instance")
				"expand": _check(result.get("facts", {}).get("loot_capacity_delta") == 20, "expansion actual capacity")
				"trader": _check(r.context.asset_ledger.get_currency(&"gold_coin") == 24, "trader actual 75percent safe income")
				"pawn": _check(r.context.asset_ledger.item_instances[item.instance_id].location_state == &"pledged", "pawn keeps same instance")
		_dispose(r)
	var r := _runtime()
	r.pools = {"shop_pool": []}
	var before := r.capture_authoritative_state()
	var empty := _result(r.command_bus.dispatch(&"select_event_option", {"option_id": "prepare"}))
	_check(not empty.get("ok", true) and r.capture_authoritative_state() == before, "explicit empty official pool preflight rolls back without fee or saved draw")
	_dispose(r)

func _test_information_choices() -> void:
	for event in ["demine", "recon", "shortcut"]:
		var r := _runtime()
		_room(r, Vector2i(2, 2), event)
		var target := Vector2i(3, 3) if event == "shortcut" else Vector2i(3, 2)
		r.context.truth_map.set_room_type(target, &"Normal" if event == "shortcut" else &"Mine")
		if event == "demine":
			r.context.intel_map.toggle_flag(target)
		if _prepare(r):
			var result: Dictionary
			if event == "shortcut":
				target = _state(r).targets[0]
				r.context.truth_map.set_room_type(target, &"Normal")
				var preview := _choose(r, "preview_target", {"target_pos": target})
				_check(preview.get("ok", false) and _black(r) == 300 and r.context.run_stats.get("integration_stage_calls", 0) == 0, "shortcut preview does not deliver/pay")
				result = _choose(r, "travel", {"target_pos": target, "preview_id": preview.get("preview", {}).get("preview_id", "")})
				_check(r.context.get_current_pos() == target and r.context.run_stats.get("integration_entry_calls", 0) == 1, "shortcut uses actual entry once")
				_check(result.get("facts", {}).get("origin") == Vector2i(2, 2) and result.get("position") == Vector2i(2, 2), "shortcut preserves original origin and source fact")
			else:
				result = _choose(r, "detonate" if event == "demine" else "recon_3", {"target_pos": target})
			_check(result.get("ok", false), event + " actual action: " + str(result.get("reason", "")))
			_check(_black(r) == 300 - {"demine": 7, "recon": 10, "shortcut": 6}[event] and r.context.run_stats.get("integration_stage_calls", 0) == 1, event + " actual fee/one effective stage")
		_dispose(r)

func _test_process_choices() -> void:
	for event in ["mechanism", "recycle", "rps", "altar"]:
		var r := _runtime()
		_room(r, Vector2i(2, 2), event)
		r.process_rules = Hooks.event_hooks(r.context, "", Callable()).process_rules
		if _prepare(r):
			var result: Dictionary
			match event:
				"mechanism": result = _choose(r, "attempt")
				"recycle": result = _choose(r, "deliver")
				"altar": result = _choose(r, "offer")
				"rps":
					for round_index in range(30):
						result = _choose(r, "rock")
						_check(result.get("ok", false), "RPS actual round")
						_check(result.get("substage", "") == "round:%d" % (round_index + 1), "RPS preserves each round substage")
						if result.get("completed", false) or not result.get("ok", false):
							break
			_check(result.get("ok", false), event + " real Loot/process action: " + str(result.get("reason", "")))
			_check(r.context.run_stats.get("integration_stage_calls", 0) == 1, event + " one delivery stage")
			if event == "altar":
				_check(result.get("facts", {}).get("tier") == 1 and _state(r).get("requires_prepare", false), "altar advances and requires next stage quote")
				_check(_prepare(r) and _state(r).get("tier") == 2, "altar next actual tier pool")
				_room(r, Vector2i(3, 2), "altar")
				_check(_prepare(r) and _choose(r, "offer").get("ok", false), "another altar progresses shared tier")
				r.context.player_pos = Vector2i(2, 2)
				r.context.current_pos = Vector2i(2, 2)
				_check(_state(r).get("requires_prepare", false), "earlier altar projection flags obsolete shared tier quote")
		_dispose(r)

func _test_level_16_altar() -> void:
	var r := _runtime()
	r.context.run_start_config.profile_fields.content_eligibility = Eligibility.freeze_profile({"profile_level": 16})
	r.context.profile_fields = r.context.run_start_config.profile_fields.duplicate(true)
	r.context.max_hp = 200
	r.context.hp = 200
	_room(r, Vector2i(2, 2), "altar")
	for tier in range(1, 6):
		if not _prepare(r):
			break
		var result := _choose(r, "offer")
		var facts: Dictionary = result.get("facts", {})
		_check(result.get("ok", false) and facts.get("tier") == tier and facts.get("items", []).size() == 1, "Lv16 altar delivers an official item at stage %d" % tier)
		if not result.get("ok", false):
			break
	_check(r.context.hp == 65 and _black(r) == 340 and _state(r).get("completed", false), "Lv16 altar completes all five costs and rewards in its first room")
	_check(not _choose(r, "offer").get("ok", false), "completed altar rejects another payment")
	_dispose(r)

func _test_continuations() -> void:
	var r := _runtime()
	_room(r, Vector2i(2, 2), "coil")
	if _prepare(r):
		var calibrated := _choose(r, "calibrate")
		_check(calibrated.get("ok", false) and _black(r) == 295 and not calibrated.get("stage_completed", true), "coil payment waits for actual search delivery")
		# Capture the source event before moving to the room that delivers its reward.
		var authoritative_view: Dictionary = _state(r)
		r.context.player_pos = Vector2i(3, 2)
		r.context.current_pos = Vector2i(3, 2)
		var receipt := {"room_type": "normal", "complete": true, "room_id": "3,2", "search_id": "integration:search:3,2"}
		var delivered := r.execute_atomic_operation(&"coil_continuation", receipt, func() -> Dictionary:
			return Events.on_normal_search_completed(r.context, Vector2i(3, 2), receipt, r.z2_event_hooks(r.context, Vector2i(3, 2), "coil")))
		_check_response(delivered, authoritative_view)
		_check(delivered.get("ok", false) and delivered.get("position") == Vector2i(2, 2), "coil continuation retains event origin rather than search room")
		_check(r.context.run_stats.get("integration_stage_calls", 0) == 1 and delivered.get("facts", {}).get("items", []).size() == 1, "coil actual output and one delayed stage")
		var before := r.capture_authoritative_state()
		var duplicate := Events.on_normal_search_completed(r.context, Vector2i(3, 2), receipt, r.z2_event_hooks(r.context, Vector2i(3, 2), "coil"))
		_check(duplicate.get("ok", false) and r.capture_authoritative_state() == before, "coil repeated search receipt is inert")
	_dispose(r)

func _test_all_player_projections() -> void:
	var expected_effects := {"shop": ["buy", "获得"], "savings": ["deposit", "50"], "seal": ["use", "20"],
		"relief": ["flat", "降低5压力"], "first_aid": ["buy", "急救贴"], "consign": ["consign", "托运"],
		"expand": ["expand", "20"], "compress": ["compress", "2件"], "trader": ["sell", "安全金币"],
		"pawn": ["pawn", "16"], "information": ["mine_count", "5×5"], "shortcut": ["preview_target", "6黑币"],
		"demine": ["detonate", "10"], "recon": ["recon_3", "3×3"], "mechanism": ["attempt", "25黑币"],
		"recycle": ["take", "带走"], "coil": ["calibrate", "下一次"], "clock_in": ["register", "3间"],
		"rps": ["rock", "两胜"], "dice": ["roll", "80"], "altar": ["offer", "生命"]}
	for event in EXPECTED:
		var r := _runtime()
		r.pools.clear()
		_room(r, Vector2i(2, 2), event)
		r.process_rules = Hooks.event_hooks(r.context, "", Callable()).process_rules
		r.context.asset_ledger.create_item_instance(Items.definition("col_22"), &"inventory")
		if event == "demine":
			r.context.intel_map.toggle_flag(Vector2i(3, 2))
		if event == "cage":
			r.context.visited_cells["2,2"] = true
			var entered := r.execute_atomic_operation(&"cage_projection", {}, func() -> Dictionary:
				return Events.on_room_entered(r.context, Vector2i(2, 2), event, r.z2_event_hooks(r.context, Vector2i(2, 2), event)))
			_check(entered.get("ok", false), "cage player projection actual entry")
		else:
			_prepare(r, {"amount": 100} if event == "savings" else {})
		var before := r.capture_authoritative_state()
		var state := _state(r)
		_check(not str(state.get("player_summary", "")).is_empty(), event + " has nonempty source-based opening summary")
		_check(r.capture_authoritative_state() == before, event + " descriptive projection remains read-only")
		if expected_effects.has(event):
			var expected: Array = expected_effects[event]
			var matched := false
			for option: Dictionary in state.options:
				if str(option.id) != expected[0]:
					continue
				matched = str(option.player_effect).contains(expected[1]) and str(option.player_effect) != str(option.player_title)
				_check(not str(option.player_cost.display_text).is_empty(), event + " actual cost text")
				break
			_check(matched, event + " effect describes actual rule/reward")
		else:
			_check(str(state.get("player_summary", "")).contains("不能撤退"), "cage exposes forced-combat rule")
		_dispose(r)

func _test_settled_player_responses() -> void:
	var r := _runtime()
	_room(r, Vector2i(2, 2), "relief")
	r.context.pressure = 40
	r.context.asset_ledger.spend_currency(&"black_coin", 291)
	if _prepare(r):
		var old := _request(r, "flat")
		var result := _choose(r, "flat")
		_check(result.get("ok", false) and _black(r) == 4 and r.context.pressure == 35, "reported Main relief9to4/40to35 reproduced")
		var text := str(result.get("message", ""))
		_check(text.contains("5黑币") and text.contains("降低5压力") and text.contains("35"), "relief reply explains actual fee and effect")
		_check(not result.get("response_lines", []).is_empty() and not result.response_lines[0].has("speaker"), "success response retains existing speaker without inventing identity")
		_test_response_nameplate(result, str(_state(r).get("speaker", "")))
		result = _result(r.command_bus.dispatch(&"select_event_option", old))
		_check(not result.get("ok", true) and not str(result.get("reason", "")).is_empty() and not str(result.get("message", "")).is_empty(), "rejected old quote retains reason and useful message")
		_check(result.get("response_lines", []).is_empty(), "failed operation stays in system feedback, outside success dialogue")
	_dispose(r)
	r = _runtime()
	_room(r, Vector2i(2, 2), "dice")
	if _prepare(r):
		for _index in range(3):
			var result := _choose(r, "roll")
			var facts: Dictionary = result.get("facts", {})
			var text := str(result.get("message", ""))
			_check(result.get("ok", false) and text.contains(str(facts.get("face", -1))) and text.contains("返还%d黑币" % int(facts.get("returned_black", -1))), "settled dice reply uses actual face and return")
			if facts.get("win") == false:
				_check(text.contains("输") and result.get("ok", false), "losing dice round is a successful settlement with truthful loss")
	_dispose(r)

func _test_response_nameplate(result: Dictionary, speaker: String) -> void:
	var dialogue := DialogueScene.instantiate()
	root.add_child(dialogue)
	var event: String = str(result.get("event_type", ""))
	_check(speaker == str(EXPECTED_EVENT_SPEAKERS.get(event, "")), event + " nameplate uses real state speaker, not event title")
	var view := {"room_id": event + "-nameplate", "phase_id": event, "revision": 1, "speaker": speaker,
		"lines": [], "options": [{"option_id": "speaker-check", "action_id": "speaker-success", "label": "选择", "enabled": true}]}
	var request := {}
	dialogue.choice_requested.connect(func(value: Dictionary) -> void: request.merge(value, true))
	_check(dialogue.present_view(view), "real dialogue accepts authoritative source speaker")
	dialogue.call("_request_option", 0)
	_check(dialogue.apply_result({"request": request, "ok": true, "committed": true, "view": view,
		"response_lines": result.get("response_lines", [])}), "real dialogue accepts settled response")
	var lines: Array = result.get("response_lines", [])
	for index in range(lines.size()):
		var line: Dictionary = lines[index]
		var expected_speaker: String = speaker
		if line.has("source_row"):
			var identity: Dictionary = _s3_response_identity(event, line)
			_check(bool(identity.get("known", false)), event + " rendered reply has known S3 identity")
			if not str(identity.get("speaker", "")).is_empty():
				expected_speaker = str(identity["speaker"])
		_check(dialogue.get_node("%Nameplate").visible and dialogue.get_node("%SpeakerName").text == expected_speaker, event + " rendered response keeps exact line identity")
		_check(str(dialogue.get_node("%DialogueText").text) == str(line.get("text", "")), event + " rendered response remains on the checked line")
		if index + 1 < lines.size():
			dialogue.call("_advance") # Complete the current typewriter line.
			dialogue.call("_advance") # Move to the next sourced line.
	view.revision = 2
	view.options[0].action_id = "speaker-error"
	dialogue.present_view(view)
	dialogue.call("_request_option", 0)
	_check(dialogue.apply_result({"request": request, "ok": false, "committed": false, "view": view, "message": "报价已变化，请重新查看后选择。"}), "system error uses independent feedback branch")
	_check(dialogue.get_node("%Nameplate").visible and dialogue.get_node("%SpeakerName").text == speaker and str(dialogue.get_node("%DialogueStatus").text).contains("报价已变化"), "system error does not replace or erase the authoritative speaker")
	dialogue.free()

func _test_clock_continuation() -> void:
	var r := _runtime()
	_room(r, Vector2i(2, 2), "clock_in")
	r.context.visited_cells["2,2"] = true
	if _prepare(r):
		_check(_choose(r, "register").get("ok", false) and _black(r) == 296, "clock registration pays4")
		for pos in [Vector2i(3, 2), Vector2i(4, 2), Vector2i(4, 3)]:
			r.context.player_pos = pos
			r.context.current_pos = pos
			r.context.visited_cells[r.context.cell_key(pos)] = true
			var entered := r.execute_atomic_operation(&"visited_continuation", {"pos": pos}, func() -> Dictionary:
				return Events.on_room_entered(r.context, pos, "", r.z2_event_hooks(r.context, pos, "")))
			_check(entered.get("ok", false), "clock actual distinct visit")
		r.context.player_pos = Vector2i(2, 2)
		r.context.current_pos = Vector2i(2, 2)
		var paid := _choose(r, "claim")
		if bool(paid.get("ok", false)):
			_test_response_nameplate(paid, str(_state(r).get("speaker", "")))
		_check(paid.get("ok", false) and _black(r) == 308 and paid.get("facts", {}).get("new_rooms", []).size() == 3, "clock original counter can settle3 real new rooms")
		_check(r.context.run_stats.get("integration_stage_calls", 0) == 1, "clock only paid service grows")
	_dispose(r)

func _test_savings_input_projection() -> void:
	var r := _runtime()
	_room(r, Vector2i(2, 2), "savings")
	if _prepare(r):
		var reachable := false
		for option: Dictionary in _state(r).options:
			if str(option.id) == "prepare" and option.enabled:
				reachable = true
		_check(reachable, "fresh savings UI can enter principal and prepare its first quote")
		_check(_prepare(r, {"amount": 101}), "savings updates chosen principal via same visible action")
		var result := _choose(r, "deposit", {"amount": 101})
		_check(result.get("ok", false) and str(result.get("message", "")).contains("50安全金币"), "odd principal uses actual floor guarantee in response")
	_dispose(r)

func _test_legacy_mechanism_weights() -> void:
	var r := _runtime()
	r.context.profile_fields.ruleset_id = "z1"
	r.context.run_start_config.profile_fields.ruleset_id = "z1"
	var counts := {"z1_event_e06": 0, "trap": 0}
	for seed in range(29):
		r.context.seed_value = seed
		r.context.z1_event_rooms.clear()
		var id := str(Service.get_event_type(r.context, Vector2i(2, 2)))
		if counts.has(id):
			counts[id] += 1
	_check(counts == {"z1_event_e06": 1, "trap": 1}, "actual enabled Z1 pool gives electric/mechanical one of29 each")
	_dispose(r)

func _test_mechanism_selection_and_replay() -> void:
	var r := _runtime()
	r.pools.clear()
	r.context.run_start_config.difficulty = "hard"
	r.process_rules = Hooks.event_hooks(r.context, "", Callable()).process_rules
	var samples := 0
	var snapshots := {}
	for seed in range(256):
		r.context.seed_value = seed
		r.context.z1_event_rooms.clear()
		var selected := r.execute_atomic_operation(&"select_mechanism_variant", {"seed": seed}, func() -> Dictionary:
			return Service.select_z2_event(r.context, Vector2i(2, 2)))
		if str(selected.get("event_type", "")) != "mechanism":
			continue
		samples += 1
		r.context.truth_map.set_room_type(Vector2i(2, 2), &"Event")
		var entered := r.execute_atomic_operation(&"prepare_selected_mechanism", {}, func() -> Dictionary:
			return r.command_bus.room_resolver.enter_room(r.context))
		_check(entered.get("ok", false), "actual selected mechanism enters/prepares through RoomResolver")
		var state := _state(r)
		var variant := str(state.get("variant", ""))
		var saved: Dictionary = r.context.z1_event_rooms["2,2"].get("z2_event_selection", {}).get("mechanism_variant", {})
		_check(variant in ["electric", "mechanical"] and saved.get("variant", "") == variant, "selection persists exact prepared mechanism variant")
		_check(saved.get("version", 0) == 1 and saved.get("pool", []).size() == 2 and str(saved.get("hash", "")).length() == 64, "variant policy and both inherited slots are versioned/hashed")
		var unsigned := saved.duplicate(true)
		unsigned.erase("hash")
		_check(saved.get("hash", "") == Snapshot.fingerprint(unsigned), "variant version/source/pool/choice all enter fingerprint")
		for entry: Dictionary in saved.get("pool", []):
			_check(entry.get("roll_weight", 0) == 1, "variant inherits one legacy slot, without new weight")
		var event_hash := 2 * 73 + 2 * 137 + seed * 31
		_check(saved.get("ticket", -1) == posmod(event_hash, 2) and variant == ("electric" if posmod(event_hash, 2) == 0 else "mechanical"), "variant retains seed/position modulo strategy over inherited equal slots")
		if variant == "mechanical":
			var base: float = (22.0 + 3.0 * r.context.current_adjacent_mines) * 1.3
			_check(float(state.get("threshold", 0)) >= base * 0.85 and float(state.get("threshold", 0)) <= base * 1.15, "mechanical threshold follows actual hard difficulty and adjacent mines")
			_check(state.get("rewards", []).size() == 2, "mechanical prepares two real rewards")
		else:
			_check(not state.has("threshold") and state.get("rewards", []).size() == 1, "electric has one reward and no mechanical threshold")
		if not snapshots.has(variant):
			snapshots[variant] = r.capture_authoritative_state()
		if samples >= 8 and snapshots.has("electric") and snapshots.has("mechanical"):
			break
	_check(snapshots.has("electric") and snapshots.has("mechanical"), "fresh actual selection plus prepare reaches both canonical mechanism encounters")
	_check(Events.event_ids().size() == 22 and Events.event_pool({"profile_level": 50}).size() == 22, "variants do not add a23rd event")
	for variant: String in snapshots:
		var encoded: Variant = r.encode_checkpoint_state(snapshots[variant])
		_check(r.restore_checkpoint_state(encoded).get("ok", false), variant + " actual checkpoint codec restore")
		var saved_room: Dictionary = r.context.z1_event_rooms["2,2"].duplicate(true)
		var quote: Dictionary = saved_room.get("z2_process", {}).get("mechanism", {}).duplicate(true)
		var selection: Dictionary = saved_room.get("z2_event_selection", {}).duplicate(true)
		r.context.seed_value += 1
		r.process_rules = Hooks.event_hooks(r.context, "", Callable()).process_rules
		r.process_rules["mechanism_variant"] = "mechanical" if variant == "electric" else "electric"
		var revisited := r.execute_atomic_operation(&"revisit_mechanism_variant", {}, func() -> Dictionary:
			return Service.select_z2_event(r.context, Vector2i(2, 2)))
		_check(revisited.get("ok", false) and revisited.get("already_selected", false), variant + " revisit reads persisted selection")
		_check(_prepare(r, {"mechanism_variant": r.process_rules.mechanism_variant}), variant + " reopen with competing input")
		_check(r.context.z1_event_rooms["2,2"].get("z2_event_selection", {}) == selection and r.context.z1_event_rooms["2,2"].get("z2_process", {}).get("mechanism", {}) == quote, variant + " restore/revisit cannot redraw variant/rewards/threshold")
		r.context.hp = 5
		r.context.shield = 2
		r.context.pressure = 0
		r.context.power = 0
		r.process_rules.mechanism_failure_damage_type = "dot"
		r.process_rules.electric_damage_type = "physical"
		var black_before := _black(r)
		var result := _choose(r, "attempt", {"mechanism_variant": r.process_rules.mechanism_variant})
		_check(result.get("ok", false) and result.get("facts", {}).get("mechanism_variant", "") == variant, variant + " outcome retains canonical variant provenance")
		var damage: Dictionary = result.get("facts", {}).get("damage", {})
		if variant == "electric":
			_check(damage.get("damage_type") == "physical" and int(damage.get("requested", -1)) == 4 and r.context.hp == 3 and r.context.shield == 0, "electric uses its actual physical packet and at-least1 cap, not mechanical failure")
			_check(_black(r) == black_before + 6 and result.get("facts", {}).get("items", []).size() == 1 and r.context.pressure == 0, "electric actual6black/1item without mechanical failure pressure")
		else:
			_check(damage.get("damage_type") == "dot" and int(damage.get("requested", -1)) == 1 and r.context.hp == 4 and r.context.shield == 2, "mechanical failure uses its own trusted damage packet")
			_check(_black(r) == black_before and result.get("facts", {}).get("items", []).is_empty() and r.context.pressure == 5, "mechanical failed threshold gives only actual1damage/5pressure")
	_dispose(r)

func _test_mechanism_saved_compatibility() -> void:
	for id in ["z1_event_e06", "trap"]:
		var r := _runtime()
		_room(r, Vector2i(2, 2), id)
		r.process_rules = Hooks.event_hooks(r.context, "", Callable()).process_rules
		var expected := "electric" if id == "z1_event_e06" else "mechanical"
		if _prepare(r):
			_check(_state(r).get("variant", "") == expected, "legacy bound identity stays " + expected)
			var state_before: Dictionary = r.context.z1_event_rooms["2,2"].z2_process.mechanism.duplicate(true)
			# A pre-fix canonical room may already have a prepared T12 encounter.
			r.context.z1_event_rooms["2,2"]["event_type"] = &"mechanism"
			r.context.z1_event_rooms["2,2"].get("z2_event_selection", {}).erase("mechanism_variant")
			r.context.seed_value += 17
			_check(_prepare(r), "existing prepared canonical encounter gains binding metadata")
			_check(r.context.z1_event_rooms["2,2"].z2_process.mechanism == state_before and _state(r).get("variant_selection", {}).get("variant", "") == expected, "migration preserves saved variant/reward/revision without reroll")
		_dispose(r)
