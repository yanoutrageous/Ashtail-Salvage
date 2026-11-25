extends Node2D

const Layout = preload("res://scripts/gameplay/runtime/g41_runtime_layout.gd")
const RoomModel = preload("res://scripts/presentation/B/B_event_room_view.gd")
const SHELL = preload("res://assets/rooms/unexplored_masonry.png")
const PITCH := Vector2(595, 663)
const EXPLORED := Color(0.52, 0.58, 0.65)
const UNEXPLORED := Color(0.28, 0.33, 0.40)

var memory := {}
var neighbors := {}

func remember(cell: Vector2i, room: Node2D) -> void:
	if room == null or not room.visible or DisplayServer.get_name() == "headless":
		return
	var view := room.get("viewport") as SubViewport
	if view == null or not is_instance_valid(view):
		return
	var image := view.get_texture().get_image()
	if image == null or image.is_empty():
		return
	image.resize(SHELL.get_width(), SHELL.get_height(), Image.INTERPOLATE_BILINEAR)
	memory.erase(cell)
	if memory.size() >= 12:
		memory.erase(memory.keys().front())
	memory[cell] = ImageTexture.create_from_image(image)

func sync(doors: Array[Dictionary]) -> void:
	for door in doors:
		var direction := Vector2i(door.payload.direction)
		var sprite := neighbors.get(direction) as Sprite2D
		if door.visual_state == &"blocked_out_of_bounds":
			if sprite != null:
				sprite.hide()
			continue
		if sprite == null:
			sprite = Sprite2D.new()
			sprite.centered = false
			sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
			add_child(sprite)
			neighbors[direction] = sprite
		var explored := bool(door.payload.get("explored", false))
		sprite.texture = memory.get(door.payload.target, SHELL) if explored else SHELL
		sprite.position = Layout.local_to_world(RoomModel.FRAME.position) + Vector2(direction) * PITCH
		sprite.scale = Layout.local_size_to_world(RoomModel.FRAME.size) / sprite.texture.get_size()
		sprite.self_modulate = EXPLORED if explored else UNEXPLORED
		sprite.show()
	queue_redraw()

func _draw() -> void:
	var center := Layout.local_to_world(Vector2(0.5, 0.5))
	for direction: Vector2i in neighbors:
		var neighbor := neighbors[direction] as Sprite2D
		if not neighbor.visible:
			continue
		var side := direction.x != 0
		var span := Vector2(96, 84) if side else Vector2(91, 132)
		var middle := center + Vector2(direction) * PITCH * 0.5
		middle.y -= 8.0 if side else 22.0
		var bridge := Rect2(middle - span * 0.5, span)
		draw_rect(bridge, Color("#202b2d"))
		var inside := bridge.grow_individual(0, -6, 0, -6) if side else bridge.grow_individual(-6, 0, -6, 0)
		draw_texture_rect_region(SHELL, inside, Rect2(234, 196, 78, 62), Color(0.78, 0.79, 0.8))
