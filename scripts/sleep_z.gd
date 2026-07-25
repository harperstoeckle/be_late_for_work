class_name SleepZ
extends Node2D


@export var bob_vec: Vector2 = Vector2(0, 10)
@export var bob_phase: float = 0
@export var bob_speed: float = 1


@onready var _animation_player: AnimationPlayer = $AnimationPlayer
@onready var _original_position := global_position

var _bob_angle := 0.0


func _process(delta: float) -> void:
	_bob_angle = wrapf(_bob_angle + delta * bob_speed, 0.0, 2 * PI)
	global_position = _original_position + sin(_bob_angle + bob_phase) * bob_vec

func pop() -> void:
	_animation_player.play("pop")

func unpop() -> void:
	_animation_player.play("RESET")
