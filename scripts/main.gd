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


## Maximum time before a subdivision is reached where an input is still considered to have landed on that subdivision.
@export var pre_subdivision_input_leeway: float = 0.05
## Maximum time after a subdivision is reached where an input is still considered to have landed on that subdivision.
@export var post_subdivision_input_leeway: float = 0.05
@export var arm_retract_delay: float = 0.1
@export var arm_retract_duration: float = 0.1
@export var dialogue_time_per_character: float = 1 / 30.0
@export var music_fade_time: float = 0.05
## Hit vfx (when hitting or missing a note) will appear at a random point within this radius about where the hand hits.
@export var hit_effect_radius: float = 20


@onready var _music_player: AudioStreamPlayer = $MusicPlayer
@onready var _miss_player: AudioStreamPlayer = $MissPlayer
@onready var _alarm_clock: AlarmClock = $AlarmClock
@onready var _alarm_clock_2: AlarmClock = $AlarmClock2
@onready var _alarm_clock_3: AlarmClock = $AlarmClock3
@onready var _arm_border: Line2D = %ArmBorder
@onready var _arm_inside: Line2D = %ArmInside
@onready var _default_hand_ref: Node2D = %DefaultHandRef
@onready var _dialogue_box: PanelContainer = %DialogueBox
@onready var _dialogue_label: RichTextLabel = %DialogueLabel
@onready var _dialogue_blip_player: AudioStreamPlayer = $DialogueBlipPlayer
@onready var _nightstand: Sprite2D = $Nightstand
@onready var _nightstand_2: Sprite2D = $Nightstand2
@onready var _shelf: Sprite2D = $Shelf
@onready var _sleep_zs_root: Node2D = $SleepZsRoot
@onready var _overlay: ColorRect = %Overlay
@onready var _success_effect_spawner: EffectSpawner = $SuccessEffectSpawner
@onready var _failure_effect_spawner: EffectSpawner = $FailureEffectSpawner
@onready var _man_head: Sprite2D = $ManHead
@onready var _man_eyes: Sprite2D = $ManHead/ManEyes

@onready var _global_hand_pos := _arm_border.to_global(_arm_border.points[1]) :
	set(v):
		_global_hand_pos = v
		_arm_border.set_point_position(1, _arm_border.to_local(_global_hand_pos))
		_arm_inside.set_point_position(1, _arm_inside.to_local(_global_hand_pos))

@onready var _default_music_volume_linear := _music_player.volume_linear


var _next_subdivision_to_handle: int = 0
# Number of times the music has fully played and looped back around.
var _num_music_loops: int = 0
var _arm_tween: Tween
var _music_bpm: int = 120
var _music_beat_count: int = 0
var _music_fade_tween: Tween
# For the dark overlay when transitioning.
var _death_reset_tween: Tween

var _checkpoint_story_index: int = 0
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

var _sleep_zs: Array[SleepZ] = []
var _num_lives_left := 1

var _alarm_spec_0 := AlarmSpec.new()
var _alarm_spec_1 := AlarmSpec.new()
var _alarm_spec_2 := AlarmSpec.new()


func _ready() -> void:
	# Describe how each alarm behaves.
	_alarm_spec_0.beep_pattern = [0, 2, 6, 8]
	_alarm_spec_0.input_subdivision = 10
	_alarm_spec_0.miss_response_subdivision = 12
	_alarm_spec_0.miss_hand_offset = Vector2(-30, 0)
	_alarm_spec_0.alarm = _alarm_clock
	_alarm_spec_0.miss_object = _nightstand

	_alarm_spec_1.beep_pattern = [0, 6, 8]
	_alarm_spec_1.input_subdivision = 12
	_alarm_spec_1.miss_response_subdivision = 14
	_alarm_spec_1.miss_hand_offset = Vector2(50, 0)
	_alarm_spec_1.alarm = _alarm_clock_2
	_alarm_spec_1.miss_object = _nightstand_2

	_alarm_spec_2.beep_pattern = [0, 1, 2, 3]
	_alarm_spec_2.input_subdivision = 10
	_alarm_spec_2.miss_response_subdivision = 12
	_alarm_spec_2.miss_hand_offset = Vector2(50, 0)
	_alarm_spec_2.alarm = _alarm_clock_3
	_alarm_spec_2.miss_object = _shelf

	_sleep_zs.assign(_sleep_zs_root.find_children("", "SleepZ", false, false))
	_num_lives_left = max(1, _sleep_zs.size())

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
	if _should_block_input(): return

	if event.is_action_pressed("ui_accept"):
		if _is_showing_dialogue():
			if not _is_dialogue_fully_visible():
				# Skip dialogue if it's not finished being displayed.
				_dialogue_label.visible_ratio = 1.0
			else:
				_continue_dialogue()
	elif event.is_action_pressed("snooze_0"):
		_do_alarm_input(_alarm_spec_0)
	elif event.is_action_pressed("snooze_1"):
		_do_alarm_input(_alarm_spec_2)
	elif event.is_action_pressed("snooze_2"):
		_do_alarm_input(_alarm_spec_1)
	elif event.is_action_pressed("ui_up"):
		_save_checkpoint()
	elif event.is_action_pressed("ui_down"):
		_load_checkpoint()

# Handle logic for the passing of the nth subdivision.
func _handle_subdivision(n: int) -> void:
	if _is_showing_dialogue(): return

	_active_events = _active_events.filter(func (e: Event) -> bool: return not _is_event_done(e, n))

	var num_events_to_remove := 0
	for e in _queued_events:
		if e.start_subdivision == n:
			_start_event(e)
			if not _is_event_done(e, n): _active_events.push_back(e)
			num_events_to_remove += 1
		else:
			break

	_queued_events = _queued_events.slice(num_events_to_remove)

	for e in _active_events:
		_handle_event_at_subdivision(e, n)

	if n % (4 * SUBDIVISIONS_PER_BEAT) == 0:
		print("Measure %s" % (n / (4 * SUBDIVISIONS_PER_BEAT)))

func _handle_event_at_subdivision(event: Event, n: int) -> void:
	if event is AlarmEvent:
		if not event.spec: return

		# Countdown ticking.
		if event.active_subdivs(n) < event.countdown * SUBDIVISIONS_PER_BEAT:
			if event.active_subdivs(n) % SUBDIVISIONS_PER_BEAT == 0:
				event.spec.alarm.set_time_left(event.countdown - event.active_subdivs(n) / SUBDIVISIONS_PER_BEAT)
				event.spec.alarm.tick()
		elif event.active_subdivs(n) - event.countdown * SUBDIVISIONS_PER_BEAT in event.spec.beep_pattern:
			event.spec.alarm.beep()
		elif not event.attempted_input and event.active_subdivs(n) - event.countdown * SUBDIVISIONS_PER_BEAT == event.spec.miss_response_subdivision:
			# The input was missed without any attempt being made.
			_miss_player.play()
			_lose_life()
			_failure_effect_spawner.spawn_at(_random_point_in_radius(event.spec.alarm.global_position, hit_effect_radius))
			_hit_react(_man_head, Vector2(-10, 0), 0.05)


		if event.active_subdivs(n) == event.countdown * SUBDIVISIONS_PER_BEAT:
			event.spec.alarm.set_indicator_text("ALARM")

# True if `event` no longer has to be active.
func _is_event_done(event: Event, n: int) -> bool:
	if event is AlarmEvent:
		return event.active_subdivs(n) > event.spec.miss_response_subdivision + event.countdown * SUBDIVISIONS_PER_BEAT

	return true

# Handles one-off events, mostly.
func _start_event(event: Event) -> void:
	if event is NextStoryEvent:
		_do_next_story()

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
	_checkpoint_story_index = _story_index
	_checkpoint_num_loops = _num_music_loops
	_checkpoint_next_subdivision = _next_subdivision_to_handle

func _load_checkpoint() -> void:
	_story_index = _checkpoint_story_index
	_num_music_loops = _checkpoint_num_loops
	_next_subdivision_to_handle = _checkpoint_next_subdivision

	# We expect these to be populated by the story code, so they shouldn't be saved.
	_dialogue_box.hide()
	_active_events.clear()
	_queued_events.clear()
	_queued_dialogue.clear()

	_man_eyes.hide()

	# Always start with all lives.
	for z in _sleep_zs:
		z.unpop()
	_num_lives_left = max(1, _sleep_zs.size())

	if _music_beat_count > 0:
		var music_subdiv: int = max(0, _next_subdivision_to_handle - 1) % (_music_beat_count * SUBDIVISIONS_PER_BEAT)
		_music_player.play(music_subdiv * 60.0 / _music_bpm / SUBDIVISIONS_PER_BEAT)

	_do_next_story()

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
func _queue_dialogue_sequence(texts: Array[String], continue_dialogue: bool = true) -> void:
	_queued_dialogue.append_array(texts)
	if continue_dialogue: _continue_dialogue()

func _fade_in_music(duration: float = -1) -> void:
	if duration < 0: duration = music_fade_time
	if _music_fade_tween: _music_fade_tween.kill()
	_music_player.volume_linear = 0.0
	_music_fade_tween = get_tree().create_tween()
	_music_fade_tween.tween_property(_music_player, "volume_linear", _default_music_volume_linear, duration)

func _fade_out_music(duration: float = -1) -> void:
	if duration < 0: duration = music_fade_time
	if _music_fade_tween: _music_fade_tween.kill()
	_music_fade_tween = get_tree().create_tween()
	_music_fade_tween.tween_property(_music_player, "volume_linear", 0.0, duration)

func _queue_event(event: Event) -> void:
	# Insert the event in sorted order.
	var idx := _queued_events.bsearch_custom(event,
		func (a: Event, b: Event) -> bool: return a.start_subdivision < b.start_subdivision,
		false)
	_queued_events.insert(idx, event)

func _queue_events(events: Array[Event]) -> void:
	for e in events: _queue_event(e)

# Call `_do_next_story` at `subdiv`.
func _queue_next_story(subdiv: int) -> void:
	_queue_event(NextStoryEvent.new(subdiv))

# Make `node` jump back by `offset` as if reacting to being hit.
func _hit_react(node: Node2D, offset: Vector2, duration: float) -> void:
	var tween := get_tree().create_tween()
	var pos := node.global_position
	tween.tween_property(node, "global_position", pos + offset, duration / 4)
	tween.tween_property(node, "global_position" , pos, duration * 3 / 4)

func _lose_life() -> void:
	_num_lives_left -= 1
	if _num_lives_left >= 0 and _num_lives_left < _sleep_zs.size():
		_sleep_zs[_num_lives_left].pop()

	if _num_lives_left <= 0:
		_man_eyes.show()

		# Fade the black overlay in and out, and go back to the last checkpoint.
		_death_reset_tween = get_tree().create_tween()
		_death_reset_tween.tween_callback(_fade_out_music.bind(0.4))
		_death_reset_tween.tween_property(_overlay, "modulate", Color.WHITE, 0.2).set_delay(0.4)
		_death_reset_tween.tween_property(_overlay, "modulate", Color(0, 0, 0, 0), 0.2).set_delay(0.4)
		_death_reset_tween.parallel().tween_callback(_load_checkpoint).set_delay(0.4)
		_death_reset_tween.parallel().tween_callback(_fade_in_music.bind(0.4)).set_delay(0.4)

# True when we're playing animations where the player shouldn't be able to do anything (like when resetting after dying).
func _should_block_input() -> bool:
	return _death_reset_tween and _death_reset_tween.is_running()

func _random_point_in_radius(pos: Vector2, radius: float) -> Vector2:
	var angle := randf_range(0.0, 2 * PI)
	# Apparently taking the square root makes this uniform.
	var dist := radius * sqrt(randf_range(0, 1))

	return pos + Vector2.from_angle(angle) * dist

# Try to press the alarm described by `spec`.
func _do_alarm_input(spec: AlarmSpec) -> void:
	if _arm_tween: _arm_tween.kill()
	_arm_tween = get_tree().create_tween()
	_global_hand_pos = spec.alarm.global_position + spec.hit_hand_offset
	_arm_tween.tween_property(self, "_global_hand_pos", _default_hand_ref.global_position, arm_retract_duration) \
		.set_ease(Tween.EASE_IN) \
		.set_delay(arm_retract_delay)

	var effect_pos := _random_point_in_radius(_global_hand_pos, hit_effect_radius)

	var alarm_found := false
	for e in _active_events:
		if e is AlarmEvent and e.spec == spec:
			e.attempted_input = true

			var cur_total_playback_time := _get_total_playback_time()
			match _get_accuracy(e.start_subdivision + e.countdown * SUBDIVISIONS_PER_BEAT + spec.input_subdivision, cur_total_playback_time):
				InputAccuracy.GOOD:
					spec.alarm.snooze()
					_hit_react(spec.alarm, Vector2(0, 20), 0.05)
					_success_effect_spawner.spawn_at(effect_pos)
				_:
					_miss_player.play()
					_hit_react(spec.miss_object, spec.miss_knockback, 0.05)
					_lose_life()
					_failure_effect_spawner.spawn_at(effect_pos)
					_hit_react(_man_head, Vector2(-10, 0), 0.05)
			alarm_found = true
			break

	if not alarm_found:
		_miss_player.play()
		_hit_react(spec.miss_object, spec.miss_knockback, 0.05)
		_lose_life()
		_failure_effect_spawner.spawn_at(effect_pos)
		_hit_react(_man_head, Vector2(-10, 0), 0.05)

# Really lazy way to make alarm events in a small amount of space.
func _alarm(start_subdivision: int, alarm_index: int, countdown: int = 0) -> AlarmEvent:
	var spec: AlarmSpec = null
	match alarm_index:
		0: spec = _alarm_spec_0
		1: spec = _alarm_spec_1
		_: spec = _alarm_spec_2

	return AlarmEvent.new(start_subdivision, spec, countdown)

# Start the next story sequence.
func _do_next_story() -> void:
	# Toby Fox-type dialogue handling.
	match _story_index:
		0:
			_alarm_clock.set_time_left(2)

			# Warning for web players to consider downloading the executable.
			if OS.has_feature("web"):
				_queue_dialogue_sequence(
					["To web users: the audio quality may not be very good. If you run into timing or quality issues, it might be better to download the executable."],
					false
				)
			_queue_dialogue_sequence([
				"My alarm is about to go off",
				"I don't want to go to work, though, so I want to snooze it instead",
				"press [j] at just the right time after the alarm beeps to snooze it",
			])

			_story_index = 1
		1:
			_save_checkpoint()
			_next_subdivision_to_handle = 0
			_num_music_loops = 0
			_fade_in_music()
			_music_player.play()
			_queue_events([
				_alarm(0, 0, 2),
				_alarm(_subdiv(2), 1, 3),
				_alarm(_subdiv(4), 2, 1)
			])
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


## Describes how an alarm sounds and accepts input.
class AlarmSpec:
	var beep_pattern: Array[int] = []
	var input_subdivision: int = 0
	# The subdiv where a miss effect will be played if there were no attempts.
	var miss_response_subdivision: int = 0
	var hit_hand_offset: Vector2 = Vector2(20, -15)
	var miss_hand_offset: Vector2 = Vector2.ZERO
	var miss_knockback: Vector2 = Vector2(0, 10)

	var alarm: AlarmClock
	# Object to knock on if the input is missed.
	var miss_object: Node2D

## A thing that happens to the beat at some subdivision.
@abstract class Event:
	# The subdivision at which this event will become active.
	var start_subdivision: int = 0

	func _init(p_start_subdivision: int) -> void:
		start_subdivision = p_start_subdivision

	# Amount of subdivs this event has spent alive at time `n`.
	func active_subdivs(n: int) -> int:
		return n - start_subdivision

## Runs the next bit of story code.
class NextStoryEvent extends Event: pass

class AlarmEvent extends Event:
	var spec: AlarmSpec

	# Number of ticks to count down.
	var countdown: int = 0

	# Set to true when the player attempts to put in an input for this alarm (even if it failed).
	var attempted_input: bool = false

	func _init(p_start_subdivision: int, p_spec: AlarmSpec, p_countdown: int = 0) -> void:
		super(p_start_subdivision)
		spec = p_spec
		countdown = p_countdown
