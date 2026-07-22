extends Node2D


const SUBDIVISIONS_PER_BEAT: int = 4


@export var metronome_pattern: Array[int] = [4, 2, 2]


@onready var _music_player: AudioStreamPlayer = $MusicPlayer
@onready var _metronome_player: AudioStreamPlayer = $MetronomePlayer


var _next_subdivision_to_handle: int = 0


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	var stream := _music_player.stream as AudioStreamOggVorbis
	if not _music_player.playing or not stream: return

	var subdiv_duration: float = 60.0 / stream.bpm / SUBDIVISIONS_PER_BEAT
	var cur_subdivision: int = floori(_music_player.get_playback_position() / subdiv_duration)

	for i in range(_next_subdivision_to_handle, cur_subdivision + 1):
		_handle_subdivision(i)
		_next_subdivision_to_handle = i + 1

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		_next_subdivision_to_handle = 0
		_music_player.play()

# Handle logic for the passing of the nth subdivision.
func _handle_subdivision(n: int) -> void:
	if not metronome_pattern: return

	var subdivs_per_metronome_cycle: int = metronome_pattern.reduce(func (a: int, b: int) -> int: return a + b, 0)
	var cur_subdiv_in_cycle := n % subdivs_per_metronome_cycle

	var subdiv_target := 0
	for i in metronome_pattern:
		if subdiv_target == cur_subdiv_in_cycle:
			_metronome_player.play()
		subdiv_target += i
