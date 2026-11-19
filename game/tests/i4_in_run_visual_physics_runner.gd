extends SceneTree

const InteractableScript := preload("res://scripts/gameplay/interaction/g41_interactable.gd")
const GroundLootEntityScript := preload("res://scripts/gameplay/loot/g41_ground_loot_entity.gd")
const RoomRuntimeViewScript := preload("res://scripts/gameplay/runtime/g41_room_runtime_view.gd")
const WorldObjectProjectionScript := preload("res://scripts/gameplay/runtime/g41_world_object_projection.gd")
const ItemCatalogScript := preload("res://scripts/core/content/m3_item_catalog.gd")
const ItemVisualCatalogScript := preload("res://scripts/presentation/art24/art24_item_visual_catalog.gd")
const ItemRarityDescriptorScript := preload("res://scripts/presentation/item_rarity_descriptor.gd")
const MapCellLayerLayoutScript := preload("res://scripts/ui/map_shared/map_cell_layer_layout.gd")
const RunSurfaceScript := preload("res://scripts/ui/run_surface/run_surface.gd")
const RunSurfaceModelScript := preload("res://scripts/ui/run_surface/run_surface_model.gd")
const RunUIViewModelScript := preload("res://scripts/ui/shell/run_ui_view_model.gd")
const UISkin := preload("res://scripts/presentation/art10_ui_skin_kit.gd")
const Z2Items := preload("res://scripts/core/content/z2_item_catalog.gd")
const LegacyMainFixture := preload("res://tests/z2_legacy_main_fixture.gd")
const UILayoutProfileScript := preload("res://scripts/ui/shell/ui_layout_profile.gd")
const PlayerScene := preload("res://scenes/player/player.tscn")
const MiniMapScene := preload("res://scenes/ui/minimap/minimap_panel.tscn")

const EXPECTED_RARITY_COLORS := {
	&"tier_1": Color("d0d8e0"),
	&"tier_2": Color("78dcaa"),
	&"tier_3": Color("5fa5ff"),
	&"tier_4": Color("be78ff"),
	&"tier_5": Color("ffc346"),
	&"tier_6": Color("fa5f55"),
	&"unique": Color("f6e079"),
	&"unknown": Color("a9b0ad"),
}

class WorldPointerProbe extends Node:
	var clicks := 0
	func _unhandled_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			clicks += 1

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	_check_rarity_palette_and_item_resolver()
	_check_map_cell_layer_contract()
	await _check_texture_fallback_and_world_drop()
	await _check_collision_visible_correspondence()
	await _check_protocol_and_left_density()
	await _check_player_contact_shadow()
	await _check_ground_depth_and_floor_reachability()
	_check_clear_world_loot_placement()
	await _check_minimap_texture_bounds()
	await _check_readable_compact_minimap()
	await _check_compact_corner_counts()
	await _check_scaled_capacity_text()
	await _check_world_item_summary_fit()
	await _check_debug_chest_spawn()
	await _check_main_tutorial_mapping()
	await _check_main_inventory_details()
	_finish()


func _check_world_item_summary_fit() -> void:
	var popup := G41WorldContextPopup.new()
	root.add_child(popup)
	var item := {"instance_id": "summary_fit", "item_id": "col_10", "display_name": "旧工具头", "item_type": "collectible", "rarity": &"tier_3", "collectible_level": 3, "weight": 1}
	popup.apply_context({"interaction_kind": &"ground_loot", "world_pos": Vector2(640, 360), "items": [item], "backpack_remaining": 10})
	var button := popup.find_child("ContextItemInfo", true, false) as Button
	await _wait_until(func() -> bool: return button != null and button.size.x > 156.0, "world item summary row sized")
	var icon_width := minf(button.icon.get_width(), button.size.y - button.get_theme_stylebox("normal").get_minimum_size().y) if button.icon != null else 0.0
	var text_width := button.size.x - button.get_theme_stylebox("normal").get_minimum_size().x - icon_width - button.get_theme_constant("h_separation")
	var summary := button.text.split("\n")[1]
	_check(summary.contains("3") and summary.contains("重1"), "World item summary lost collection level or weight")
	_check(button.get_theme_font("font").get_string_size(summary, HORIZONTAL_ALIGNMENT_LEFT, -1, button.get_theme_font_size("font_size")).x <= text_width, "World item summary clips its weight behind the pickup action")
	popup.queue_free()
	await popup.tree_exited


func _check_scaled_capacity_text() -> void:
	var settings := root.get_node("SettingsManager")
	var original_percent := int(settings.applied.get("ui_scale_percent", 100))
	var original_size := root.size
	var canvas := Control.new()
	canvas.size = Vector2(1280, 720)
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(canvas)
	var surface = RunSurfaceScript.new()
	canvas.add_child(surface)
	surface.build()
	for physical in [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(960, 720), Vector2i(1600, 1000)]:
		root.size = physical
		await process_frame
		for factor in [1.0, 1.25, 1.5]:
			settings.begin_transaction()
			_check(settings.set_draft_value(&"ui_scale_percent", int(round(factor * 100))), "Scale transaction rejected valid percentage")
			_check(settings.apply_draft(), "Scale transaction failed to apply")
			var viewport := root.get_visible_rect()
			canvas.size = viewport.size
			var profile := UILayoutProfileScript.profile_for_size(viewport.size)
			profile["actual_viewport_size"] = Vector2i(viewport.size)
			profile["ui_scale_factor"] = factor
			surface.set_ui_scale_factor(factor)
			surface.apply_layout_profile(profile)
			for dimensions in [Vector2i(5, 5), Vector2i(7, 7), Vector2i(10, 10), Vector2i(13, 13), Vector2i(13, 7), Vector2i(7, 13)]:
				for count in [0, 4]:
					var items := _sample_items(count)
					var model := _surface_model(profile, items, 5, 100)
					model["map_dimensions"] = dimensions
					surface.apply_surface_model(model)
					var minimap_model := MiniMapViewModel.new()
					minimap_model.width = dimensions.x
					minimap_model.height = dimensions.y
					surface.minimap_panel.apply_view_model(minimap_model)
					await _settle_hud(surface)
					_check_reference_geometry(surface, profile, viewport)
					_check_bag_layout(surface, items, factor)
					_check(is_equal_approx(surface.ui_scale_factor, factor), "Capacity probe did not use requested scale")
					var grid := surface.minimap_panel.get_node("Grid") as GridContainer
					_check(Rect2(Vector2.ZERO, surface.minimap_panel.size).encloses(grid.get_rect()), "Actual-size map escapes its right-rail viewport at UI scale %s" % factor)
					_check(grid.get_child_count() == dimensions.x * dimensions.y, "HUD cropped the actual map at UI scale %s" % factor)
					if count == 4:
						await _check_bag_scroll(surface, false)
			var long_items := _long_catalog_items()
			surface.apply_surface_model(_surface_model(profile, long_items, 5, 100))
			await _settle_hud(surface)
			_check_bag_layout(surface, long_items, factor)
			await _check_bag_scroll(surface, true)
			await _check_room_description(surface, profile, factor)
			print("I4_ADAPTIVE_HUD physical=%s logical=%s scale=%s long_items=%d" % [physical, viewport.size, factor, long_items.size()])
	var high_profile := UILayoutProfileScript.profile_for_resolution(&"2560x1440")
	high_profile["ui_scale_factor"] = 1.5
	surface.apply_layout_profile(high_profile)
	surface.apply_surface_model(_surface_model(high_profile, [], 5, 100))
	await process_frame
	_check(surface.scanner_title_label.size.y >= surface.scanner_title_label.get_line_height(), "High-resolution overview title is clipped at 150 percent")
	settings.set_draft_value(&"ui_scale_percent", original_percent)
	settings.apply_draft()
	settings.close_transaction()
	root.size = original_size
	canvas.queue_free()
	await canvas.tree_exited


func _check_minimap_texture_bounds() -> void:
	var minimap = MiniMapScene.instantiate()
	root.add_child(minimap)
	minimap.size = Vector2(248, 200)
	var model := MiniMapViewModel.new()
	model.width = 7
	model.height = 7
	model.set_room_markers([{"pos": Vector2i(3, 3), "is_current": true, "known_state": &"explored", "adjacent_mines": 2}])
	minimap.apply_view_model(model)
	await process_frame
	await process_frame
	for cell in minimap.get_node("Grid").get_children():
		var base := cell.get_node("CellBase") as TextureRect
		var intended := Rect2((cell.get_meta("map_cell_layer_layout") as Dictionary)["base_rect"])
		_check(base.get_rect().is_equal_approx(intended), "Minimap texture retained its native minimum size: %s expected=%s" % [base.get_rect(), intended])
		_check(Rect2(Vector2.ZERO, cell.size).encloses(base.get_rect()), "Minimap cell clips its base texture")
		var semantic := cell.get_node_or_null("SemanticMarker") as TextureRect
		if semantic != null:
			var semantic_rect := Rect2((cell.get_meta("map_cell_layer_layout") as Dictionary)["semantic_rect"])
			_check(semantic.get_rect().is_equal_approx(semantic_rect), "Minimap semantic marker retained its native minimum size")
	_check(minimap.get_node("Grid/MiniMapCell_3_3/SemanticMarker") != null, "Minimap bound check lacks a public player marker")
	minimap.queue_free()
	await minimap.tree_exited


func _check_readable_compact_minimap() -> void:
	for edge in [7, 10]:
		var minimap = MiniMapScene.instantiate()
		root.add_child(minimap)
		minimap.size = Vector2(212, 200)
		var model := MiniMapViewModel.new()
		model.width = edge
		model.height = edge
		model.set_room_markers([
			{"pos": Vector2i(3, 3), "is_current": true, "known_state": &"explored", "adjacent_mines": 2},
			{"pos": Vector2i(2, 3), "room_type": &"Normal", "known_state": &"explored", "adjacent_mines": 2},
		])
		minimap.apply_view_model(model)
		await process_frame
		await process_frame
		var grid := minimap.get_node("Grid") as GridContainer
		_check(grid.get_child_count() == edge * edge, "Readable minimap lost complete map dimensions")
		var first := grid.get_child(0) as Control
		var second := grid.get_child(1) as Control
		_check(is_equal_approx(first.get_rect().end.x, second.position.x), "Compact minimap cells still have an empty gutter")
		_check(first.get_node("CellBase").get_rect().is_equal_approx(Rect2(Vector2.ZERO, first.size)), "Compact minimap base still wastes cell area on fixed insets")
		var current := grid.get_node("MiniMapCell_3_3") as Control
		var icon := current.get_node("SemanticMarker") as TextureRect
		_check(icon.size.x >= current.size.x - 2.0 and icon.size.y >= current.size.y - 2.0, "Compact minimap icon is reduced to a tiny central patch")
		var count := grid.get_node("MiniMapCell_2_3").get_node_or_null("AdjacentMineCount") as Label
		_check(count != null and count.text == "2", "Plain known minimap room hides its public risk number")
		if count != null:
			_check(count.size.y >= count.get_line_height(), "Compact public risk number is vertically clipped")
		minimap.queue_free()
		await minimap.tree_exited


func _check_compact_corner_counts() -> void:
	for edge in [7, 10]:
		var panel = MiniMapScene.instantiate()
		root.add_child(panel)
		panel.size = Vector2(212, 200)
		var model := MiniMapViewModel.new()
		model.width = edge
		model.height = edge
		var types := [&"Normal", &"Chest", &"Monster", &"Mine", &"Event", &"Exit", &"Normal", &"Unknown", &"Normal"]
		var markers: Array[Dictionary] = []
		for value in range(9):
			markers.append({"pos": Vector2i(value % 5 + 1, value / 5 + 1), "room_type": types[value], "known_state": &"scanned" if value == 7 else &"explored", "is_current": value == 0, "flagged": value == 8, "adjacent_mines": value})
		model.set_room_markers(markers)
		panel.apply_view_model(model)
		await process_frame
		await process_frame
		for marker in markers:
			var cell: Control = panel.get_node("Grid/MiniMapCell_%d_%d" % [marker.pos.x, marker.pos.y])
			var count := cell.get_node_or_null("AdjacentMineCount") as Label
			_check(count != null and count.text == str(marker.adjacent_mines), "Compact minimap lost public count on %s" % marker.room_type)
			if count != null:
				_check(count.get_rect().end.is_equal_approx(cell.size), "Public count is not anchored at the cell bottom-right")
				_check(count.z_index > 20, "Public count does not float above room content")
				_check(count.size.y >= count.get_line_height(), "Corner count clips its digit")
		panel.queue_free()
		await panel.tree_exited


func _check_player_contact_shadow() -> void:
	var player = PlayerScene.instantiate()
	root.add_child(player)
	var sprite := player.get_node_or_null("Sprite") as Sprite2D
	var shadow := player.get_node_or_null("GroundShadow") as Sprite2D
	_check(shadow != null and shadow.texture != null, "Player lacks a textured contact shadow")
	if shadow != null and shadow.texture != null and sprite != null:
		var foot_y := sprite.position.y + sprite.get_rect().end.y * sprite.scale.y
		_check(absf(foot_y) <= 5.0 and shadow.position.length() <= 1.0, "Player feet and contact shadow are not grounded at the collision origin")
		_check(absf(shadow.position.y - foot_y) <= 5.0, "Contact shadow is detached from the authored feet")
		_check(shadow.z_index < sprite.z_index, "Contact shadow draws over the actor")
		var width := shadow.texture.get_width() * shadow.scale.x
		_check(width >= 24.0 and width <= sprite.texture.get_width() * sprite.scale.x, "Contact shadow exceeds the actor silhouette")
		var original_obstacles: Array = player.logical_obstacles.duplicate()
		var offset := shadow.position
		player.set_local_position(Vector2(0.25, 0.75))
		_check(shadow.global_position.is_equal_approx(player.global_position + offset), "Contact shadow did not follow the real player position")
		_check(player.logical_obstacles == original_obstacles, "Contact shadow changed collision authority")
		player.call("_apply_visual")
		_check(player.get_node("GroundShadow") == shadow, "Refreshing appearance duplicated the contact shadow")
	player.queue_free()
	await player.tree_exited


func _check_ground_depth_and_floor_reachability() -> void:
	var scene := Node2D.new()
	var room_layer := Node2D.new()
	room_layer.name = "RoomLayer"
	scene.add_child(room_layer)
	var player_layer := Node2D.new()
	player_layer.name = "PlayerLayer"
	scene.add_child(player_layer)
	var view = RoomRuntimeViewScript.new()
	room_layer.add_child(view)
	var player = PlayerScene.instantiate()
	player.name = "PlayerController"
	player_layer.add_child(player)
	root.add_child(scene)
	view.configure_room(_room_snapshot(&"Chest", Vector2i.ZERO))
	view.call("_update_visual_depths", Vector2(0.50, 0.43))
	_check(player.z_index < view.chest.z_index, "Player behind the chest draws over its lid")
	view.call("_update_visual_depths", Vector2(0.50, 0.635))
	_check(player.z_index > view.chest.z_index, "Chest cuts through the player standing in front")
	var rear_actor := Node2D.new()
	var front_actor := Node2D.new()
	view.add_child(rear_actor)
	view.add_child(front_actor)
	view.call("_apply_actor_depth", rear_actor, Vector2(0.50, 0.43))
	view.call("_apply_actor_depth", front_actor, Vector2(0.50, 0.70))
	_check(rear_actor.z_index < player.z_index and front_actor.z_index > player.z_index, "Nearby actors do not share the player's foot-depth order")
	view.configure_room(_room_snapshot(&"Normal", Vector2i.ZERO))
	player.set_logical_obstacles(view.get_logical_obstacles())
	player.set_door_projections(view.get_door_projections())
	for entry_direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		var landing: Vector2 = player.place_from_entry(entry_direction)
		_check(WorldObjectProjectionScript.room_floor_interior().grow(-player.PLAYER_RADIUS).has_point(landing), "Door entry did not clear the wall thickness for lateral movement")
		_check(not player.call("_position_hits_obstacle", landing), "Door entry landed inside a solid body")
	for blocked in [Vector2(0.30, 0.10), Vector2(0.10, 0.30), Vector2(0.18, 0.23)]:
		_check(player.call("_position_hits_obstacle", blocked), "Visible wall or corner prop has no body at %s" % blocked)
	for floor_point in [Vector2(0.30, 0.32), Vector2(0.50, 0.50), Vector2(0.65, 0.72), Vector2(0.43, 0.10), Vector2(0.57, 0.10), Vector2(0.10, 0.43), Vector2(0.10, 0.57)]:
		_check(not player.call("_position_hits_obstacle", floor_point), "Clear floor or door lane is blocked at %s" % floor_point)
	player.set_local_position(Vector2(0.35, 0.72))
	for index in range(25):
		player.move_local(Vector2.RIGHT, 1.0 / 60.0)
	_check(player.get_local_position().x > 0.60, "Held movement could not cross clear interior floor")
	player.local_velocity = Vector2.ZERO
	player.set_local_position(Vector2(0.30, 0.50))
	for index in range(60):
		player.move_local(Vector2.UP, 1.0 / 60.0)
	_check(player.get_local_position().y >= 0.20, "Player walked through the visible north wall")
	view.configure_room(_room_snapshot(&"Event", Vector2i.ZERO))
	player.set_logical_obstacles(view.get_logical_obstacles())
	_check(player.call("_position_hits_obstacle", Vector2(0.50, 0.535)), "Event table remains walkable while its detached badge blocks floor")
	_check(not player.call("_position_hits_obstacle", Vector2(0.50, 0.70)), "Event table blocks the clear floor in front")
	scene.queue_free()
	await scene.tree_exited


func _check_clear_world_loot_placement() -> void:
	for room_type in [&"Normal", &"Monster", &"Event", &"Mine", &"Exit"]:
		var snapshot := _room_snapshot(room_type, Vector2i.ZERO)
		var items: Array[Dictionary] = []
		for index in range(48):
			items.append({"instance_id": "floor_clearance_%d" % index, "item_id": "tool_blade", "display_name": "测试物资"})
		snapshot["room_floor_items"] = items
		var projection := WorldObjectProjectionScript.build(snapshot)
		var floor_count := 0
		var positions: Dictionary = {}
		for object in projection["world_objects"]:
			if object["interaction_kind"] != &"ground_loot":
				continue
			floor_count += 1
			var point: Vector2 = object["local_pos"]
			positions[point] = true
			for solid in WorldObjectProjectionScript.room_solid_rects(room_type):
				_check(not solid.grow(G41RuntimeLayout.PLAYER_BODY_RADIUS).has_point(point), "%s loot is on furniture or unreachable floor: %s" % [room_type, point])
		_check(floor_count == items.size(), "%s geometry adjustment lost ledger instances" % room_type)
		_check(positions.size() == 12, "%s geometry adjustment collapsed the existing twelve floor slots" % room_type)


func _check_debug_chest_spawn() -> void:
	var manager := root.get_node("SettingsManager")
	var original_resolution: String = str(manager.applied.get("resolution_id", "auto"))
	manager.begin_transaction()
	manager.set_draft_value(&"resolution_id", "1280x720")
	manager.apply_draft()
	manager.confirm_pending_changes()
	manager.close_transaction()
	var main := (load("res://scenes/main/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	# Let the freshly attached scene finish its deferred anchor layout before
	# dispatching a route from this same frame's component-test teardown.
	await process_frame
	var run_scene := main.get_node("RunScene")
	await _wait_until(func() -> bool: return run_scene.get("result_panel").is_node_ready(), "main scene controls ready")
	run_scene.call("_show_settings_shell")
	var settings = run_scene.get("ui_shell").get("settings_panel")
	settings.get("test_room_button").pressed.emit()
	if not await _wait_until(func() -> bool: return run_scene.get("screen_state") == &"run", "original sandbox entry"):
		run_scene.get("in_run_runtime").bind(null)
		run_scene.get("command_bus").bind_runtime_controller(null)
		main.queue_free()
		await main.tree_exited
		return
	run_scene.get("debug_panel_controller").call("teleport_to_room_type", &"Chest")
	var view = run_scene.get("room_runtime_view")
	await _wait_until(func() -> bool: return view.get("room_type") == &"Chest", "original debug Chest teleport")
	var player = run_scene.get("player_controller")
	var map_player_position: Vector2 = player.get_local_position()
	run_scene.call("_open_map_from_ui", &"keyboard")
	var overlay = run_scene.get("map_overlay_panel")
	await _wait_until(func() -> bool: return root.gui_get_focus_owner() is Button and overlay.is_ancestor_of(root.gui_get_focus_owner()), "map initial cell focus")
	var map_start: Vector2i = overlay.selected_marker.get("pos", Vector2i.ZERO)
	for step in [{"key": KEY_LEFT, "offset": Vector2i.LEFT}, {"key": KEY_RIGHT, "offset": Vector2i.ZERO}, {"key": KEY_DOWN, "offset": Vector2i.DOWN}, {"key": KEY_UP, "offset": Vector2i.ZERO}]:
		await _tap_map_key(step.key)
		var expected: Vector2i = map_start + Vector2i(step.offset)
		var expected_cell := overlay.get_node("Panel/Content/Grid/MapCell_%d_%d" % [expected.x, expected.y]) as Button
		_check(root.gui_get_focus_owner() == expected_cell, "Map direction key escaped the adjacent cell onto the overlay root")
		_check(overlay.visible and expected_cell.is_visible_in_tree(), "Map vanished during keyboard navigation")
	for key in [KEY_LEFT, KEY_UP, KEY_RIGHT, KEY_DOWN]:
		for index in range(8):
			await _tap_map_key(key)
			var focus := root.gui_get_focus_owner()
			_check(focus != null and overlay.is_ancestor_of(focus), "Map edge navigation escaped to the background HUD")
			_check(overlay.visible and overlay.get_node("Panel/Content/Grid").get_child_count() == 49, "Map content disappeared at a directional edge")
			var selected_outlines := 0
			for cell in overlay.get_node("Panel/Content/Grid").get_children():
				if cell.get_node("FocusSelectionOutline").visible:
					selected_outlines += 1
			_check(selected_outlines == 1, "Map navigation left stale selection outlines on previous cells")
	await _tap_map_key(KEY_LEFT)
	var flag_target: Vector2i = overlay.selected_marker.pos
	var original_flags := _map_flag_positions(overlay)
	var expected_flags := original_flags.duplicate()
	expected_flags.append(str(flag_target))
	expected_flags.sort()
	await _tap_map_key(KEY_ENTER)
	await _wait_until(func() -> bool: return _map_flag_positions(overlay) == expected_flags, "keyboard flag changes only the selected cell")
	await _tap_map_key(KEY_ENTER)
	await _wait_until(func() -> bool: return _map_flag_positions(overlay) == original_flags, "keyboard flag cancellation restores only the selected cell")
	_check(player.get_local_position().is_equal_approx(map_player_position) and not player.input_enabled, "Map navigation moved the character or left gameplay input enabled")
	await _tap_map_key(KEY_ESCAPE)
	for close_key in [{"key": KEY_TAB, "shift": false}, {"key": KEY_TAB, "shift": true}, {"key": KEY_ESCAPE, "shift": false}]:
		await _tap_map_key(KEY_M)
		await _wait_until(func() -> bool: return overlay.visible and not player.input_enabled, "keyboard map reopen blocks movement")
		await _tap_map_key(close_key.key, close_key.shift)
		await _wait_until(func() -> bool: return not overlay.visible and player.input_enabled, "existing map close shortcut restores gameplay input")
	var move_input := InputEventKey.new()
	move_input.keycode = KEY_D
	move_input.physical_keycode = KEY_D
	move_input.pressed = true
	Input.parse_input_event(move_input)
	await _wait_until(func() -> bool: return player.get_local_position().x > map_player_position.x + 0.02, "held movement resumes after closing the map")
	move_input.pressed = false
	Input.parse_input_event(move_input)
	var before: Vector2 = player.get_local_position()
	var banner := main.find_child("DebugSandboxBanner", true, false) as Label
	var room_bounds: Rect2 = view.get_global_transform_with_canvas() * G41RuntimeLayout.ROOM_RECT
	_check(banner != null and not banner.get_global_rect().intersects(room_bounds), "Sandbox status banner covers the traversable room and player")
	_check(not banner.text.contains("commit=") and not banner.text.contains("save=") and banner.text.split("\n").size() <= 2, "Sandbox banner repeats detailed diagnostic identity")
	var identity := main.find_child("DebugSessionIdentity", true, false) as Label
	_check(identity != null and identity.text.contains("commit=") and identity.text.contains("profile=") and identity.text.contains("scenario=") and identity.text.contains("seed=") and identity.text.contains("save="), "Diagnostic panel lost the sandbox identity fields")
	_check(identity != null and not identity.is_visible_in_tree(), "Detailed sandbox identity is visible outside diagnostics")
	run_scene.get("debug_panel_controller").open_panel()
	_check(identity != null and identity.is_visible_in_tree(), "Existing diagnostic panel cannot reveal the full sandbox identity")
	_check(not banner.is_visible_in_tree(), "Redundant sandbox marker covers the open diagnostic panel header")
	run_scene.get("debug_panel_controller").close_panel()
	_check(banner.is_visible_in_tree(), "Closing diagnostics did not restore the sandbox marker")
	await _wait_until(func() -> bool: return view.context_popup.visible and banner.size.y <= 300.0, "sandbox banner and Chest context layout")
	_check(Rect2(Vector2.ZERO, root.size).encloses(banner.get_global_rect()), "Sandbox banner extends beyond the visible viewport")
	_check(not banner.get_global_rect().intersects(view.context_popup.get_global_rect()), "Chest action card covers the sandbox identity")
	var original_scale := int(manager.applied.get("ui_scale_percent", 100))
	var protocol_card := main.find_child("Art21RunStatusCard", true, false) as Control
	var logical_room: Rect2 = player.room_rect
	var logical_solids: Array = player.logical_obstacles.duplicate(true)
	var logical_doors: Array = player.get_door_projections().duplicate(true)
	for scale_percent in [125, 150, 100]:
		manager.begin_transaction()
		manager.set_draft_value(&"ui_scale_percent", scale_percent)
		manager.apply_draft()
		await _wait_until(func() -> bool:
			return (
				banner.get_global_rect().position.y >= protocol_card.get_global_rect().end.y + 11.0
				and not banner.get_global_rect().intersects(view.get_global_transform() * G41RuntimeLayout.ROOM_RECT)
			)
		, "sandbox banner follows room and protocol scale")
		_check(not banner.get_global_rect().intersects(protocol_card.get_global_rect()), "Sandbox banner overlaps the scaled protocol card")
		_check(not protocol_card.get_global_rect().intersects(view.get_global_transform() * G41RuntimeLayout.ROOM_RECT), "Protocol card covers the playable room at %d%%" % scale_percent)
		_check(not banner.get_global_rect().intersects(view.get_global_transform() * G41RuntimeLayout.ROOM_RECT), "UI scaling moved the banner into the room")
		_check_world_mapping(run_scene)
		_check(player.room_rect == logical_room and player.logical_obstacles == logical_solids and player.get_door_projections() == logical_doors, "UI scaling changed logical room, obstacles or door bodies")
	manager.begin_transaction()
	manager.set_draft_value(&"ui_scale_percent", original_scale)
	manager.apply_draft()
	_check(not player.call("_position_hits_obstacle", map_player_position), "Debug Chest teleport placed the player inside a solid body")
	_check(view.chest.can_interact_from(map_player_position), "Debug Chest inspection spawn is outside interaction reach")
	for index in range(20):
		player.move_local(Vector2.RIGHT, 1.0 / 60.0)
	_check(player.get_local_position().x - before.x > 0.10, "Debug Chest spawn remains stuck under held movement")
	await _check_native_door_crossing(run_scene)
	run_scene.get("in_run_runtime").bind(null)
	run_scene.get("command_bus").bind_runtime_controller(null)
	var main_instance_id := main.get_instance_id()
	main.queue_free()
	await main.tree_exited
	await _wait_until(func() -> bool: return not is_instance_id_valid(main_instance_id), "main scene released before restoring settings")
	manager.begin_transaction()
	manager.set_draft_value(&"resolution_id", original_resolution)
	manager.apply_draft()
	manager.confirm_pending_changes()
	manager.close_transaction()


func _check_world_mapping(scene) -> void:
	var room_layer := scene.get_node("RoomLayer") as Node2D
	var player_layer := scene.get_node("PlayerLayer") as Node2D
	var background := scene.room_controller.get_node("Background/BackgroundSprite") as Sprite2D
	var rendered := background.get_global_transform() * background.get_rect()
	var stage: Rect2 = RunSurfaceModelScript.layout_geometry(scene._current_layout_profile()).room_stage_rect
	_check(stage.grow(0.5).encloses(rendered) and rendered.get_center().distance_to(stage.get_center()) < 0.5, "Actual rendered room is not centered inside the HUD's shared room allocation")
	_check(room_layer.transform.is_equal_approx(player_layer.transform), "Room and player layers use different transforms")
	var player: PlayerController = scene.player_controller
	var expected := player.room_rect.position + player.get_local_position() * player.room_rect.size
	_check(room_layer.to_local(player.global_position).distance_to(expected) < 0.01, "Rendered player no longer maps to its unchanged logical position")
	_check(not rendered.intersects(scene.run_surface.status_card_art.get_global_rect()) and not rendered.intersects(scene.run_surface.left_rail_art.get_global_rect()), "Actual room overlaps a permanent HUD rail")


func _check_native_door_crossing(scene) -> void:
	var context: RunContext = scene.run_context
	var origin := Vector2i(2, 2)
	var result: Dictionary = scene.runtime_controller.execute_atomic_operation(&"i4_door_fixture", {}, func() -> Dictionary:
		for direction: Vector2i in [Vector2i.ZERO, Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]:
			var target := origin + direction
			context.truth_map.set_room_type(target, &"Normal")
			context.intel_map.reveal_cell(target, context.truth_map)
			if context.intel_map.is_flagged(target): context.intel_map.toggle_flag(target)
		return {"ok": true}
	)
	_check(result.get("ok", false), "Sandbox cross-room fixture failed: " + str(result))
	if not result.get("ok", false): return
	var player: PlayerController = scene.player_controller
	for pair in [[Vector2i.UP, KEY_W], [Vector2i.RIGHT, KEY_D], [Vector2i.DOWN, KEY_S], [Vector2i.LEFT, KEY_A]]:
		var admitted: Dictionary = scene.command_bus.dispatch(&"debug_teleport_to", {"pos": origin, "enter_room": true})
		_check(admitted.get("ok", false), "Sandbox door origin rejected: " + str(admitted))
		if not admitted.get("ok", false): return
		await process_frame
		player.local_velocity = Vector2.ZERO
		player.set_local_position(Vector2(0.5, 0.5))
		var direction: Vector2i = pair[0]
		var committed := {}
		var observe := func(command_name: StringName, command: Dictionary) -> void:
			if command_name == &"attempt_room_transition":
				committed.request = (command.get("payload", {}) as Dictionary).duplicate(true)
				committed.landing = scene.runtime_controller.get_restored_local_position(Vector2(-1, -1))
		scene.command_bus.command_requested.connect(observe)
		var deadline := Time.get_ticks_msec() + 3000
		var repeat_at := Time.get_ticks_msec()
		_hold_input(pair[1], true)
		while context.get_current_pos() == origin and Time.get_ticks_msec() < deadline:
			if Time.get_ticks_msec() >= repeat_at:
				_hold_input(pair[1], true, true)
				repeat_at = Time.get_ticks_msec() + 100
			await process_frame
		var actual_landing := player.get_local_position()
		_hold_input(pair[1], false)
		scene.command_bus.command_requested.disconnect(observe)
		var requested: Vector2 = (committed.get("request", {}) as Dictionary).get("entry_position", Vector2(-1, -1))
		var landing: Vector2 = committed.get("landing", Vector2(-1, -1))
		var safe_floor := WorldObjectProjectionScript.room_floor_interior().grow(-player.PLAYER_RADIUS - 0.005)
		_check(context.get_current_pos() == origin + direction and not committed.is_empty(), "Held input did not enter the exact adjacent room: " + str(direction))
		_check(player.get_facing_vector().dot(Vector2(direction)) > 0.99, "Room entry changed the held direction's facing")
		_check(landing.distance_to(requested.clamp(safe_floor.position, safe_floor.end)) < 0.001 and actual_landing.distance_to(landing) < 0.02 and not player._position_hits_obstacle(actual_landing), "Real door transition did not preserve the committed safe landing")
		scene.command_bus.dispatch(&"debug_teleport_to", {"pos": origin, "enter_room": true})
		await process_frame
	scene.command_bus.dispatch(&"debug_teleport_to", {"pos": origin, "enter_room": true})
	player.local_velocity = Vector2.ZERO
	player.set_local_position(Vector2(0.30, 0.50))
	var deadline := Time.get_ticks_msec() + 850
	var repeat_at := Time.get_ticks_msec()
	_hold_input(KEY_W, true)
	while Time.get_ticks_msec() < deadline:
		if Time.get_ticks_msec() >= repeat_at:
			_hold_input(KEY_W, true, true)
			repeat_at = Time.get_ticks_msec() + 100
		await process_frame
	_hold_input(KEY_W, false)
	var wall_stop := player.get_local_position()
	_check(context.get_current_pos() == origin and wall_stop.y >= 0.20 and wall_stop.y < 0.5 and not player._position_hits_obstacle(wall_stop), "Held movement outside the door lane bypassed a visible world wall")
	_check_world_mapping(scene)


func _hold_input(key: int, pressed: bool, echo: bool = false) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = pressed
	event.echo = echo
	Input.parse_input_event(event)


func _new_isolated_main(label: String) -> Node:
	var saves := SaveManager.new()
	saves.load_manifest()
	var original := saves.active_profile_id
	saves.switch_profile("i4_" + label + "_" + str(Time.get_ticks_usec()))
	_check(saves.save_manifest().get("ok", false), "Isolated Main profile could not be selected")
	var main := (load("res://scenes/main/main.tscn") as PackedScene).instantiate()
	main.set_meta("i4_original_profile", original)
	root.add_child(main)
	await process_frame
	return main


func _dispose_isolated_main(main: Node) -> void:
	var scene := main.get_node("RunScene")
	scene.in_run_runtime.bind(null)
	scene.command_bus.bind_runtime_controller(null)
	var original := str(main.get_meta("i4_original_profile"))
	main.queue_free()
	await main.tree_exited
	var saves := SaveManager.new()
	saves.load_manifest()
	saves.switch_profile(original)
	_check(saves.save_manifest().get("ok", false), "Original test profile could not be restored")


func _check_main_tutorial_mapping() -> void:
	var main := await _new_isolated_main("tutorial_mapping")
	var scene := main.get_node("RunScene")
	var started: Dictionary = scene.command_bus.dispatch(&"start_standard_run", {"run_start_config": {"map_config_id": "tutorial_5x5", "difficulty": "tutorial", "seed_value": 3141}})
	_check(started.get("ok", false), "Actual Main tutorial admission failed: " + str(started))
	if not started.get("ok", false):
		await _dispose_isolated_main(main)
		return
	scene._show_run_screen()
	await _wait_until(func() -> bool: return scene.tutorial_popup_panel.visible, "actual tutorial shown")
	await process_frame
	await process_frame
	var player: PlayerController = scene.player_controller
	var transform: Transform2D = scene.get_node("RoomLayer").transform
	var logical := [player.room_rect, player.logical_obstacles.duplicate(true), player.get_door_projections().duplicate(true), player.get_local_position()]
	_check_world_mapping(scene)
	var details := scene.tutorial_popup_panel.get_node("Panel/Content/ConfirmButton") as Button
	var learn := scene.tutorial_popup_panel.get_node("Panel/Content/LearnFlagButton") as Button
	var meta = scene.meta_progress_adapter
	var before_learning: Dictionary = meta.data.duplicate(true)
	var meta_hash := FileAccess.get_sha256(meta.active_meta_progress_path)
	_check(before_learning.get("talent_points") == 100 and before_learning.get("talent_spent") == 0 and before_learning.get("talent_earned") == 100 and before_learning.get("talent_flags", []).is_empty(), "Actual Main tutorial must begin with its untouched100-point learning budget")
	_check(not details.text.contains("100点") and learn.text.contains("100点"), "Main tutorial separates read-only details from the actual100-point Learn action")
	await _click_tutorial_button(details, "native Main guidance expand")
	await _wait_until(func() -> bool: return scene.tutorial_popup_panel.layout_snapshot().get("guidance_expanded", false), "native Main guidance expanded")
	await _click_tutorial_button(details, "native Main guidance close")
	await _wait_until(func() -> bool: return scene.run_context.tutorial_popup.is_empty() and not scene.tutorial_popup_panel.layout_snapshot().get("guidance_expanded", true), "native Main guidance dismissed without learning")
	_check(meta.data.get("talent_points") == before_learning.talent_points and meta.data.get("talent_spent") == before_learning.talent_spent and meta.data.get("talent_earned") == before_learning.talent_earned and meta.data.get("talent_flags") == before_learning.talent_flags and FileAccess.get_sha256(meta.active_meta_progress_path) == meta_hash, "Reading/closing pure Main guidance purchased or rewrote teaching entitlement")
	_check(not scene.run_context.profile_fields.get("flag_unlocked", false), "Closing pure Main guidance granted flag capability")
	_check(scene.get_node("RoomLayer").transform.is_equal_approx(transform), "Tutorial dismissal changed the room mapping")
	_check([player.room_rect, player.logical_obstacles, player.get_door_projections(), player.get_local_position()] == logical, "Tutorial dismissal changed logical position, walls or door bodies")
	_check_world_mapping(scene)
	await _click_tutorial_button(learn, "native Main explicit Learn purchase")
	await _wait_until(func() -> bool: return scene.run_context.profile_fields.get("flag_unlocked", false) and meta.data.get("talent_points") == 0 and meta.data.get("talent_spent") == 100, "native Main independent Learn pays exactly100 and grants flag capability")
	var disk: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta.active_meta_progress_path))
	_check(disk is Dictionary, "Actual Main learning Meta bytes no longer decode")
	if disk is Dictionary:
		for source: Dictionary in [meta.data, disk]:
			_check(source.get("talent_points") == 0 and source.get("talent_spent") == 100 and source.get("talent_earned") == 100 and source.get("talent_flags", []).count("z2_talent_01") == 1 and source.get("profile_level") == 0 and not source.get("tutorial_completed", false), "Explicit Main Learn must durably cost100 exactly once without completing teaching")
	_check(scene.get_node("RoomLayer").transform.is_equal_approx(transform), "Explicit learning changed the room mapping")
	_check([player.room_rect, player.logical_obstacles, player.get_door_projections(), player.get_local_position()] == logical, "Explicit learning changed logical position, walls or door bodies")
	_check_world_mapping(scene)
	await _dispose_isolated_main(main)


func _click_tutorial_button(button: Button, label: String) -> void:
	_check(button != null, label + " exists")
	if button == null:
		return
	var ref: WeakRef = weakref(button)
	if not await _wait_until(func() -> bool: return _tutorial_button_hit_testable(ref), label + " is natively hit-testable"):
		return
	var observed := {"pressed": false}
	var on_pressed := func() -> void: observed.pressed = true
	button.pressed.connect(on_pressed, CONNECT_ONE_SHOT)
	_pointer(button.get_global_transform_with_canvas() * (button.size * 0.5), MOUSE_BUTTON_LEFT)
	if is_instance_valid(button) and button.pressed.is_connected(on_pressed):
		button.pressed.disconnect(on_pressed)
	_check(observed.pressed, label + " did not receive actual native Button.pressed")


func _tutorial_button_hit_testable(ref: WeakRef) -> bool:
	var button := ref.get_ref() as Button
	if button == null or not button.is_visible_in_tree() or button.disabled or button.size.x <= 1.0 or button.size.y <= 1.0:
		return false
	var motion := InputEventMouseMotion.new()
	motion.position = button.get_global_transform_with_canvas() * (button.size * 0.5)
	motion.global_position = motion.position
	root.push_input(motion, true)
	var hovered := root.gui_get_hovered_control()
	while hovered != null:
		if hovered == button:
			return true
		if hovered.mouse_filter == Control.MOUSE_FILTER_STOP:
			return false
		hovered = hovered.get_parent_control()
	return false


func _check_main_inventory_details() -> void:
	var main := await _new_isolated_main("bag_details")
	var scene := main.get_node("RunScene")
	var started := LegacyMainFixture.start(scene, 71)
	_check(started.get("ok", false), "Legally qualified Main departure failed: " + str(started))
	if not started.get("ok", false):
		await _dispose_isolated_main(main)
		return
	scene._show_run_screen()
	# Freeze only the scene's clock for a read-only UI selection comparison.
	scene.set_process(false)
	var runtime: RunRuntimeController = scene.runtime_controller
	var added: Dictionary = runtime.execute_atomic_operation(&"i4_detail_fixture", {}, func() -> Dictionary:
		return runtime.context.asset_ledger.add_reward_items([Z2Items.definition("col_01"), Z2Items.definition("con_countdown_pill")], &"inventory", runtime.context.get_current_pos(), "i4_detail_fixture")
	)
	_check(added.get("ok", false), "Actual inventory detail fixture could not commit: " + str(added))
	scene._refresh_view_models()
	await process_frame
	await process_frame
	_pointer(scene.run_surface.action_buttons[&"inventory"].get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
	var panel = scene.inventory_panel
	if not await _wait_until(func() -> bool: return panel.visible, "native HUD inventory entry"):
		await _dispose_isolated_main(main)
		return
	await _settle_hud(scene.run_surface)
	var target: Dictionary = {}
	for item: Dictionary in runtime.context.asset_ledger.get_inventory_and_equipped_items():
		if str(item.item_id) == "con_countdown_pill": target = item
	_check(not target.is_empty(), "Real countdown item was not in inventory")
	var selected: Button = null
	for button: Button in panel.find_children("*", "Button", true, false):
		if not button.is_queued_for_deletion() and button.name == "InventoryItemButton" and str(button.get_meta("item_instance_id", "")) == str(target.get("instance_id", "")) and not str(target.get("instance_id", "")).is_empty():
			selected = button
			break
	_check(selected != null, "Actual inventory entry did not expose the reward instance")
	if selected != null:
		var before := runtime.capture_authoritative_state()
		_pointer(selected.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
		var expected := str(RunUIViewModelScript.item_presentation(target).detail_text)
		await _wait_until(func() -> bool: return panel.tooltip_label.text == expected, "native selection shows full shared item descriptor")
		var label := panel.tooltip_label as Label
		var scroll := panel.detail_scroll as ScrollContainer
		_check(scroll.is_ancestor_of(label) and label.is_visible_in_tree() and label.text == expected and label.get_theme_font_size("font_size") >= UISkin.scaled_font_size(15, panel._ui_scale_factor), "Actual inventory detail loses source copy or readable font")
		var bar := scroll.get_v_scroll_bar()
		var deadline := Time.get_ticks_msec() + 3000
		while bar.value < bar.max_value - bar.page - 1.0 and Time.get_ticks_msec() < deadline:
			_pointer(scroll.get_global_rect().get_center(), MOUSE_BUTTON_WHEEL_DOWN)
			await process_frame
		var tail := label.get_global_rect()
		tail.position.y = tail.end.y - label.get_line_height()
		tail.size.y = label.get_line_height()
		_check(scroll.get_global_rect().grow(1.0).encloses(tail), "Actual inventory detail last line is unreachable")
		_check(runtime.capture_authoritative_state() == before and not scene.player_controller.input_enabled, "Read-only inventory selection changes authority or leaks gameplay input")
	_pointer(panel.close_button.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
	await _wait_until(func() -> bool: return not panel.visible, "native inventory close")
	await _dispose_isolated_main(main)


func _tap_map_key(key: int, shift: bool = false) -> void:
	var input := InputEventKey.new()
	input.keycode = key
	input.physical_keycode = key
	input.shift_pressed = shift
	input.pressed = true
	Input.parse_input_event(input)
	await process_frame
	input.pressed = false
	Input.parse_input_event(input)
	await process_frame


func _map_flag_positions(overlay: Control) -> Array[String]:
	var result: Array[String] = []
	for marker in overlay.get("view_model").room_markers:
		if bool(marker.get("flagged", false)):
			result.append(str(marker.pos))
	result.sort()
	return result


func _check_rarity_palette_and_item_resolver() -> void:
	for rarity_key in EXPECTED_RARITY_COLORS:
		var actual := Color(ItemRarityDescriptorScript.describe(rarity_key).get("color", Color.TRANSPARENT))
		var expected := Color(EXPECTED_RARITY_COLORS[rarity_key])
		_check(_color_within_channel_tolerance(actual, expected), "Rarity palette drifted for %s" % String(rarity_key))
	for raw_item in ItemCatalogScript.all_items():
		var item := (raw_item as Dictionary).duplicate(true)
		var world_resolution := ItemVisualCatalogScript.resolve(item, &"world_ground_drop")
		var backpack_resolution := ItemVisualCatalogScript.resolve(item, &"run_backpack")
		for field in [
			"requested_key",
			"requested_path",
			"resolved_key",
			"resolved_path",
			"resolved_size",
			"explicit_mapping",
			"fallback_used",
			"reason",
			"consumer",
		]:
			_check(world_resolution.has(field), "Item resolver omitted %s for %s" % [field, item.get("item_id", "")])
		_check(bool(world_resolution.get("resolved", false)), "Formal item texture did not resolve for %s" % item.get("item_id", ""))
		_check(
			world_resolution.get("resolved_key") == backpack_resolution.get("resolved_key")
			and world_resolution.get("resolved_path") == backpack_resolution.get("resolved_path"),
			"Item consumers resolved different art for %s" % item.get("item_id", "")
		)
	var explicit_world := ItemVisualCatalogScript.resolve({
		"item_id": "anomaly_shard",
		"item_type": "special",
	}, &"probe")
	_check(bool(explicit_world.get("explicit_mapping", false)), "ART24 anomaly_shard is not treated as an explicit mapping")
	_check(
		String(explicit_world.get("resolved_key", "")).ends_with(".anomaly_shard"),
		"ART24 anomaly_shard fell back to a generic type texture"
	)
	var unknown := ItemVisualCatalogScript.resolve({
		"item_id": "i4_unknown_fixture",
		"item_type": "consumable",
	}, &"probe")
	_check(
		bool(unknown.get("fallback_used", false))
		and String(unknown.get("resolved_key", "")).ends_with(".emergency_bandage")
		and bool(unknown.get("resolved", false)),
		"Unknown consumable did not receive the visible typed fallback"
	)


func _check_map_cell_layer_contract() -> void:
	for cell_size in [Vector2(36, 36), Vector2(42, 42), Vector2(56, 48)]:
		var layout := MapCellLayerLayoutScript.calculate(cell_size, true)
		var cell_rect := Rect2(layout.get("cell_rect", Rect2()))
		var semantic_rect := Rect2(layout.get("semantic_rect", Rect2()))
		var count_rect := Rect2(layout.get("count_rect", Rect2()))
		var focus_rect := Rect2(layout.get("focus_rect", Rect2()))
		_check(
			int(layout.get("base_z", -1)) == 0
			and int(layout.get("semantic_z", -1)) == 20
			and int(layout.get("count_z", -1)) == 30
			and int(layout.get("focus_z", -1)) == 40,
			"Map-cell z order drifted at %s" % cell_size
		)
		_check(
			cell_rect.encloses(semantic_rect)
			and cell_rect.encloses(count_rect)
			and cell_rect.encloses(focus_rect),
			"Map-cell child allocation spills beyond %s" % cell_size
		)
		var overlap := semantic_rect.intersection(count_rect)
		_check(overlap.size.x * overlap.size.y == 0.0, "Map semantic/count allocations overlap at %s" % cell_size)
		_check(
			count_rect.size.x >= 12.0
			and count_rect.size.x <= 18.0
			and is_equal_approx(count_rect.size.x, count_rect.size.y),
			"Map count badge is outside the 12..18 px square rule at %s" % cell_size
		)


func _check_texture_fallback_and_world_drop() -> void:
	var interactable = InteractableScript.new()
	root.add_child(interactable)
	interactable.configure_interactable({
		"projection_id": "i4-null-texture",
		"interaction_kind": &"fixture",
		"body_rect": Rect2(0.45, 0.45, 0.10, 0.10),
		"visual_rect_local": Rect2(0.45, 0.45, 0.10, 0.10),
	})
	var null_sprite := Sprite2D.new()
	null_sprite.name = "ArtVisual"
	interactable.get_node("VisualRoot").add_child(null_sprite)
	interactable.call("_apply_visual_state")
	var placeholder := interactable.get_node("VisualRoot/ProgramPlaceholder") as Polygon2D
	_check(placeholder.visible, "A present ArtVisual node with texture=null hid the program fallback")
	_check(interactable.has_visible_collision_correspondence(), "Null-texture interactable has no visible collision fallback")
	interactable.queue_free()

	var item := {
		"instance_id": "i4-ground-drop",
		"item_id": "anomaly_shard",
		"item_type": "special",
		"display_name": "异常核心碎片",
		"rarity": &"tier_4",
		"weight": 1,
	}
	var snapshot := _room_snapshot(&"Normal", Vector2i(1, 1))
	snapshot["room_floor_items"] = [item]
	var projection := (WorldObjectProjectionScript.build(snapshot).get("world_objects", []) as Array)[0] as Dictionary
	var entity = GroundLootEntityScript.new()
	root.add_child(entity)
	entity.configure_item(projection)
	await _wait_until(
		func() -> bool:
			var candidate_art := entity.get_node_or_null("VisualRoot/ArtVisual") as Sprite2D
			var candidate_beam := entity.get_node_or_null("VisualRoot/PickupBeam") as Sprite2D
			return (
				candidate_art != null
				and candidate_art.texture != null
				and candidate_art.visible
				and candidate_beam != null
				and candidate_beam.visible
			),
		"ground-drop body and rarity beam"
	)
	var art := entity.get_node("VisualRoot/ArtVisual") as Sprite2D
	var beam := entity.get_node("VisualRoot/PickupBeam") as Sprite2D
	var rarity_color := Color(ItemRarityDescriptorScript.describe_item(item).get("color", Color.TRANSPARENT))
	_check(art.texture != null and art.visible, "Ground drop rendered without an item body texture")
	_check(
		_is_same_rgb(beam.modulate, rarity_color),
		"Ground-drop beam does not use the shared item rarity color"
	)
	entity.set_pickup_result(false)
	var blocked_marker := entity.get_node("VisualRoot/BlockedMarker") as Label
	_check(blocked_marker.visible and _is_same_rgb(beam.modulate, rarity_color), "Blocked feedback overwrote the ground-drop rarity channel")
	entity.queue_free()
	await entity.tree_exited


func _check_collision_visible_correspondence() -> void:
	var view = RoomRuntimeViewScript.new()
	root.add_child(view)
	for room_case in [
		{"type": &"Normal", "position": Vector2i(0, 0), "expected": 12},
		{"type": &"Monster", "position": Vector2i(1, 0), "expected": 9},
		{"type": &"Event", "position": Vector2i(2, 0), "expected": 9},
		{"type": &"Chest", "position": Vector2i(3, 0), "expected": 13},
	]:
		var snapshot := _room_snapshot(room_case["type"], room_case["position"])
		if room_case["type"] == &"Event":
			snapshot["event_state"] = {"event_type": &"altar", "completed": false}
		if room_case["type"] == &"Chest":
			snapshot["search_state_data"] = {"searched": false}
		var room_position := Vector2i(room_case["position"])
		var expected_room_key := "%d,%d" % [room_position.x, room_position.y]
		view.configure_room(snapshot)
		await _wait_until(
			func() -> bool:
				return (
					String(view.get("room_key")) == expected_room_key
					and view.get_obstacle_descriptors().size() == int(room_case["expected"])
				),
			"%s room obstacle projection commit" % String(room_case["type"])
		)
		var descriptors := view.get_obstacle_descriptors()
		_check(
			descriptors.size() == int(room_case["expected"]),
			"%s room projected %d collision descriptors; expected %d" % [
				String(room_case["type"]),
				descriptors.size(),
				int(room_case["expected"]),
			]
		)
		_check(
			view.get_logical_obstacles().size() == int(room_case["expected"]),
			"%s room retained an anonymous or disabled collision" % String(room_case["type"])
		)
		for descriptor in descriptors:
			for field in [
				"obstacle_id",
				"source_projection_id",
				"source_kind",
				"room_type",
				"body_rect",
				"visual_key",
				"resolved_texture_path",
				"resolved_texture_size",
				"visual_footprint",
				"visual_node_path",
				"visible_alpha",
				"body_center_inside_visual",
				"visual_body_coverage_ratio",
				"collision_enabled",
				"disable_reason",
			]:
				_check(descriptor.has(field), "%s collision descriptor omitted %s" % [room_case["type"], field])
			_check(bool(descriptor.get("collision_enabled", false)), "%s collision lacks visible correspondence" % room_case["type"])
			_check(float(descriptor.get("visible_alpha", 0.0)) >= 0.25, "%s collision visual alpha is below 0.25" % room_case["type"])
			_check(bool(descriptor.get("body_center_inside_visual", false)), "%s collision center is outside its visual" % room_case["type"])
			_check(float(descriptor.get("visual_body_coverage_ratio", 0.0)) >= 0.90, "%s collision coverage is below 0.90" % room_case["type"])
	view.queue_free()
	await view.tree_exited


func _check_protocol_and_left_density() -> void:
	var canvas := Control.new()
	canvas.size = Vector2(1280, 720)
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(canvas)
	var world_pointer := WorldPointerProbe.new()
	canvas.add_child(world_pointer)
	var surface = RunSurfaceScript.new()
	canvas.add_child(surface)
	surface.build()
	var profile := UILayoutProfileScript.profile_for_resolution(&"1280x720")
	surface.apply_layout_profile(profile)
	for count in [0, 1, 4]:
		var items := _sample_items(count)
		surface.apply_surface_model(_surface_model(profile, items, 5, 100))
		await _wait_until(
			func() -> bool:
				var layout := surface.scanner_text_mask.get_meta("content_layout_rects", {}) as Dictionary
				return (
					int(surface.scanner_text_mask.get_meta("content_item_count", -1)) == count
					and layout.has("panel")
					and layout.has("header")
					and layout.has("list")
					and layout.has("capacity")
					and _bag_buttons(surface).size() == count
				),
			"backpack content-driven layout for %d items" % count
		)
		await _settle_hud(surface)
		_check_bag_layout(surface, items, 1.0)
		if count == 0:
			_check(not surface.backpack_scroll.visible, "Empty backpack retains a fixed empty scroll surface")
			var watermark := surface.backpack_empty_watermark as TextureRect
			_check(watermark.visible and watermark.size.x <= 80.0 and watermark.size.y <= 80.0 and surface.backpack_scroll.get_global_rect().encloses(watermark.get_global_rect()), "Empty backpack watermark exceeds its actual available list area")
			_check(_bag_buttons(surface).is_empty(), "Empty backpack renders fake item slots")
			var before := world_pointer.clicks
			_pointer(surface.backpack_scroll.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
			_check(world_pointer.clicks == before + 1, "Hidden empty backpack scroll intercepts world input")
		elif count == 1:
			var bar := surface.backpack_scroll.get_v_scroll_bar() as VScrollBar
			_check(surface.backpack_scroll.visible and surface.backpack_scroll.get_global_rect().grow(1.0).encloses(_bag_buttons(surface)[0].get_global_rect()), "Single complete item is outside the actual bag viewport")
			_check(bar.max_value - bar.page <= 1.0 and not bar.is_visible_in_tree(), "One-item backpack exposes actual unnecessary scrolling")
		else:
			await _check_bag_scroll(surface, false)
			var columns := {}
			for button in _bag_buttons(surface):
				var x := roundi(button.get_global_rect().position.x)
				columns[x] = int(columns.get(x, 0)) + 1
			_check(columns.size() == 2 and columns.values() == [2, 2], "Balanced four-item fixture must occupy both columns with two real items each")
	# Unequal columns, unknown legacy types and capability-only changes must not
	# lose identities or be hidden by the quick-bag signature cache.
	var unknown := _sample_items(1)[0]
	unknown.item_type = "unknown_legacy"
	unknown.instance_ids = ["legacy-a", "legacy-b"]
	unknown.stack_key = "legacy-stack"
	unknown.quantity = 2
	var special := _sample_items(1)[0]
	special.instance_id = "special-tool"
	special.item_type = "special"
	special.can_consume = true
	var uneven := _sample_items(4)
	uneven[1].item_type = "collectible"
	uneven[1].can_consume = false
	var only_tool: Array[Dictionary] = [_sample_items(2)[1]]
	var edge_items: Array[Dictionary] = [unknown, special]
	for items: Array[Dictionary] in [only_tool, uneven, edge_items]:
		surface.apply_surface_model(_surface_model(profile, items, 5, 100))
		await _settle_hud(surface)
		_check_bag_layout(surface, items, 1.0)
		await _check_bag_scroll(surface, false)
	for can_consume in [false, true, false]:
		unknown.can_consume = can_consume
		var toggle_items: Array[Dictionary] = [unknown]
		surface.apply_surface_model(_surface_model(profile, toggle_items, 5, 100))
		await _settle_hud(surface)
		_check_bag_layout(surface, toggle_items, 1.0)
	# Capacity comes from snapshot counters, independently of visible stack rows.
	var capacity_model := _surface_model(profile, _sample_items(4), 5, 100)
	capacity_model.equipment_used = 2
	capacity_model.equipment_capacity = 11
	capacity_model.backpack_used = 9
	capacity_model.backpack_capacity = 17
	surface.apply_surface_model(capacity_model)
	await _settle_hud(surface)
	_check(surface.backpack_capacity_label.text == "共享 2/11\n战利品 9/17", "Bag recalculated authoritative capacity counters from visible category or stack counts")
	_check_readable_label(surface.backpack_capacity_label, 13, 1.0, "Independent snapshot capacity")
	var safe_rect := Rect2(surface.status_card_art.get_meta("protocol_safe_rect", Rect2()))
	for control in [surface.right_title_label, surface.right_body_label, surface.player_health_hud, surface.protocol_pressure_track]:
		var control_rect := (control as Control).get_global_rect()
		_check(
			_rect_encloses_with_tolerance(safe_rect, control_rect),
			"Protocol content escaped the measured safe rectangle: %s safe=%s actual=%s"
			% [(control as Control).name, safe_rect, control_rect]
		)
	var title_body_gap: float = surface.right_body_label.get_global_rect().position.x - surface.right_title_label.get_global_rect().end.x
	var body_track_gap := _vertical_gap(surface.right_body_label.get_global_rect(), surface.protocol_pressure_track.get_global_rect())
	_check(title_body_gap >= 0.0, "Protocol title overlaps pressure (measured %.2f)" % title_body_gap)
	_check(
		body_track_gap >= 5.5,
		"Protocol body/track gap is below 6 px (measured %.2f, body=%s, track=%s)"
		% [
			body_track_gap,
			surface.right_body_label.get_global_rect(),
			surface.protocol_pressure_track.get_global_rect(),
		]
	)
	_check_readable_label(surface.right_body_label, 13, 1.0, "Protocol body")
	var health_value := surface.player_health_hud.get_node("HealthValue") as Label
	var power_value := surface.player_health_hud.get_node("PowerValue") as Label
	_check(surface.right_body_label.text == "压力 100%" and health_value.text == "10 / 10" and power_value.text == "强度 3", "Protocol projection lost complete pressure/HP/power facts")
	_check(_vertical_gap(surface.player_health_hud.get_global_rect(), surface.right_body_label.get_global_rect()) >= 3.5, "Health widget overlaps the pressure text")
	canvas.queue_free()
	await canvas.tree_exited


func _settle_hud(surface: RunSurface) -> void:
	var previous := ""
	var stable := 0
	var deadline := Time.get_ticks_msec() + 3000
	while stable < 3 and Time.get_ticks_msec() < deadline:
		await process_frame
		var rows: Array[String] = []
		for control: Control in surface.find_children("*", "Control", true, false):
			if control.is_queued_for_deletion(): continue
			rows.append(str(control.get_path()) + str(control.get_global_rect()) + str(control.get_minimum_size()) + str(control.visible))
		var signature := "\n".join(rows)
		stable = stable + 1 if signature == previous else 0
		previous = signature
	_check(stable >= 3, "HUD layout did not reach three identical measured frames")


func _check_reference_geometry(surface: RunSurface, profile: Dictionary, viewport: Rect2) -> void:
	var projected := RunSurfaceModelScript.layout_geometry(profile)
	var protocol := surface.status_card_art.get_global_rect()
	var rail := surface.left_rail_art.get_global_rect()
	var map_rect := surface.minimap_panel.get_global_rect()
	var room: Rect2 = projected.room_stage_rect
	_check(protocol.get_center().x < viewport.get_center().x and map_rect.get_center().x > viewport.get_center().x, "Actual protocol/map controls are on the wrong sides")
	_check(viewport.encloses(protocol) and viewport.encloses(rail) and viewport.encloses(room), "Adaptive side rails or central room exceed the logical viewport")
	_check(protocol.end.x < room.position.x and room.end.x < rail.position.x, "HUD side rails overlap the central room allocation")
	_check(protocol.is_equal_approx(projected.protocol_rect) and rail.is_equal_approx(projected.scanner_rail_rect), "Actual HUD controls disagree with their public layout projection")
	_check(rail.grow(-18.0).grow(0.5).encloses(map_rect), "Complete minimap escapes the right rail's texture-safe content area")
	_check(surface.resource_backdrop.get_global_rect().position.y - map_rect.end.y >= 7.5, "Actual-size map leaves less than 8px before the currency band")


func _check_readable_label(label: Label, base_size: int, factor: float, subject: String) -> void:
	_check(label.get_theme_font_size("font_size") >= UISkin.scaled_font_size(base_size, factor), subject + " shrinks below its scaled theme font")
	_check(not label.clip_text and label.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING, subject + " clips or elides text")
	_check(label.max_lines_visible < 0 or label.max_lines_visible >= label.get_line_count(), subject + " hides shaped text lines")
	_check(label.get_minimum_size().x <= label.size.x + 0.5, subject + " does not contain its complete native-shaped width")
	_check(label.get_minimum_size().y <= label.size.y + 0.5 and label.get_line_count() * label.get_line_height() <= label.size.y + 0.5, subject + " does not contain its complete native-shaped height")


func _bag_buttons(surface: RunSurface) -> Array[Button]:
	var result: Array[Button] = []
	for child in surface.backpack_strip.find_children("*", "Button", true, false):
		if child.has_meta("item_instance_id") and not child.is_queued_for_deletion():
			result.append(child as Button)
	return result


func _check_bag_layout(surface: RunSurface, items: Array[Dictionary], factor: float) -> void:
	var inner := surface.left_rail_art.get_global_rect().grow(-18.0)
	var header := surface.scanner_detail_label.get_global_rect()
	var capacity := surface.backpack_capacity_label.get_global_rect()
	var supplies := surface.backpack_supplies_header.get_global_rect()
	var tools := surface.backpack_tools_header.get_global_rect()
	var list := surface.backpack_scroll.get_global_rect()
	var geometry: Dictionary = surface.scanner_text_mask.get_meta("content_layout_rects", {})
	_check_readable_label(surface.scanner_detail_label, 13, factor, "Backpack header")
	_check_readable_label(surface.backpack_capacity_label, 13, factor, "Backpack capacity")
	_check(surface.backpack_capacity_label.text == "共享 7/100\n战利品 %d/12" % items.size() and surface.backpack_capacity_label.max_lines_visible == -1, "Full shared/loot capacity values and units must remain visible")
	_check(inner.grow(0.5).encloses(header) and inner.grow(0.5).encloses(capacity) and inner.grow(0.5).encloses(list), "Backpack header/capacity/list escapes right-rail safe content")
	_check(absf(_vertical_gap(header, capacity) - 6.0) <= 0.5 and absf(_vertical_gap(capacity, supplies) - 6.0) <= 0.5 and absf(_vertical_gap(supplies, list) - 4.0) <= 0.5, "Actual bag order must be header, capacity, categories, list with 6/6/4px spacing")
	_check(surface.backpack_supplies_header.text == "物资" and surface.backpack_tools_header.text == "道具", "Fixed bag category names changed")
	for label: Label in [surface.backpack_supplies_header, surface.backpack_tools_header]:
		_check_readable_label(label, 13, factor, "Bag category")
		_check(inner.grow(0.5).encloses(label.get_global_rect()), "Bag category escaped the frame safe area")
	_check(is_equal_approx(supplies.position.y, tools.position.y) and absf(tools.position.x - supplies.end.x - 4.0) <= 0.5, "Category headers lost their common baseline or 4px gap")
	_check(absf(list.end.y - inner.end.y) <= 0.5, "Bag list does not end at the frame's 18px safe inset")
	_check(not surface.backpack_detail_label.visible and not Rect2(geometry.get("detail", Rect2())).has_area(), "On-demand details retained a permanent blank layout allocation")
	_check(Rect2(geometry.get("header", Rect2())).is_equal_approx(surface.scanner_detail_label.get_rect()) and Rect2(geometry.get("capacity", Rect2())).is_equal_approx(surface.backpack_capacity_label.get_rect()) and Rect2(geometry.get("list", Rect2())).is_equal_approx(surface.backpack_scroll.get_rect()), "Bag content geometry disagrees with actual controls")
	_check(surface.backpack_strip.columns == 2 and surface.backpack_strip.get_theme_constant("h_separation") == 4 and surface.backpack_strip.get_theme_constant("v_separation") == 4, "Two bag columns lost the 4px spacing contract")
	var buttons := _bag_buttons(surface)
	_check(buttons.size() == items.size(), "Bag hides real items or inserts fake slots")
	var by_id := {}
	var expected_columns: Array = [[], []]
	for item in items:
		by_id[str(item.instance_id)] = item
		expected_columns[1 if bool(item.get("can_consume", false)) or str(item.get("item_type", "")) == "consumable" else 0].append(str(item.instance_id))
	var actual_columns: Array = [[], []]
	var seen := {}
	for button in buttons:
		var id := str(button.get_meta("item_instance_id", ""))
		if not by_id.has(id):
			_check(false, "Bag button has no corresponding projected item: " + id)
			continue
		var descriptor := RunUIViewModelScript.item_presentation(by_id[id])
		_check(not seen.has(id), "Bag renders a projected instance more than once: " + id)
		seen[id] = true
		_check(button.get_meta("item_instance_ids", []) == by_id[id].get("instance_ids", []) and str(button.get_meta("item_stack_key", "")) == str(by_id[id].get("stack_key", "")), "Bag lost stack member identities or stack key")
		var column := 1 if bool(by_id[id].get("can_consume", false)) or str(by_id[id].get("item_type", "")) == "consumable" else 0
		var category: Rect2 = tools if column == 1 else supplies
		# GridContainer distributes whole pixels; the header keeps its fractional
		# Rect2 width (114.8 at 100%). Check its exact floor/ceil pixel allocation,
		# including a non-expanding empty left column, rather than a false 0.5px gate.
		var grid_x := surface.backpack_strip.get_global_rect().position.x
		var expected_x := category.position.x - grid_x
		var actual_x := button.get_global_rect().position.x - grid_x
		var aligned := (is_equal_approx(actual_x, expected_x) or is_equal_approx(actual_x, floorf(expected_x)) or is_equal_approx(actual_x, ceilf(expected_x))) and (is_equal_approx(button.size.x, category.size.x) or is_equal_approx(button.size.x, floorf(category.size.x)) or is_equal_approx(button.size.x, ceilf(category.size.x)))
		_check(aligned, "Real item is not aligned with its category's native pixel allocation: %s column=%d count=%d actual=%s category=%s" % [id, column, items.size(), button.get_global_rect(), category])
		actual_columns[column].append(id)
		_check(button.text == "%s ×%d" % [descriptor.display_name, descriptor.quantity], "Bag lost a full item name or quantity")
		_check(button.tooltip_text == str(descriptor.detail_text), "Bag tooltip lost shared name/rarity/weight/quantity/effect detail")
		_check(button.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART and button.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING, "Bag item does not preserve wrapped full text")
		_check(button.get_theme_font_size("font_size") >= UISkin.scaled_font_size(13, factor), "Bag item font was reduced to fit")
		var style := button.get_theme_stylebox("normal")
		var icon_width := minf(button.icon.get_width(), button.get_theme_constant("icon_max_width")) if button.icon != null else 0.0
		var text_width := button.size.x - style.get_minimum_size().x - icon_width - (button.get_theme_constant("h_separation") if icon_width > 0.0 else 0)
		var shaped := button.get_theme_font("font").get_multiline_string_size(button.text, HORIZONTAL_ALIGNMENT_LEFT, text_width, button.get_theme_font_size("font_size"), -1, TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE)
		_check(text_width > 0.0 and shaped.x <= text_width + 0.5 and shaped.y <= button.size.y - style.get_minimum_size().y + 0.5 and button.get_minimum_size().y <= button.size.y + 0.5, "Native-shaped complete item name/quantity exceeds its actual text allocation")
		for other in buttons:
			if other != button:
				_check(not button.get_global_rect().intersects(other.get_global_rect()), "Bag items overlap")
	_check(actual_columns == expected_columns, "Bag classification changed stable order or omitted an identity")
	if not items.is_empty():
		var slots := surface.backpack_strip.get_children().filter(func(child: Node) -> bool: return not child.is_queued_for_deletion())
		_check(slots.size() == maxi(expected_columns[0].size(), expected_columns[1].size()) * 2, "Bag rows must equal the larger category count")
		for child: Control in slots:
			if child is Button: continue
			_check(child.get_class() == "Control" and child.get_child_count() == 0 and child.focus_mode == Control.FOCUS_NONE and child.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Short category contains a fake or interactive item placeholder")


func _check_bag_scroll(surface: RunSurface, require_overflow: bool) -> void:
	var scroll := surface.backpack_scroll
	var bar := scroll.get_v_scroll_bar()
	var buttons := _bag_buttons(surface)
	var overflow := bar.max_value - bar.page > 1.0
	_check(not require_overflow or overflow, "Sixteen actual long-name items did not exercise the overflow branch")
	if not overflow:
		_check(not bar.is_visible_in_tree(), "A fitting bag shows an unnecessary scrollbar")
		for button in buttons:
			_check(scroll.get_global_rect().grow(1.0).encloses(button.get_global_rect()), "A fitting bag hides part of an actual item")
		return
	_check(scroll.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_AUTO, "Overflow bag is not scrollable")
	var seen := {}
	var header_rects := [surface.backpack_supplies_header.get_global_rect(), surface.backpack_tools_header.get_global_rect()]
	var start := bar.value
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		for button in buttons:
			if scroll.get_global_rect().grow(1.0).encloses(button.get_global_rect()):
				seen[button.get_instance_id()] = true
		if bar.value >= bar.max_value - bar.page - 1.0: break
		_pointer(scroll.get_global_rect().get_center(), MOUSE_BUTTON_WHEEL_DOWN)
		await process_frame
	_check(bar.value > start and bar.value >= bar.max_value - bar.page - 1.0, "Native wheel never reached the real bag end")
	_check(seen.size() == buttons.size(), "Native wheel cannot expose every complete item, including the final row")
	_check(header_rects == [surface.backpack_supplies_header.get_global_rect(), surface.backpack_tools_header.get_global_rect()] and surface.backpack_supplies_header.is_visible_in_tree() and surface.backpack_tools_header.is_visible_in_tree(), "Bag wheel scroll moved or hid its category headers")
	scroll.scroll_vertical = 0
	await process_frame


func _pointer(position: Vector2, button_index: MouseButton) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	root.push_input(motion, true)
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = button_index
	event.pressed = true
	root.push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event, true)


func _long_catalog_items() -> Array[Dictionary]:
	var pool := Z2Items.all_items()
	pool.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.display_name).length() > str(b.display_name).length())
	var result: Array[Dictionary] = []
	var counts := [0, 0]
	for source: Dictionary in pool:
		var column := 1 if bool(source.get("can_consume", false)) or str(source.get("item_type", "")) == "consumable" else 0
		if counts[column] >= 8: continue
		var item := source.duplicate(true)
		item.instance_id = "i4-long-" + str(result.size())
		item.quantity = 3
		item.instance_ids = [item.instance_id + "-a", item.instance_id + "-b", item.instance_id + "-c"]
		item.stack_key = "stack-" + str(item.item_id)
		result.append(item)
		counts[column] += 1
	_check(result.size() == 16, "Real catalog must supply all sixteen long-name stacks")
	return result


func _check_room_description(surface: RunSurface, profile: Dictionary, factor: float) -> void:
	var model := _surface_model(profile, [], 5, 100)
	model.room_summary = "房间说明：回收物资前请确认周围雷险。\n".repeat(10).strip_edges()
	model.current_objective = "作业目标：完成委托并抵达撤离信标。"
	model.commission_text = "委托末行：带回完整任务物资后结算。"
	surface.apply_surface_model(model)
	await _settle_hud(surface)
	var scroll := surface.room_description_scroll
	var label := surface.room_body_label
	var text := "%s\n\n%s\n\n%s" % [model.room_summary, model.current_objective, model.commission_text]
	_check(label.text == text and scroll.is_ancestor_of(label), "Short left panel lost full room/objective/commission text")
	_check(label.get_theme_font_size("font_size") >= UISkin.scaled_font_size(13, factor) and label.max_lines_visible == -1 and not label.clip_text and label.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING, "Short left panel shrinks or trims its source text")
	var geometry := RunSurfaceModelScript.layout_geometry(profile)
	var description: Rect2 = geometry.description_rect
	_check(surface.room_text_mask.get_global_rect().is_equal_approx(description) and scroll.get_global_rect().is_equal_approx(description.grow(-18.0)), "Actual short description or its 18px safe text inset differs from the public layout")
	var viewport_height := root.get_visible_rect().size.y
	_check(description.size.y <= viewport_height * 5.0 / 12.0 + 64.0 * ((factor - 1.0) / 0.5) + 0.5 and viewport_height - description.end.y >= 87.5, "Short left panel consumed the reserved lower space")
	var bar := scroll.get_v_scroll_bar()
	_check(bar.max_value - bar.page > 1.0, "Room description fixture failed to exercise real overflow")
	var deadline := Time.get_ticks_msec() + 3000
	while bar.value < bar.max_value - bar.page - 1.0 and Time.get_ticks_msec() < deadline:
		_pointer(scroll.get_global_rect().get_center(), MOUSE_BUTTON_WHEEL_DOWN)
		await process_frame
	var tail := label.get_global_rect()
	tail.position.y = tail.end.y - label.get_line_height()
	tail.size.y = label.get_line_height()
	_check(bar.value >= bar.max_value - bar.page - 1.0 and scroll.get_global_rect().grow(1.0).encloses(tail), "Native wheel cannot reach the complete room/objective last line")


func _room_snapshot(room_type: StringName, position: Vector2i) -> Dictionary:
	return {
		"position": position,
		"player_pos": position,
		"width": 5,
		"height": 5,
		"current_room": room_type,
		"room_floor_items": [],
		"run_map_snapshot": {
			"KnownMap": {
				"width": 5,
				"height": 5,
				"player_pos": position,
				"public_cells": [],
			},
		},
		"run_start_config": {"move_requires_revealed": false},
	}


func _surface_model(
	profile: Dictionary,
	items: Array[Dictionary],
	protocol_level: int,
	pressure: int
) -> Dictionary:
	return {
		"layout_profile": profile,
		"backpack_items": items,
		"backpack_used": items.size(),
		"backpack_capacity": 12,
		"equipment_used": 7,
		"equipment_capacity": 100,
		"hp": 10, "max_hp": 10, "power": 3,
		"resource_summary": "生命 10/10 | 作业强度 3 | 待结算黑币 0 | 安全金币 0",
		"mine_risk": {"count": 0},
		"protocol_level": protocol_level,
		"protocol_title": "正常作业",
		"pressure": pressure,
		"status_lines": [],
		"action_buttons": [],
		"encounter_section": {},
	}


func _sample_items(count: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var ids := ["col_01", "con_ration", "col_02", "con_hard_shell_patch"]
	for index in range(count):
		var item := Z2Items.definition(ids[index % ids.size()])
		item.instance_id = "i4-density-%d" % index
		item.quantity = 1
		result.append(item)
	return result


func _color_within_channel_tolerance(actual: Color, expected: Color) -> bool:
	var tolerance := 1.0 / 255.0 + 0.000001
	return (
		absf(actual.r - expected.r) <= tolerance
		and absf(actual.g - expected.g) <= tolerance
		and absf(actual.b - expected.b) <= tolerance
		and absf(actual.a - expected.a) <= tolerance
	)


func _is_same_rgb(first: Color, second: Color) -> bool:
	var tolerance := 1.0 / 255.0 + 0.000001
	return (
		absf(first.r - second.r) <= tolerance
		and absf(first.g - second.g) <= tolerance
		and absf(first.b - second.b) <= tolerance
	)


func _vertical_gap(upper: Rect2, lower: Rect2) -> float:
	return lower.position.y - upper.end.y


func _rect_encloses_with_tolerance(outer: Rect2, inner: Rect2) -> bool:
	return (
		inner.position.x >= outer.position.x - 0.5
		and inner.position.y >= outer.position.y - 0.5
		and inner.end.x <= outer.end.x + 0.5
		and inner.end.y <= outer.end.y + 0.5
	)


func _wait_until(predicate: Callable, label: String, timeout_ms: int = 5000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() <= deadline:
		if bool(predicate.call()):
			return true
		await process_frame
	failures.append("timed out waiting for semantic state: %s" % label)
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print(
			"I4_IN_RUN_VISUAL_PHYSICS=PASS"
			+ " palette=8 resolver=formal_same_path+typed_fallback"
			+ " map=base,semantic,count,focus"
			+ " collision=normal12,monster9,event9,chest13"
			+ " drops=body+rarity_beam+failure_marker"
			+ " hud=protocol_safe_rect+bag_0,1,4"
		)
		quit(0)
		return
	for failure in failures:
		push_error("I4 in-run visual/physics failure: " + failure)
	print("I4_IN_RUN_VISUAL_PHYSICS=FAIL failures=%d" % failures.size())
	quit(1)
