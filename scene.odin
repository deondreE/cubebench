package main

import "core:fmt"
import "core:math"
import "core:math/linalg/glsl"
import gl "vendor:OpenGL"

// Cube geometry data with normals and UVs
cube :: [216]f32 {
	// Front face (Z+)
	-0.5,
	-0.5,
	0.5,
	0.0,
	0.0,
	1.0,
	0.5,
	-0.5,
	0.5,
	0.0,
	0.0,
	1.0,
	0.5,
	0.5,
	0.5,
	0.0,
	0.0,
	1.0,
	0.5,
	0.5,
	0.5,
	0.0,
	0.0,
	1.0,
	-0.5,
	0.5,
	0.5,
	0.0,
	0.0,
	1.0,
	-0.5,
	-0.5,
	0.5,
	0.0,
	0.0,
	1.0,

	// Back face (Z-)
	0.5,
	-0.5,
	-0.5,
	0.0,
	0.0,
	-1.0,
	-0.5,
	-0.5,
	-0.5,
	0.0,
	0.0,
	-1.0,
	-0.5,
	0.5,
	-0.5,
	0.0,
	0.0,
	-1.0,
	-0.5,
	0.5,
	-0.5,
	0.0,
	0.0,
	-1.0,
	0.5,
	0.5,
	-0.5,
	0.0,
	0.0,
	-1.0,
	0.5,
	-0.5,
	-0.5,
	0.0,
	0.0,
	-1.0,

	// Left face (X-)
	-0.5,
	-0.5,
	-0.5,
	-1.0,
	0.0,
	0.0,
	-0.5,
	-0.5,
	0.5,
	-1.0,
	0.0,
	0.0,
	-0.5,
	0.5,
	0.5,
	-1.0,
	0.0,
	0.0,
	-0.5,
	0.5,
	0.5,
	-1.0,
	0.0,
	0.0,
	-0.5,
	0.5,
	-0.5,
	-1.0,
	0.0,
	0.0,
	-0.5,
	-0.5,
	-0.5,
	-1.0,
	0.0,
	0.0,

	// Right face (X+)
	0.5,
	-0.5,
	0.5,
	1.0,
	0.0,
	0.0,
	0.5,
	-0.5,
	-0.5,
	1.0,
	0.0,
	0.0,
	0.5,
	0.5,
	-0.5,
	1.0,
	0.0,
	0.0,
	0.5,
	0.5,
	-0.5,
	1.0,
	0.0,
	0.0,
	0.5,
	0.5,
	0.5,
	1.0,
	0.0,
	0.0,
	0.5,
	-0.5,
	0.5,
	1.0,
	0.0,
	0.0,

	// Top face (Y+)
	-0.5,
	0.5,
	0.5,
	0.0,
	1.0,
	0.0,
	0.5,
	0.5,
	0.5,
	0.0,
	1.0,
	0.0,
	0.5,
	0.5,
	-0.5,
	0.0,
	1.0,
	0.0,
	0.5,
	0.5,
	-0.5,
	0.0,
	1.0,
	0.0,
	-0.5,
	0.5,
	-0.5,
	0.0,
	1.0,
	0.0,
	-0.5,
	0.5,
	0.5,
	0.0,
	1.0,
	0.0,

	// Bottom face (Y-)
	-0.5,
	-0.5,
	-0.5,
	0.0,
	-1.0,
	0.0,
	0.5,
	-0.5,
	-0.5,
	0.0,
	-1.0,
	0.0,
	0.5,
	-0.5,
	0.5,
	0.0,
	-1.0,
	0.0,
	0.5,
	-0.5,
	0.5,
	0.0,
	-1.0,
	0.0,
	-0.5,
	-0.5,
	0.5,
	0.0,
	-1.0,
	0.0,
	-0.5,
	-0.5,
	-0.5,
	0.0,
	-1.0,
	0.0,
}

Face_Index :: enum i32 {
	FRONT  = 0,
	BACK   = 1,
	LEFT   = 2,
	RIGHT  = 3,
	TOP    = 4,
	BOTTOM = 5,
}

Scene_Object :: struct {
	position:            glsl.vec3,
	rotation:            glsl.vec3, // Euler angles in degrees
	scale:               glsl.vec3,
	color:               glsl.vec4,
	face_colors:         [6]glsl.vec4, // Per-face colors
	use_per_face_colors: bool,
	vao, vbo:            u32,
}

Scene :: struct {
	objects:          [dynamic]Scene_Object,
	selected_objects: [dynamic]int,
}

scene_init :: proc(scene: ^Scene) {
	scene.objects = make([dynamic]Scene_Object, 0, 16)
	scene.selected_objects = make([dynamic]int, 0, 16)
}

scene_cleanup :: proc(scene: ^Scene) {
	for obj in scene.objects {
		o := obj
		gl.DeleteVertexArrays(1, &o.vao)
		gl.DeleteBuffers(1, &o.vbo)
	}
	delete(scene.objects)
	delete(scene.selected_objects)
}

scene_add_cube :: proc(scene: ^Scene, pos, scale: glsl.vec3, color: glsl.vec4) -> int {
	obj := Scene_Object {
		position            = pos,
		rotation            = {0, 0, 0},
		scale               = scale,
		color               = color,
		use_per_face_colors = false,
	}

	// Initialize all face colors to object color
	for i in 0 ..< 6 {
		obj.face_colors[i] = color
	}

	c := cube

	// Create VAO/VBO
	gl.GenVertexArrays(1, &obj.vao)
	gl.GenBuffers(1, &obj.vbo)
	gl.BindVertexArray(obj.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, obj.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(cube), &c[0], gl.STATIC_DRAW)

	gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 6 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(1, 3, gl.FLOAT, gl.FALSE, 6 * size_of(f32), 3 * size_of(f32))
	gl.EnableVertexAttribArray(1)

	append(&scene.objects, obj)
	return len(scene.objects) - 1
}

scene_select_object :: proc(scene: ^Scene, index: int) {
	clear(&scene.selected_objects)
	if index >= 0 && index < len(scene.objects) {
		append(&scene.selected_objects, index)
	}
}

scene_toggle_selection :: proc(scene: ^Scene, index: int) {
	if index < 0 || index >= len(scene.objects) do return

	// Check if already selected
	for sel, i in scene.selected_objects {
		if sel == index {
			ordered_remove(&scene.selected_objects, i)
			return
		}
	}

	// Not selected, add it
	append(&scene.selected_objects, index)
}

scene_clear_selection :: proc(scene: ^Scene) {
	clear(&scene.selected_objects)
}

scene_get_selection_center :: proc(scene: ^Scene) -> glsl.vec3 {
	if len(scene.selected_objects) == 0 do return {0, 0, 0}

	center := glsl.vec3{0, 0, 0}
	for idx in scene.selected_objects {
		center += scene.objects[idx].position
	}
	return center / f32(len(scene.selected_objects))
}

scene_delete_selected :: proc(scene: ^Scene) {
	if len(scene.selected_objects) == 0 do return

	// Sort in reverse order to delete from back to front
	for i := len(scene.selected_objects) - 1; i >= 0; i -= 1 {
		idx := scene.selected_objects[i]
		obj := scene.objects[idx]
		gl.DeleteVertexArrays(1, &obj.vao)
		gl.DeleteBuffers(1, &obj.vbo)
		ordered_remove(&scene.objects, idx)
	}

	clear(&scene.selected_objects)
}

scene_duplicate_selected :: proc(scene: ^Scene) {
	if len(scene.selected_objects) == 0 do return

	new_selections := make([dynamic]int, 0, len(scene.selected_objects))
	defer delete(new_selections)

	for idx in scene.selected_objects {
		orig := scene.objects[idx]
		new_idx := scene_add_cube(
			scene,
			orig.position + glsl.vec3{0.5, 0, 0},
			orig.scale,
			orig.color,
		)
		scene.objects[new_idx].rotation = orig.rotation
		scene.objects[new_idx].face_colors = orig.face_colors
		scene.objects[new_idx].use_per_face_colors = orig.use_per_face_colors
		append(&new_selections, new_idx)
	}

	clear(&scene.selected_objects)
	for idx in new_selections {
		append(&scene.selected_objects, idx)
	}
}

scene_translate_selected :: proc(scene: ^Scene, axis: Axis, dx, dy: f32) {
	for idx in scene.selected_objects {
		obj := &scene.objects[idx]
		switch axis {
		case .X:
			obj.position.x += dx
		case .Y:
			obj.position.y += dy
		case .Z:
			obj.position.z += dx
		case .NONE:
		}
	}
}

scene_scale_selected :: proc(scene: ^Scene, axis: Axis, delta: f32) {
	scale_delta := delta * 0.1
	for idx in scene.selected_objects {
		obj := &scene.objects[idx]
		switch axis {
		case .X:
			obj.scale.x = max(0.1, obj.scale.x + scale_delta)
		case .Y:
			obj.scale.y = max(0.1, obj.scale.y + scale_delta)
		case .Z:
			obj.scale.z = max(0.1, obj.scale.z + scale_delta)
		case .NONE:
		}
	}
}

scene_rotate_selected :: proc(scene: ^Scene, axis: Axis, delta: f32) {
	for idx in scene.selected_objects {
		obj := &scene.objects[idx]
		switch axis {
		case .X:
			obj.rotation.x += delta
		case .Y:
			obj.rotation.y += delta
		case .Z:
			obj.rotation.z += delta
		case .NONE:
		}
	}
}

scene_raycast :: proc(scene: ^Scene, origin, dir: glsl.vec3) -> int {
	closest_dist: f32 = 9999999.0
	closest_obj: int = -1

	for obj, i in scene.objects {
		min := obj.position - 0.5 * obj.scale
		max := obj.position + 0.5 * obj.scale

		if test_ray_cube(origin, dir, min, max) {
			dist := glsl.length(obj.position - origin)
			if dist < closest_dist {
				closest_dist = dist
				closest_obj = i
			}
		}
	}

	return closest_obj
}

scene_raycast_face :: proc(
	scene: ^Scene,
	origin, dir: glsl.vec3,
) -> (
	obj_idx: int,
	face_idx: i32,
) {
	obj_idx = scene_raycast(scene, origin, dir)
	if obj_idx < 0 do return obj_idx, -1

	obj := scene.objects[obj_idx]

	// Transform ray to object space
	model := glsl.mat4Translate(obj.position)
	model *= glsl.mat4Rotate({1, 0, 0}, glsl.radians(obj.rotation.x))
	model *= glsl.mat4Rotate({0, 1, 0}, glsl.radians(obj.rotation.y))
	model *= glsl.mat4Rotate({0, 0, 1}, glsl.radians(obj.rotation.z))
	model *= glsl.mat4Scale(obj.scale)

	inv_model := glsl.inverse_mat4(model)
	local_origin := (inv_model * glsl.vec4{origin.x, origin.y, origin.z, 1.0}).xyz
	local_dir := glsl.normalize((inv_model * glsl.vec4{dir.x, dir.y, dir.z, 0.0}).xyz)

	// Test each face
	closest_t: f32 = 9999999.0
	face_idx = -1

	// Front face (Z+)
	if t, ok := ray_plane_intersect(local_origin, local_dir, {0, 0, 1}, 0.5); ok {
		hit := local_origin + local_dir * t
		if abs(hit.x) <= 0.5 && abs(hit.y) <= 0.5 && t < closest_t {
			closest_t = t
			face_idx = i32(Face_Index.FRONT)
		}
	}

	// Back face (Z-)
	if t, ok := ray_plane_intersect(local_origin, local_dir, {0, 0, -1}, 0.5); ok {
		hit := local_origin + local_dir * t
		if abs(hit.x) <= 0.5 && abs(hit.y) <= 0.5 && t < closest_t {
			closest_t = t
			face_idx = i32(Face_Index.BACK)
		}
	}

	// Left face (X-)
	if t, ok := ray_plane_intersect(local_origin, local_dir, {-1, 0, 0}, 0.5); ok {
		hit := local_origin + local_dir * t
		if abs(hit.y) <= 0.5 && abs(hit.z) <= 0.5 && t < closest_t {
			closest_t = t
			face_idx = i32(Face_Index.LEFT)
		}
	}

	// Right face (X+)
	if t, ok := ray_plane_intersect(local_origin, local_dir, {1, 0, 0}, 0.5); ok {
		hit := local_origin + local_dir * t
		if abs(hit.y) <= 0.5 && abs(hit.z) <= 0.5 && t < closest_t {
			closest_t = t
			face_idx = i32(Face_Index.RIGHT)
		}
	}

	// Top face (Y+)
	if t, ok := ray_plane_intersect(local_origin, local_dir, {0, 1, 0}, 0.5); ok {
		hit := local_origin + local_dir * t
		if abs(hit.x) <= 0.5 && abs(hit.z) <= 0.5 && t < closest_t {
			closest_t = t
			face_idx = i32(Face_Index.TOP)
		}
	}

	// Bottom face (Y-)
	if t, ok := ray_plane_intersect(local_origin, local_dir, {0, -1, 0}, 0.5); ok {
		hit := local_origin + local_dir * t
		if abs(hit.x) <= 0.5 && abs(hit.z) <= 0.5 && t < closest_t {
			closest_t = t
			face_idx = i32(Face_Index.BOTTOM)
		}
	}

	return obj_idx, face_idx
}

ray_plane_intersect :: proc(origin, dir, normal: glsl.vec3, distance: f32) -> (t: f32, ok: bool) {
	denom := glsl.dot(normal, dir)
	if abs(denom) < 0.0001 do return 0, false

	t = (distance - glsl.dot(normal, origin)) / denom
	if t < 0 do return 0, false

	return t, true
}

scene_render :: proc(scene: ^Scene, shader: u32, view, proj: glsl.mat4, highlight_face: i32 = -1) {
	gl.UseProgram(shader)
	v := view
	p := proj
	gl.UniformMatrix4fv(gl.GetUniformLocation(shader, "view"), 1, false, &v[0, 0])
	gl.UniformMatrix4fv(gl.GetUniformLocation(shader, "projection"), 1, false, &p[0, 0])

	for obj, i in scene.objects {
		// Check if selected
		is_selected := false
		for sel_idx in scene.selected_objects {
			if sel_idx == i {
				is_selected = true
				break
			}
		}

		model := glsl.mat4Translate(obj.position)
		model *= glsl.mat4Rotate({1, 0, 0}, glsl.radians(obj.rotation.x))
		model *= glsl.mat4Rotate({0, 1, 0}, glsl.radians(obj.rotation.y))
		model *= glsl.mat4Rotate({0, 0, 1}, glsl.radians(obj.rotation.z))
		model *= glsl.mat4Scale(obj.scale)

		gl.UniformMatrix4fv(gl.GetUniformLocation(shader, "model"), 1, false, &model[0, 0])

		// Draw with selection outline
		if is_selected {
			// Draw outline
			gl.Enable(gl.POLYGON_OFFSET_FILL)
			gl.PolygonOffset(-1.0, -1.0)
			gl.PolygonMode(gl.FRONT_AND_BACK, gl.LINE)
			gl.LineWidth(3.0)

			outline_color := glsl.vec4{1, 0.5, 0, 1}
			gl.Uniform4f(
				gl.GetUniformLocation(shader, "objectColor"),
				outline_color.r,
				outline_color.g,
				outline_color.b,
				outline_color.a,
			)

			gl.BindVertexArray(obj.vao)
			gl.DrawArrays(gl.TRIANGLES, 0, 36)

			gl.PolygonMode(gl.FRONT_AND_BACK, gl.FILL)
			gl.Disable(gl.POLYGON_OFFSET_FILL)
		}

		// Draw faces with colors
		if obj.use_per_face_colors {
			for face_idx in 0 ..< 6 {
				color := obj.face_colors[face_idx]

				// Highlight if this is the selected face
				if highlight_face == i32(face_idx) && is_selected {
					color = color * 1.3 // Brighten
				}

				gl.Uniform4f(
					gl.GetUniformLocation(shader, "objectColor"),
					color.r,
					color.g,
					color.b,
					color.a,
				)

				gl.BindVertexArray(obj.vao)
				gl.DrawArrays(gl.TRIANGLES, i32(face_idx) * 6, 6)
			}
		} else {
			gl.Uniform4f(
				gl.GetUniformLocation(shader, "objectColor"),
				obj.color.r,
				obj.color.g,
				obj.color.b,
				obj.color.a,
			)

			gl.BindVertexArray(obj.vao)
			gl.DrawArrays(gl.TRIANGLES, 0, 36)
		}
	}
}

// Ray-AABB intersection test
// test_ray_cube :: proc(origin, dir, min, max: glsl.vec3) -> bool {
// 	t1 := (min.x - origin.x) / dir.x
// 	t2 := (max.x - origin.x) / dir.x
// 	t3 := (min.y - origin.y) / dir.y
// 	t4 := (max.y - origin.y) / dir.y
// 	t5 := (min.z - origin.z) / dir.z
// 	t6 := (max.z - origin.z) / dir.z

// 	tmin := max(max(min(t1, t2), min(t3, t4)), min(t5, t6))
// 	tmax := min(min(max(t1, t2), max(t3, t4)), max(t5, t6))

// 	if tmax < 0 do return false
// 	if tmin > tmax do return false

// 	return true
// }
