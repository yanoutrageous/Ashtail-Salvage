extends Control
## Mount z2_notification_queue.tscn in a viewport-sized Control or CanvasLayer.
## Queue entries, including the dedupe keys, live for this instance's lifetime.

signal notification_shown(notice: Dictionary)
signal notification_finished(notice: Dictionary)

const DEFAULT_ICON := preload("res://assets/ui/art25/content/long_term/task/task_first_survey.png")
const RunVectorSkin := preload("res://scripts/ui/run_surface/run_vector_skin.gd")
const StationSkin := preload("res://scripts/ui/shell/station_ui_skin.gd")
const HOLD_SECONDS := 3.4
const TOP := 14.0
const REFERENCE_WIDTH := 616.0 / 1920.0

@onready var _card: PanelContainer = %NotificationCard
@onready var _icon: TextureRect = %NotificationIcon
@onready var _title: Label = %NotificationTitle
@onready var _body: Label = %NotificationBody

var _seen := {}
var _waiting: Array[Dictionary] = []
var _current: Dictionary = {}
var _kind: Label
var _ui_scale_factor := 1.0
var _slide_progress := 0.0


func _ready() -> void:
	var style := RunVectorSkin.frame(RunVectorSkin.STATUS, Vector4(12, 10, 14, 10))
	_card.add_theme_stylebox_override(&"panel", style)
	_kind = Label.new()
	_kind.name = "NotificationKind"
	_kind.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_kind.add_theme_color_override(&"font_color", Color(0.65, 0.74, 0.71))
	_kind.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.get_parent().add_child(_kind)
	_title.get_parent().move_child(_kind, 0)
	_kind.hide()
	for label in [_title, _body]:
		label.add_theme_font_override("font", StationSkin.FONT)
		label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		label.max_lines_visible = -1
	resized.connect(_fit_card)
	_card.minimum_size_changed.connect(_fit_card)
	set_ui_scale_factor(_ui_scale_factor)
	_play_next()


func set_ui_scale_factor(value: float) -> void:
	_ui_scale_factor = clampf(value, 1.0, 1.5)
	if not is_node_ready():
		return
	_title.add_theme_font_size_override(&"font_size", roundi(22.0 * _ui_scale_factor))
	_body.add_theme_font_size_override(&"font_size", roundi(17.0 * _ui_scale_factor))
	_kind.add_theme_font_size_override(&"font_size", roundi(13.0 * _ui_scale_factor))
	_icon.custom_minimum_size = Vector2(48.0, 48.0) * _ui_scale_factor
	_fit_card()


## receipt: {ok: true, committed: true, receipt_id: String}.
## notice: {goal_id: String, tier: int or String, title: String, body?: String, icon?: Texture2D}.
## Use a stable tier per goal (0 for a goal without tiers). Signals carry the notice plus receipt_id.
func enqueue_committed(receipt: Dictionary, notice: Dictionary) -> bool:
	if receipt.get("ok") != true or receipt.get("committed") != true:
		return false
	var receipt_id: Variant = receipt.get("receipt_id")
	var goal_id: Variant = notice.get("goal_id")
	var tier: Variant = notice.get("tier")
	if not _is_id(receipt_id) or not _is_id(goal_id) or not (tier is int or _is_id(tier)):
		return false
	if not _is_id(notice.get("title")):
		return false

	var key := [str(receipt_id), str(goal_id), str(tier)]
	if _seen.has(key):
		return false
	_seen[key] = true
	var entry := notice.duplicate(true)
	entry["receipt_id"] = str(receipt_id)
	_waiting.append(entry)
	_play_next()
	return true


func _play_next() -> void:
	if not is_node_ready() or not _current.is_empty() or _waiting.is_empty():
		return
	_current = _waiting.pop_front()
	_kind.text = {"achievement": "成就达成", "main": "任务完成", "side": "任务完成", "task": "任务完成"}.get(str(_current.get("kind", "")), "")
	_kind.visible = not _kind.text.is_empty()
	_title.text = str(_current.title)
	_body.text = str(_current.get("body", ""))
	_body.visible = not _body.text.is_empty()
	var texture := _current.get("icon") as Texture2D
	_icon.texture = texture if texture != null else DEFAULT_ICON
	_card.modulate.a = 0.0
	_card.show()
	_fit_card()
	await get_tree().process_frame
	_fit_card()
	_slide(0.0)
	_card.modulate.a = 1.0

	var tween := create_tween().set_trans(Tween.TRANS_QUAD)
	tween.tween_method(_slide, 0.0, 1.0, 0.24).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func() -> void: notification_shown.emit(_current.duplicate(true)))
	tween.tween_interval(HOLD_SECONDS)
	tween.tween_method(_slide, 1.0, 0.0, 0.22).set_ease(Tween.EASE_IN)
	tween.tween_callback(_finish_current)


func _finish_current() -> void:
	_card.hide()
	notification_finished.emit(_current.duplicate(true))
	_current = {}
	_play_next()


func _fit_card() -> void:
	if not is_node_ready():
		return
	var width := clampf(size.x * REFERENCE_WIDTH, minf(360.0, size.x - 28.0), size.x - 28.0)
	_card.size = Vector2(width, 0.0)
	_card.position.x = (size.x - _card.size.x) / 2.0
	_slide(_slide_progress)


func _slide(progress: float) -> void:
	_slide_progress = progress
	_card.position.y = lerpf(-_card.size.y - 1.0, TOP, progress)


func _is_id(value: Variant) -> bool:
	return (value is String or value is StringName) and not str(value).strip_edges().is_empty()
