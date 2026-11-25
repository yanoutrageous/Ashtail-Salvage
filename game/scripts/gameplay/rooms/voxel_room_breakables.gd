extends RefCounted
## Room-local smashable footprints. Slots stay off doors and floor loot lanes.

const RoomProjection := preload("res://scripts/gameplay/runtime/g41_world_object_projection.gd")
const SLOTS := {
	&"north_west": Vector2(0.188, 0.245),
	&"north_east": Vector2(0.810, 0.243),
	&"south_west": Vector2(0.181, 0.777),
	&"south_east": Vector2(0.821, 0.795),
}
const SIZE := {
	&"crate": Vector2(0.056, 0.072),
	&"barrel": Vector2(0.047, 0.064),
	&"urn": Vector2(0.042, 0.055),
}
const MAX_HP := {&"crate": 12, &"barrel": 14, &"urn": 7}


static func for_room(room_type: StringName, event_type: StringName = &"", room_key: String = "") -> Array[Dictionary]:
	var occupants: Dictionary = {}
	match room_type:
		&"Spawn", &"Normal":
			occupants = {&"south_west": &"crate", &"south_east": &"barrel"}
		&"Chest":
			occupants = {&"north_west": &"crate", &"south_east": &"barrel"}
		&"Monster", &"Combat", &"Boss":
			occupants = {&"north_east": &"urn", &"south_west": &"crate", &"south_east": &"barrel"}
		&"Mine":
			occupants = {&"north_west": &"barrel", &"south_east": &"crate"}
		&"Exit":
			occupants = {&"south_west": &"barrel", &"north_east": &"crate"}
		&"Event":
			occupants = {&"south_west": &"crate", &"south_east": &"urn"}
			match event_type:
				&"altar":
					occupants[&"north_east"] = &"urn"
				&"trader", &"shop", &"consign", &"pawn", &"recycle", &"expand":
					occupants[&"south_east"] = &"barrel"
				&"first_aid", &"mechanism", &"compress", &"seal":
					occupants[&"south_west"] = &"urn"
					occupants[&"south_east"] = &"crate"
	if occupants.is_empty():
		return []
	var solids := RoomProjection.room_solid_rects(room_type, event_type, true, room_key)
	var props: Array[Dictionary] = []
	for slot: StringName in occupants:
		var kind: StringName = occupants[slot]
		var dimension: Vector2 = SIZE[kind]
		var corner: Vector2 = SLOTS[slot]
		var inward := (Vector2(0.5, 0.5) - corner).sign()
		for offset in [Vector2.ZERO, Vector2(0.082 * inward.x, 0), Vector2(0, 0.078 * inward.y)]:
			var rect := Rect2(corner + Vector2(offset) - dimension * 0.5, dimension)
			var clearance := rect.grow(0.015)
			if solids.any(func(solid: Rect2) -> bool: return solid.intersects(clearance)):
				continue
			props.append({"id": "breakable_%s" % slot, "rect": rect, "kind": kind, "max_hp": MAX_HP[kind]})
			break
	return props
