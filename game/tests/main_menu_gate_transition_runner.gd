extends SceneTree

const GATE_PATH := "BackgroundRoot/MainMenuSceneCleanPlate"
const CHARACTER_PATH := "CharacterRoot/MainMenuCharacter"

var failures: Array[String] = []
var output_dir := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			output_dir = argument.trim_prefix("--capture-dir=")
	root.position = Vector2i(-3000, -3000)
	root.size = Vector2i(1280, 720)

	var menu := load("res://scripts/ui/main_menu/main_menu_shell.gd").new() as Control
	root.add_child(menu)
	menu.call("build")
	menu.call("set_reduced_motion_enabled", false)
	menu.set_process(false)
	await process_frame
	var backdrop := menu.get_node(GATE_PATH) as TextureRect
	var character := menu.get_node(CHARACTER_PATH) as TextureRect
	var base_position := character.position
	var shadow := menu.get_node("CharacterRoot/MainMenuCharacterShadow") as TextureRect
	var base_shadow_position := shadow.position
	var base_shadow_modulate := shadow.modulate
	var overlay := menu.get_node("OverlayRoot/MainMenuSceneTransition") as ColorRect
	var gate := backdrop.material as ShaderMaterial
	_check(gate != null, "Production lobby art needs an independent gate animation")
	_check(_lift(gate) == 0.0, "Gate should be closed before starting")
	await _capture("00_idle")

	_check(menu.call("play_navigation_transition", 1, &"enter_cave", &"deploy", false), "Enter-cave transition did not start")
	menu.set_process(false)
	menu.call("_process", 0.12)
	var early_lift := _lift(gate)
	_check(early_lift > 0.0 and character.position == base_position, "Gate should begin lifting before the character approaches")
	await _capture("01_gate_starts")

	menu.call("_process", 0.20)
	var middle_lift := _lift(gate)
	_check(middle_lift > early_lift and character.position.y < base_position.y and character.modulate.a > 0.9, "Character should approach the moving gate in view")
	await _capture("02_approach")
	menu.call("_process", 0.18)
	_check(is_equal_approx(_lift(gate), 1.0) and character.modulate.a > 0.0 and overlay.color.a < 0.5, "Gate should be fully open while the character is visible")
	await _capture("03_open")
	menu.call("_process", 0.09)
	await _capture("04_crossing")

	_check(menu.call("cancel_navigation_transition", 1), "Active gate transition did not cancel")
	_check(_lift(gate) == 0.0 and character.position == base_position and not overlay.visible, "Cancel should restore the closed gate and idle pose")
	_check(shadow.position == base_shadow_position and shadow.modulate == base_shadow_modulate, "Cancel should restore the original idle shadow")
	await _capture("05_cancelled")
	_check(menu.call("play_navigation_transition", 2, &"enter_cave", &"deploy", false), "Transition did not retry after cancel")
	menu.set_process(false)
	_check(_lift(gate) == 0.0, "Retry inherited the previous gate pose")
	menu.call("_process", 0.32)
	_check(is_equal_approx(_lift(gate), middle_lift), "Retry did not replay the same opening")

	menu.call("set_reduced_motion_enabled", true)
	_check(not menu.get("transition_active") and _lift(gate) == 1.0 and overlay.color.a == 1.0, "Mid-transition reduced motion should snap to the covered end pose")
	_check(menu.call("cancel_navigation_transition", 2), "Completed presenter should reset when asked")
	_check(menu.call("play_navigation_transition", 3, &"enter_cave", &"deploy", true), "Reduced-motion transition did not start")
	_check(not menu.get("transition_active") and _lift(gate) == 1.0 and overlay.color.a == 1.0, "Reduced motion should apply only the covered end pose")
	menu.call("set_page_active", false)
	_check(_lift(gate) == 0.0, "Leaving the page should reset the gate")

	menu.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	print("MAIN_MENU_GATE_TRANSITION=%s failures=%d native_capture=%s" % ["PASS" if failures.is_empty() else "FAIL", failures.size(), not output_dir.is_empty()])
	quit(0 if failures.is_empty() else 1)


func _lift(gate: ShaderMaterial) -> float:
	if gate == null:
		return 0.0
	var lift: Variant = gate.get_shader_parameter(&"gate_lift")
	return float(lift) if lift is float else -1.0


func _capture(stem: String) -> void:
	if output_dir.is_empty():
		return
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		_check(false, "Native framebuffer unavailable")
		return
	_check(image.save_png(output_dir.path_join(stem + ".png")) == OK, "Could not capture " + stem)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
