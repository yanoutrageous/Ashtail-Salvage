extends RefCounted
class_name RunStateSnapshot

# Explicit run-owned components; UI nodes, services and content caches are bindings.
const COMPONENTS := ["truth_map", "intel_map", "asset_ledger", "run_event_log", "transaction_log", "rule_pipeline"]
const CONTEXT_BINDINGS := ["truth_map", "intel_map", "asset_ledger", "run_event_log", "transaction_log", "rule_pipeline", "query_facade", "minefield_service", "content_defs"]
const CHECKPOINT_CODEC := "godot46_data_zstd_v1"
const MAX_CHECKPOINT_BYTES := 64 * 1024 * 1024
const ENCODABLE_LEAF_TYPES := [TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING, TYPE_STRING_NAME, TYPE_PACKED_STRING_ARRAY]

static func pack_checkpoint(state: Dictionary) -> Dictionary:
	if not can_encode(state):
		return {}
	# Native Variant data preserves int64/float bits and typed containers. The
	# object-free decoder below never permits object construction from a save.
	var raw := var_to_bytes(state)
	if raw.size() > MAX_CHECKPOINT_BYTES:
		return {}
	var compressed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	var data := Marshalls.raw_to_base64(compressed)
	return {"codec": CHECKPOINT_CODEC, "byte_count": raw.size(), "sha256": data.sha256_text(), "data": data}

static func unpack_checkpoint(encoded: Variant) -> Dictionary:
	if not encoded is Dictionary or not encoded.has("codec"):
		return {"ok": true, "state": decode(encoded)} if valid_encoding(encoded) else {"ok": false}
	if encoded.size() != 4 or encoded.get("codec") != CHECKPOINT_CODEC or not encoded.get("data") is String or not encoded.get("sha256") is String:
		return {"ok": false}
	var count: Variant = encoded.get("byte_count")
	if not (count is int or count is float) or not is_finite(float(count)) or float(count) != floor(float(count)) or count < 4 or count > MAX_CHECKPOINT_BYTES or encoded.data.length() > MAX_CHECKPOINT_BYTES * 2:
		return {"ok": false}
	if encoded.data.sha256_text() != encoded.sha256:
		return {"ok": false}
	var invalid_base64 := RegEx.new()
	invalid_base64.compile("[^A-Za-z0-9+/=]")
	var padding: int = encoded.data.find("=")
	if encoded.data.is_empty() or encoded.data.length() % 4 != 0 or invalid_base64.search(encoded.data) != null or (padding >= 0 and encoded.data.substr(padding) not in ["=", "=="]):
		return {"ok": false}
	var compressed := Marshalls.base64_to_raw(encoded.data)
	if compressed.is_empty() or Marshalls.raw_to_base64(compressed) != encoded.data:
		return {"ok": false}
	var raw := compressed.decompress(int(count), FileAccess.COMPRESSION_ZSTD)
	if raw.size() != int(count) or raw.decode_u32(0) != TYPE_DICTIONARY:
		return {"ok": false}
	var state: Variant = bytes_to_var(raw)
	if not state is Dictionary or not can_encode(state) or var_to_bytes(state) != raw:
		return {"ok": false}
	return {"ok": true, "state": state}

static func capture_data(target: Object, excluded: Array = []) -> Dictionary:
	var result: Dictionary = {}
	if target == null:
		return result
	for property in target.get_script().get_script_property_list():
		var name := str(property["name"])
		if (int(property.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0 or name in excluded:
			continue
		var value: Variant = target.get(name)
		if target is TruthMap and name == "rooms":
			var rooms := {}
			for key in value:
				var room: Dictionary = value[key].duplicate()
				# This schema is explicitly display_only/no_persistence and depends
				# only on room type. Retain all actual room state and other fields.
				room.erase("RoomRulePreview")
				rooms[key] = room.duplicate(true)
			result[name] = rooms
		elif value is Dictionary or value is Array:
			result[name] = value.duplicate(true)
		elif value is PackedStringArray:
			result[name] = value.duplicate()
		elif not value is Object and not value is Callable and not value is Signal:
			result[name] = value
	return result

static func install_data(target: Object, data: Dictionary) -> void:
	for raw_name in data:
		var name := str(raw_name)
		var value: Variant = data[raw_name]
		var current: Variant = target.get(name)
		if current is Array and value is Array:
			current.assign(value)
		elif current is Dictionary and value is Dictionary:
			current.clear()
			current.merge(value.duplicate(true))
		else:
			target.set(name, value)
	if target is TruthMap and data.has("rooms"):
		# Rebuild after spawn_pos and the other map fields have been installed.
		var previews := {}
		for room: Dictionary in target.rooms.values():
			if room.has("RoomRulePreview"):
				continue
			var room_type: StringName = target._normalized_room_type(room, room.get("pos", Vector2i.ZERO))
			if not previews.has(room_type):
				previews[room_type] = TruthMap.RoomCommonRuleSchemaScript.room_rule_preview_for(room_type)
			room["RoomRulePreview"] = previews[room_type].duplicate(true)

static func capture_context(context: RunContext) -> Dictionary:
	var components: Dictionary = {}
	for name in COMPONENTS:
		var component: Variant = context.get(name)
		components[name] = null if component == null else capture_data(component)
	return {"data": capture_data(context, CONTEXT_BINDINGS), "components": components}

static func install_context(context: RunContext, snapshot: Dictionary, installed_snapshot: Dictionary = {}) -> Dictionary:
	if not snapshot.get("data") is Dictionary or not snapshot.get("components") is Dictionary:
		return {"ok": false, "reason": "invalid_context_snapshot"}
	var components: Dictionary = snapshot["components"]
	var installed_components: Dictionary = installed_snapshot.get("components", {})
	for name in COMPONENTS:
		if not components.has(name):
			return {"ok": false, "reason": "missing_snapshot_component"}
	var registry: ContentDefRegistry = context.content_defs
	var data: Dictionary = snapshot["data"]
	var profile: Dictionary = data.get("profile_fields", {})
	var use_z2 := str(profile.get("ruleset_id", "")) == "z2" and int(profile.get("z2_progression_version", 0)) == 1
	if bool(data.get("run_started", false)) and (registry == null or registry.definitions.has("rules.z2") != use_z2):
		registry = ContentDefRegistry.new()
		if use_z2:
			var registered := registry.setup_z2()
			if not registered.get("ok", false):
				return registered
		else:
			registry.setup_defaults()
	for name in COMPONENTS:
		var component_data: Variant = components[name]
		# Both snapshots come from this live context. Keep unchanged components
		# in place, including the truth map's derived room previews.
		if installed_components.has(name) and component_data == installed_components[name]:
			continue
		if component_data == null:
			context.set(name, null)
			continue
		var target: Variant = context.get(name)
		if target == null:
			match name:
				"truth_map": target = TruthMap.new()
				"intel_map": target = IntelMap.new()
				"asset_ledger": target = RunAssetLedger.new()
				"run_event_log": target = RunEventLog.new()
				"transaction_log": target = RunTransactionLog.new()
				"rule_pipeline": target = RunRulePipeline.new()
			context.set(name, target)
		install_data(target, component_data)
	install_data(context, snapshot["data"])
	if context.query_facade == null:
		context.query_facade = RunQueryFacade.new()
	if context.minefield_service == null:
		context.minefield_service = MinefieldService.new()
	context.content_defs = registry
	return {"ok": true}

static func can_encode(value: Variant) -> bool:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING, TYPE_STRING_NAME, TYPE_PACKED_STRING_ARRAY:
			return true
		TYPE_VECTOR2:
			return is_finite(value.x) and is_finite(value.y)
		TYPE_VECTOR2I:
			return true
		TYPE_RECT2:
			return can_encode(value.position) and can_encode(value.size)
		TYPE_COLOR:
			return is_finite(value.r) and is_finite(value.g) and is_finite(value.b) and is_finite(value.a)
		TYPE_FLOAT:
			return is_finite(float(value))
		TYPE_ARRAY:
			for entry in value:
				if typeof(entry) not in ENCODABLE_LEAF_TYPES and not can_encode(entry):
					return false
			return true
		TYPE_DICTIONARY:
			for key in value:
				if typeof(key) not in ENCODABLE_LEAF_TYPES and not can_encode(key):
					return false
				var entry: Variant = value[key]
				if typeof(entry) not in ENCODABLE_LEAF_TYPES and not can_encode(entry):
					return false
			return true
	return false

static func encode(value: Variant) -> Variant:
	match typeof(value):
		TYPE_INT:
			return {"$type": "i64", "value": str(value)}
		TYPE_FLOAT:
			return {"$type": "f64", "value": PackedFloat64Array([value]).to_byte_array().hex_encode()}
		TYPE_STRING_NAME:
			return {"$type": "name", "value": str(value)}
		TYPE_PACKED_STRING_ARRAY:
			return {"$type": "strings", "value": Array(value)}
		TYPE_VECTOR2:
			return {"$type": "v2", "value": [encode(value.x), encode(value.y)]}
		TYPE_VECTOR2I:
			return {"$type": "v2i", "value": [value.x, value.y]}
		TYPE_RECT2:
			return {"$type": "rect", "value": [encode(value.position.x), encode(value.position.y), encode(value.size.x), encode(value.size.y)]}
		TYPE_COLOR:
			return {"$type": "color", "value": [encode(value.r), encode(value.g), encode(value.b), encode(value.a)]}
		TYPE_ARRAY:
			var result: Array = []
			for entry in value:
				result.append(encode(entry))
			return {"$type": "array", "value": result}
		TYPE_DICTIONARY:
			var entries: Array = []
			for key in value:
				entries.append([encode(key), encode(value[key])])
			entries.sort_custom(func(a: Array, b: Array) -> bool: return JSON.stringify(a[0]) < JSON.stringify(b[0]))
			return {"$type": "dict", "value": entries}
	return value

static func decode(value: Variant) -> Variant:
	if not value is Dictionary:
		return value
	var payload: Variant = value.get("value")
	match str(value.get("$type", "")):
		"i64": return int(payload)
		"f64": return str(payload).hex_decode().decode_double(0)
		"name": return StringName(payload)
		"strings": return PackedStringArray(payload)
		"v2": return Vector2(float(decode(payload[0])), float(decode(payload[1])))
		"v2i": return Vector2i(int(payload[0]), int(payload[1]))
		"rect": return Rect2(float(decode(payload[0])), float(decode(payload[1])), float(decode(payload[2])), float(decode(payload[3])))
		"color": return Color(float(decode(payload[0])), float(decode(payload[1])), float(decode(payload[2])), float(decode(payload[3])))
		"array":
			var array: Array = []
			for entry in payload:
				array.append(decode(entry))
			return array
		"dict":
			var dictionary: Dictionary = {}
			for entry in payload:
				dictionary[decode(entry[0])] = decode(entry[1])
			return dictionary
	return null

static func fingerprint(value: Variant) -> String:
	return JSON.stringify(encode(value)).sha256_text()

# Validate the complete untrusted representation before decoding or touching authority.
static func valid_encoding(value: Variant, depth: int = 0) -> bool:
	if depth > 96:
		return false
	if not value is Dictionary:
		return typeof(value) in [TYPE_NIL, TYPE_BOOL, TYPE_STRING] or (typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value)))
	if value.size() != 2 or not value.has("$type") or not value.has("value"):
		return false
	var payload: Variant = value["value"]
	match str(value["$type"]):
		"i64": return payload is String and payload.is_valid_int() and str(int(payload)) == payload
		"f64": return payload is String and payload.length() == 16 and payload.is_valid_hex_number(false) and is_finite(payload.hex_decode().decode_double(0))
		"name": return payload is String
		"strings":
			if not payload is Array:
				return false
			for entry in payload:
				if not entry is String:
					return false
			return true
		"v2", "v2i", "rect", "color":
			var count := 2 if str(value["$type"]) in ["v2", "v2i"] else 4
			if not payload is Array or payload.size() != count:
				return false
			for number in payload:
				if not valid_encoding(number, depth + 1):
					return false
				var decoded: Variant = decode(number)
				if not typeof(decoded) in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(decoded)):
					return false
				if str(value["$type"]) == "v2i" and (float(decoded) != floor(float(decoded)) or abs(float(decoded)) > 2147483647.0):
					return false
			return true
		"array":
			if not payload is Array:
				return false
			for entry in payload:
				if not valid_encoding(entry, depth + 1):
					return false
			return true
		"dict":
			if not payload is Array:
				return false
			var keys: Dictionary = {}
			for entry in payload:
				if not entry is Array or entry.size() != 2 or not valid_encoding(entry[0], depth + 1) or not valid_encoding(entry[1], depth + 1):
					return false
				var key: Variant = decode(entry[0])
				if key is Array or key is Dictionary or keys.has(key):
					return false
				keys[key] = true
			return true
	return false

static func _valid_data(target: Object, data: Variant, excluded: Array = []) -> bool:
	if not data is Dictionary:
		return false
	var template := capture_data(target, excluded)
	if data.size() != template.size():
		return false
	for key in template:
		if not data.has(key) or typeof(template[key]) != typeof(data[key]):
			return false
		if template[key] is Array and template[key].is_typed():
			var element_type: int = template[key].get_typed_builtin()
			for entry in data[key]:
				if typeof(entry) != element_type:
					return false
	return true

static func valid_context(snapshot: Variant) -> bool:
	if not snapshot is Dictionary or not snapshot.get("components") is Dictionary:
		return false
	var data: Variant = snapshot.get("data")
	if not _valid_data(RunContext.new(), data, CONTEXT_BINDINGS):
		return false
	if int(data["hp"]) < 0 or int(data["max_hp"]) < 1 or int(data["hp"]) > int(data["max_hp"]) or int(data["pressure"]) < 0 or int(data["pressure"]) > 100:
		return false
	if int(data["shield"]) < 0 or not RunStatusService._valid_statuses(data["temporary_statuses"]):
		return false
	var factories := {"truth_map": TruthMap.new(), "intel_map": IntelMap.new(), "asset_ledger": RunAssetLedger.new(), "run_event_log": RunEventLog.new(), "transaction_log": RunTransactionLog.new(), "rule_pipeline": RunRulePipeline.new()}
	var components: Dictionary = snapshot["components"]
	if components.size() != factories.size():
		return false
	for key in factories:
		if not components.has(key):
			return false
		if components[key] == null:
			if bool(data["run_started"]):
				return false
		elif not _valid_data(factories[key], components[key]):
			return false
	if not bool(data["run_started"]):
		return true
	var map: Dictionary = components["truth_map"]
	if int(map["width"]) != int(data["width"]) or int(map["height"]) != int(data["height"]) or int(data["width"]) <= 0 or int(data["height"]) <= 0:
		return false
	var pos: Vector2i = data["current_pos"]
	if pos.x < 0 or pos.y < 0 or pos.x >= int(data["width"]) or pos.y >= int(data["height"]):
		return false
	if map["rooms"].size() != int(data["width"]) * int(data["height"]):
		return false
	for room_key in map["rooms"]:
		var room: Variant = map["rooms"][room_key]
		if not room is Dictionary or not room.get("pos") is Vector2i:
			return false
		var room_pos: Vector2i = room["pos"]
		if str(room_key) != "%d,%d" % [room_pos.x, room_pos.y] or room_pos.x < 0 or room_pos.y < 0 or room_pos.x >= int(data["width"]) or room_pos.y >= int(data["height"]):
			return false
	var ledger: Dictionary = components["asset_ledger"]
	var locations := ["inventory", "equipped", "room_floor", "warehouse", "settlement_pool", "lost", "consumed", "cleared", "consigned", "pledged"]
	var floor_ids: Dictionary = {}
	for instance_id in ledger["item_instances"]:
		var item: Variant = ledger["item_instances"][instance_id]
		if not item is Dictionary or str(item.get("instance_id", "")) != str(instance_id) or not str(item.get("location_state", "")) in locations:
			return false
	for room_key in ledger["room_floor_items"]:
		var ids: Variant = ledger["room_floor_items"][room_key]
		if not ids is Array or not map["rooms"].has(room_key):
			return false
		for instance_id in ids:
			if not ledger["item_instances"].has(instance_id) or str(ledger["item_instances"][instance_id].get("location_state", "")) != "room_floor":
				return false
			var floor_item: Dictionary = ledger["item_instances"][instance_id]
			if floor_ids.has(instance_id) or floor_item.get("room_pos") != map["rooms"][room_key]["pos"]:
				return false
			floor_ids[instance_id] = true
	for instance_id in ledger["item_instances"]:
		if str(ledger["item_instances"][instance_id]["location_state"]) == "room_floor" and not floor_ids.has(instance_id):
			return false
	return true
