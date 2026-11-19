extends SceneTree

const ResultPanelScene := preload("res://scenes/ui/result/result_panel.tscn")
const RunSurfaceScript := preload("res://scripts/ui/run_surface/run_surface.gd")
const ItemCatalogScript := preload("res://scripts/core/content/m3_item_catalog.gd")
const ItemVisualCatalogScript := preload("res://scripts/presentation/art24/art24_item_visual_catalog.gd")
const RuntimeTextureCacheScript := preload("res://scripts/presentation/runtime_texture_cache.gd")
const UILayoutProfileScript := preload("res://scripts/ui/shell/ui_layout_profile.gd")

const MANIFEST_PATH := "res://data/assets/asset_manifest.csv"
const RESULT_PATH_BY_STATE := {
	&"success": "res://assets/art24/ui/result_banner_success.png",
	&"failure": "res://assets/art24/ui/result_banner_failure.png",
	&"abandon": "res://assets/art24/ui/result_banner_abandoned.png",
}
const DIRECT_LICENSE_STATUSES := [
	"internal_generated",
	"internal_generated_from_audited_sources",
	"same_project_audited",
]
const DIRECT_SOURCE_STATUSES := [
	"art24_generated",
	"art24_ue_audited_import",
	"art25_generated_audited_reuse",
	"art21r2_generated_contract_component",
	"run_vector_generated",
]
const PROTOCOL_UI_SCALES := [1.0, 1.5]
const PROTOCOL_FRAME_PATH := "res://assets/ui/run_vector/frame_status.svg"
const PROTOCOL_FRAME_SHA256 := "25FBB88C0E262AB95D77F6903441D40B4F659C8E4FB65512B1C0F9D9DB7847B3"
# Corner cuts and pins fit inside these source rectangles.
const PROTOCOL_FIXED_ORNAMENTS := [
	Rect2(0, 0, 9, 9), Rect2(63, 0, 9, 9),
	Rect2(0, 39, 9, 9), Rect2(63, 39, 9, 9),
]
# Reviewed layout coordinates stay independent of NinePatch sampling margins.
const PROTOCOL_FRAME_RECTS := {100: Rect2(12, 12, 256, 148), 150: Rect2(12, 12, 288, 190)}
const PROTOCOL_COPY_SAFE_RECTS := {
	100: Rect2(23, 23, 234, 126),
	150: Rect2(23, 23, 266, 168),
}
const PROTOCOL_COPY_PRESSURE_GAP := 2.0
const RECT_EPSILON := 0.5

var manifest_by_path: Dictionary = {}
var manifest_by_id: Dictionary = {}
var checked_paths: Dictionary = {}
var verified_hash_count := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = []
	manifest_by_path = _read_manifest(failures)
	_check_manifest_assets(failures)
	_check_item_bindings(failures)
	await _check_result_runtime(failures)
	await _check_protocol_runtime(failures)
	if failures.is_empty():
		print("I2_ASSET_BINDING=PASS result_states=3 protocol_levels=5 protocol_scales=100,150 protocol_frame=single_ninepatch_ornaments_fixed_copy_safe item_bindings=63 verified_hashes=%d" % verified_hash_count)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	print("I2_ASSET_BINDING=FAIL failures=%d" % failures.size())
	quit(2)


func _read_manifest(failures: Array[String]) -> Dictionary:
	var rows_by_path: Dictionary = {}
	var file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if file == null:
		failures.append("manifest_open_failed=%s" % MANIFEST_PATH)
		return rows_by_path
	var raw_headers := file.get_csv_line()
	var headers: Array[String] = []
	for raw_header in raw_headers:
		headers.append(String(raw_header))
	while file.get_position() < file.get_length():
		var values := file.get_csv_line()
		if values.is_empty() or (values.size() == 1 and String(values[0]).strip_edges() == ""):
			continue
		var row: Dictionary = {}
		for index in range(mini(headers.size(), values.size())):
			row[headers[index]] = String(values[index])
		var godot_path := String(row.get("godot_path", ""))
		if godot_path != "":
			rows_by_path[godot_path] = row
		var asset_id := String(row.get("asset_id", ""))
		if not asset_id.is_empty():
			manifest_by_id[asset_id] = row
	return rows_by_path


func _check_manifest_assets(failures: Array[String]) -> void:
	for file_name in DirAccess.get_files_at("res://assets/ui/run_vector"):
		if file_name.ends_with(".svg"):
			_check_registered_path("res://assets/ui/run_vector/" + file_name, failures)
	for path_value in RESULT_PATH_BY_STATE.values():
		_check_registered_path(String(path_value), failures)
	for level in range(1, 6):
		_check_registered_path("res://assets/art24/ui/protocol/level_%d.png" % level, failures)


func _check_item_bindings(failures: Array[String]) -> void:
	RuntimeTextureCacheScript.clear_for_tests()
	var all_items: Array[Dictionary] = ItemCatalogScript.all_items()
	var unique_texture_paths: Dictionary = {}
	if all_items.size() != 63:
		failures.append("item_catalog_count=%d_expected=63" % all_items.size())
	for item in all_items:
		var item_id := String(item.get("item_id", ""))
		if not ItemVisualCatalogScript.has_explicit_mapping(item_id):
			failures.append("item_mapping_missing=%s" % item_id)
			continue
		var texture_path := ItemVisualCatalogScript.texture_path(item)
		var z1_row: Dictionary = {}
		if texture_path.begins_with("res://assets/items/"):
			z1_row = manifest_by_id.get("z1.item.%s" % item_id, {})
			if (
				not texture_path.begins_with("res://assets/items/z1/")
				or z1_row.get("godot_path", "") != texture_path
				or z1_row.get("linked_data", "") != item_id
				or z1_row.get("type", "") != "texture"
			):
				failures.append("item_binding_reopened_unregistered_source=%s:%s" % [item_id, texture_path])
				continue
		unique_texture_paths[texture_path] = true
		_check_registered_path(texture_path, failures, z1_row)
		var first_texture := ItemVisualCatalogScript.texture_for(item)
		var cached_texture := ItemVisualCatalogScript.texture_for(item)
		if first_texture == null or first_texture.resource_path != texture_path:
			failures.append("item_texture_load_failed=%s:%s" % [item_id, texture_path])
		elif cached_texture != first_texture:
			failures.append("item_texture_cache_identity_mismatch=%s:%s" % [item_id, texture_path])
	for fallback_path_value in ItemVisualCatalogScript.TYPE_FALLBACKS.values():
		var fallback_path := String(fallback_path_value)
		if fallback_path.begins_with("res://assets/items/"):
			failures.append("item_fallback_reopened_unregistered_source=%s" % fallback_path)
			continue
		_check_registered_path(fallback_path, failures)
	var cache_metrics: Dictionary = RuntimeTextureCacheScript.metrics()
	var expected_requests := all_items.size() * 2
	var expected_loads := unique_texture_paths.size()
	if int(cache_metrics.get("requests", -1)) != expected_requests:
		failures.append("item_texture_cache_requests=%s_expected=%d" % [cache_metrics.get("requests", -1), expected_requests])
	if int(cache_metrics.get("loads", -1)) != expected_loads:
		failures.append("item_texture_cache_loads=%s_expected=%d" % [cache_metrics.get("loads", -1), expected_loads])
	if int(cache_metrics.get("cache_hits", -1)) != expected_requests - expected_loads:
		failures.append("item_texture_cache_hits=%s_expected=%d" % [cache_metrics.get("cache_hits", -1), expected_requests - expected_loads])
	if int(cache_metrics.get("failures", -1)) != 0:
		failures.append("item_texture_cache_failures=%s_expected=0" % cache_metrics.get("failures", -1))
	if int(cache_metrics.get("entries", -1)) != expected_loads:
		failures.append("item_texture_cache_entries=%s_expected=%d" % [cache_metrics.get("entries", -1), expected_loads])


func _check_result_runtime(failures: Array[String]) -> void:
	root.size = Vector2i(1280, 720)
	var canvas := Control.new()
	canvas.size = Vector2(1280, 720)
	root.add_child(canvas)
	var panel := ResultPanelScene.instantiate() as ResultPanel
	canvas.add_child(panel)
	await _frames(2)
	for state_value in RESULT_PATH_BY_STATE.keys():
		var state := StringName(state_value)
		var dynamic_title := "I2 dynamic localized title: %s" % String(state)
		panel.set_result_summary(dynamic_title, "I2 summary")
		panel.call("_apply_result_title_plate", state)
		await _frames(1)
		var banner := panel.get_node("ResultTitlePlate") as TextureRect
		var expected_path := String(RESULT_PATH_BY_STATE[state])
		if banner.texture == null or banner.texture.resource_path != expected_path:
			failures.append("result_banner_%s=%s_expected=%s" % [state, "<null>" if banner.texture == null else banner.texture.resource_path, expected_path])
		var title := panel.get_node("ResultTitle") as Label
		if not title.visible or title.text != dynamic_title:
			failures.append("result_dynamic_title_%s_visible=%s_text=%s" % [state, title.visible, title.text])
	canvas.queue_free()
	await _frames(2)


func _check_protocol_runtime(failures: Array[String]) -> void:
	root.size = Vector2i(1280, 720)
	var surface := RunSurfaceScript.new() as RunSurface
	root.add_child(surface)
	surface.build()
	var base_profile: Dictionary = UILayoutProfileScript.profile_for_resolution(&"1280x720")
	base_profile["actual_viewport_size"] = Vector2i(1280, 720)
	for ui_scale in PROTOCOL_UI_SCALES:
		var profile := base_profile.duplicate(true)
		profile["ui_scale_factor"] = ui_scale
		surface.set_ui_scale_factor(ui_scale)
		surface.apply_layout_profile(profile)
		await _frames(2)
		var seen_pressure_colors: Dictionary = {}
		for level in range(1, 6):
			var pressure := (5 - level) * 25
			surface.apply_surface_model({
				"protocol_level": level,
				"pressure": pressure,
				"danger_theme_key": &"ui.warning",
				"danger_label": "I2 pressure state",
				"resource_summary": "",
				"hp": 100, "max_hp": 100, "power": 20,
				"backpack_items": [],
				"backpack_used": 0,
				"backpack_capacity": 0,
				"layout_profile": profile,
				"action_buttons": [],
				"encounter_section": {},
			})
			await _frames(1)
			var expected_path := "res://assets/art24/ui/protocol/level_%d.png" % level
			if surface.protocol_level_plate.texture == null or surface.protocol_level_plate.texture.resource_path != expected_path:
				failures.append("protocol_level_%d_scale_%d=%s_expected=%s" % [
					level,
					int(round(ui_scale * 100.0)),
					"<null>" if surface.protocol_level_plate.texture == null else surface.protocol_level_plate.texture.resource_path,
					expected_path,
				])
			if surface.right_title_label.text.find(str(level)) < 0 or surface.right_body_label.text.find(str(pressure)) < 0:
				failures.append("protocol_text_redundancy_missing=level_%d_pressure_%d_scale_%d" % [
					level,
					pressure,
					int(round(ui_scale * 100.0)),
				])
			var expected_width := surface.protocol_pressure_track.size.x * float(pressure) / 100.0
			if not is_equal_approx(surface.protocol_pressure_fill.size.x, expected_width):
				failures.append("protocol_progress_%d_scale_%d=%s_expected=%s" % [
					pressure,
					int(round(ui_scale * 100.0)),
					surface.protocol_pressure_fill.size.x,
					expected_width,
				])
			if not surface.protocol_glow_layer.visible:
				failures.append("protocol_color_redundancy_hidden=level_%d_scale_%d" % [
					level,
					int(round(ui_scale * 100.0)),
				])
			seen_pressure_colors[surface.protocol_pressure_fill.color] = true
		if seen_pressure_colors.size() < 3:
			failures.append("protocol_pressure_color_bands_scale_%d=%d_expected_at_least_3" % [
				int(round(ui_scale * 100.0)),
				seen_pressure_colors.size(),
			])
		_check_protocol_main_frame(surface, profile, ui_scale, failures)
	surface.queue_free()
	await _frames(2)


func _check_protocol_main_frame(
	surface: RunSurface,
	profile: Dictionary,
	ui_scale: float,
	failures: Array[String]
) -> void:
	var scale_percent := int(round(ui_scale * 100.0))
	var visible_frames := _visible_protocol_frames(surface)
	if visible_frames.size() != 1:
		failures.append("protocol_main_frame_count_scale_%d=%d_expected=1" % [
			scale_percent,
			visible_frames.size(),
		])
		return
	var frame := visible_frames[0]
	var texture := _control_texture(frame)
	if texture == null:
		failures.append("protocol_main_frame_texture_missing_scale_%d" % scale_percent)
		return
	if texture.resource_path.is_empty():
		failures.append("protocol_main_frame_resource_path_missing_scale_%d" % scale_percent)
	else:
		_check_registered_path(texture.resource_path, failures)
	_check_protocol_ornaments(frame, texture, scale_percent, failures)
	var frame_rect := frame.get_global_rect()
	if not frame_rect.is_equal_approx(PROTOCOL_FRAME_RECTS[scale_percent]):
		failures.append("protocol_frame_layout_changed_scale_%d=%s" % [scale_percent, frame_rect])
	var viewport_size := Vector2(profile.get("actual_viewport_size", Vector2i(1280, 720)))
	if not _contains_with_epsilon(Rect2(Vector2.ZERO, viewport_size), frame_rect):
		failures.append("protocol_main_frame_outside_viewport_scale_%d=%s" % [
			scale_percent,
			frame_rect,
		])
	var safe_rect: Rect2 = PROTOCOL_COPY_SAFE_RECTS[scale_percent]
	var title_rect := surface.right_title_label.get_global_rect()
	var body_rect := surface.right_body_label.get_global_rect()
	var vitals_rect := surface.player_health_hud.get_global_rect()
	var copy_rect := title_rect.merge(body_rect).merge(vitals_rect)
	for label in [surface.right_title_label, surface.right_body_label]:
		if not label.is_visible_in_tree() or label.text.is_empty() or label.clip_text or label.text_overrun_behavior != TextServer.OVERRUN_NO_TRIMMING or label.get_minimum_size().y > label.size.y + RECT_EPSILON:
			failures.append("protocol_copy_clipped_scale_%d=%s" % [scale_percent, label.name])
	if not _contains_with_epsilon(safe_rect, copy_rect):
		failures.append("protocol_copy_unsafe_scale_%d=copy:%s_safe:%s_frame:%s" % [
			scale_percent,
			copy_rect,
			safe_rect,
			frame_rect,
		])
	if title_rect.intersects(body_rect):
		failures.append("protocol_title_body_overlap_scale_%d=title:%s_body:%s" % [
			scale_percent,
			title_rect,
			body_rect,
		])
	if vitals_rect.intersects(title_rect) or vitals_rect.intersects(body_rect):
		failures.append("protocol_vitals_overlap_scale_%d=%s" % [scale_percent, vitals_rect])
	var pressure_rect := surface.protocol_pressure_track.get_global_rect()
	if not _contains_with_epsilon(safe_rect, pressure_rect):
		failures.append("protocol_pressure_unsafe_scale_%d=pressure:%s_safe:%s_frame:%s" % [
			scale_percent,
			pressure_rect,
			safe_rect,
			frame_rect,
		])
	if copy_rect.end.y + PROTOCOL_COPY_PRESSURE_GAP > pressure_rect.position.y + RECT_EPSILON:
		failures.append("protocol_copy_pressure_gap_scale_%d=copy_end:%.2f_pressure_top:%.2f_expected_gap:%.2f" % [
			scale_percent,
			copy_rect.end.y,
			pressure_rect.position.y,
			PROTOCOL_COPY_PRESSURE_GAP,
		])


func _visible_protocol_frames(surface: RunSurface) -> Array[Control]:
	var frames: Array[Control] = []
	for candidate in [surface.status_card_art, surface.protocol_level_plate]:
		if not (candidate is Control):
			continue
		var control := candidate as Control
		if control.visible and control.get_global_rect().get_area() > 0.0:
			frames.append(control)
	return frames


func _control_texture(control: Control) -> Texture2D:
	if control is NinePatchRect:
		return (control as NinePatchRect).texture
	if control is TextureRect:
		return (control as TextureRect).texture
	return null


func _check_protocol_ornaments(frame: Control, texture: Texture2D, scale_percent: int, failures: Array[String]) -> void:
	if texture.resource_path != PROTOCOL_FRAME_PATH or texture.get_size() != Vector2(72, 48) or FileAccess.get_sha256(PROTOCOL_FRAME_PATH).to_upper() != PROTOCOL_FRAME_SHA256:
		failures.append("protocol_ornament_source_changed_scale_%d" % scale_percent)
		return
	if not (frame is NinePatchRect):
		failures.append("protocol_ornaments_require_ninepatch_scale_%d" % scale_percent)
		return
	var patch := frame as NinePatchRect
	var leading := Vector2(patch.patch_margin_left, patch.patch_margin_top)
	var trailing := Vector2(patch.patch_margin_right, patch.patch_margin_bottom)
	var source_size := texture.get_size()
	if patch.region_rect != Rect2() or patch.axis_stretch_horizontal != NinePatchRect.AXIS_STRETCH_MODE_STRETCH or patch.axis_stretch_vertical != NinePatchRect.AXIS_STRETCH_MODE_STRETCH:
		failures.append("protocol_ninepatch_sampling_changed_scale_%d" % scale_percent)
	if frame.size.x <= leading.x + trailing.x or frame.size.y <= leading.y + trailing.y or source_size.x <= leading.x + trailing.x or source_size.y <= leading.y + trailing.y:
		failures.append("protocol_ninepatch_corner_overlap_scale_%d" % scale_percent)
	var canvas_transform := frame.get_global_transform_with_canvas()
	if not is_equal_approx(canvas_transform.x.length(), canvas_transform.y.length()):
		failures.append("protocol_ornaments_nonuniform_canvas_scale_%d" % scale_percent)
	var fixed_corners := [
		Rect2(Vector2.ZERO, leading),
		Rect2(source_size.x - trailing.x, 0, trailing.x, leading.y),
		Rect2(0, source_size.y - trailing.y, leading.x, trailing.y),
		Rect2(source_size - trailing, trailing),
	]
	for index in range(PROTOCOL_FIXED_ORNAMENTS.size()):
		var corner: Rect2 = fixed_corners[index]
		if not corner.encloses(PROTOCOL_FIXED_ORNAMENTS[index]):
			failures.append("protocol_ornament_enters_stretch_scale_%d_corner_%d=ornament:%s_fixed:%s" % [scale_percent, index, PROTOCOL_FIXED_ORNAMENTS[index], corner])


func _contains_with_epsilon(outer: Rect2, inner: Rect2) -> bool:
	return outer.grow(RECT_EPSILON).encloses(inner)


func _check_registered_path(path: String, failures: Array[String], z1_row: Dictionary = {}) -> void:
	if checked_paths.has(path):
		return
	checked_paths[path] = true
	if not manifest_by_path.has(path):
		failures.append("manifest_path_missing=%s" % path)
		return
	var row: Dictionary = manifest_by_path[path] if z1_row.is_empty() else z1_row
	var license_status := String(row.get("license_status", ""))
	var source_status := String(row.get("source_status", ""))
	var valid_license := DIRECT_LICENSE_STATUSES.has(license_status) if z1_row.is_empty() else license_status == "internal_ai_generated"
	var valid_source := DIRECT_SOURCE_STATUSES.has(source_status) if z1_row.is_empty() else source_status == "z1_generated"
	if not valid_license:
		failures.append("manifest_license_not_direct=%s:%s" % [path, license_status])
	if not valid_source:
		failures.append("manifest_source_status_not_direct=%s:%s" % [path, source_status])
	if String(row.get("replacement_needed", "")).to_lower() != "false":
		failures.append("manifest_replacement_required=%s" % path)
	if String(row.get("source_repo_path", "")).strip_edges() == "":
		failures.append("manifest_source_missing=%s" % path)
	if not FileAccess.file_exists(path):
		failures.append("registered_asset_missing=%s" % path)
		return
	var note := String(row.get("note", ""))
	var marker_index := note.to_lower().find("sha256=")
	if marker_index < 0:
		failures.append("manifest_hash_missing=%s" % path)
		return
	var expected_hash := note.substr(marker_index + 7, 64).to_lower()
	var actual_hash := FileAccess.get_sha256(path).to_lower()
	if expected_hash.length() != 64 or actual_hash != expected_hash:
		failures.append("manifest_hash_mismatch=%s expected=%s actual=%s" % [path, expected_hash, actual_hash])
		return
	verified_hash_count += 1


func _frames(count: int) -> void:
	for _index in range(count):
		await process_frame
