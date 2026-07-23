extends Node2D


const SUBDIVISIONS_PER_BEAT: int = 4


@export var metronome_pattern: Array[int] = [4, 2, 2]
@export var alarm_beep_pattern: Array[int] = [0, 2, 6, 8]
@export var alarm_start_subdivisions: Array[int] = [2 * 4 * 4, 4 * 4 * 4 + 2]


@onready var _music_player: AudioStreamPlayer = $MusicPlayer
@onready var _metronome_player: AudioStreamPlayer = $MetronomePlayer
@onready var _beep_player: AudioStreamPlayer = $BeepPlayer
@onready var _snooze_player: AudioStreamPlayer = $SnoozePlayer


var _next_subdivision_to_handle: int = 0
var _alarm_start_subdiv: int = -1


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	var stream := _music_player.stream as AudioStreamOggVorbis
	if not _music_player.playing or not stream: return

	var subdiv_duration: float = 60.0 / stream.bpm / SUBDIVISIONS_PER_BEAT
	var cur_subdivision: int = floori(_music_player.get_playback_position() / subdiv_duration)
	var subdivs_in_stream: int = stream.beat_count * SUBDIVISIONS_PER_BEAT

	# At most, `_next_subdivision_to_handle` (modulo `subdivs_in_stream`) should be one above
	# `cur_subdivision`if we just handled the current subdivision and haven't moved on yet. If
	# `cur_subdivision` is less than that, then the music has looped back to an earlier position,
	# which means we need to first handle all remaining subdivisions from the previous loop.
	if cur_subdivision + 1 < _next_subdivision_to_handle % subdivs_in_stream:
		for i in range(_next_subdivision_to_handle % subdivs_in_stream, subdivs_in_stream):
			_handle_subdivision(_next_subdivision_to_handle)
			_next_subdivision_to_handle += 1

	# We do this modulo the subdivisions in the stream to allow looping to work.
	for i in range(_next_subdivision_to_handle % subdivs_in_stream, (cur_subdivision + 1) % subdivs_in_stream):
		_handle_subdivision(_next_subdivision_to_handle)
		_next_subdivision_to_handle += 1

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		_next_subdivision_to_handle = 0
		_music_player.play()
	elif event.is_action_pressed("snooze"):
		_snooze_player.play(0.15)

# Handle logic for the passing of the nth subdivision.
func _handle_subdivision(n: int) -> void:
	if n % (4 * SUBDIVISIONS_PER_BEAT) == 0:
		print("Measure %s" % (n / (4 * SUBDIVISIONS_PER_BEAT)))
	if not metronome_pattern: return

	var subdivs_per_metronome_cycle: int = metronome_pattern.reduce(func (a: int, b: int) -> int: return a + b, 0)
	var cur_subdiv_in_cycle := n % subdivs_per_metronome_cycle

	var subdiv_target := 0
	for i in metronome_pattern:
		if subdiv_target == cur_subdiv_in_cycle:
			_metronome_player.play()
		subdiv_target += i

	if n in alarm_start_subdivisions:
		_alarm_start_subdiv = n

	_handle_alarm(n)

func _handle_alarm(subdiv: int) -> void:
	if _alarm_start_subdiv < 0: return

	if subdiv - _alarm_start_subdiv in alarm_beep_pattern:
		_beep_player.play()
