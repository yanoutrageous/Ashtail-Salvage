extends SceneTree

const Catalog = preload("res://scripts/presentation/B/B_event_room_catalog.gd")
const Events = preload("res://scripts/core/run/z2_event_runtime.gd")
const View = preload("res://scripts/gameplay/runtime/g41_room_runtime_view.gd")
const WorldProjection = preload("res://scripts/gameplay/runtime/g41_world_object_projection.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("B_EVENT_ROOM_FAIL ", label)

func _run() -> void:
	var view := View.new()
	root.add_child(view)
	for id: String in Events.event_ids():
		var entry := Catalog.room(StringName(id))
		check(not entry.is_empty(), id + " has GLB mapping")
		if entry.is_empty():
			continue
		var snapshot := {"position": Vector2i(2, 2), "width": 5, "height": 5, "current_room": &"Event", "event_state": {"event_type": id, "completed": false}, "KnownMap": {"public_cells": []}}
		check(entry.body_rect.get_center().distance_to(Vector2(0.5, 0.5)) < 0.001, id + " station centered")
		var original := snapshot.duplicate(true)
		view.configure_room(snapshot)
		await process_frame
		var renderer := view.get_node_or_null("BModelRoom")
		check(renderer != null and renderer.visible, id + " GLB renderer active")
		if renderer == null:
			continue
		check(renderer.room_world.has_node("VoxelArchitecture") and renderer.assemblies.has("ArchitectureWalls"), id + " uses shared masonry")
		var info: Dictionary = renderer.call("debug_snapshot")
		check(info.model_loaded and info.assemblies.size() >= 2, id + " actual meshes loaded")
		check(info.lights == 8, id + " eight candle lights")
		for point: Vector2 in [Vector2(.2,.2), Vector2(.5,.5), Vector2(.8,.8)]:
			var pixel: Vector2 = renderer.camera.unproject_position(renderer.call("local_to_model", point))
			var aligned: Vector2 = renderer.back_sprite.position + pixel * renderer.back_sprite.scale
			check(aligned.distance_to(G41RuntimeLayout.local_to_world(point)) < 1.0, id + " GLB projection aligns with 2D actor coordinates")
		check(info.gate_targets.values().all(func(v): return v < 0), id + " traversable doors open")
		view.apply_combat_snapshot({"door_locked": true})
		check(renderer.call("debug_snapshot").gate_targets.values().all(func(v): return v == 0), id + " combat closes visible gates")
		view.apply_combat_snapshot({"door_locked": false})
		check(renderer.call("debug_snapshot").gate_targets.values().all(func(v): return v < 0), id + " clearing combat reopens visible gates")
		var projected := WorldProjection.build(snapshot)
		check(projected.event_room.model_path == entry.model_path, id + " production WorldProjection uses B model")
		check(view.get_logical_obstacles().size() == entry.solids.size() + WorldProjection.ROOM_WALL_RECTS.size(), id + " solids match actual furniture and walls")
		var approach: Vector2 = entry.interaction_pos
		check(_clear(approach, view.get_logical_obstacles()), id + " clear interaction approach")
		check(bool(view.request_nearest_interaction(approach).get("accepted", false)), id + " production E interaction accepted")
		var reach := _reachable(Vector2(.5, .94), view.get_logical_obstacles())
		check(reach.has(_cell(approach)), id + " approach reachable from south door")
		for door: Dictionary in view.get_door_projections():
			check(reach.has(_cell(door.local_pos)), id + " connected " + String(door.orientation) + " doorway")
		check(snapshot == original, id + " presentation leaves source state untouched")
		var completed := snapshot.duplicate(true)
		completed.event_state.completed = true
		view.configure_room(completed)
		check(renderer == view.get_node("BModelRoom"), id + " reuses renderer on state refresh")
		check(not bool(view.request_nearest_interaction(approach).get("accepted", false)), id + " completed event cannot settle twice")
		view.configure_room({"position": Vector2i(3, 2), "current_room": &"Event", "event_state": {"event_type": &"z1_event_e01"}})
		var legacy = view.special_entities.get("event:3,2")
		check(legacy != null and legacy.get_node("VisualRoot/ArtVisual").visible, id + " legacy sprite visibility restored after 3D")
		view.configure_room({"position": Vector2i(3, 2), "current_room": &"Normal"})
		check(not renderer.visible and renderer.get_child_count() == 0, id + " leaving unloads 3D room")
		await process_frame
	view.free()
	for f in failures:
		printerr(f)
	print("B_EVENT_ROOM_INTEGRATION=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _cell(p: Vector2) -> Vector2i:
	return Vector2i((p * 80.0).round())

func _clear(p: Vector2, solids: Array[Rect2]) -> bool:
	for r in solids:
		if r.grow(0.0549).has_point(p):
			return false
	return true

func _reachable(origin: Vector2, solids: Array[Rect2]) -> Dictionary:
	var first := _cell(origin)
	var reached := {first: true}
	var queue: Array[Vector2i] = [first]
	var cursor := 0
	while cursor < queue.size():
		var c := queue[cursor]
		cursor += 1
		for d: Vector2i in [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]:
			var n := c + d
			if n.x < 4 or n.y < 4 or n.x > 76 or n.y > 76 or reached.has(n):
				continue
			if _clear(Vector2(n) / 80.0, solids):
				reached[n] = true
				queue.append(n)
	return reached
