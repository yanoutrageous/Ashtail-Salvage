extends SceneTree
const View = preload("res://scripts/gameplay/runtime/g41_room_runtime_view.gd")
const Catalog = preload("res://scripts/presentation/B/B_event_room_catalog.gd")
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	root.size = Vector2i(1280, 720)
	var bg := ColorRect.new()
	bg.color = Color("101a1c")
	bg.size = Vector2(1280, 720)
	bg.z_index = -2000
	root.add_child(bg)
	var view := View.new()
	root.add_child(view)
	var player := (load("res://scenes/player/player.tscn") as PackedScene).instantiate()
	root.add_child(player)
	var dir := OS.get_environment("B_CAPTURE_DIR")
	DirAccess.make_dir_recursive_absolute(dir)
	for id in ["seal", "trader", "relief", "cage", "consign", "shortcut", "pawn"]:
		var entry := Catalog.room(StringName(id))
		view.configure_room({"position": Vector2i(2, 2), "current_room": &"Event", "event_state": {"event_type": id}})
		player.set_process(false)
		player.set_local_position(entry.interaction_pos + Vector2(0.0, .07))
		view.advance(0.0, player.get_local_position())
		await create_timer(.35).timeout
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		if image == null or image.is_empty() or image.save_png(dir.path_join(String(entry.code)+"_runtime.png")) != OK:
			printerr("B_CAPTURE_FAILED ", id)
			quit(1)
			return
		print("B_RUNTIME_CAPTURE ", entry.code)
	view.free()
	player.free()
	bg.free()
	quit(0)
