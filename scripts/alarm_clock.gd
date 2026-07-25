class_name AlarmClock
extends Node2D


@onready var _beep_player: AudioStreamPlayer2D = $BeepPlayer
@onready var _beep_effect_spawner: EffectSpawner = %BeepEffectSpawner
@onready var _indicator_label: Label = $IndicatorLabel
@onready var _countdown: Node2D = $Countdown
@onready var _tick_player: AudioStreamPlayer2D = $TickPlayer
@onready var _snooze_player: AudioStreamPlayer2D = $SnoozePlayer
# Digit labels.
@onready var _d_0: Label = %D0
@onready var _d_1: Label = %D1
@onready var _d_2: Label = %D2
@onready var _d_3: Label = %D3


func beep() -> void:
	_beep_player.play()
	_beep_effect_spawner.spawn()

func tick() -> void:
	_tick_player.play()

func snooze() -> void:
	_snooze_player.play(0.15)

func set_time_left(seconds: int) -> void:
	_indicator_label.hide()
	_countdown.show()

	var mins: int = min(99, seconds / 60)
	var secs: int = seconds % 60

	_d_0.text = ""
	_d_1.text = ""
	_d_2.text = ""
	_d_3.text = ""

	if mins > 0:
		var mins_text := "%s" % min
		if mins_text.length() >= 1:
			_d_1.text = mins_text[mins_text.length() - 1]
		if mins_text.length() >= 2:
			_d_0.text = mins_text[0]
		_d_2.text = "0"
		_d_3.text = "0"

	if secs > 0:
		var secs_text := "%s" % secs
		if secs_text.length() >= 1:
			_d_3.text = secs_text[secs_text.length() - 1]
		if secs_text.length() >= 2:
			_d_2.text = secs_text[0]

func set_indicator_text(text: String) -> void:
	_indicator_label.show()
	_countdown.hide()
	_indicator_label.text = text
