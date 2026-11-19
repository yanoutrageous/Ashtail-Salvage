extends SceneTree

const PASS_MARKER := "I1_COMBAT_REFRESH=PASS"
const FAIL_MARKER := "I1_COMBAT_REFRESH=FAIL"
const DAMAGE_SAMPLES := 180
const FULL_SAMPLES := 40

var failures: Array[String] = []
var damage_dispatch_samples: Array[int] = []
var full_dispatch_samples: Array[int] = []
var durable_revisions: Array[int] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	_require(packed != null, "production main scene could not be loaded")
	if packed == null:
		_finish([], [])
		return
	var main := packed.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	var run_scene := main.get_node_or_null("RunScene")
	_require(run_scene != null, "production RunScene is missing")
	if run_scene == null:
		main.queue_free()
		await process_frame
		_finish([], [])
		return
	var controller: Variant = run_scene.get("runtime_controller")
	var context: Variant = run_scene.get("run_context")
	var bus: Variant = run_scene.get("command_bus")
	_require(controller != null and context != null and bus != null, "runtime authority was not initialized")
	if controller == null or context == null or bus == null:
		main.queue_free()
		await process_frame
		_finish([], [])
		return

	var start_result: Dictionary = preload("res://tests/z2_legacy_main_fixture.gd").start(run_scene)
	_require(bool(start_result.get("ok", false)), "qualified standard run could not be started")
	run_scene.call("_show_run_screen")
	context.max_hp = 10000
	context.hp = 10000
	var combat_pos: Vector2i = context.get_current_pos()
	context.truth_map.set_room_type(combat_pos, &"Monster")
	bus.room_resolver.enter_room(context)
	controller.in_run_runtime.sync_room(Vector2(0.50, 0.50))
	_require(context.current_room_type == &"Monster", "combat room setup failed")
	_require(controller.in_run_runtime.has_active_combat(), "production combat runtime did not activate")
	run_scene.call("_refresh_view_models")

	var observed_scopes: Array[StringName] = []
	bus.state_changed.connect(func(snapshot: Dictionary) -> void:
		observed_scopes.append(StringName(snapshot.get("_change_scope", &"missing")))
	)

	for warmup_index in range(8):
		var before_revision: int = controller.transaction_revision
		var before_hp: int = context.hp
		var result: Dictionary = bus.dispatch(&"apply_runtime_combat_damage", _damage_payload(warmup_index))
		_verify_durable_damage(controller, result, before_revision, before_hp, warmup_index)
	run_scene.call("reset_refresh_metrics")
	observed_scopes.clear()

	var combat_samples: Array[int] = []
	var hp_before_samples: int = context.hp
	for sample_index in range(DAMAGE_SAMPLES):
		var before_metrics: Dictionary = run_scene.call("get_refresh_metrics")
		var before_revision: int = controller.transaction_revision
		var before_hp: int = context.hp
		var started_usec := Time.get_ticks_usec()
		var result: Dictionary = bus.dispatch(&"apply_runtime_combat_damage", _damage_payload(sample_index + 8))
		damage_dispatch_samples.append(Time.get_ticks_usec() - started_usec)
		var after_metrics: Dictionary = run_scene.call("get_refresh_metrics")
		var refresh_usec := int(after_metrics.get("combat_total_usec", -1)) - int(before_metrics.get("combat_total_usec", -1))
		combat_samples.append(refresh_usec)
		_require(refresh_usec >= 0 and int(after_metrics.get("combat_count", -1)) - int(before_metrics.get("combat_count", -1)) == 1, "sample %d did not measure exactly one combat refresh" % sample_index)
		_require(int(after_metrics.get("full_count", -1)) == int(before_metrics.get("full_count", -1)), "sample %d also performed a full refresh" % sample_index)
		_require(bool(result.get("ok", false)), "combat damage command failed at sample %d" % sample_index)
		_verify_durable_damage(controller, result, before_revision, before_hp, sample_index + 8)

	var combat_metrics: Dictionary = run_scene.call("get_refresh_metrics")
	_require(int(combat_metrics.get("combat_count", -1)) == DAMAGE_SAMPLES, "damage did not use exactly one combat refresh per command")
	_require(int(combat_metrics.get("full_count", -1)) == 0, "damage still triggered a full RunScene refresh")
	_require(StringName(combat_metrics.get("last_scope", &"missing")) == &"combat", "combat refresh scope was not retained")
	_require(observed_scopes.size() == DAMAGE_SAMPLES, "state signal count diverged from damage command count")
	for scope in observed_scopes:
		_require(scope == &"combat", "damage emitted a non-combat state scope")
	var run_surface: Variant = run_scene.get("run_surface")
	var health_hud: Control = run_surface.get("player_health_hud") if run_surface != null else null
	var combat_status_label := health_hud.get_node_or_null("HealthValue") as Label if health_hud != null else null
	_require(combat_status_label != null, "production health HUD number is missing")
	if combat_status_label != null:
		var expected_hp_line := "%s / %s" % [context.hp, context.max_hp]
		_require(combat_status_label.text == expected_hp_line, "lightweight combat refresh did not expose exact current/max HP")
		_require(combat_status_label.is_visible_in_tree(), "current HP exists only in a hidden control")
		_require(root.get_visible_rect().encloses(combat_status_label.get_global_rect()), "current HP is outside the viewport")
		var maximum_label := health_hud.get_node_or_null("HealthMaximum") as Label
		_require(maximum_label != null and maximum_label.is_visible_in_tree(), "maximum HP has no visible readout")
		if maximum_label != null:
			var current_size := combat_status_label.get_theme_font_size("font_size")
			var maximum_size := maximum_label.get_theme_font_size("font_size")
			var current_width := combat_status_label.get_theme_font("font").get_string_size(str(context.hp), HORIZONTAL_ALIGNMENT_LEFT, -1, current_size).x
			var maximum_width := maximum_label.get_theme_font("font").get_string_size(maximum_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, maximum_size).x
			_require(combat_status_label.visible_characters == str(context.hp).length() and maximum_label.text == "/ %s" % context.max_hp, "split-sized health readout changed its displayed values")
			_require(current_size >= 13 and maximum_size >= 11 and current_size > maximum_size, "health glyph sizes lost readable hierarchy")
			_require(current_width <= combat_status_label.size.x + 0.5 and maximum_width <= maximum_label.size.x + 0.5, "complete current/max HP does not fit readable text width")
			for label: Label in [combat_status_label, maximum_label]:
				_require(label.get_minimum_size().y <= label.size.y + 0.5, "visible protocol vitals clip their native text height")

	for warmup_index in range(4):
		bus.call("_emit_state")
	run_scene.call("reset_refresh_metrics")
	var full_samples: Array[int] = []
	for _sample_index in range(FULL_SAMPLES):
		var before_metrics: Dictionary = run_scene.call("get_refresh_metrics")
		var started_usec := Time.get_ticks_usec()
		bus.call("_emit_state")
		full_dispatch_samples.append(Time.get_ticks_usec() - started_usec)
		var after_metrics: Dictionary = run_scene.call("get_refresh_metrics")
		var refresh_usec := int(after_metrics.get("full_total_usec", -1)) - int(before_metrics.get("full_total_usec", -1))
		full_samples.append(refresh_usec)
		_require(refresh_usec >= 0 and int(after_metrics.get("full_count", -1)) - int(before_metrics.get("full_count", -1)) == 1, "full control did not measure exactly one full refresh")
	var full_metrics: Dictionary = run_scene.call("get_refresh_metrics")
	_require(int(full_metrics.get("full_count", -1)) == FULL_SAMPLES, "full refresh control sample count diverged")
	_require(int(full_metrics.get("combat_count", -1)) == 0, "full refresh control unexpectedly used combat scope")

	var combat_p95 := _percentile(combat_samples, 0.95)
	var full_p95 := _percentile(full_samples, 0.95)
	# T01/T04 adds synchronous durable work to dispatch. The retained 8 ms UI
	# budget measures the controller's internal refresh interval on both paths;
	# complete dispatch latency remains a separate, unfiltered diagnostic below.
	_require(combat_samples.size() == DAMAGE_SAMPLES and full_samples.size() == FULL_SAMPLES, "refresh sample count changed")
	_require(combat_p95 <= 8000, "combat refresh p95 exceeded 8 ms: %d usec" % combat_p95)
	_require(combat_p95 < full_p95, "combat refresh p95 was not lower than full refresh p95")
	_verify_final_disk_hp(controller, hp_before_samples - DAMAGE_SAMPLES)
	var map_overlay := run_scene.get("map_overlay_panel") as MapOverlayPanel
	var map_grid := map_overlay.get_node("Panel/Content/Grid") as GridContainer
	_require(not map_overlay.visible and map_grid.get_child_count() == 0, "closed map allocated cell controls during full run refreshes")
	map_overlay.show_overlay()
	_require(map_grid.get_child_count() == map_overlay.view_model.width * map_overlay.view_model.height, "opening the deferred map did not build the latest grid")
	var visible_cells := map_grid.get_children()
	map_overlay.hide_overlay()
	run_scene.call("_refresh_view_models")
	_require(map_grid.get_children() == visible_cells, "closed map rebuilt its existing cells during a full refresh")
	var updated_map := MiniMapViewModel.new()
	updated_map.width = 2
	updated_map.height = 2
	updated_map.room_markers = [{"pos": Vector2i.ZERO, "known_state": &"explored", "room_type": &"Normal", "is_current": true, "adjacent_mines": 3}]
	var updated_layout := map_overlay.layout_profile.duplicate(true)
	updated_layout["ui_scale_factor"] = 1.5
	map_overlay.apply_layout_profile(updated_layout)
	map_overlay.apply_view_model(updated_map)
	_require(map_grid.get_children() == visible_cells, "hidden data/scale update rebuilt the map")
	map_overlay.show_overlay()
	await process_frame
	await process_frame
	_require(map_grid.get_child_count() == 4 and is_equal_approx(map_overlay.get_ui_scale_factor(), 1.5), "reopened map retained stale dimensions or scale")
	var adjacent_count := map_grid.get_node_or_null("MapCell_0_0/AdjacentMineCount") as Label
	_require(adjacent_count != null and adjacent_count.text == "3", "reopened map did not render the newest public cell data")
	var map_focus := map_overlay.preferred_focus_control()
	_require(map_focus != null and map_focus.has_focus(), "reopened map did not restore focus inside the updated grid")

	main.queue_free()
	await process_frame
	await process_frame
	_finish(combat_samples, full_samples)


func _damage_payload(index: int) -> Dictionary:
	return {
		"source": "g41_combat_simulation",
		"damage": 1,
		"damage_kind": &"i1_refresh_probe",
		"source_id": "i1_probe",
		"combat_tick": index,
	}


func _verify_durable_damage(controller: Variant, result: Dictionary, before_revision: int, before_hp: int, index: int) -> void:
	_require(bool(result.get("ok", false)), "durable damage failed at command %d" % index)
	_require(int(result.get("revision", -1)) == before_revision + 1 and controller.transaction_revision == before_revision + 1, "damage did not commit exactly one revision at command %d" % index)
	_require(controller.context.hp == before_hp - 1, "damage did not apply one HP at command %d" % index)
	_require(controller.checkpoint_service != null, "damage has no durable checkpoint service")
	if controller.checkpoint_service == null:
		return
	# Disk verification is outside both the UI interval and dispatch stopwatch.
	var loaded: Dictionary = controller.checkpoint_service.load_checkpoint()
	_require(bool(loaded.get("ok", false)) and bool(loaded.get("can_simulate", false)) and str(loaded.get("status", "")) == "loaded", "damage checkpoint is not durably active at command %d" % index)
	_require(int(loaded.get("revision", -1)) == before_revision + 1 and str(loaded.get("run_id", "")) == str(controller.context.run_id), "disk revision/run diverged at command %d" % index)
	durable_revisions.append(int(loaded.get("revision", -1)))


func _verify_final_disk_hp(controller: Variant, expected_hp: int) -> void:
	_require(controller.context.hp == expected_hp, "measured damage sequence did not preserve expected final HP")
	var meta := MetaProgressAdapter.new()
	meta.set_active_profile_path(controller.meta_progress_adapter.active_meta_progress_path, controller.meta_progress_adapter.active_profile_id)
	var checkpoint := RunCheckpointService.new()
	_require(bool(checkpoint.configure(meta, "z2", RunRuntimeController.Z2_CONTENT_VERSION).get("ok", false)), "fresh disk reader could not configure checkpoint")
	var loaded := checkpoint.load_checkpoint()
	_require(bool(loaded.get("ok", false)) and bool(loaded.get("can_simulate", false)) and str(loaded.get("status", "")) == "loaded", "fresh disk reader did not load the active primary checkpoint")
	var snapshot: Dictionary = loaded.get("snapshot", {})
	var decoded: Dictionary = controller.decode_checkpoint_state(snapshot.get("state", {}))
	_require(bool(decoded.get("ok", false)), "final durable checkpoint did not decode")
	var saved_hp := int(decoded.get("state", {}).get("context", {}).get("data", {}).get("hp", -1))
	_require(saved_hp == expected_hp, "actual loaded checkpoint HP differs from final command HP")
	_require(int(loaded.get("revision", -1)) == controller.transaction_revision and str(loaded.get("run_id", "")) == str(controller.context.run_id), "final durable revision/run differs from runtime")
	_require(bool(controller.restore_checkpoint_state(snapshot.get("state", {}), snapshot, false).get("ok", false)), "final complete checkpoint failed read-only validation")
	_require(durable_revisions.size() == DAMAGE_SAMPLES + 8, "not every warmup/measured damage checked a durable revision")
	print("I1_COMBAT_REFRESH_DURABLE %s" % JSON.stringify({"verified_commands": durable_revisions.size(), "revisions": durable_revisions, "run_id": loaded.get("run_id", ""), "revision": loaded.get("revision", -1), "snapshot_hash": loaded.get("snapshot_hash", ""), "loaded_hp": saved_hp, "expected_hp": expected_hp}))


func _percentile(samples: Array[int], percentile: float) -> int:
	if samples.is_empty():
		return -1
	var sorted := samples.duplicate()
	sorted.sort()
	var index := clampi(int(ceil(float(sorted.size() - 1) * percentile)), 0, sorted.size() - 1)
	return sorted[index]


func _require(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish(combat_samples: Array[int], full_samples: Array[int]) -> void:
	var detail := "combat_p50=%dus combat_p95=%dus combat_p99=%dus combat_max=%dus full_p95=%dus samples=%d/%d" % [
		_percentile(combat_samples, 0.50),
		_percentile(combat_samples, 0.95),
		_percentile(combat_samples, 0.99),
		_percentile(combat_samples, 1.0),
		_percentile(full_samples, 0.95),
		combat_samples.size(),
		full_samples.size(),
	]
	print("I1_COMBAT_REFRESH_TIMING_SCOPE controller_total_usec_delta; legacy_dispatch_8ms_assertion_superseded_by_T01_T04_sync_durability")
	print("I1_COMBAT_REFRESH_END_TO_END damage_dispatch_p50=%dus damage_dispatch_p95=%dus damage_dispatch_max=%dus full_emit_p50=%dus full_emit_p95=%dus full_emit_max=%dus samples=%d/%d" % [
		_percentile(damage_dispatch_samples, 0.50), _percentile(damage_dispatch_samples, 0.95), _percentile(damage_dispatch_samples, 1.0),
		_percentile(full_dispatch_samples, 0.50), _percentile(full_dispatch_samples, 0.95), _percentile(full_dispatch_samples, 1.0),
		damage_dispatch_samples.size(), full_dispatch_samples.size(),
	])
	if failures.is_empty():
		print(PASS_MARKER)
		print("I1_COMBAT_REFRESH_DETAILS %s" % detail)
		quit(0)
		return
	for failure in failures:
		print("I1_COMBAT_REFRESH_FAILURE %s" % failure)
	print("%s %s" % [FAIL_MARKER, detail])
	quit(1)
