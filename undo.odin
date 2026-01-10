package main

import "core:fmt"
import "core:math/linalg/glsl"
import gl "vendor:OpenGL"

Action_Type :: enum {
	ADD_OBJECT,
	DELETE_OBJECT,
	TRANSFORM,
	PAINT,
	MODIFY_COLOR,
	MODIFY_FACE_COLOR,
}

Undo_Action :: struct {
	type:         Action_Type,
	object_index: int,
	old_position: glsl.vec3,
	new_position: glsl.vec3,
	old_rotation: glsl.vec3,
	new_rotation: glsl.vec3,
	old_scale:    glsl.vec3,
	new_scale:    glsl.vec3,
	object_data:  Maybe(Scene_Object_Data),
	paint_rect:   struct {
		x, y, w, h: i32,
	},
	old_pixels:   []u8,
	new_pixels:   []u8,
	old_color:    glsl.vec4,
	new_color:    glsl.vec4,
	face_index:   i32,
}

Undo_Stack :: struct {
	actions:       [dynamic]Undo_Action,
	current_index: int,
	max_size:      int,
}

undo_stack: Undo_Stack

undo_init :: proc(max_size: int = 100) {
	// TODO: We should save the current action set to the project file, so when you load you can tell where you where.
	undo_stack.actions = make([dynamic]Undo_Action, 0, max_size)
	undo_stack.current_index = -1
	undo_stack.max_size = max_size
}

undo_cleanup :: proc() {
	for &action in undo_stack.actions {
		if action.old_pixels != nil do delete(action.old_pixels)
		if action.new_pixels != nil do delete(action.new_pixels)
	}
	delete(undo_stack.actions)
}

undo_push_action :: proc(action: Undo_Action) {
	if undo_stack.current_index < len(undo_stack.actions) - 1 {
		for i := undo_stack.current_index + 1; i < len(undo_stack.actions); i += 1 {
			if undo_stack.actions[i].old_pixels != nil {
				delete(undo_stack.actions[i].old_pixels)
			}
			if undo_stack.actions[i].new_pixels != nil {
				delete(undo_stack.actions[i].new_pixels)
			}
		}
		resize(&undo_stack.actions, undo_stack.current_index + 1)
	}

	append(&undo_stack.actions, action)
	undo_stack.current_index += 1

	if len(undo_stack.actions) > undo_stack.max_size {
		if undo_stack.actions[0].old_pixels != nil {
			delete(undo_stack.actions[0].old_pixels)
		}
		if undo_stack.actions[0].new_pixels != nil {
			delete(undo_stack.actions[0].new_pixels)
		}
		ordered_remove(&undo_stack.actions, 0)
		undo_stack.current_index -= 1
	}

	fmt.printf("Action Pushed: %v (stack size: %d)\n", action.type, len(undo_stack.actions))
}

undo_can_undo :: proc() -> bool {
	return undo_stack.current_index >= 0
}

undo_can_redo :: proc() -> bool {
	return undo_stack.current_index < len(undo_stack.actions) - 1
}

undo_perform :: proc(scene: ^Scene) -> bool {
	if !undo_can_undo() {
		fmt.printf("Nothing to undo!\n")
		return false
	}

	action := &undo_stack.actions[undo_stack.current_index]

	switch action.type {
	case .TRANSFORM:
		if action.object_index >= 0 && undo_stack.current_index < len(scene.objects) {
			obj := &scene.objects[action.object_index]
			obj.position = action.old_position
			obj.rotation = action.old_rotation
			obj.scale = action.old_scale
			fmt.print("Undo TRANSFORM")
		}

	case .ADD_OBJECT:
		// remove if added
		if action.object_index >= 0 && action.object_index < len(scene.objects) {
			obj := &scene.objects[action.object_index]
			gl.DeleteVertexArrays(1, &obj.vao)
			gl.DeleteBuffers(1, &obj.vbo)
			ordered_remove(&scene.objects, action.object_index)
			fmt.print("Undo ADD_OBJECT")
		}

	case .DELETE_OBJECT:
		if data, ok := action.object_data.?; ok {
			idx := restore_object_from_data(scene, data)
			fmt.print("Undo DELETE_OBJECT")
		}

	case .PAINT:
		if action.old_pixels != nil {
			atlas := &scene.default_atlas
			rect := action.paint_rect
			for y in 0 ..< rect.h {
				for x in 0 ..< rect.w {
					src_idx := (y * rect.w + x) * 4
					dst_idx := ((rect.y + y) * atlas.width + (rect.w + x) * 4)
					if int(dst_idx + 3) < len(atlas.pixel_data) &&
					   int(src_idx + 3) < len(action.old_pixels) {
						atlas.pixel_data[dst_idx + 0] = action.old_pixels[src_idx + 0]
						atlas.pixel_data[dst_idx + 1] = action.old_pixels[src_idx + 1]
						atlas.pixel_data[dst_idx + 2] = action.old_pixels[src_idx + 2]
						atlas.pixel_data[dst_idx + 3] = action.old_pixels[src_idx + 3]
					}
				}
			}
			update_texture_atlas(atlas)
			fmt.print("Undo PAINT")
		}

	case .MODIFY_COLOR:
		if action.object_index >= 0 && action.object_index < len(scene.objects) {
			obj := &scene.objects[action.object_index]
			obj.color = action.old_color
			fmt.print("Undo MODIFY_COLOR")
		}

	case .MODIFY_FACE_COLOR:
		if action.object_index >= 0 && action.object_index < len(scene.objects) {
			obj := &scene.objects[action.object_index]
			if action.face_index >= 0 && action.face_index < 6 {
				obj.face_colors[action.face_index] = action.old_color
			}
		}
	}

	undo_stack.current_index -= 1
	return true
}

redo_perform :: proc(scene: ^Scene) -> bool {
	if !undo_can_redo() {
		fmt.printf("Nothing to redo\n")
		return false
	}

	undo_stack.current_index += 1
	action := &undo_stack.actions[undo_stack.current_index]

	switch action.type {
		case .TRANSFORM:
			if action.object_index >= 0 && action.object_index < len(scene.objects) {
				obj := &scene.objects[action.object_index]
				obj.position = action.new_position
				obj.rotation = action.new_rotation
				obj.scale = action.new_scale
				fmt.print("Redid TRANSFORM")
			}
		case .ADD_OBJECT:
			if data, ok := action.object_data.?; ok {
				idx := restore_object_from_data(scene, data)
				fmt.print("Redid ADD_OBJECT")
			}
		case .DELETE_OBJECT:
			if action.object_index >= 0 && action.object_index < len(scene.objects) {
				obj := scene.objects[action.object_index]
				gl.DeleteVertexArrays(1, &obj.vao)
				gl.DeleteBuffers(1, &obj.vbo)
				ordered_remove(&scene.objects, action.object_index)
				fmt.print("Redid DELETE_OBJECT")
			}

		case .PAINT:
			if action.new_pixels != nil {
				atlas := &scene.default_atlas
				rect :=  action.paint_rect
				for y in 0 ..< rect.h {
					for x in 0 ..< rect.w {
						src_idx := (y * rect.w + x) * 4
						dst_idx := ((rect.y + y) * atlas.width + (rect.x + x)) * 4
						if int(dst_idx + 3) < len(atlas.pixel_data) &&
							int(src_idx + 3) < len(action.new_pixels) {
								atlas.pixel_data[dst_idx + 0] = action.new_pixels[src_idx + 0]
								atlas.pixel_data[dst_idx + 1] = action.new_pixels[src_idx + 1]
								atlas.pixel_data[dst_idx + 2] = action.new_pixels[src_idx + 2]
								atlas.pixel_data[dst_idx + 3] = action.new_pixels[src_idx + 3]
							}
					}
				}
				update_texture_atlas(atlas)
				fmt.print("Redid paint operation")
			}
		case .MODIFY_COLOR:
			if action.object_index >= 0 && action.object_index < len(scene.objects) {
				obj := &scene.objects[action.object_index]
				obj.color = action.new_color
				fmt.printf("Reded Change Color")
			}

		case .MODIFY_FACE_COLOR:
			if action.object_index >= 0 && action.object_index < len(scene.objects) {
				obj := &scene.objects[action.object_index]
				if action.face_index >= 0 && action.face_index < 6 {
					obj.face_colors[action.face_index] = action.new_color
					fmt.print("Redid face color change")
				}
			}
	}

	return true
}

record_transform :: proc(
	obj_idx: int,
	old_pos, new_pos: glsl.vec3,
	old_rot, new_rot: glsl.vec3,
	old_scale, new_scale: glsl.vec3,
) {
	action := Undo_Action{
		type = .TRANSFORM,
		object_index = obj_idx,
		old_position = old_pos,
		new_position = new_pos,
		old_scale = old_scale,
		new_scale = new_scale,
		old_rotation = old_rot,
		new_rotation = new_rot,
	}
	undo_push_action(action)
}

record_add_object :: proc(scene: ^Scene, obj_idx: int) {
	if obj_idx < 0 || obj_idx >= len(scene.objects) do return

	obj_data := scene_object_to_data(scene.objects[obj_idx])
	action := Undo_Action {
		type = .ADD_OBJECT,
		object_index = obj_idx,
		object_data = obj_data,
	}
	undo_push_action(action)
}

record_delete_object :: proc(scene: ^Scene, obj_idx: int) {
	if obj_idx < 0 || obj_idx >= len(scene.objects) do return

	obj_data := scene_object_to_data(scene.objects[obj_idx])
	action := Undo_Action {
		type = .DELETE_OBJECT,
		object_index = obj_idx,
		object_data = obj_data,
	}
	undo_push_action(action)
}
