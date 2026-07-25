class_name Main
extends Node2D


enum InputAccuracy
{
	EARLY,
	GOOD,
	LATE,
}


# This should maybe change depending on the music, but there's not time for that.
const BEATS_PER_MEASURE: int = 4
const SUBDIVISIONS_PER_BEAT: int = 4


@export var alarm_beep_pattern: Array[int] = [0, 2, 6, 8]
@export var alarm_input_subdivision: int = 10
@export var alarm_start_subdivisions: Array[int] = [
	_subdiv(1),
	_subdiv(2, 0, 2),
	_subdiv(3),
	_subdiv(3, 3),
]
## Maximum time before a subdivision is reached where an input is still considered to have landed on that subdivision.
@export var pre_subdivision_input_leeway: float = 0.05
## Maximum time after a subdivision is reached where an input is still considered to have landed on that subdivision.
@export var post_subdivision_input_leeway: float = 0.05
@export var arm_retract_delay: float = 0.1
@export var arm_retract_duration: float = 0.1
@export var snooze_button_hand_offset: Vector2 = Vector2(20, -20)
@export var dialogue_time_per_character: float = 1 / 30.0
@export var music_fade_time: float = 0.05


@onready var _music_player: AudioStreamPlayer = $MusicPlayer
@onready var _snooze_player: AudioStreamPlayer = $SnoozePlayer
@onready var _miss_player: AudioStreamPlayer = $MissPlayer
@onready var _alarm_clock: AlarmClock = $AlarmClock
@onready var _arm_border: Line2D = %ArmBorder
@onready var _arm_inside: Line2D = %ArmInside
@onready var _default_hand_ref: Node2D = %DefaultHandRef
@onready var _dialogue_box: PanelContainer = %DialogueBox
@onready var _dialogue_label: RichTextLabel = %DialogueLabel
@onready var _dialogue_blip_player: AudioStreamPlayer = $DialogueBlipPlayer

@onready var _global_hand_pos := _arm_border.to_global(_arm_border.points[1]) :
	set(v):
		_global_hand_pos = v
		_arm_border.set_point_position(1, _arm_border.to_local(_global_hand_pos))
		_arm_inside.set_point_position(1, _arm_inside.to_local(_global_hand_pos))

@onready var _default_music_volume_linear := _music_player.volume_linear


var _next_subdivision_to_handle: int = 0
# Number of times the music has fully played and looped back around.
var _num_music_loops: int = 0
var _alarm_start_subdiv: int = -1
var _arm_tween: Tween
var _music_bpm: int = 120
var _music_beat_count: int = 0
var _music_fade_tween: Tween

var _checkpoint_next_subdivision: int = 0
var _checkpoint_num_loops: int = 0

var _time_since_current_dialogue_box_shown: float = 0.0
# Dialogue to be shown in the current sequence.
var _queued_dialogue: Array[String] = []
var _story_index: int = 0

# Sorted in order of start time.
var _queued_events: Array[Event] = []
# Events being actively updated.
var _active_events: Array[Event] = []


func _ready() -> void:
	var stream := _music_player.stream as AudioStreamOggVorbis
	if stream:
		_music_bpm = max(stream.bpm, 1)
		_music_beat_count = stream.beat_count
		if _music_beat_count <= 0:
			_music_beat_count = floori(stream.get_length() / 60.0 * _music_bpm)

	_do_next_story()



# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if _is_showing_dialogue() and not _is_dialogue_fully_visible():
		_time_since_current_dialogue_box_shown += delta
		var prev_visible_chars := _dialogue_label.visible_characters
		_dialogue_label.visible_characters = min(_dialogue_label.get_total_character_count(), _time_since_current_dialogue_box_shown / dialogue_time_per_character)

		if prev_visible_chars != _dialogue_label.visible_characters:
			_dialogue_blip_player.play()

	if not _music_player.playing: return

	var subdiv_duration: float = 60.0 / _music_bpm / SUBDIVISIONS_PER_BEAT
	var cur_subdivision: int = floori(_music_player.get_playback_position() / subdiv_duration)
	var subdivs_in_stream: int = _music_beat_count * SUBDIVISIONS_PER_BEAT

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
		if _is_showing_dialogue():
			if not _is_dialogue_fully_visible():
				# Skip dialogue if it's not finished being displayed.
				_dialogue_label.visible_ratio = 1.0
			else:
				_continue_dialogue()
	elif event.is_action_pressed("snooze"):
		if _arm_tween: _arm_tween.kill()
		_arm_tween = get_tree().create_tween()
		_global_hand_pos = _alarm_clock.global_position + snooze_button_hand_offset
		_arm_tween.tween_property(self, "_global_hand_pos", _default_hand_ref.global_position, arm_retract_duration) \
			.set_ease(Tween.EASE_IN) \
			.set_delay(arm_retract_delay)

		if _alarm_start_subdiv >= 0:
			var cur_total_playback_time := _get_total_playback_time()
			match _get_accuracy(_alarm_start_subdiv + alarm_input_subdivision, cur_total_playback_time):
				InputAccuracy.GOOD:
					_snooze_player.play(0.15)
				_:
					_miss_player.play()
		else:
			_miss_player.play()
	elif event.is_action_pressed("ui_up"):
		_save_checkpoint()
	elif event.is_action_pressed("ui_down"):
		_load_checkpoint()

# Handle logic for the passing of the nth subdivision.
func _handle_subdivision(n: int) -> void:
	if _is_showing_dialogue(): return

	_active_events = _active_events.filter(func (e: Event) -> bool: return not e.is_done(n))

	var num_events_to_remove := 0
	for e in _queued_events:
		if e.start_subdivision == n:
			e.start(self)
			if not e.is_done(n): _active_events.push_back(e)
			num_events_to_remove += 1
		else:
			break

	_queued_events = _queued_events.slice(num_events_to_remove)

	for e in _active_events:
		e.handle_subdivision(self, n)

	if n % (4 * SUBDIVISIONS_PER_BEAT) == 0:
		print("Measure %s" % (n / (4 * SUBDIVISIONS_PER_BEAT)))

	if n in alarm_start_subdivisions:
		_alarm_start_subdiv = n

	_handle_alarm(n)

func _handle_alarm(subdiv: int) -> void:
	if _alarm_start_subdiv < 0: return

	if subdiv - _alarm_start_subdiv in alarm_beep_pattern:
		_alarm_clock.beep()

# Get the total amount of playback time since the current music was started (this accounts for loops).
func _get_total_playback_time() -> float:
	var stream := _music_player.stream as AudioStreamOggVorbis
	if not stream: return 0.0

	var subdiv_duration: float = 60.0 / _music_bpm / SUBDIVISIONS_PER_BEAT
	var stream_loop_duration: float = 60.0 / _music_bpm * _music_beat_count

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
	var subdiv_duration: float = 60.0 / _music_bpm / SUBDIVISIONS_PER_BEAT
	var target_total_playback_time: float = target_subdivision * subdiv_duration

	if input_total_playback_time < target_total_playback_time - pre_subdivision_input_leeway:
		return InputAccuracy.EARLY
	elif input_total_playback_time > target_total_playback_time + post_subdivision_input_leeway:
		return InputAccuracy.LATE
	else:
		return InputAccuracy.GOOD

func _subdiv(measure: int, beat: int = 0, subdiv: int = 0) -> int:
	return (measure * BEATS_PER_MEASURE + beat) * SUBDIVISIONS_PER_BEAT + subdiv

# Get the subdivision of the start of the next measure. Useful when scheduling future event when the music is still playing.
func _next_measure_subdiv() -> int:
	var m: int = BEATS_PER_MEASURE * SUBDIVISIONS_PER_BEAT
	var cur_subdiv: int = max(0, _next_subdivision_to_handle - 1)

	var remainder := cur_subdiv % m
	if remainder == 0:
		return cur_subdiv
	else:
		return cur_subdiv + m - remainder

func _save_checkpoint() -> void:
	_checkpoint_num_loops = _num_music_loops
	_checkpoint_next_subdivision = _next_subdivision_to_handle

func _load_checkpoint() -> void:
	_num_music_loops = _checkpoint_num_loops
	_next_subdivision_to_handle = _checkpoint_next_subdivision
	_alarm_start_subdiv = -1

	if _music_beat_count > 0:
		var music_subdiv: int = max(0, _next_subdivision_to_handle - 1) % (_music_beat_count * SUBDIVISIONS_PER_BEAT)
		_music_player.seek(music_subdiv * 60.0 / _music_bpm / SUBDIVISIONS_PER_BEAT)

func _show_dialogue(text: String) -> void:
	_dialogue_box.show()
	_dialogue_label.text = text
	_dialogue_label.visible_characters = 0
	_time_since_current_dialogue_box_shown = 0.0

func _is_showing_dialogue() -> bool:
	return _dialogue_box.visible

func _is_dialogue_fully_visible() -> bool:
	return is_equal_approx(_dialogue_label.visible_ratio, 1.0)

# Will close the dialogue box if no dialogue is left, or will go to the next one if it is available.
func _continue_dialogue() -> void:
	if _queued_dialogue:
		_show_dialogue(_queued_dialogue[0])
		_queued_dialogue.remove_at(0)
	elif _is_showing_dialogue():
		_dialogue_box.hide()
		_do_next_story()

# All of these will be shown in order. Any currently queued dialogue will be canceled.
func _queue_dialogue_sequence(texts: Array[String]) -> void:
	_queued_dialogue.assign(texts)
	_continue_dialogue()

func _fade_in_music() -> void:
	if _music_fade_tween: _music_fade_tween.kill()
	_music_player.volume_linear = 0.0
	_music_fade_tween = get_tree().create_tween()
	_music_fade_tween.tween_property(_music_player, "volume_linear", _default_music_volume_linear, music_fade_time)

func _queue_event(event: Event) -> void:
	# Insert the event in sorted order.
	var idx := _queued_events.bsearch_custom(event,
		func (a: Event, b: Event) -> bool: return a.start_subdivision < b.start_subdivision,
		false)
	_queued_events.insert(idx, event)

# Call `_do_next_story` at `subdiv`.
func _queue_next_story(subdiv: int) -> void:
	_queue_event(NextStoryEvent.new(subdiv))

# Start the next story sequence.
func _do_next_story() -> void:
	# Toby Fox-type dialogue handling.
	match _story_index:
		0:
			_alarm_clock.set_time_left(10)
			_queue_dialogue_sequence([
				"My alarm is about to go off",
				"I don't want to go to work, though, so I want to snooze it instead",
				"press [j] at just the right time after the alarm beeps to snooze it",
			])

			_story_index = 1
		1:
			_next_subdivision_to_handle = 0
			_num_music_loops = 0
			_fade_in_music()
			_music_player.play()
			_queue_next_story(_subdiv(6))
			_story_index = 2
		2:
			_music_player.stream_paused = true
			_queue_dialogue_sequence([
				"Good job",
			])
			_story_index = 3
		3:
			_music_player.stream_paused = false
			# Wait two measures after the start of the next measure.
			_queue_next_story(_next_measure_subdiv() + _subdiv(2))
			_story_index = 4
		4:
			_queue_dialogue_sequence(["You're done now"])


## A thing that happens to the beat at some subdivision.
@abstract class Event:
	# The subdivision at which this event will become active.
	var start_subdivision: int = 0


	func handle_subdivision(main: Main, subdiv: int) -> void: pass
	## Called when this event's start subdivision is reached. We don't need to pass the subdivision to it, because it would always be equal to [member start_subdivision].
	func start(main: Main) -> void: pass

	## Returns true if this event can be removed from the active event list at subdivision [param subdiv]. If this is true, then this event will not be updated at [param subdiv].
	func is_done(subdiv: int) -> bool: return true

## Runs the next bit of story code.
class NextStoryEvent extends Event:
	func _init(p_start_subdivision: int) -> void:
		start_subdivision = p_start_subdivision
	func start(main: Main) -> void:
		print("Doing story %s" % main._story_index)
		main._do_next_story()
