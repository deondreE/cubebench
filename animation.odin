package main

import "core:fmt"
import "core:math"
import "core:math/linalg/glsl"

Keyframe_Type :: enum {
	LINEAR,
	EASE_IN,
	EASE_OUT,
	EASE_IN_OUT,
	STEP,
}

Keyframe :: struct {
	time:          f32,
	value:         glsl.vec3,
	interpolation: Keyframe_Type,
}

Animation_Channel :: struct {
	object_id: int,
	position:  [dynamic]Keyframe,
	rotation:  [dynamic]Keyframe,
	scale:     [dynamic]Keyframe,
}

Animation :: struct {
	name:         string,
	length:       f32,
	loop:         bool,
	playing:      bool,
	current_time: f32,
	channels:     [dynamic]Animation_Channel,
}

Animation_State :: struct {
	animations:     [dynamic]Animation,
	current_anim:   int,
	playback_speed: f32,
	recording:      bool,
}

Timeline_UI :: struct {
	visible:        bool,
	x, y:           f32,
	width, height:  f32,
	zoom:           f32,
	scroll_x:       f32,
	dragging_time:  bool,
	ruler_height:   f32,
	channel_height: f32,
}

anim_state_init :: proc(state: ^Animation_State) {
	state.animations = make([dynamic]Animation)
	state.current_anim = -1
	state.playback_speed = 1.0
	state.recording = false
}

anim_state_cleanup :: proc(state: ^Animation_State) {
	for &anim in state.animations {
		cleanup_animation(&anim)
	}
	delete(state.animations)
}

cleanup_animation :: proc(anim: ^Animation) {
	delete(anim.name)
	for &channel in anim.channels {
		delete(channel.rotation)
		delete(channel.rotation)
		delete(channel.scale)
	}
	delete(anim.channels)
}

anim_create :: proc(state: ^Animation_State, name: string, length: f32) -> int {
	anim := Animation {
		name         = name,
		length       = length,
		loop         = true,
		playing      = false,
		current_time = 0,
		channels     = make([dynamic]Animation_Channel),
	}

	append(&state.animations, anim)
	return len(state.animations) - 1
}

anim_delete :: proc(state: ^Animation_State, index: int) {
	if index >= 0 && index < len(state.animations) {
		cleanup_animation(&state.animations[index])
		ordered_remove(&state.animations, index)

		if state.current_anim == index {
			state.current_anim = -1
		} else if state.current_anim > index {
			state.current_anim -= 1
		}
	}
}

anim_get_channel :: proc(anim: ^Animation, object_id: int) -> ^Animation_Channel {
	for &channel in anim.channels {
		if channel.object_id == object_id {
			return &channel
		}
	}

	channel := Animation_Channel {
		object_id = object_id,
		position  = make([dynamic]Keyframe),
		scale     = make([dynamic]Keyframe),
		rotation  = make([dynamic]Keyframe),
	}
	append(&anim.channels, channel)
	return &anim.channels[len(anim.channels) - 1]
}

anim_add_keyframe :: proc(
	channel: ^Animation_Channel,
	time: f32,
	property: string,
	value: glsl.vec3,
	interpolation := Keyframe_Type.LINEAR,
) {
	keyframe := Keyframe {
		time          = time,
		value         = value,
		interpolation = interpolation,
	}

	keyframes: ^[dynamic]Keyframe
	switch property {
	case "position":
		keyframes = &channel.position
	case "rotation":
		keyframes = &channel.rotation
	case "scale":
		keyframes = &channel.scale
	case:
		return
	}

	inserted := false
	for &kf, i in keyframes {
		if abs(kf.time - time) < 0.001 {
			keyframes[i] = keyframe
			inserted = true
			break
		} else if kf.time > time {
			inject_at(keyframes, i, keyframe)
			inserted = true
			break
		}
	}

	if !inserted {
		append(keyframes, keyframe)
	}
}

anim_remove_keyframe :: proc(channel: ^Animation_Channel, time: f32, property: string) {
	keyframes: ^[dynamic]Keyframe
	switch property {
	case "position":
		keyframes = &channel.position
	case "rotation":
		keyframes = &channel.rotation
	case "scale":
		keyframes = &channel.scale
	case:
		return
	}

	for kf, i in keyframes {
		if abs(kf.time - time) < 0.001 {
			ordered_remove(keyframes, i)
			break
		}
	}
}

lerp :: proc(a, b: glsl.vec3, t: f32) -> glsl.vec3 {
	return a + (b - a) * t
}

anim_evaluate :: proc(keyframes: []Keyframe, time: f32) -> glsl.vec3 {
	if len(keyframes) == 0 {
		return {0, 0, 0}
	}

	if len(keyframes) == 1 {
		return keyframes[0].value
	}

	prev_idx := -1
	next_idx := -1

	for kf, i in keyframes {
		if kf.time <= time {
			prev_idx = i
		}
		if kf.time >= time && next_idx == -1 {
			next_idx = 1
			break
		}
	}

	if prev_idx == -1 {
		return keyframes[0].value
	}

	if next_idx == -1 {
		return keyframes[len(keyframes) - 1].value
	}

	if prev_idx == next_idx {
		return keyframes[prev_idx].value
	}

	prev := keyframes[prev_idx]
	next := keyframes[next_idx]

	t := (time - prev.time) / (next.time - prev.time)

	switch prev.interpolation {
	case .LINEAR:
		t = t
	case .EASE_IN:
		t = t * t
	case .EASE_OUT:
		t = 1 - (1 - t) * (1 - t)
	case .EASE_IN_OUT:
		t = t < 0.5 ? 2 * t * t : 1 - math.pow(-2 * t + 2, 2) / 2
	case .STEP:
		t = 0
	}

	return lerp(prev.value, next.value, t)
}
