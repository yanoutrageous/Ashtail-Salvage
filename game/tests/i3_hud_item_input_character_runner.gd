extends SceneTree

const RunSurfaceScript := preload("res://scripts/ui/run_surface/run_surface.gd")
const RunSurfaceModelScript := preload("res://scripts/ui/run_surface/run_surface_model.gd")
const RunUIViewModelScript := preload("res://scripts/ui/shell/run_ui_view_model.gd")
const InventoryPanelScript := preload("res://scripts/ui/inventory/inventory_panel.gd")
const GroundLootPanelScript := preload("res://scripts/ui/ground_loot/ground_loot_panel.gd")
const WorldContextPopupScript := preload("res://scripts/gameplay/interaction/g41_world_context_popup.gd")
const PlayerControllerScript := preload("res://scripts/gameplay/player/player_controller.gd")
const RuntimeAnimationCatalogScript := preload("res://scripts/presentation/art24/art24_runtime_animation_catalog.gd")
const RuntimeInputProfileScript := preload("res://scripts/core/input/runtime_input_profile.gd")
const UILayoutProfileScript := preload("res://scripts/ui/shell/ui_layout_profile.gd")
const Z2ItemCatalogScript := preload("res://scripts/core/content/z2_item_catalog.gd")

const PASS_MARKER := "I3_HUD_ITEM_INPUT_CHARACTER=PASS"
const FAIL_MARKER := "I3_HUD_ITEM_INPUT_CHARACTER=FAIL"

var failures: Array[String] = []
var item_action_count := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	RuntimeInputProfileScript.install()
	await _check_hud_actions_and_items()
	await _check_classified_quick_bag()
	await _check_input_and_character_profile()
	await _check_production_gamepad_propagation()
	_finish()


func _check_hud_actions_and_items() -> void:
	var profile: Dictionary = UILayoutProfileScript.profile_for_resolution(&"1280x720")
	profile["actual_viewport_size"] = Vector2i(1280, 720)
	var item := _sample_item("i3_shared_item", "沉星罗盘", 3, 4)
	var snapshot := {
		"run_active": true,
		"mode": &"RAW_MODE",
		"phase": &"RAW_PHASE",
		"outcome": "RAW_OUTCOME",
		"position": Vector2i(2, 1),
		"current_room": &"Monster",
		"adjacent_mines": 3,
		"protocol_level": 4,
		"pressure": 20,
		"inventory_items": [item],
		"backpack_used": 4,
		"backpack_capacity": 12,
		"room_floor_item_count": 1,
		"combat_runtime": {"active": true},
		"search_state_data": {"can_search": false, "searched": false},
	}
	var model := RunSurfaceModelScript.build(snapshot, null, profile, {})
	var actions: Array = model.get("action_buttons", [])
	_require(actions.size() == 7, "HUD did not retain exactly seven action descriptors")
	var ids: Dictionary = {}
	var saw_disabled := false
	for index in range(actions.size()):
		var action: Dictionary = actions[index]
		var action_id := StringName(action.get("id", &""))
		ids[action_id] = true
		var enabled := bool(action.get("enabled", false))
		if not enabled:
			saw_disabled = true
		elif saw_disabled:
			_require(false, "enabled HUD action appeared after disabled context actions")
		_require(int(action.get("context_rank", -1)) == index, "HUD context rank drifted at %d" % index)
	_require(ids.size() == 7, "HUD action IDs are not unique")
	_require(StringName((actions[0] as Dictionary).get("id", &"")) == &"combat", "combat room did not place its executable primary action first")
	_require(bool((actions[0] as Dictionary).get("is_primary", false)), "first executable HUD action is not marked primary")
	_require(not String(model.get("action_hint", "")).contains("暂不可用"), "default HUD guidance selected a disabled action")
	var player_copy := "%s\n%s" % [model.get("room_summary", ""), "\n".join(model.get("status_lines", []))]
	for forbidden in ["RAW_MODE", "RAW_PHASE", "RAW_OUTCOME", "Running", "运行状态"]:
		_require(not player_copy.contains(forbidden), "HUD leaked engineering copy: %s" % forbidden)
	_require(String((model.get("mine_risk", {}) as Dictionary).get("display_text", "")).contains("周围雷险"), "HUD lost the authoritative nearby-mine descriptor")
	_require(RunSurfaceModelScript.protocol_title_for_level(5) == "正常作业", "authoritative protocol-5 title was renamed")

	var host := Control.new()
	host.size = Vector2(1280, 720)
	root.add_child(host)
	var surface := RunSurfaceScript.new()
	host.add_child(surface)
	surface.build()
	surface.apply_layout_profile(profile)
	surface.apply_surface_model(model)
	await _frames(3)
	var first_action := surface.action_bar.get_child(0) as Button
	_require(first_action != null and first_action.name == "RunAction_combat", "production HUD did not apply contextual action order")
	_require(first_action != null and bool(first_action.get_meta("context_primary", false)), "production HUD did not visually mark its primary action")
	for raw_button in surface.action_buttons.values():
		var button := raw_button as Button
		if button == null:
			continue
		_require(
			button.focus_mode == (Control.FOCUS_NONE if button.disabled else Control.FOCUS_ALL),
			"HUD action %s has focus mode %s while disabled=%s" % [button.name, button.focus_mode, button.disabled]
		)
	_require(surface.resource_label.text.contains("周围雷险"), "production HUD omitted 周围雷险")
	_require(not surface.resource_label.text.contains("正常作业"), "left HUD rail retained the redundant normal-operation label")

	var descriptor := RunUIViewModelScript.item_presentation(item)
	_require(bool(descriptor.get("read_only", false)), "shared item presentation is not read-only")
	_require(String(descriptor.get("display_name", "")) == "沉星罗盘", "shared item name drifted")
	_require(int(descriptor.get("quantity", 0)) == 3 and int(descriptor.get("weight", 0)) == 4, "shared item quantity/weight drifted")
	_require(String(descriptor.get("detail_text", "")).contains("秘藏") and not String(descriptor.get("detail_text", "")).contains("[T6]"), "shared item detail omitted natural-language rarity or exposed a T-code")
	_require(not String(descriptor.get("detail_text", "")).contains("raw_internal_item_id"), "shared item detail leaked item_id")
	var quick_button := surface.backpack_strip.get_child(0) as Button
	_require(quick_button != null and quick_button.tooltip_text == String(descriptor.get("detail_text", "")), "quick bag bypassed the shared item detail")
	_require(surface.backpack_detail_label.text == String(descriptor.get("detail_text", "")), "quick bag focus detail drifted from the shared descriptor")
	_require(surface.current_backpack_item_count == 1, "single aggregated quick-bag row count drifted")
	_check_single_bag_row(surface, quick_button)
	_require(not surface.backpack_detail_label.visible, "quick bag retained a permanent duplicate detail block")
	_require(surface.backpack_capacity_label.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER, "quick bag capacity text lost centered alignment")
	_require(not _tree_text(surface.backpack_strip).contains("空位"), "quick bag rendered fake empty slots")

	var inventory := InventoryPanelScript.new()
	var ground := GroundLootPanelScript.new()
	host.add_child(inventory)
	host.add_child(ground)
	await _frames(2)
	_require(String(inventory.call("_item_summary_text", item)) == String(descriptor.get("summary_text", "")), "inventory summary bypassed the shared descriptor")
	_require(String(inventory.call("_item_detail_text", item)) == String(descriptor.get("detail_text", "")), "inventory detail bypassed the shared descriptor")
	_require(String(ground.call("_item_summary_text", item)) == String(descriptor.get("summary_text", "")), "ground-loot summary bypassed the shared descriptor")
	_require(String(ground.call("_item_detail_text", item)) == String(descriptor.get("detail_text", "")), "ground-loot detail bypassed the shared descriptor")
	var result_item := RunUIViewModelScript.result_item_model(item)
	_require(String(result_item.get("display_name", "")) == String(descriptor.get("display_name", "")), "result item name bypassed the shared descriptor")
	_require(int(result_item.get("weight", -1)) == int(descriptor.get("weight", -2)), "result item weight bypassed the shared descriptor")
	var drop_envelope := {
		"accepted": true,
		"ok": true,
		"status": &"dropped",
		"action_result": {"ok": true, "status": &"dropped", "item": item.duplicate(true)},
	}
	_require(
		RunUIViewModelScript.command_result_text(drop_envelope) == "已放下：沉星罗盘。",
		"item command feedback ignored the authoritative item inside the CommandResult envelope"
	)

	var world_popup := WorldContextPopupScript.new()
	host.add_child(world_popup)
	await _frames(2)
	world_popup.pickup_requested.connect(_count_item_action)
	world_popup.replace_requested.connect(func(_ground_id: String, _drop_id: String) -> void: item_action_count += 1)
	var candidate_without_level := _sample_item("i3_candidate_no_level", "普通绷带", 1, 1)
	candidate_without_level.erase("collectible_level")
	world_popup.apply_context({
		"interaction_kind": &"ground_loot",
		"world_pos": Vector2(620, 360),
		"player_world_pos": Vector2(560, 360),
		"room_bounds": Rect2(300, 20, 960, 650),
		"items": [item],
		"inventory_items": [
			_sample_item("i3_candidate", "旧式罗盘", 1, 2),
			candidate_without_level,
		],
		"backpack_remaining": 1,
		"pickup_allowed": true,
	})
	await _frames(2)
	var world_info := world_popup.find_child("ContextItemInfo", true, false) as Button
	var world_marker := world_popup.find_child("WorldContextItemRarityMarker", true, false) as ColorRect
	for expected in [
		String(descriptor.get("display_name", "")),
		String(descriptor.get("rarity_text", "")),
		String(descriptor.get("collectible_level_text", "")),
		"重%s" % descriptor.get("weight", 0),
	]:
		_require(world_info != null and world_info.text.contains(expected), "world item compact summary omitted shared descriptor field: %s" % expected)
	_require(world_info != null and world_info.tooltip_text == String(descriptor.get("detail_text", "")), "world item detail bypassed the shared descriptor")
	_require(world_marker != null and world_marker.color.is_equal_approx(Color((descriptor.get("rarity", {}) as Dictionary).get("color"))), "world item independent rarity marker bypassed the shared descriptor")
	if world_info != null:
		world_info.mouse_entered.emit()
		world_info.grab_focus()
	await process_frame
	_require(item_action_count == 0, "world item hover/focus emitted a command")
	world_popup.call("_begin_replacement", "i3_shared_item")
	await _frames(2)
	var replacement_info := world_popup.find_child("ReplacementCandidateInfo", true, false) as Button
	var replacement_name := replacement_info.find_child("ReplacementCandidateName", true, false) as Label if replacement_info != null else null
	var replacement_meta := replacement_info.find_child("ReplacementCandidateMeta", true, false) as Label if replacement_info != null else null
	var candidate_descriptor := RunUIViewModelScript.item_presentation(_sample_item("i3_candidate", "旧式罗盘", 1, 2))
	_require(replacement_info != null and replacement_info.text.is_empty(), "replacement candidate retained clipped single-control copy")
	_require(
		replacement_info != null and replacement_info.get_meta("replacement_layout", &"") == &"two_line",
		"replacement candidate did not expose the two-line layout contract"
	)
	_require(
		replacement_name != null
		and replacement_name.text == "%s ×%d" % [
			candidate_descriptor.get("display_name", ""),
			candidate_descriptor.get("quantity", 0),
		],
		"replacement candidate name/count line drifted from the shared descriptor"
	)
	for expected in [
		String(candidate_descriptor.get("rarity_text", "")).replace("] ", "]"),
		String(candidate_descriptor.get("collectible_level_text", "")).replace(" ", ""),
		"重%s" % candidate_descriptor.get("weight", 0),
	]:
		_require(replacement_meta != null and replacement_meta.text.contains(expected), "replacement metadata line omitted shared descriptor field: %s" % expected)
	_require(
		replacement_name != null
		and replacement_meta != null
		and not replacement_name.text.contains("\n")
		and not replacement_meta.text.contains("\n")
		and replacement_name.get_global_rect().end.y <= replacement_meta.get_global_rect().end.y,
		"replacement candidate did not retain a readable two-line hierarchy"
	)
	_require(
		replacement_name != null and _label_text_fits(replacement_name),
		"replacement name/count line is visually clipped (text %.1f / available %.1f)" % [
			_label_text_width(replacement_name),
			replacement_name.size.x if replacement_name != null else 0.0,
		]
	)
	_require(
		replacement_meta != null and _label_text_fits(replacement_meta),
		"replacement quality/level/weight line is visually clipped (text %.1f / available %.1f)" % [
			_label_text_width(replacement_meta),
			replacement_meta.size.x if replacement_meta != null else 0.0,
		]
	)
	_require(
		replacement_meta != null
		and int(replacement_meta.get_meta("collectible_level", -1)) == int(candidate_descriptor.get("collectible_level", 0)),
		"replacement candidate did not preserve the authoritative collectible level"
	)
	var level_less_info: Button
	for raw_candidate in world_popup.find_children("ReplacementCandidateInfo", "", true, false):
		var candidate := raw_candidate as Button
		if candidate != null and String(candidate.get_meta("item_instance_id", "")) == "i3_candidate_no_level":
			level_less_info = candidate
			break
	var level_less_meta := level_less_info.find_child("ReplacementCandidateMeta", true, false) as Label if level_less_info != null else null
	_require(
		level_less_meta != null
		and int(level_less_meta.get_meta("collectible_level", -1)) == 0
		and not level_less_meta.text.contains("收藏等级"),
		"replacement candidate invented a collectible level for an item without one"
	)
	var replacement_marker := replacement_info.find_child("WorldContextItemRarityMarker", true, false) as ColorRect if replacement_info != null else null
	_require(replacement_marker != null, "replacement candidate lost its independent rarity marker")
	_require(replacement_info != null and replacement_info.tooltip_text == String(candidate_descriptor.get("detail_text", "")), "replacement detail bypassed the shared descriptor")

	host.queue_free()
	await _frames(3)


func _check_classified_quick_bag() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	root.add_child(host)
	var surface := RunSurfaceScript.new()
	host.add_child(surface)
	surface.build()
	var legacy := _sample_item("legacy-a", "旧物资", 2, 4)
	legacy["item_type"] = "legacy_unknown"
	legacy["instance_ids"] = ["legacy-a", "legacy-b"]
	var material := _sample_item("material", "材料", 1, 3)
	material["item_type"] = "material"
	var supply := _sample_item("supply", "装备", 1, 5)
	var tool := _sample_item("tool", "药品", 1, 2)
	tool["item_type"] = "consumable"
	var special := _sample_item("special", "特殊道具", 1, 1)
	special["item_type"] = "special"
	special["can_consume"] = true
	var cases := [
		{"items": [], "columns": [[], []]},
		{"items": [legacy], "columns": [["legacy-a"], []]},
		{"items": [tool], "columns": [[], ["tool"]]},
		{"items": [tool, legacy, special, material], "columns": [["legacy-a", "material"], ["tool", "special"]]},
		{"items": [legacy, tool, material, supply], "columns": [["legacy-a", "material", "supply"], ["tool"]]},
	]
	var snapshot := {"inventory_items": [], "equipment_used": 17, "equipment_capacity": 83, "backpack_used": 29, "backpack_capacity": 97}
	for scale: float in [1.0, 1.25, 1.5]:
		var profile: Dictionary = UILayoutProfileScript.profile_for_resolution(&"1280x720")
		profile.merge({"actual_viewport_size": Vector2i(1280, 720), "ui_scale_factor": scale}, true)
		surface.apply_layout_profile(profile)
		for fixture: Dictionary in cases:
			snapshot["inventory_items"] = fixture.items
			var model := RunSurfaceModelScript.build(snapshot, null, profile, {})
			surface.apply_surface_model(model)
			await _frames(5)
			_check_bag_columns(surface, model.backpack_items, fixture.columns)
			var buttons := _bag_buttons(surface)
			if buttons.size() == 1:
				_check_single_bag_row(surface, buttons[0])
			if buttons.is_empty():
				_require(not surface.backpack_scroll.visible and surface.backpack_empty_watermark.visible, "empty bag did not show only its noninteractive watermark")
		# The instance/type stay identical: classification must invalidate the cache.
		snapshot["inventory_items"] = [legacy]
		surface.apply_surface_model(RunSurfaceModelScript.build(snapshot, null, profile, {}))
		await _frames(3)
		var usable_legacy := legacy.duplicate(true)
		usable_legacy["can_consume"] = true
		snapshot["inventory_items"] = [usable_legacy]
		var changed := RunSurfaceModelScript.build(snapshot, null, profile, {})
		surface.apply_surface_model(changed)
		await _frames(5)
		_check_bag_columns(surface, changed.backpack_items, [[], ["legacy-a"]])
		var long_columns: Array = [[], []]
		var long_items: Array = []
		var catalog := Z2ItemCatalogScript.all_items()
		catalog.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.display_name).length() > str(b.display_name).length())
		for item: Dictionary in catalog:
			var column := 1 if str(item.item_type) == "consumable" else 0
			if long_columns[column].size() >= 8:
				continue
			var id := "catalog-%s" % item.item_id
			item.merge({"instance_id": id + "-a", "instance_ids": [id + "-a", id + "-b", id + "-c"], "quantity": 3}, true)
			long_items.append(item)
			long_columns[column].append(id + "-a")
		_require(long_columns[0].size() == 8 and long_columns[1].size() == 8, "long bag fixture lacks eight actual catalog stacks in each category")
		snapshot["inventory_items"] = long_items
		var long_model := RunSurfaceModelScript.build(snapshot, null, profile, {})
		surface.apply_surface_model(long_model)
		await _frames(5)
		_check_bag_columns(surface, long_model.backpack_items, long_columns)
		var bar: VScrollBar = surface.backpack_scroll.get_v_scroll_bar()
		_require(bar.is_visible_in_tree() and bar.max_value - bar.page > 1.0, "long catalog list did not exercise actual scrolling")
		var headers := [surface.backpack_supplies_header.get_global_rect(), surface.backpack_tools_header.get_global_rect()]
		var before_scroll := bar.value
		await _wheel_bag(surface.backpack_scroll)
		_require(bar.value > before_scroll and absf(bar.value - (bar.max_value - bar.page)) <= 1.0, "native bag wheel cannot reach the end of the long catalog list")
		for column in range(2):
			var header: Label = surface.backpack_supplies_header if column == 0 else surface.backpack_tools_header
			_require(header.is_visible_in_tree() and header.get_global_rect() == headers[column], "bag category header moved while scrolling")
			var last: Control = surface.backpack_strip.get_child(14 + column)
			_require(surface.backpack_scroll.get_global_rect().grow(1.0).encloses(last.get_global_rect()), "last complete catalog row is unreachable by wheel")
		surface.backpack_scroll.scroll_vertical = 0
		await _check_short_left_panel(surface, profile)
	_require(item_action_count == 0, "bag presentation or scrolling issued an item action")
	host.queue_free()
	await _frames(3)


func _bag_buttons(surface: RunSurface) -> Array[Button]:
	var buttons: Array[Button] = []
	for child in surface.backpack_strip.get_children():
		if child is Button:
			buttons.append(child)
	return buttons


func _check_bag_columns(surface: RunSurface, items: Array, expected_columns: Array) -> void:
	var grid: GridContainer = surface.backpack_strip
	_require(grid.columns == 2 and grid.get_theme_constant("h_separation") == 4 and grid.get_theme_constant("v_separation") == 4, "bag lost its two-column geometry")
	_require(surface.backpack_supplies_header.text == "物资" and surface.backpack_tools_header.text == "道具", "bag category headings changed")
	_require(surface.backpack_capacity_label.text == "共享 17/83\n战利品 29/97", "bag classification replaced independent capacity values")
	_require(_bag_buttons(surface).size() == items.size() and surface.current_backpack_item_count == items.size(), "bag lost or duplicated an actual item stack")
	_require(grid.get_child_count() == 2 * maxi(expected_columns[0].size(), expected_columns[1].size()), "bag row count does not match the longer category")
	var actual_columns: Array = [[], []]
	for index in range(grid.get_child_count()):
		var child: Control = grid.get_child(index)
		if not child is Button:
			_require(child.get_class() == "Control" and child.get_child_count() == 0 and child.focus_mode == Control.FOCUS_NONE and child.mouse_filter == Control.MOUSE_FILTER_IGNORE, "blank category alignment became a fake or interactive item")
			continue
		var button := child as Button
		var id := String(button.get_meta("item_instance_id", ""))
		actual_columns[index % 2].append(id)
		var header: Label = surface.backpack_supplies_header if index % 2 == 0 else surface.backpack_tools_header
		_require(absf(button.get_global_rect().position.x - header.get_global_rect().position.x) <= 1.0, "bag item is not aligned under its fixed category: " + id)
		var matches := items.filter(func(item: Dictionary) -> bool: return str(item.instance_id) == id)
		_require(matches.size() == 1, "bag stack identity is missing or repeated: " + id)
		if matches.size() != 1:
			continue
		var item: Dictionary = matches[0]
		var detail := RunUIViewModelScript.item_presentation(item)
		_require(button.get_meta("item_instance_ids", []) == item.instance_ids and button.get_meta("item_stack_key", "") == item.stack_key, "bag lost grouped instance IDs or stack key: " + id)
		_require(button.text == "%s ×%d" % [detail.display_name, detail.quantity] and button.tooltip_text == detail.detail_text, "bag truncated name/count/shared full detail: " + id)
		_require(button.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING and button.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART, "bag hides long names instead of wrapping: " + id)
		_require(button.get_minimum_size().y <= button.size.y + 1.0, "bag clips native button height: " + id)
		var style := button.get_theme_stylebox("normal")
		var icon_width := float(button.get_theme_constant("icon_max_width")) + button.get_theme_constant("h_separation") if button.icon != null else 0.0
		var safe_width := button.size.x - style.get_minimum_size().x - icon_width
		var shaped := button.get_theme_font("font").get_multiline_string_size(button.text, HORIZONTAL_ALIGNMENT_LEFT, safe_width, button.get_theme_font_size("font_size"), -1, TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE)
		_require(shaped.x <= safe_width + 1.0 and shaped.y <= button.size.y - style.get_minimum_size().y + 1.0, "bag native shaping does not fit the complete name/count: " + id)
	_require(actual_columns == expected_columns, "bag changed category, within-category order, or exact item identity: %s" % str(actual_columns))
	_require(not _tree_text(grid).contains("空位"), "bag alignment created fake empty-slot copy")


func _check_single_bag_row(surface: RunSurface, button: Button) -> void:
	var bar := surface.backpack_scroll.get_v_scroll_bar()
	_require(not bar.is_visible_in_tree() and bar.max_value - bar.page <= 1.0, "single short bag row exposes actual scrolling")
	_require(button != null and surface.backpack_scroll.get_global_rect().grow(1.0).encloses(button.get_global_rect()), "complete single item is outside the bag viewport")


func _wheel_bag(scroll: Control) -> void:
	for _index in range(64):
		var motion := InputEventMouseMotion.new()
		motion.position = scroll.get_global_rect().get_center()
		motion.global_position = motion.position
		root.push_input(motion, true)
		for pressed in [true, false]:
			var event := InputEventMouseButton.new()
			event.position = motion.position
			event.global_position = motion.position
			event.button_index = MOUSE_BUTTON_WHEEL_DOWN
			event.pressed = pressed
			root.push_input(event, true)
		await process_frame


func _check_short_left_panel(surface: RunSurface, profile: Dictionary) -> void:
	# Presentation boundaries only. Real new-save admission and gameplay input
	# remain in the Main-scene test below; this does not complete a tutorial.
	var room_copy := "房间说明：搜索结束后检查现场物资，确认负重再继续探索。".repeat(8)
	var quest_copy := "当前任务：结束一次正式探索后回营地手动领取奖励。".repeat(6)
	var model := RunSurfaceModelScript.build({"run_active": true, "current_room": &"Normal"}, null, profile, {})
	model.merge({"room_summary": room_copy, "current_objective": quest_copy, "commission_text": "委托说明末行。"}, true)
	surface.apply_surface_model(model)
	await _frames(5)
	var frame: Rect2 = surface.room_text_mask.get_global_rect()
	var scale: float = profile.ui_scale_factor
	var expected_blank := 210.0 if scale == 1.0 else (149.0 if scale == 1.25 else 88.0)
	_require(absf(720.0 - frame.end.y - expected_blank) <= 1.0, "short left panel lost its reference lower-left space")
	_require(frame.size.y <= 300.0 + 64.0 * (scale - 1.0) / 0.5 + 1.0, "short left panel exceeds the final height budget")
	var body: Label = surface.room_body_label
	var scroll: ScrollContainer = surface.room_description_scroll
	_require(body.text == room_copy + "\n\n" + quest_copy + "\n\n委托说明末行。", "short left panel changed or discarded room/quest copy")
	_require(body.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING and body.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART and body.max_lines_visible == -1, "short left panel clips text instead of scrolling it")
	_require(body.get_theme_font_size("font_size") >= roundi(13.0 * scale), "short left panel shrank its font to meet the height budget")
	_require(frame.encloses(scroll.get_global_rect()) and scroll.is_ancestor_of(body), "room copy escaped its actual scroll viewport")
	var bar := scroll.get_v_scroll_bar()
	_require(bar.max_value - bar.page > 1.0, "long room/quest fixture did not exercise actual overflow")
	await _wheel_bag(scroll)
	_require(absf(bar.value - (bar.max_value - bar.page)) <= 1.0 and body.get_global_rect().end.y <= scroll.get_global_rect().end.y + 1.0, "native wheel cannot reach the complete room/quest final line")
	var map_actions: Array[StringName] = []
	var on_map := func(source: StringName) -> void: map_actions.append(source)
	surface.map_requested.connect(on_map)
	await _click_native(surface.action_buttons[&"map"])
	_require(map_actions == [&"surface_button"], "short panel blocked or duplicated the native main-action click")
	surface.map_requested.disconnect(on_map)
	var tutorial := preload("res://scenes/ui/tutorial/tutorial_popup_panel.tscn").instantiate() as TutorialPopupPanel
	surface.get_parent().add_child(tutorial)
	tutorial.apply_layout_profile(profile)
	var context := RunContext.new()
	context.mode = &"tutorial"
	context.run_active = true
	context.phase = &"running"
	context.profile_fields = {"ruleset_id": "z2", "z2_progression_version": 1, "flag_unlocked": false}
	context.tutorial_triggers = {"0,0": &"spawn_intro"}
	preload("res://scripts/core/run/tutorial_service.gd").trigger_for(context, Vector2i.ZERO)
	var cost_popup := context.tutorial_popup.duplicate(true)
	var training := {"run_id": "hud-short-teaching:%s" % scale, "position": Vector2i.ZERO, "mode": &"tutorial", "run_active": true, "phase": &"running", "profile_fields": context.profile_fields.duplicate(true), "tutorial_popup": cost_popup.duplicate(true)}
	var teaching_events: Array[Dictionary] = []
	var on_confirm := func() -> void: teaching_events.append({"signal": &"confirmed"})
	var on_cancel := func() -> void: teaching_events.append({"signal": &"cancelled"})
	var on_learn := func() -> void: teaching_events.append({"signal": &"learn_flag_requested"})
	var on_dismiss := func(id: StringName) -> void: teaching_events.append({"signal": &"guidance_dismissed", "popup_id": id})
	tutorial.confirmed.connect(on_confirm)
	tutorial.cancelled.connect(on_cancel)
	tutorial.learn_flag_requested.connect(on_learn)
	tutorial.guidance_dismissed.connect(on_dismiss)
	var external_focus := root.gui_get_focus_owner()
	tutorial.apply_training_state(training)
	tutorial.apply_popup(cost_popup)
	await _frames(5)
	var message := tutorial.get_node("Panel/Content/Message") as RichTextLabel
	var confirm := tutorial.get_node("Panel/Content/ConfirmButton") as Button
	var learn := tutorial.get_node_or_null("Panel/Content/LearnFlagButton") as Button
	var content := tutorial.get_node("Panel/Content") as Control
	_require(root.gui_get_focus_owner() == external_focus, "teaching presentation automatically stole external keyboard focus")
	_require(not context.has_blocking_tutorial_popup() and context.can_accept_command() and tutorial.mouse_filter == Control.MOUSE_FILTER_IGNORE, "short teaching guidance blocked runtime commands")
	_require(not bool(tutorial.layout_snapshot().get("guidance_expanded", true)) and message.text == str(cost_popup.message).get_slice("\n", 0) and str(tutorial.popup.get("message", "")) == str(cost_popup.message), "short tutorial did not retain its full source behind the collapsed summary")
	_require(message.get_theme_font_size("normal_font_size") >= roundi(13.0 * scale), "short tutorial panel reduced its body font")
	_require(confirm.text == "查看教学说明" and confirm.focus_mode == Control.FOCUS_NONE, "teaching details still look or behave like a business confirmation")
	_require(learn != null and learn.is_visible_in_tree() and not learn.disabled and learn.focus_mode == Control.FOCUS_ALL and learn.text == "100点 · 学习插旗" and learn.tooltip_text.contains("花费100点"), "independent teaching action lost its exact cost or manual keyboard access")
	await _click_native(confirm)
	_require(bool(tutorial.layout_snapshot().get("guidance_expanded", false)) and message.text == str(cost_popup.message) and message.text.contains("100点 · 学习插旗") and message.text.contains("收起说明不会扣点"), "expanded short tutorial changed or discarded the complete teaching cost explanation")
	_require(teaching_events.is_empty(), "expanding teaching guidance emitted a business or dismissal signal: %s" % str(teaching_events))
	await _wheel_bag(message)
	var message_bar := message.get_v_scroll_bar()
	_require(message_bar.value >= message_bar.max_value - message_bar.page - 1.0 and message.get_content_height() - message_bar.value <= message.size.y + 1.0, "native wheel cannot reach the teaching cost final line")
	for action: Button in [confirm, learn]:
		if action == null:
			continue
		_require(action.is_visible_in_tree() and content.get_global_rect().grow(1.0).encloses(action.get_global_rect()) and action.get_minimum_size().y <= action.size.y + 1.0 and action.get_minimum_size().x <= action.size.x + 1.0, "teaching action does not fit its native minimum size or safe rect: %s" % action.name)
		_require(action.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING and action.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART and action.get_theme_font_size("font_size") >= roundi(13.0 * scale), "teaching action clipped text or reduced its font: %s" % action.name)
		_require(not action.get_global_rect().intersects(message.get_global_rect()), "teaching action overlaps the complete explanation: %s" % action.name)
	_require(learn == null or not confirm.get_global_rect().intersects(learn.get_global_rect()), "details and paid learning actions overlap")
	await _click_native(confirm)
	var expected_events: Array[Dictionary] = [{"signal": &"guidance_dismissed", "popup_id": &"spawn_intro"}]
	_require(not bool(tutorial.layout_snapshot().get("guidance_expanded", true)) and teaching_events == expected_events, "collapsing guidance did not emit only its dedicated exact dismissal: %s" % str(teaching_events))
	if learn != null:
		await _click_native(learn)
	expected_events.append({"signal": &"learn_flag_requested"})
	_require(teaching_events == expected_events and not bool(context.profile_fields.get("flag_unlocked", true)) and context.tutorial_popup == cost_popup, "native learning request crossed signal channels or mutated authority: %s" % str(teaching_events))

	# Risk decisions retain real modality; they are not a renamed cost lesson.
	var entry_popup := {"id": &"flag_entry_confirm", "title": "进入插旗房间？", "message": "这里已被你标记。继续进入会正常触发房间风险，旗帜仍会保留。", "blocking": true, "confirm_text": "确认进入", "confirm_action": &"ui_accept", "confirm_action_hint": cost_popup.get("confirm_action_hint", {})}
	context.tutorial_popup = entry_popup.duplicate(true)
	var risk_state := training.duplicate(true)
	risk_state["tutorial_popup"] = entry_popup.duplicate(true)
	tutorial.apply_training_state(risk_state)
	tutorial.apply_popup(entry_popup)
	await _frames(5)
	var cancel := tutorial.get_node("Panel/Content/CancelButton") as Button
	_require(context.has_blocking_tutorial_popup() and not context.can_accept_command() and tutorial.mouse_filter == Control.MOUSE_FILTER_STOP and bool(tutorial.layout_snapshot().get("blocking", false)), "short risk confirmation lost its genuine runtime/input modality")
	_require(root.gui_get_focus_owner() == cancel and (learn == null or not learn.is_visible_in_tree()), "risk confirmation did not choose safe Cancel focus or exposed the learning action")
	for action: Button in [confirm, cancel]:
		_require(action.visible and content.get_global_rect().grow(1.0).encloses(action.get_global_rect()) and action.get_minimum_size().y <= action.size.y + 1.0 and action.get_minimum_size().x <= action.size.x + 1.0, "short confirmation panel lost a complete native action")
		_require(action.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING and action.get_theme_font_size("font_size") >= roundi(13.0 * scale) and not action.get_global_rect().intersects(message.get_global_rect()), "risk confirmation clipped/reduced an action or overlaps its message")
	_require(not confirm.get_global_rect().intersects(cancel.get_global_rect()), "short risk confirmation actions overlap")
	await _click_native(cancel)
	expected_events.append({"signal": &"cancelled"})
	_require(teaching_events == expected_events, "native risk cancel leaked or duplicated another signal: %s" % str(teaching_events))
	await _click_native(confirm)
	expected_events.append({"signal": &"confirmed"})
	_require(teaching_events == expected_events, "native risk confirm leaked or duplicated another signal: %s" % str(teaching_events))
	root.gui_release_focus()
	await _press_native_key(KEY_ENTER)
	expected_events.append({"signal": &"cancelled"})
	_require(teaching_events == expected_events, "unfocused risk accept did not take exactly the safe cancellation path: %s" % str(teaching_events))
	confirm.grab_focus()
	await process_frame
	_require(root.gui_get_focus_owner() == confirm, "explicit risk confirm keyboard focus is unreachable")
	await _press_native_key(KEY_ENTER)
	expected_events.append({"signal": &"confirmed"})
	_require(teaching_events == expected_events, "manually focused risk confirm Enter did not use exactly the GUI confirmation path: %s" % str(teaching_events))
	tutorial.confirmed.disconnect(on_confirm)
	tutorial.cancelled.disconnect(on_cancel)
	tutorial.learn_flag_requested.disconnect(on_learn)
	tutorial.guidance_dismissed.disconnect(on_dismiss)
	tutorial.queue_free()
	await _frames(3)


func _click_native(control: Control) -> void:
	_require(control.is_visible_in_tree(), "native click target is hidden: %s" % control.name)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = control.get_global_rect().get_center()
		event.global_position = event.position
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)
		await process_frame
	await _frames(2)


func _press_native_key(keycode: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.pressed = pressed
		root.push_input(event, true)
		await process_frame
	await _frames(2)


func _check_input_and_character_profile() -> void:
	var player := PlayerControllerScript.new()
	root.add_child(player)
	await _frames(2)
	player.set_local_position(Vector2(0.25, 0.25))
	var before_preview: Vector2 = player.get_local_position()
	player.play_step(Vector2.RIGHT)
	_require(player.get_local_position().is_equal_approx(before_preview), "key-down preview added an extra displacement")
	var move_result: Dictionary = player.move_local(Vector2.RIGHT, 1.0 / 60.0)
	_require(StringName(move_result.get("status", &"")) == &"moved", "continuous movement did not own the first displacement")
	_require(player.get_local_position().x > before_preview.x, "continuous movement did not change player position")

	var default_set := RuntimeAnimationCatalogScript.default_player_animation_set()
	var fixture_set := default_set.duplicate(true)
	fixture_set["appearance_id"] = &"graytail_field_coat"
	fixture_set["source_status"] = &"audited_runtime_fixture"
	var position_before_profile: Vector2 = player.get_local_position()
	player.set_presentation_profile(&"graytail_field_coat", &"i3_fixture_set", {&"i3_fixture_set": fixture_set})
	var presentation: Dictionary = player.presentation_snapshot()
	_require(StringName(presentation.get("appearance_id", &"")) == &"graytail_field_coat", "appearance replacement API did not apply")
	_require(StringName(presentation.get("animation_set_id", &"")) == &"i3_fixture_set", "animation-set replacement API did not apply")
	_require(String(presentation.get("animation_root", "")) == RuntimeAnimationCatalogScript.PLAYER_ROOT, "animation-set API did not retain the audited runtime root")
	_require(player.get_local_position().is_equal_approx(position_before_profile), "presentation replacement mutated gameplay position")
	for forbidden_key in ["inventory", "equipped", "owned", "save", "authority"]:
		_require(not presentation.has(forbidden_key), "presentation snapshot gained gameplay authority: %s" % forbidden_key)
	var fixture_path := RuntimeAnimationCatalogScript.player_texture_path(&"right", &"move", 0, false, false, fixture_set)
	_require(fixture_path == "res://assets/art24/actors/player/right_walk_a.png", "audited runtime walking frame did not resolve through the replacement API")
	_require(RuntimeAnimationCatalogScript.player_walk_bob_offset(0.1, true, fixture_set) == 0.0, "reduced motion no longer suppresses character bob")
	var fallback := RuntimeAnimationCatalogScript.resolve_player_animation_set(&"missing_i3_set")
	_require(bool(fallback.get("used_fallback", false)), "missing animation set did not fail closed to the audited default")
	_require(String(fallback.get("root", "")) == RuntimeAnimationCatalogScript.PLAYER_ROOT, "animation fallback escaped the audited runtime root")
	player.queue_free()
	await _frames(2)


func _check_production_gamepad_propagation() -> void:
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	_require(packed != null, "production main scene could not be loaded for gamepad propagation")
	if packed == null:
		return
	var main := packed.instantiate()
	root.add_child(main)
	await _frames(5)
	var run_scene := main.get_node_or_null("RunScene")
	_require(run_scene != null, "production RunScene is missing")
	if run_scene == null:
		main.queue_free()
		await _frames(2)
		return
	var bus: Variant = run_scene.get("command_bus")
	_require(bus != null, "production CommandBus is missing")
	if bus == null:
		main.queue_free()
		await _frames(2)
		return
	var start_result: Dictionary = preload("res://tests/z2_legacy_main_fixture.gd").start(run_scene)
	_require(bool(start_result.get("ok", false)), "production run could not start: %s" % start_result)
	if not bool(start_result.get("ok", false)):
		main.queue_free()
		await _frames(3)
		return
	run_scene.call("_show_run_screen")
	run_scene.call("_debug_teleport_to_room_type", &"Normal")
	await _frames(5)
	var context: RunContext = run_scene.get("run_context")
	_require(context.get_status_snapshot().get("current_room") == &"Normal" and context.asset_ledger.get_room_floor_items(context.get_current_pos()).is_empty(), "gamepad fixture is not a clear noncombat room")
	var production_player := run_scene.get("player_controller") as PlayerController
	var inventory_panel := run_scene.get("inventory_panel") as Control
	_require(production_player != null and inventory_panel != null, "production input fixtures are missing")
	if production_player != null:
		production_player.set_local_position(Vector2(0.25, 0.25))
		_require(production_player.input_enabled, "production gamepad movement is unexpectedly input-blocked")
		var before_gamepad := production_player.get_local_position()
		_parse_joy_button(JOY_BUTTON_DPAD_RIGHT, true)
		await create_timer(0.15).timeout
		_parse_joy_button(JOY_BUTTON_DPAD_RIGHT, false)
		await _frames(2)
		_require(production_player.get_local_position().x > before_gamepad.x, "D-pad input did not propagate through production continuous movement")
		_require(is_equal_approx(production_player.get_local_position().y, before_gamepad.y), "right D-pad input introduced vertical displacement")
	_parse_joy_button(JOY_BUTTON_LEFT_SHOULDER, true)
	await process_frame
	_parse_joy_button(JOY_BUTTON_LEFT_SHOULDER, false)
	await _frames(3)
	_require(inventory_panel != null and inventory_panel.visible, "LB InputEventJoypadButton did not open the production inventory")
	_parse_joy_button(JOY_BUTTON_B, true)
	await process_frame
	_parse_joy_button(JOY_BUTTON_B, false)
	await _frames(3)
	_require(inventory_panel == null or not inventory_panel.visible, "B InputEventJoypadButton did not close the production inventory")
	main.queue_free()
	await _frames(4)


func _sample_item(instance_id: String, display_name: String, quantity: int, weight: int) -> Dictionary:
	return {
		"instance_id": instance_id,
		"item_id": "raw_internal_item_id",
		"display_name": display_name,
		"item_type": "collectible",
		"rarity": &"tier_6",
		"collectible_level": 6,
		"quantity": quantity,
		"weight": weight,
		"base_value": 17,
		"short_description": "指针会记录穿过的回廊与回声。",
		"pickup_allowed": true,
	}


func _parse_joy_button(button_index: int, pressed: bool) -> void:
	var event := InputEventJoypadButton.new()
	event.device = 0
	event.button_index = button_index
	event.pressed = pressed
	event.pressure = 1.0 if pressed else 0.0
	Input.parse_input_event(event)


func _count_item_action(_instance_id: String) -> void:
	item_action_count += 1


func _tree_text(node: Node) -> String:
	var parts: Array[String] = []
	if node is Label:
		parts.append((node as Label).text)
	elif node is Button:
		parts.append((node as Button).text)
	for child in node.get_children():
		parts.append(_tree_text(child))
	return "\n".join(parts)


func _label_text_fits(label: Label) -> bool:
	return _label_text_width(label) <= label.size.x + 0.5


func _label_text_width(label: Label) -> float:
	if label == null:
		return INF
	var font := label.get_theme_font("font")
	if font == null:
		return INF
	return font.get_string_size(
		label.text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		label.get_theme_font_size("font_size")
	).x


func _frames(count: int) -> void:
	for _index in range(count):
		await process_frame


func _require(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("I3_HUD_CLASSIFICATION columns=2 cases=empty,1+0,0+1,2+2,3+1,can_consume_changed catalog=8+8 scales=100,125,150 text=native_full wheel=last_row short_left=summary+expanded_full_copy,explicit_cost_learning,risk_confirm_cancel,safe_keyboard_focus")
		print("%s hud=primary_action,mine_risk actions=7,context_order items=shared_descriptor,scroll replacement=two_line,no_clip,authoritative_level input=single_path,gamepad_propagated character=appearance,animation_set reduced_motion=preserved" % PASS_MARKER)
		quit(0)
		return
	for failure in failures:
		push_error("I3 HUD/item/input/character failure: " + failure)
	print("%s failures=%d" % [FAIL_MARKER, failures.size()])
	quit(1)
