extends RefCounted
class_name Z2OpeningOffer

# Pure meta reducer. The parent saves candidate meta + action receipt atomically.
# `meta.gold` in the candidate is already debited; expense is a report, not an
# instruction to charge again. A discarded candidate has no external effects.
const KEY := "z2_opening_offer"
const IDS := ["mine_pressure", "rebate", "avoidance", "power_life", "status_clear", "sacrifice", "forced_cash", "dismantle", "auto_clear"]
const LABELS := ["雷压交换", "达标返款", "避战蓄势", "战力换生命", "状态清空", "削命强攻", "强制变现", "现场拆件", "清场换空箱"]
const DESCRIPTIONS := [
	"前3次实际触雷将原＋10压力改为－10；每次开箱额外＋4压力。",
	"累计毛入账80黑币返50安全金币；此前每累计5黑币尝试扣2，80门槛先停止；不足2整笔跳过且不欠费。",
	"前8个新房每间积累初始战力的2.5%，上限20%；蓄势时不能攻击，可提前结束并保留已积累加成。",
	"最大生命增加冻结出发战力的50%，战力减少其10%；可主动解除一次，两项同时结束，不额外治疗。",
	"同时持有3种不同临时状态时清除全部正负临时状态，每局一次。",
	"不同普通战斗房实际清场后战力＋2、最大生命－5，最多6次；无法支付生命上限则不触发。",
	"战利品背包容量＋40%；首次严格超过80%且有可兑现战利品时按60%价值变现，撤销扩容并处理超重。",
	"最多拆3件非装备战利品为扫描或破机关工具；后者门槛－3，每次实际使用工具＋4压力。",
	"前2个普通战斗房自动清场，不给该房战利品或清场成长；首个宝箱为空。",
]


static func public_state(meta: Dictionary) -> Dictionary:
	var offer: Dictionary = meta.get(KEY, {}).duplicate(true) if meta.get(KEY, {}) is Dictionary else {}
	offer.erase("receipts")
	return offer


static func execute(meta: Dictionary, action: String, payload: Dictionary = {}, seed: int = 0, run_offer: Dictionary = {}) -> Dictionary:
	if meta.get("ruleset_id", "") != "z2" or meta.get("z2_progression_version", 0) != 1:
		return _failure(meta, "z2_profile_required")
	if not meta.get("talent_flags", []) is Array or not meta.get("talent_flags", []).has("z2_talent_15"):
		return _failure(meta, "first_batch_locked")
	if not _natural(meta.get("gold")) or not _natural(meta.get("run_count")) or str(meta.get("profile_id", "")).is_empty():
		return _failure(meta, "invalid_meta_balance_or_identity")
	if not run_offer.is_empty():
		var admission: Dictionary = meta.get("admission", {})
		if action != "refresh" or admission.get("phase") != "active" or str(admission.get("run_id")) != str(payload.get("run_id")) or not valid_offer(run_offer):
			return _failure(meta, "active_opening_required")
	elif not meta.get("admission", {}) is Dictionary or not meta.get("admission", {}).is_empty():
		return _failure(meta, "departure_in_progress")
	var request_id := str(payload.get("request_id", ""))
	if request_id.is_empty():
		return _failure(meta, "request_id_required")
	var key := str(meta.profile_id) + ":opening:" + str(int(meta.run_count))
	var candidate := meta.duplicate(true)
	if not run_offer.is_empty():
		key = str(run_offer.offer_key)
		candidate[KEY] = run_offer.duplicate(true)
	if not candidate.get(KEY, {}) is Dictionary:
		return _failure(meta, "invalid_saved_offer")
	var offer: Dictionary = candidate.get(KEY, {}).duplicate(true)
	if not offer.is_empty() and not valid_offer(offer):
		return _failure(meta, "invalid_saved_offer")
	var request := {"action": action, "payload": payload.duplicate(true)}
	if not offer.is_empty() and str(offer.offer_key) == key and offer.get("receipts", {}).has(request_id):
		if offer.receipts[request_id] != request:
			return _failure(meta, "request_id_conflict")
		return _success(candidate, 0, true)
	var expense := 0
	if action == "prepare":
		if offer.is_empty() or str(offer.offer_key) != key:
			offer = initial_offer(key, key.hash() if seed == 0 else seed)
	else:
		if offer.is_empty() or str(offer.offer_key) != key:
			return _failure(meta, "requires_prepare")
		if str(offer.status) != "offered":
			return _failure(meta, "choice_closed")
		if action != "skip" and str(payload.get("offer_id", "")) != str(offer.offer_id):
			return _failure(meta, "stale_offer")
		match action:
			"refresh":
				if int(offer.refresh_count) >= 10:
					return _failure(meta, "refresh_limit")
				expense = (int(offer.refresh_count) + 1) * 5
				if int(candidate.gold) < expense:
					return _failure(meta, "insufficient_meta_gold")
				candidate.gold = int(candidate.gold) - expense
				offer.refresh_count = int(offer.refresh_count) + 1
				offer.paid_gold = int(offer.paid_gold) + expense
				_set_draw(offer)
			"choose":
				var selected := str(payload.get("effect_id", ""))
				if not offer.candidates.has(selected):
					return _failure(meta, "effect_not_offered")
				offer.selected = selected
				offer.status = "selected"
			"skip":
				offer.status = "skipped"
			_:
				return _failure(meta, "unknown_action")
	if not offer.has("receipts"):
		offer.receipts = {}
	offer.receipts[request_id] = request
	candidate[KEY] = offer
	return _success(candidate, expense)


static func initial_offer(key: String, seed: int) -> Dictionary:
	var offer := {"version": 1, "batch": 1, "offer_key": key, "seed": seed,
		"refresh_count": 0, "paid_gold": 0, "status": "offered", "selected": "", "receipts": {}}
	_set_draw(offer)
	return offer


static func draw_candidates(offer_key: String, seed: int, refresh_count: int) -> Array:
	if offer_key.is_empty() or refresh_count < 0 or refresh_count > 10:
		return []
	var previous: Array = []
	for refresh in range(refresh_count + 1):
		var rng := RandomNumberGenerator.new()
		rng.seed = (offer_key + ":" + str(seed) + ":" + str(refresh)).hash()
		var pool := IDS.duplicate()
		var drawn: Array = []
		for i in range(3):
			var index := rng.randi_range(0, pool.size() - 1)
			drawn.append(pool[index])
			pool.remove_at(index)
		if drawn == previous:
			drawn[2] = pool[0]
		previous = drawn
	return previous


static func valid_offer(value: Variant, require_final: bool = false) -> bool:
	if not value is Dictionary:
		return false
	var o: Dictionary = value
	if o.get("version") != 1 or o.get("batch") != 1 or not o.get("offer_key") is String or o.offer_key.is_empty():
		return false
	if not _integer(o.get("seed")) or not _natural(o.get("refresh_count")) or int(o.refresh_count) > 10 or not _natural(o.get("paid_gold")):
		return false
	var count := int(o.refresh_count)
	if int(o.paid_gold) != count * (count + 1) * 5 / 2 or str(o.get("offer_id", "")) != str(o.offer_key) + ":" + str(count):
		return false
	if not o.get("candidates") is Array or o.candidates != draw_candidates(o.offer_key, int(o.seed), count):
		return false
	var status := str(o.get("status", ""))
	if not status in ["offered", "selected", "skipped"] or (require_final and status == "offered"):
		return false
	if not o.get("selected") is String or (status == "selected" and not o.candidates.has(o.selected)) or (status != "selected" and o.selected != ""):
		return false
	return o.get("receipts", {}) is Dictionary


static func _set_draw(offer: Dictionary) -> void:
	offer.candidates = draw_candidates(str(offer.offer_key), int(offer.seed), int(offer.refresh_count))
	offer.offer_id = str(offer.offer_key) + ":" + str(int(offer.refresh_count))


static func _integer(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and floor(float(value)) == float(value) and absf(float(value)) <= 9007199254740991.0


static func _natural(value: Variant) -> bool:
	return _integer(value) and float(value) >= 0.0


static func _success(meta: Dictionary, amount: int, duplicate: bool = false) -> Dictionary:
	return {"ok": true, "meta": meta, "offer": public_state(meta), "expense": {"currency": "meta_gold", "amount": amount}, "duplicate": duplicate}


static func _failure(meta: Dictionary, reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "meta": meta.duplicate(true), "expense": {"currency": "meta_gold", "amount": 0}}
