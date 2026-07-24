class_name AlarmClock
extends Node2D


@onready var _beep_player: AudioStreamPlayer2D = $BeepPlayer
@onready var _beep_effect_spawner: EffectSpawner = %BeepEffectSpawner


func beep() -> void:
	_beep_player.play()
	_beep_effect_spawner.spawn()
