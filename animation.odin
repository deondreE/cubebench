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
	channel_width: f32,
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

anim_update :: proc(state: ^Animation_State, scene: ^Scene, dt: f32) {
	if state.current_anim < 0 || state.current_anim >= len(state.animations) {
		return
	}

	anim := &state.animations[state.current_anim]

	if !anim.playing {
		return
	}

	anim.current_time += dt * state.playback_speed

	if anim.current_time >= anim.length {
		if anim.loop {
			anim.current_time = math.mod(anim.current_time, anim.length)
		} else {
			anim.current_time = anim.length
			anim.playing = false
		}
	}

	if anim.current_time < 0 {
		if anim.loop {
			anim.current_time = anim.length
		} else {
			anim.current_time = 0
			anim.playing = false
		}
	}

	anim_apply(anim, scene, anim.current_time)
}

anim_apply :: proc(anim: ^Animation, scene: ^Scene, time: f32) {
	for channel in anim.channels {
		if channel.object_id >= 0 && channel.object_id < len(scene.objects) {
			obj := &scene.objects[channel.object_id]

			if len(channel.position) > 0 {
				obj.position = anim_evaluate(channel.position[:], time)
			}

			if len(channel.rotation) > 0 {
				obj.rotation = anim_evaluate(channel.rotation[:], time)
			}

			if len(channel.scale) > 0 {
				obj.scale = anim_evaluate(channel.scale[:], time)
			}
		}
	}
}

anim_play :: proc(state: ^Animation_State) {
	if state.current_anim >= 0 && state.current_anim < len(state.animations) {
		state.animations[state.current_anim].playing = true
	}
}

anim_pause :: proc(state: ^Animation_State) {
	if state.current_anim >= 0 && state.current_anim < len(state.animations) {
		state.animations[state.current_anim].playing = false
	}
}

anim_stop :: proc(state: ^Animation_State) {
	if state.current_anim >= 0 && state.current_anim < len(state.animations) {
		anim := &state.animations[state.current_anim]
		anim.playing = false
		anim.current_time = 0
	}
}

anim_record_transform :: proc(state: ^Animation_State, scene: ^Scene, object_id: int) {
	if !state.recording || state.current_anim < 0 {
		return
	}

	anim := &state.animations[state.current_anim]
	channel := anim_get_channel(anim, object_id)

	if object_id < 0 || object_id >= len(scene.objects) {
		return
	}

	obj := &scene.objects[object_id]
	time := anim.current_time

	anim_add_keyframe(channel, time, "position", obj.position)
	anim_add_keyframe(channel, time, "rotation", obj.rotation)
	anim_add_keyframe(channel, time, "scale", obj.scale)
}

timeline_init :: proc(timeline: ^Timeline_UI) {
	timeline.visible = false
	timeline.x = 0
	timeline.y = SCR_HEIGHT - 250
	timeline.width = SCR_WIDTH
	timeline.zoom = 100
	timeline.scroll_x = 0
	timeline.dragging_time = false
	timeline.ruler_height = 30
	timeline.channel_height = 60
}

timeline_render :: proc(
	timeline: ^Timeline_UI,
	state: ^Animation_State,
	scene: ^Scene,
	ctx: ^UI_Context,
) {
	if !timeline.visible || state.current_anim < 0 {
		return
	}

	anim := &state.animations[state.current_anim]

	bg := UI_Rect{timeline.x, timeline.y, timeline.width, timeline.ruler_height}
	batch_rect(ctx, bg, UI_Color{0.12, 0.12, 0.15, 1})
	batch_rect_outline(ctx, bg, ctx.style.border_color, 2)

	ruler := UI_Rect{timeline.x, timeline.y, timeline.width, timeline.ruler_height}
	batch_rect(ctx, ruler, UI_Color{0.15, 0.15, 0.18, 1})
	// Draw time markers
	seconds_visible := timeline.width / timeline.zoom
	for i := 0; i <= int(seconds_visible) + 1; i += 1 {
		time := f32(i) - timeline.scroll_x / timeline.zoom
		if time < 0 || time > anim.length {
			continue
		}

		x := timeline.x + (time * timeline.zoom) - timeline.scroll_x

		batch_rect(ctx, UI_Rect{x, timeline.y, 1, timeline.ruler_height}, UI_Color{0.4, 0.4, 0.45, 1})
		batch_text(ctx, fmt.tprintf("%.1f", time), x + 2, timeline.y + 5, ctx.style.text_color)
	}

	// Current time
	playhead_x := timeline.x + (anim.current_time * timeline.zoom) - timeline.scroll_x
	batch_rect(
		ctx,
		UI_Rect{playhead_x - 1, timeline.y, 3, timeline.height},
		UI_Color{1, 0.3, 0.3, 1},
	)

	// draw channel
	y_offset := timeline.y + timeline.ruler_height

	for &channel, i in anim.channels {
		channel_y := y_offset + f32(i) * timeline.channel_height

		bg_color :=
			i % 2 == 0 ? UI_Color{0.14, 0.14, 0.17, 1} : UI_Color{0.16, 0.16, 0.19, 1}
		batch_rect(ctx, UI_Rect{timeline.x, channel_y, timeline.width, timeline.channel_width}, bg_color)

		batch_text(
			ctx,
			fmt.tprintf("Cube.%03d", channel.object_id),
			timeline.x + 5,
			channel_y + 5,
			ctx.style.text_color,
		)

		timeline_render_track(
			timeline,
			&channel.position,
			channel_y + 20,
			"Position",
			UI_Color{1, 0.3, 0.3, 1},
			ctx,
		)

		timeline_render_track(
			timeline,
			&channel.rotation,
			channel_y + 35,
			"Rotation",
			UI_Color{0.3, 1, 0.3, 1},
			ctx,
		)

		timeline_render_track(
			timeline,
			&channel.scale,
			channel_y + 50,
			"Scale",
			UI_Color{0.3, 0.3, 1, 1},
			ctx,
		)
	}

	timeline_handle_input(timeline, state, scene, ctx)
}

timeline_render_track :: proc(
	timeline: ^Timeline_UI,
	keyframes: ^[dynamic]Keyframe,
	y: f32,
	label: string,
	color: UI_Color,
	ctx: ^UI_Context,
) {
	batch_text(ctx, label, timeline.x + 5, y, UI_Color{0.6, 0.6, 0.65, 1})

	for kf in keyframes {
		x := timeline.x + (kf.time * timeline.zoom) - timeline.scroll_x

		if x < timeline.x || x > timeline.x + timeline.width {
			continue
		}

		size: f32 = 8
		kf_rect := UI_Rect{x - size / 2, y - size / 2, size, size}
		batch_rect(ctx, kf_rect, color)
		batch_rect_outline(ctx, kf_rect, UI_Color{1,1,1,1})
	}
}

timeline_handle_input :: proc(
	timeline: ^Timeline_UI,
	state: ^Animation_State,
	scene: ^Scene,
	ctx: ^UI_Context,
) {
	if state.current_anim < 0 {
		return
	}

	anim := &state.animations[state.current_anim]

	if ctx.mouse_x < timeline.x || ctx.mouse_x > timeline.x + timeline.width ||
		ctx.mouse_y < timeline.y || ctx.mouse_y > timeline.y + timeline.height {
		timeline.dragging_time = false
		return
	}

	if ctx.mouse_pressed {
		timeline.dragging_time = true
	}

	if timeline.dragging_time && ctx.mouse_down {
		local_x := ctx.mouse_x - timeline.x + timeline.scroll_x
		time := local_x / timeline.zoom
		anim.current_time = clamp(time, 0, anim.length)

		anim_apply(anim, scene, anim.current_time)
	} else {
		timeline.dragging_time = false
	}
}
