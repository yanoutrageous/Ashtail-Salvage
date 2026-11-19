extends "res://tests/i3_production_input_journey_runner.gd"

const RunUIViewModelScript := preload("res://scripts/ui/shell/run_ui_view_model.gd")

const BAG_PASS_MARKER := "I3_PRODUCTION_FULL_BAG_REPLACEMENT=PASS"
const BAG_FAIL_MARKER := "I3_PRODUCTION_FULL_BAG_REPLACEMENT=FAIL"

var replacement_completed := false
var searched_room_count := 0
var forced_priority_clearance_completed := false


func _run() -> void:
	root.size = Vector2i(1280, 720)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	evidence_dir = _option("evidence-dir", "user://tests/i3_production_full_bag_replacement")
	evidence_contract = "I3 production main.tscn genuine-input full-bag replacement journey"
	require_screenshots = _bool_option("require-screenshots", false)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(evidence_dir))
	journey_started_msec = Time.get_ticks_msec()
	if not await _boot_run():
		await _finish_bag()
		return

	# Seed 13's current Lv1 route yields only 63 total item weight. The explicit
	# room-floor boundary fixture supplies canonical items without changing the
	# profile or capacities; movement, pickup and replacement still use real input.
	_require(await _transition_room(Vector2i.RIGHT, Vector2i(3, 6), &"Chest"), "bag journey could not enter chest (3,6)")
	await _open_and_collect_chest("bag_03_chest_a")
	_require(await _transition_room(Vector2i.RIGHT, Vector2i(4, 6), &"Normal"), "bag journey could not enter normal (4,6)")
	await _search_and_collect_normal("bag_04_normal_a")
	_require(await _transition_room(Vector2i.RIGHT, Vector2i(5, 6), &"Normal"), "bag journey could not enter normal (5,6)")
	await _search_and_collect_normal("bag_05_normal_b")
	_require(await _transition_room(Vector2i.RIGHT, Vector2i(6, 6), &"Chest"), "bag journey could not enter chest (6,6)")
	await _open_and_collect_chest("bag_06_chest_b")
	_require(await _transition_room(Vector2i.UP, Vector2i(6, 5), &"Normal"), "bag journey could not enter normal (6,5)")
	await _search_and_collect_normal("bag_07_normal_c")
	if not replacement_completed:
		_require(await _transition_room(Vector2i.UP, Vector2i(6, 4), &"Chest"), "bag journey could not enter chest (6,4)")
		await _open_and_collect_chest("bag_08_chest_c")
	if not replacement_completed:
		_require(await _transition_room(Vector2i.DOWN, Vector2i(6, 5), &"Normal"), "bag journey could not return through normal (6,5)")
		_require(await _transition_room(Vector2i.LEFT, Vector2i(5, 5), &"Normal"), "bag journey could not enter normal (5,5)")
		await _search_and_collect_normal("bag_09_normal_d")
	if not replacement_completed:
		# Follow audited safe rooms to another item that exceeds the remaining
		# capacity. Its search overflow stays on the floor for replacement.
		_require(await _transition_room(Vector2i.DOWN, Vector2i(5, 6), &"Normal"), "bag journey could not return to normal (5,6)")
		_require(await _transition_room(Vector2i.LEFT, Vector2i(4, 6), &"Normal"), "bag journey could not return to normal (4,6)")
		_require(await _transition_room(Vector2i.LEFT, Vector2i(3, 6), &"Chest"), "bag journey could not return through chest (3,6)")
		_require(await _transition_room(Vector2i.LEFT, Vector2i(2, 6), &"Normal"), "bag journey could not return through spawn (2,6)")
		_require(await _transition_room(Vector2i.LEFT, Vector2i(1, 6), &"Normal"), "bag journey could not enter overflow normal (1,6)")
		await _search_and_collect_normal("bag_10_overflow_normal")

	_require(forced_priority_clearance_completed, "first Normal (4,6) search did not dynamically exercise priority-ground-loot WASD clearance and unchanged ledger")
	_require(replacement_completed, "audited production route did not reach a full-bag replacement decision")
	await _checkpoint("bag_11_complete", "full-bag replacement settled through player input")
	await _finish_bag()


func _boot_run() -> bool:
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	_require(packed != null, "bag journey could not load main.tscn")
	if packed == null:
		return false
	main = packed.instantiate()
	root.add_child(main)
	await _frames(12)
	run_scene = main.get_node_or_null("RunScene")
	_require(run_scene != null, "bag journey is missing production RunScene")
	if run_scene == null:
		return false
	if not _configure_isolated_z2_profile("full_bag"):
		return false
	await _checkpoint("bag_01_main", "full-bag journey begins at main.tscn")
	_require(
		await _enter_deploy_through_cave_transition("bag_01b_enter_cave_motion"),
		"bag journey did not complete the measured enter-cave transition"
	)
	var deploy_page := _deploy_page()
	_require(deploy_page != null, "bag journey deploy page missing")
	if deploy_page == null:
		return false
	_set_only_fixed_seed(deploy_page)
	var start_button := deploy_page.find_child("DeployPrimaryAction", true, false) as Button
	_require(start_button != null, "bag journey start action missing")
	if start_button == null:
		return false
	await _click_control(start_button, "bag.deploy_confirm")
	_require(await _wait_screen(&"run", 6.0), "bag journey did not start through real pointer input")
	_require(int(run_scene.get("run_context").get("seed_value")) == FIXED_SEED, "bag journey lost fixed seed")
	_prepare_capacity_boundary_room()
	await _checkpoint("bag_02_run", "fixed-seed run admitted")
	return StringName(run_scene.get("screen_state")) == &"run"


func _prepare_capacity_boundary_room() -> void:
	var context: RunContext = run_scene.get("run_context")
	var ledger: RunAssetLedger = context.asset_ledger
	var room := Vector2i(4, 6)
	var item := preload("res://scripts/core/content/z2_loot_catalog.gd").definition("col_18")
	_require(context.truth_map.get_room_type(room) == &"Normal" and not item.is_empty() and int(item.get("weight", 0)) == 20, "full-bag boundary fixture lost its canonical room or item")
	_require(ledger.backpack_capacity == 100 and ledger.get_backpack_used() == 0, "boundary fixture must begin with an untouched empty 100-capacity backpack")
	var initial_inventory := ledger.get_items_by_location(RunAssetLedger.LOCATION_INVENTORY).duplicate(true)
	for index in range(6):
		var floor_item := item.duplicate(true)
		floor_item["instance_id"] = "full_bag_room_boundary_%d" % index
		ledger.create_item_instance(floor_item, RunAssetLedger.LOCATION_ROOM_FLOOR, room)
	_require(ledger.get_room_floor_items(room).size() == 6 and ledger.get_items_by_location(RunAssetLedger.LOCATION_INVENTORY) == initial_inventory, "boundary fixture must create six floor items without granting carried items")
	setup_exceptions.append("six canonical col_18 floor items in Normal (4,6), weight20 each, for real-input capacity100 replacement; not natural loot or growth")


func _open_and_collect_chest(checkpoint_id: String) -> void:
	searched_room_count += 1
	await _move_axis(&"x", 0.30)
	await _move_axis(&"y", 0.53)
	await _move_axis(&"x", 0.53)
	_require(await _wait_context(&"chest", 2.0), "chest search did not expose proximity context")
	if not bool((_status().get("search_state_data", {}) as Dictionary).get("searched", false)):
		await _tap_key(KEY_E, "%s.open" % checkpoint_id)
		_require(await _wait_until(func() -> bool: return bool((_status().get("search_state_data", {}) as Dictionary).get("searched", false)), 3.0), "chest did not open through real E")
		await _frames(18)
	var context: RunContext = run_scene.get("run_context")
	_require(_context_item_count() == context.asset_ledger.get_room_floor_items(context.get_current_pos()).size(), "completed chest search did not publish its exact floor contents to the popup")
	await _checkpoint(checkpoint_id, "chest contents visible; capacity governed")
	for _index in range(8):
		if _context_kind() != &"chest" or _context_item_count() <= 0:
			break
		var popup = _context_popup()
		var items: Array = popup.get("context_items")
		var first_item: Dictionary = items[0] if not items.is_empty() and items[0] is Dictionary else {}
		var remaining := int(_status().get("backpack_capacity", 0)) - int(_status().get("backpack_used", 0))
		if int(first_item.get("weight", 0)) > remaining:
			break
		var before_count := (_status().get("inventory_items", []) as Array).size()
		await _tap_key(KEY_G, "%s.pickup" % checkpoint_id)
		if not await _wait_until(func() -> bool: return (_status().get("inventory_items", []) as Array).size() > before_count, 2.0):
			break


func _search_and_collect_normal(checkpoint_id: String) -> void:
	searched_room_count += 1
	var search_state: Dictionary = _status().get("search_state_data", {})
	if bool(search_state.get("can_search", false)):
		if not await _prepare_normal_search(checkpoint_id):
			return
		_record_input(checkpoint_id + ".search_before_e", _normal_search_observation())
		var submitted: Array[String] = []
		var on_command := func(command_name: StringName, _payload: Dictionary) -> void: submitted.append(str(command_name))
		run_scene.command_bus.command_requested.connect(on_command)
		await _tap_key(KEY_E, "%s.search" % checkpoint_id)
		var after_e := _normal_search_observation()
		after_e["submitted_commands"] = submitted.duplicate()
		_record_input(checkpoint_id + ".search_after_e", after_e)
		# UI input is queued: immediate `accepted` is not an executed command.
		# Observe real published commands through the original completion budget.
		var searched := await _wait_until(func() -> bool: return bool((_status().get("search_state_data", {}) as Dictionary).get("searched", false)), 3.0)
		run_scene.command_bus.command_requested.disconnect(on_command)
		var after_search := _normal_search_observation()
		after_search["submitted_commands"] = submitted.duplicate()
		_record_input(checkpoint_id + ".search_after_wait", after_search)
		_require(submitted.count("search_current_room") == 1 and not submitted.has("pickup_ground_item"), "normal-room real E selected another/duplicate command: " + JSON.stringify(after_search))
		_require(searched, "normal room did not search through real E: " + JSON.stringify(after_search))
		await _close_optional_runtime_modal("%s.reward_close" % checkpoint_id)
	await _checkpoint(checkpoint_id, "normal search settled; floor overflow remains in world")
	for _pass in range(8):
		var ground := _first_ground_descriptor()
		if ground.is_empty():
			break
		var target := Vector2(ground.get("local_pos", Vector2(-1, -1)))
		await _move_axis(&"x", 0.22)
		await _move_axis(&"y", 0.84)
		await _move_axis(&"x", target.x)
		await _move_axis(&"y", minf(0.86, target.y + 0.10))
		_require(await _wait_context(&"ground_loot", 2.0), "ground overflow did not auto-display on approach")
		var payload: Dictionary = ground.get("payload", {})
		var item: Dictionary = payload.get("item", {})
		var used := int(_status().get("backpack_used", 0))
		var capacity := int(_status().get("backpack_capacity", 0))
		var remaining := capacity - used
		if int(item.get("weight", 0)) > remaining:
			await _tap_key(KEY_G, "%s.open_replacement" % checkpoint_id)
			var popup = _context_popup()
			_require(await _wait_until(func() -> bool: return String(popup.get("replacement_ground_id")) != "", 2.0), "full bag did not open replacement candidates")
			_require_replacement_candidate_layout(popup)
			var replacement_button := popup.find_child("ReplacementCandidateButton", true, false) as Button
			_require(replacement_button != null and not replacement_button.disabled, "replacement view exposed no eligible carried item")
			if replacement_button != null:
				var incoming_id := String(item.get("instance_id", ""))
				await _checkpoint("%s_replacement" % checkpoint_id, "incoming item and carried replacement candidates visible")
				await _click_control(replacement_button, "%s.confirm_replacement" % checkpoint_id)
				_require(await _wait_until(func() -> bool: return _inventory_has(incoming_id), 3.0), "real replacement input did not move the incoming item into the bag")
				replacement_completed = _inventory_has(incoming_id)
			return
		var before_id := String(item.get("instance_id", ""))
		await _tap_key(KEY_G, "%s.pickup_ground" % checkpoint_id)
		if not await _wait_until(func() -> bool: return _inventory_has(before_id), 3.0):
			break


func _prepare_normal_search(checkpoint_id: String) -> bool:
	# E correctly prioritizes in-range ground loot. The explicit six-item floor
	# fixture can reach the west entrance, so walk to a clear same-room search
	# position instead of picking up a fixture item and calling that "search".
	# Deliberately reproduce the original priority-loot landing on the first
	# Normal room; do not let harmless entrance jitter silently skip this branch.
	var forced_priority_case := checkpoint_id == "bag_04_normal_a"
	if forced_priority_case and not await _approach_priority_search_loot(checkpoint_id):
		return false
	_record_input(checkpoint_id + ".search_position_before", _normal_search_observation())
	if not _nearby_search_pickups().is_empty():
		var before_pos: Vector2i = _status().get("position", Vector2i(-1, -1))
		var before_state: Dictionary = run_scene.runtime_controller.capture_authoritative_state()
		if not await _move_axis(&"x", 0.24) or not await _move_axis(&"y", 0.32) or not await _move_axis(&"x", 0.50):
			_require(false, "real WASD could not reach normal-room search clearance: " + JSON.stringify(_normal_search_observation()))
			return false
		var clear := await _wait_until(func() -> bool: return _nearby_search_pickups().is_empty() and _context_kind() != &"ground_loot", 2.0)
		var after_state: Dictionary = run_scene.runtime_controller.capture_authoritative_state()
		var same_room_and_ledger: bool = _status().get("position") == before_pos and after_state.context.components.asset_ledger == before_state.context.components.asset_ledger
		var after_position := _normal_search_observation()
		after_position["priority_branch_exercised"] = true
		after_position["clear"] = clear
		after_position["same_room_and_ledger"] = same_room_and_ledger
		after_position["ledger_before_sha256"] = JSON.stringify(before_state.context.components.asset_ledger).sha256_text()
		after_position["ledger_after_sha256"] = JSON.stringify(after_state.context.components.asset_ledger).sha256_text()
		_record_input(checkpoint_id + ".search_position_after", after_position)
		_require(clear and same_room_and_ledger, "normal search positioning left the room, changed ledger or retained priority loot: " + JSON.stringify(after_position))
		if not clear or not same_room_and_ledger:
			return false
		if forced_priority_case:
			forced_priority_clearance_completed = true
	return true


func _approach_priority_search_loot(checkpoint_id: String) -> bool:
	var before_state: Dictionary = run_scene.runtime_controller.capture_authoritative_state()
	var before_room: Vector2i = _status().get("position", Vector2i(-1, -1))
	if before_room != Vector2i(4, 6) or StringName(_status().get("current_room", &"")) != &"Normal":
		_require(false, "priority-loot regression must begin in the original Normal (4,6)")
		return false
	_record_input(checkpoint_id + ".search_priority_approach_before", _normal_search_observation())
	# Return to the safe west aisle before the forward walk, even if a slower
	# entry frame already landed near x=0.278. All positioning is genuine WASD.
	if not await _move_axis(&"y", 0.50) or not await _move_axis(&"x", 0.20):
		_require(false, "real WASD could not reach the west aisle before priority-loot approach: " + JSON.stringify(_normal_search_observation()))
		return false
	# One-way approach: the general axis helper may reverse after braking and
	# stop within its 0.035 tolerance but outside strict pickup range. Do not
	# rely only on the visible-focus grace margin to reproduce this regression.
	if not await _hold_until(KEY_D, func() -> bool: return _player_local_pos().x >= 0.278, 1.9, checkpoint_id + ".approach_priority_pickup"):
		_require(false, "real D could not reproduce the original priority-loot search landing: " + JSON.stringify(_normal_search_observation()))
		return false
	await _seconds(0.10)
	var priority_present := await _wait_until(func() -> bool:
		var observation := _normal_search_observation()
		return not _nearby_search_pickups().is_empty() and str(observation.get("e_candidate_kind", "")) == "ground_loot" and bool(observation.get("e_candidate_strict_range", false)) and _context_kind() == &"ground_loot"
	, 2.0)
	var after_state: Dictionary = run_scene.runtime_controller.capture_authoritative_state()
	var unchanged: bool = _status().get("position") == before_room and after_state.context.components.asset_ledger == before_state.context.components.asset_ledger
	var observation := _normal_search_observation()
	observation["target_local_position"] = {"x": 0.278, "y": 0.50}
	observation["same_room_and_ledger"] = unchanged
	observation["priority_present"] = priority_present
	_record_input(checkpoint_id + ".search_priority_approach_after", observation)
	_require(priority_present and unchanged, "original Normal-room landing did not expose genuine priority ground loot without modifying assets: " + JSON.stringify(observation))
	return priority_present and unchanged


func _nearby_search_pickups() -> Array[Dictionary]:
	var nearby: Array[Dictionary] = []
	var room: Dictionary = run_scene.room_runtime_view.build_read_only_snapshot()
	for raw: Dictionary in room.get("interactables", []):
		if StringName(raw.get("interaction_kind", &"")) != &"ground_loot" or not raw.get("enabled", false):
			continue
		var point: Vector2 = raw.get("local_pos", Vector2(-1, -1))
		var distance := _player_local_pos().distance_to(point)
		var radius := float(raw.get("interaction_radius", 0.0))
		# Conservative clearance also excludes the visible-focus grace margin.
		if distance <= radius + 0.03:
			nearby.append({"id": str(raw.get("interaction_id", "")), "distance": distance, "radius": radius, "local_pos": {"x": point.x, "y": point.y}})
	return nearby


func _normal_search_observation() -> Dictionary:
	var command: Dictionary = run_scene.last_command_result
	var active: Dictionary = run_scene.run_context.active_command
	# Read the same resolver E uses, including its visible-focus grace; this is
	# observation only and does not build/execute a pickup or search command.
	var candidate = run_scene.room_runtime_view._nearest_actionable_interactable(_player_local_pos(), true)
	return {
		"search": (_status().get("search_state_data", {}) as Dictionary).duplicate(true),
		"nearby_pickups": _nearby_search_pickups(),
		"e_candidate_kind": str(candidate.get("interaction_kind")) if candidate != null else "none",
		"e_candidate_id": str(candidate.get("interaction_id")) if candidate != null else "",
		"e_candidate_strict_range": bool(candidate.can_interact_from(_player_local_pos())) if candidate != null else false,
		"last_command_result": {"ok": bool(command.get("ok", false)), "status": str(command.get("status", "")), "reason": str(command.get("reason", command.get("reason_code", "")))},
		"active_command_name": str(active.get("command_name", "")),
	}


func _first_ground_descriptor() -> Dictionary:
	var view = run_scene.get("room_runtime_view") if run_scene != null else null
	if view == null:
		return {}
	var snapshot: Dictionary = view.call("build_read_only_snapshot")
	for raw in snapshot.get("interactables", []) as Array:
		if raw is Dictionary and StringName((raw as Dictionary).get("interaction_kind", &"")) == &"ground_loot":
			return (raw as Dictionary).duplicate(true)
	return {}


func _inventory_has(instance_id: String) -> bool:
	for raw in _status().get("inventory_items", []) as Array:
		if raw is Dictionary and String((raw as Dictionary).get("instance_id", "")) == instance_id:
			return true
	return false


func _require_replacement_candidate_layout(popup: Node) -> void:
	var info := popup.find_child("ReplacementCandidateInfo", true, false) as Button
	var name_line := info.find_child("ReplacementCandidateName", true, false) as Label if info != null else null
	var meta_line := info.find_child("ReplacementCandidateMeta", true, false) as Label if info != null else null
	var marker := info.find_child("WorldContextItemRarityMarker", true, false) as ColorRect if info != null else null
	var scroll := popup.find_child("ContextItemScroll", true, false) as ScrollContainer
	_require(info != null and info.text.is_empty(), "replacement candidate retained clipped single-control copy")
	_require(
		info != null and info.get_meta("replacement_layout", &"") == &"two_line",
		"replacement candidate did not use the two-line layout"
	)
	_require(
		name_line != null
		and meta_line != null
		and not name_line.text.contains("\n")
		and not meta_line.text.contains("\n")
		and name_line.position.y < meta_line.position.y,
		"replacement candidate name and metadata are not two distinct visual lines"
	)
	_require(name_line != null and _label_text_fits(name_line), "replacement name/count line is visually clipped")
	_require(meta_line != null and _label_text_fits(meta_line), "replacement quality/level/weight line is visually clipped")
	_require(marker != null and marker.mouse_filter == Control.MOUSE_FILTER_IGNORE, "replacement candidate lost its independent rarity marker")
	_require(scroll != null and scroll.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_AUTO, "replacement candidate list lost vertical scrolling")

	var candidate_id := String(info.get_meta("item_instance_id", "")) if info != null else ""
	var candidate_item: Dictionary = {}
	for raw_item in popup.get("inventory_items") as Array:
		if raw_item is Dictionary and String((raw_item as Dictionary).get("instance_id", "")) == candidate_id:
			candidate_item = (raw_item as Dictionary).duplicate(true)
			break
	_require(not candidate_item.is_empty(), "replacement candidate could not be mapped back to the carried item")
	if candidate_item.is_empty() or meta_line == null:
		return
	var presentation := RunUIViewModelScript.item_presentation(candidate_item)
	var expected_level := maxi(0, int(presentation.get("collectible_level", 0)))
	_require(
		int(meta_line.get_meta("collectible_level", -1)) == expected_level,
		"replacement candidate collectible level drifted from the carried item"
	)
	_require(
		meta_line.text.contains(String(presentation.get("rarity_text", "[?] 未鉴定")).replace("] ", "]"))
		and meta_line.text.contains("重%s" % presentation.get("weight", 0)),
		"replacement candidate metadata omitted quality or weight"
	)
	if expected_level > 0:
		_require(
			meta_line.text.contains("收藏等级%d" % expected_level),
			"replacement candidate omitted its real collectible level"
		)
	else:
		_require(
			not meta_line.text.contains("收藏等级"),
			"replacement candidate invented a collectible level"
		)


func _label_text_fits(label: Label) -> bool:
	var font := label.get_theme_font("font")
	if font == null:
		return false
	var text_width := font.get_string_size(
		label.text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		label.get_theme_font_size("font_size")
	).x
	return text_width <= label.size.x + 0.5


func _finish_bag() -> void:
	if require_screenshots:
		_require(screenshot_count >= 9, "full-bag journey emitted fewer than nine screenshots")
	var final_status := _status()
	var final_used := int(final_status.get("backpack_used", 0))
	var final_capacity := int(final_status.get("backpack_capacity", 0))
	var evidence_path := _write_evidence()
	await _drain_bag_audio()
	_dispose_main_immediately()
	if failures.is_empty():
		print("%s seed=%d searched_rooms=%d capacity=%d replacement=real_input screenshots=%d inputs=%d evidence=%s csv=%s" % [BAG_PASS_MARKER, FIXED_SEED, searched_room_count, final_capacity, screenshot_count, evidence_rows.size(), evidence_path, ProjectSettings.globalize_path("%s/journey.csv" % evidence_dir)])
		_schedule_quit(0)
		return
	for failure in failures:
		push_error("I3 production full-bag journey failure: " + failure)
	print("%s failures=%d used=%d capacity=%d screenshots=%d evidence=%s csv=%s" % [BAG_FAIL_MARKER, failures.size(), final_used, final_capacity, screenshot_count, evidence_path, ProjectSettings.globalize_path("%s/journey.csv" % evidence_dir)])
	_schedule_quit(1)


func _drain_bag_audio() -> void:
	if run_scene == null or not is_instance_valid(run_scene):
		return
	# Gameplay assertions/evidence are complete. AudioServer releases playback
	# references asynchronously; a fixed count of fast headless frames is not a fence.
	run_scene.set_process(false)
	var streams: Array[WeakRef] = []
	for child in run_scene.player_feedback_service.get_children():
		if child is AudioStreamPlayer and child.stream != null:
			streams.append(weakref(child.stream))
			child.stop()
			child.stream = null
	var deadline := Time.get_ticks_msec() + 1000
	while streams.any(func(stream: WeakRef) -> bool: return stream.get_ref() != null) and Time.get_ticks_msec() < deadline:
		await process_frame
	var released := not streams.any(func(stream: WeakRef) -> bool: return stream.get_ref() != null)
	_require(released, "full-bag audio teardown timed out")
	print("I3_FULL_BAG_AUDIO_DRAIN streams=%d released=%s" % [streams.size(), released])
