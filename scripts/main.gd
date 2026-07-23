extends Node2D


enum InputAccuracy
{
	EARLY,
	GOOD,
	LATE,
}


const SUBDIVISIONS_PER_BEAT: int = 4


@export var metronome_pattern: Array[int] = [4, 2, 2]
@export var alarm_beep_pattern: Array[int] = [0, 2, 6, 8]
@export var alarm_input_subdivision: int = 12
@export var alarm_start_subdivisions: Array[int] = [1 * 4 * 4, 2 * 4 * 4 + 2, 3 * 4 * 4, 3 * 4 * 4 + 12]
## Maximum time before a subdivision is reached where an input is still considered to have landed on that subdivision.
@export var pre_subdivision_input_leeway: float = 0.05
## Maximum time after a subdivision is reached where an input is still considered to have landed on that subdivision.
@export var post_subdivision_input_leeway: float = 0.05


@onready var _music_player: AudioStreamPlayer = $MusicPlayer
@onready var _metronome_player: AudioStreamPlayer = $MetronomePlayer
@onready var _beep_player: AudioStreamPlayer = $BeepPlayer
@onready var _snooze_player: AudioStreamPlayer = $SnoozePlayer
@onready var _miss_player: AudioStreamPlayer = $MissPlayer


var _next_subdivision_to_handle: int = 0
# Number of times the music has fully played and looped back around.
var _num_music_loops: int = 0
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

		_num_music_loops += 1

	# We do this modulo the subdivisions in the stream to allow looping to work.
	for i in range(_next_subdivision_to_handle % subdivs_in_stream, (cur_subdivision + 1) % subdivs_in_stream):
		_handle_subdivision(_next_subdivision_to_handle)
		_next_subdivision_to_handle += 1

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		_next_subdivision_to_handle = 0
		_num_music_loops = 0
		_music_player.play()
	elif event.is_action_pressed("snooze"):
		if _alarm_start_subdiv >= 0:
			var cur_total_playback_time := _get_total_playback_time()
			match _get_accuracy(_alarm_start_subdiv + alarm_input_subdivision, cur_total_playback_time):
				InputAccuracy.GOOD:
					_snooze_player.play(0.15)
				_:
					_miss_player.play()
		else:
			_miss_player.play()

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

# Get the total amount of playback time since the current music was started (this accounts for loops).
func _get_total_playback_time() -> float:
	var stream := _music_player.stream as AudioStreamOggVorbis
	if not stream: return 0.0

	var subdiv_duration: float = 60.0 / stream.bpm / SUBDIVISIONS_PER_BEAT
	var stream_loop_duration: float = 60.0 / stream.bpm * stream.beat_count

	var subdiv_total_playback_time: float = max(0, _next_subdivision_to_handle - 1) * subdiv_duration
	# This might not be wrong if we just looped and have not handled the loop yet in `_process`.
	var prospective_loop_playback_time: float = _num_music_loops * stream_loop_duration + _music_player.get_playback_position()

	if prospective_loop_playback_time < subdiv_total_playback_time:
		# A loop has happened, but has not been processed yet, so we just add it manually.
		return prospective_loop_playback_time + stream_loop_duration
	else:
		return prospective_loop_playback_time

# Used to determine whether an input successfully hit a certain beat subdivision.
func _get_accuracy(target_subdivision: int, input_total_playback_time: float) -> InputAccuracy:
	var stream := _music_player.stream as AudioStreamOggVorbis
	if not stream: return InputAccuracy.GOOD

	var subdiv_duration: float = 60.0 / stream.bpm / SUBDIVISIONS_PER_BEAT
	var target_total_playback_time: float = target_subdivision * subdiv_duration

	if input_total_playback_time < target_total_playback_time - pre_subdivision_input_leeway:
		return InputAccuracy.EARLY
	elif input_total_playback_time > target_total_playback_time + post_subdivision_input_leeway:
		return InputAccuracy.LATE
	else:
		return InputAccuracy.GOOD
