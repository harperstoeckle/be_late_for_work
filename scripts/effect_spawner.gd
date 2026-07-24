class_name EffectSpawner
extends Node2D
## Instantiates a scene at this node, and deletes it after a set time.


@export var scene: PackedScene
## Time in seconds from spawning an effect before it is freed.
@export var free_delay: float = 1
@export var retain_effect_spawn_transform: bool = true


# So we can continuously keep the global transform of the effects the same.
var _effect_node_to_transform: Dictionary[Node2D, Transform2D] = {}


func spawn() -> void:
	if not scene: return

	var node := scene.instantiate() as Node2D
	if not node: return

	add_child(node)
	_effect_node_to_transform[node] = node.global_transform

	get_tree().create_timer(free_delay).timeout.connect(func() -> void:
		node.queue_free()
		_effect_node_to_transform.erase(node))

func _process(_delta: float) -> void:
	if not retain_effect_spawn_transform: return

	# We want effects to maintain their global transforms from when they were first created. We
	# *could* do this by just setting them as top-level, but this would mess up their draw order,
	# so we update them manually instead.
	for node: Node2D in _effect_node_to_transform:
		node.global_transform = _effect_node_to_transform[node]
