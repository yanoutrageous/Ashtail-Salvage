extends Node2D

const Layout = preload("res://scripts/gameplay/runtime/g41_runtime_layout.gd")
const RoomModel = preload("res://scripts/presentation/B/B_event_room_view.gd")
const SHELL = preload("res://assets/rooms/unexplored_masonry.png")
# The transparent camera frame extends beyond the stone silhouette.
# Overlap the return course so the shaded bottom fascia sits behind the next wall.
const PITCH := Vector2(548, 574)
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

func sync(snapshot: Dictionary, public_cells: Array) -> void:
	var current: Vector2i = snapshot.get("position", Vector2i.ZERO)
	var board := Rect2i(0, 0, int(snapshot.get("width", 0)), int(snapshot.get("height", 0)))
	var explored := {}
	for cell: Dictionary in public_cells:
		if cell.get("explored", false):
			explored[cell.pos] = true
	# Corner rooms fill the view where two perpendicular neighbors meet.
	for y in range(-1, 2):
		for x in range(-1, 2):
			var delta := Vector2i(x, y)
			if delta == Vector2i.ZERO:
				continue
			var target := current + delta
			var sprite := neighbors.get(delta) as Sprite2D
			if not board.has_point(target):
				if sprite != null:
					sprite.hide()
				continue
			if sprite == null:
				sprite = Sprite2D.new()
				sprite.centered = false
				sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
				add_child(sprite)
				neighbors[delta] = sprite
			var visited := explored.has(target)
			sprite.texture = memory.get(target, SHELL) if visited else SHELL
			sprite.position = Layout.local_to_world(RoomModel.FRAME.position) + Vector2(delta) * PITCH
			sprite.scale = Layout.local_size_to_world(RoomModel.FRAME.size) / sprite.texture.get_size()
			sprite.self_modulate = EXPLORED if visited else UNEXPLORED
			sprite.show()
