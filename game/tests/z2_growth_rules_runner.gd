extends SceneTree

const RULE_PATH := "res://scripts/core/progression/z2_progression_rules.gd"
var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(ResourceLoader.exists(RULE_PATH), "Z2 independent growth rules exist")
	if ResourceLoader.exists(RULE_PATH):
		var rules = load(RULE_PATH)
		var checkpoints := {2: 30, 3: 60, 4: 110, 5: 160, 6: 230, 10: 510, 11: 610, 15: 1010, 16: 1210, 20: 2010, 21: 2260, 25: 3260, 26: 3560, 30: 4760, 31: 5070, 49: 12360, 50: 12860}
		for level in checkpoints:
			var xp: int = checkpoints[level]
			_check(rules.exp_for_level(level) == xp, "curve threshold Lv%d" % level)
			_check(rules.level_for_exp(xp - 1) == level - 1, "before threshold Lv%d" % level)
			_check(rules.level_for_exp(xp) == level, "at threshold Lv%d" % level)
		_check(rules.level_for_exp(9999999) == 50, "level is capped at 50")
		var cases := [
			["classic_7x7_simple", 1, ""], ["classic_7x7_normal", 3, "classic_7x7_simple"],
			["classic_10x10_easy", 3, ""], ["classic_10x10_standard", 5, "classic_10x10_easy"],
			["classic_10x10_hard", 10, "classic_10x10_standard"], ["classic_13x13_normal", 15, ""],
			["classic_13x13_hard", 20, "classic_13x13_normal"], ["classic_13x13_hell", 25, "classic_13x13_hard"],
		]
		for row in cases:
			var meta := {"profile_level": row[1] - 1, "tutorial_completed": true, "map_success_counts": {row[2]: 1}}
			_check(not rules.map_blockers(meta, row[0]).is_empty(), "%s previous level is locked" % row[0])
			meta.profile_level = row[1]
			_check(rules.map_blockers(meta, row[0]).is_empty(), "%s unlocks at exact threshold" % row[0])
			meta.map_success_counts = {}
			_check(rules.map_blockers(meta, row[0]).is_empty() == (row[2] == ""), "%s predecessor requirement" % row[0])
		var settlement_cases := [
			["tutorial_5x5", 0, 0, 0],
			["classic_7x7_simple", 10, 20, 50], ["classic_7x7_normal", 10, 30, 50],
			["classic_10x10_easy", 10, 50, 100], ["classic_10x10_standard", 12, 70, 120],
			["classic_10x10_hard", 15, 100, 150], ["classic_13x13_normal", 15, 120, 200],
			["classic_13x13_hard", 18, 150, 250], ["classic_13x13_hell", 20, 200, 300],
		]
		for row in settlement_cases:
			var uncapped: Dictionary = rules.settle_scores(row[0], 10, 10, "success")
			_check(uncapped.experience == row[1] and uncapped.talent_points == row[1], "success multiplier " + row[0])
			for ending in ["success", "failure", "abandon"]:
				var capped: Dictionary = rules.settle_scores(row[0], 1000, 1000, ending)
				var factor := 1.0 if ending == "success" else 0.5
				_check(capped.experience == int(row[2] * factor) and capped.talent_points == int(row[3] * factor), "caps and ending ratio " + row[0] + ending)
		var success: Dictionary = rules.settle_scores("classic_10x10_standard", 100, 101, "success")
		_check(success.experience == 70 and success.talent_points == 120, "success caps XP and talent independently")
		for ending in ["failure", "abandon"]:
			var loss: Dictionary = rules.settle_scores("classic_10x10_standard", 100, 101, ending)
			_check(loss.experience == 35 and loss.talent_points == 60, "cap before ending ratio " + ending)
			_check(rules.settle_scores("classic_7x7_simple", 1, 1, ending).talent_points == 1, "genuine one-point progress receives minimum " + ending)
			_check(rules.settle_scores("classic_7x7_simple", 0, 0, ending).talent_points == 0, "empty run grants no points " + ending)
		var events := [
			_event("run_started", {"position": Vector2i.ZERO}),
			_event("room_entered", {"position": Vector2i.ZERO}),
			_event("room_entered", {"position": Vector2i(1, 0)}),
			_event("room_entered", {"position": Vector2i(1, 0)}),
			_event("room_searched", {"position": Vector2i(1, 0), "is_chest": false}),
			_event("room_searched", {"position": Vector2i(1, 0), "is_chest": false}),
			_event("room_searched", {"position": Vector2i(2, 0), "is_chest": true}),
			_event("combat_resolved", {"position": Vector2i(3, 0), "runtime": true}),
			_event("combat_resolved", {"position": Vector2i(3, 0), "runtime": true}),
			_event("combat_resolved", {"position": Vector2i(4, 0), "automatic": true}),
		]
		var facts: Dictionary = rules.score_events(events)
		_check(facts.experience == 10 and facts.talent_points == 7, "facts exclude spawn, repeats and automatic combat")
	print("Z2_GROWTH_RULES checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures:
		print("Z2_GROWTH_RULES_CASE_FAIL " + failure)
	print("Z2_GROWTH_RULES=%s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)


func _event(type: String, payload: Dictionary) -> Dictionary:
	return {"event_type": type, "payload": payload}


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
