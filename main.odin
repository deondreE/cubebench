package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg/glsl"
import gl "vendor:OpenGL"
import "vendor:glfw"
import "vendor:stb/image"

SCR_WIDTH :: 1280
SCR_HEIGHT :: 720

Window_State :: struct {
	width: i32,
	height: i32,
	aspect_ratio: f32,
}

window_state_init :: proc(w, h: i32) {
	window_state.width = w
	window_state.height = h
	window_state.aspect_ratio = f32(w) / f32(h)
}

window_state: Window_State

// Camera
camera_yaw: f32 = -45.0
camera_pitch: f32 = 30.0
camera_dist: f32 = 10.0
is_camera_panning: bool = false
pan_offset: glsl.vec3 = {0, 0, 0}
last_mouse_x: f64 = SCR_WIDTH / 2.0
last_mouse_y: f64 = SCR_HEIGHT / 2.0
first_mouse: bool = true

// Scene
scene: Scene
ui: UI_Context
anim_state: Animation_State
timeline: Timeline_UI
tool_mode: Tool_Mode = .SELECT
edit_mode: Edit_Mode = .OBJECT

// Interaction state
is_dragging: bool = false
active_axis: Axis = .NONE
drag_start_pos: glsl.vec2
selected_face: i32 = -1

Tool_Mode :: enum {
	SELECT,
	TRANSLATE,
	SCALE,
	ROTATE,
	EXTRUDE,
	PAINT,
}

Extrude_State :: struct {
	active: bool,
	original_face: i32,
	extrude_obj: int,
	extrude_distance: f32,
}

Paint_State :: struct {
	active:         bool,
	brush_color:    glsl.vec4,
	brush_size:     i32,
	last_paint_pos: glsl.vec2,
	painting:       bool,
}

Edit_Mode :: enum {
	OBJECT,
	FACE,
}

Axis :: enum {
	NONE,
	X,
	Y,
	Z,
}

paint_state: Paint_State = {
	active         = false,
	brush_color    = {1, 0, 0, 1},
	brush_size     = 5,
	last_paint_pos = {-1, -1},
	painting       = false,
}

uv_editor: UV_Editor
extrude_state: Extrude_State

paint_on_face :: proc(scene: ^Scene, obj_idx: int, face_idx: i32, uv: glsl.vec2) {
	if obj_idx < 0 || obj_idx >= len(scene.objects) do return

	obj := scene.objects[obj_idx]
	if obj.texture_atlas == nil do return

	if !obj.use_texture {
		obj.use_texture = true
	}

	u0, v0, u1, v1 := get_face_uv_region(Face_Index(face_idx), obj.texture_atlas.width)

	// convert uv to pixel space
	local_u := uv.x
	local_v := uv.y

	texture_u := u0 + local_u * (u1 - u0)
	texture_v := v0 + local_v * (v1 - v0)

	pixel_x := i32(texture_u * f32(obj.texture_atlas.width))
	pixel_y := i32(texture_v * f32(obj.texture_atlas.height))

	paint_brush(
		obj.texture_atlas,
		pixel_x,
		pixel_y,
		paint_state.brush_size,
		paint_state.brush_color,
	)
}

// UV coords from the raycast hit.
get_face_uv_from_hit :: proc(local_hit: glsl.vec3, face_idx: Face_Index) -> glsl.vec2 {
	switch face_idx {
	case .FRONT:
		// Z+
		return {(local_hit.x + 0.5), (local_hit.y + 0.5)}
	case .BACK:
		// Z-
		return {(0.5 - local_hit.x), (local_hit.y + 0.5)}
	case .LEFT:
		// X-
		return {(0.5 - local_hit.z), (local_hit.y + 0.5)}
	case .RIGHT:
		// X+
		return {(0.5 - local_hit.z + 0.5), (local_hit.y + 0.5)}
	case .TOP:
		// Y+
		return {(local_hit.x + 0.5), (0.5 - local_hit.z)}
	case .BOTTOM:
		// Y-
		return {(local_hit.x + 0.5), (local_hit.z + 0.5)}
	}
	return {0, 0}
}

calculate_ray :: proc(nx, ny: f32, proj, view: glsl.mat4) -> (origin, dir: glsl.vec3) {
	inv_proj := glsl.inverse_mat4(proj)
	inv_view := glsl.inverse_mat4(view)

	near_pt := inv_proj * glsl.vec4{nx, ny, -1, 1}
	near_pt /= near_pt.w
	origin = (inv_view * near_pt).xyz

	far_pt := inv_proj * glsl.vec4{nx, ny, 1, 1}
	far_pt /= far_pt.w
	dir = glsl.normalize((inv_view * far_pt).xyz - origin)
	return
}

draw_gizmo_axis :: proc(
	shader, vao_stem, vao_tip: u32,
	pos, color: glsl.vec3,
	axis_type: i32,
	is_active: bool,
	view, proj: glsl.mat4,
	mode: Tool_Mode,
) {
	gl.UseProgram(shader)
	m_loc := gl.GetUniformLocation(shader, "model")
	v_loc := gl.GetUniformLocation(shader, "view")
	p_loc := gl.GetUniformLocation(shader, "projection")
	c_loc := gl.GetUniformLocation(shader, "gizmoColor")
	a_loc := gl.GetUniformLocation(shader, "isActive")

	v := view
	p := proj
	gl.UniformMatrix4fv(v_loc, 1, false, &v[0, 0])
	gl.UniformMatrix4fv(p_loc, 1, false, &p[0, 0])
	gl.Uniform3f(c_loc, color.r, color.g, color.b)
	gl.Uniform1i(a_loc, i32(is_active))

	model := glsl.mat4Translate(pos)
	if axis_type == 0 do model *= glsl.mat4Rotate({0, 1, 0}, glsl.radians(f32(90.0)))
	if axis_type == 1 do model *= glsl.mat4Rotate({1, 0, 0}, glsl.radians(f32(-90.0)))

	switch mode {
	case .TRANSLATE:
		gl.UniformMatrix4fv(m_loc, 1, false, &model[0, 0])
		gl.BindVertexArray(vao_stem)
		gl.DrawArrays(gl.LINES, 0, 2)

		tip_model := model * glsl.mat4Translate({0, 0, 1.0})
		gl.UniformMatrix4fv(m_loc, 1, false, &tip_model[0, 0])
		gl.BindVertexArray(vao_tip)
		gl.DrawArrays(gl.TRIANGLES, 0, 96)

	case .SCALE:
		gl.UniformMatrix4fv(m_loc, 1, false, &model[0, 0])
		gl.BindVertexArray(vao_stem)
		gl.DrawArrays(gl.LINES, 0, 2)

		tip_model := model * glsl.mat4Translate({0, 0, 1.0})
		gl.UniformMatrix4fv(m_loc, 1, false, &tip_model[0, 0])
		gl.BindVertexArray(vao_tip)
		gl.DrawArrays(gl.TRIANGLES, 96, 36)

	case .ROTATE:
		gl.LineWidth(3.0)
		gl.UniformMatrix4fv(m_loc, 1, false, &model[0, 0])
		gl.BindVertexArray(vao_tip)
		gl.DrawArrays(gl.LINES, 100, 64)

	case .SELECT, .EXTRUDE, .PAINT:
	// No gizmo for these modes
	}
}

framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
	context = runtime.default_context()
	gl.Viewport(0, 0, width, height)

	window_state.width = width
	window_state.height = height
	window_state.aspect_ratio = f32(width) / f32(height)

	ui_resize(&ui, width, height)
}

mouse_callback :: proc "c" (window: glfw.WindowHandle, xpos, ypos: f64) {
	context = runtime.default_context()

	nx := f32((2.0 * xpos) / f64(window_state.width) - 1.0)
	ny := f32(1.0 - (2.0 * ypos) / f64(window_state.height))
	
	if glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_RIGHT) != glfw.PRESS {
		first_mouse = true
		return
	}
	
	if first_mouse {
		last_mouse_x, last_mouse_y = xpos, ypos
		first_mouse = false
	}
	
	xoffset := f32(xpos - last_mouse_x)
	yoffset := f32(last_mouse_y - ypos)
	last_mouse_x, last_mouse_y = xpos, ypos

	sensitivity: f32 = 0.5
	camera_yaw += xoffset * sensitivity
	camera_pitch += yoffset * sensitivity
	camera_pitch = clamp(camera_pitch, -89.0, 89.0)

	if glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_MIDDLE) == glfw.PRESS {
		front := glsl.normalize(
			glsl.vec3 {
				glsl.cos(glsl.radians(camera_yaw)) * glsl.cos(glsl.radians(camera_pitch)),
				glsl.sin(glsl.radians(camera_pitch)),
				glsl.sin(glsl.radians(camera_yaw)) * glsl.cos(glsl.radians(camera_pitch)),
			},
		)
		right := glsl.normalize(glsl.cross(front, glsl.vec3{0, 1, 0}))
		up := glsl.normalize(glsl.cross(right, front))

		pan_speed := camera_dist * 0.001
		pan_offset -= right * xoffset * pan_speed
		pan_offset -= up * yoffset * pan_speed
		return
	}

	if uv_editor.visible && len(scene.selected_objects) > 0 {
		obj := &scene.objects[scene.selected_objects[0]]
		left_pressed := glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS
		middle_pressed := glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_MIDDLE) == glfw.PRESS

		uv_editor_handle_input(&uv_editor, xpos, ypos, left_pressed, middle_pressed, obj)

		// if painting switch to next frame
		for uv_editor.is_painting {
			glfw.SwapBuffers(window)
			glfw.PollEvents()
			continue
		}
	}
}

scroll_callback :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
	context = runtime.default_context()

	mx, my := glfw.GetCursorPos(window)
	local_x := f32(mx) - uv_editor.x
	local_y := f32(my) - uv_editor.y

	// Check if mouse is over UV editor
	if uv_editor.visible &&
	   local_x >= 0 &&
	   local_x <= uv_editor.width &&
	   local_y >= 0 &&
	   local_y <= uv_editor.height {
		uv_editor_handle_scroll(&uv_editor, mx, my, yoffset)
	} else {
		camera_dist -= f32(yoffset) * 0.5
		camera_dist = clamp(camera_dist, 1.0, 50.0)
	}
}

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	context = runtime.default_context()
	if action == glfw.PRESS {
		switch key {
		case glfw.KEY_G:
			tool_mode = .TRANSLATE
		case glfw.KEY_O:
			if mods == glfw.MOD_CONTROL {
				load_scene_from_file(&scene, "./test_project.json")
			}
		case glfw.KEY_Z:
			if mods == glfw.MOD_CONTROL {
				undo_perform(&scene)
			} else if mods == glfw.MOD_SHIFT {
				redo_perform(&scene)
			}
		case glfw.KEY_S:
			if mods == glfw.MOD_CONTROL {
				// TODO: Save
				save_scene_to_file(&scene, "./test_project.json")
			} else {
				tool_mode = .SCALE
			}
		case glfw.KEY_SPACE:
			if anim_state.animations[anim_state.current_anim].playing {
				anim_pause(&anim_state)
			} else {
				anim_play(&anim_state)
			}
		case glfw.KEY_K:
			for obj_id in scene.selected_objects {
				anim_record_transform(&anim_state, &scene, obj_id)
			}
		case glfw.KEY_U:
			uv_editor.visible = !uv_editor.visible
			if uv_editor.visible && len(scene.selected_objects) > 0 {
				obj := &scene.objects[scene.selected_objects[0]]
				uv_editor_update_mesh(&uv_editor, obj)
			}
		case glfw.KEY_R:
			tool_mode = .ROTATE
		case glfw.KEY_E:
			tool_mode = .EXTRUDE
		case glfw.KEY_P:
			tool_mode = .PAINT
		case glfw.KEY_T:
			if mods == glfw.MOD_CONTROL {
				timeline.visible = !timeline.visible
			} else {
				if len(scene.selected_objects) > 0 {
					obj := &scene.objects[scene.selected_objects[0]]
					obj.use_texture = !obj.use_texture
				}
			}
		case glfw.KEY_L:
			if len(scene.selected_objects) > 0 {
				obj := &scene.objects[scene.selected_objects[0]]
				if load_texture_from_file(obj.texture_atlas, "texture.png") {
					obj.use_texture = true
				}
			}
		case glfw.KEY_TAB:
			edit_mode = edit_mode == .OBJECT ? .FACE : .OBJECT
		case glfw.KEY_DELETE:
			record_delete_object(&scene, len(scene.objects) + 1)
			scene_delete_selected(&scene)
		case glfw.KEY_D:
			if mods == glfw.MOD_CONTROL {
				record_add_object(&scene, len(scene.objects) + 1)
				scene_duplicate_selected(&scene)
			}
		}
	}
}

generate_grid :: proc(size, step: i32) -> []f32 {
	grid := make([dynamic]f32)
	f_size, f_step := f32(size), f32(step)
	for i := -f_size; i <= f_size + 0.1; i += f_step {
		append(&grid, i, 0, -f_size, i, 0, f_size)
		append(&grid, -f_size, 0, i, f_size, 0, i)
	}
	return grid[:]
}

generate_cone :: proc(segments: i32 = 16, radius: f32 = 0.1, height: f32 = 0.4) -> []f32 {
	vertices := make([dynamic]f32)

	tip := glsl.vec3({0, 0, height})

	for i in 0 ..< segments {
		angle1 := f32(i) * 2.0 * math.PI / f32(segments)
		angle2 := f32(i + 1) * 2.0 * math.PI / f32(segments)

		p1 := glsl.vec3{radius * math.cos(angle1), radius * math.sin(angle1), 0}
		p2 := glsl.vec3{radius * math.cos(angle2), radius * math.sin(angle2), 0}

		edge1 := p2 - p1
		edge2 := tip - p1
		normal := glsl.normalize(glsl.cross(edge1, edge2))

		append(&vertices, tip.x, tip.y, tip.z, normal.x, normal.y, normal.z)
		append(&vertices, p1.x, p1.y, p1.z, normal.x, normal.y, normal.z)
		append(&vertices, p2.x, p2.y, p2.z, normal.x, normal.y, normal.z)

		base_normal := glsl.vec3{0, 0, -1}
		append(&vertices, 0, 0, 0, base_normal.x, base_normal.y, base_normal.z)
		append(&vertices, p2.x, p2.y, p2.z, base_normal.x, base_normal.y, base_normal.z)
		append(&vertices, p1.x, p1.y, p1.z, base_normal.x, base_normal.y, base_normal.z)
	}

	return vertices[:]
}

generate_cube_tip :: proc(s: f32) -> []f32 {
	v := make([dynamic]f32)

	add_v :: proc(v: ^[dynamic]f32, x, y, z, nx, ny, nz: f32) {
		append(v, x, y, z, nx, ny, nz)
	}

	add_v(&v, -s, -s, s, 0, 0, 1); add_v(&v, s, -s, s, 0, 0, 1); add_v(&v, s, s, s, 0, 0, 1)
	add_v(&v, s, s, s, 0, 0, 1); add_v(&v, -s, s, s, 0, 0, 1); add_v(&v, -s, -s, s, 0, 0, 1)

	add_v(&v, s, -s, -s, 0, 0, -1); add_v(&v, -s, -s, -s, 0, 0, -1); add_v(&v, -s, s, -s, 0, 0, -1)
	add_v(&v, -s, s, -s, 0, 0, -1); add_v(&v, s, s, -s, 0, 0, -1); add_v(&v, s, -s, -s, 0, 0, -1)

	add_v(&v, -s, -s, -s, -1, 0, 0); add_v(&v, -s, -s, s, -1, 0, 0); add_v(&v, -s, s, s, -1, 0, 0)
	add_v(&v, -s, s, s, -1, 0, 0); add_v(&v, -s, s, -s, -1, 0, 0); add_v(&v, -s, -s, -s, -1, 0, 0)

	add_v(&v, s, -s, s, 1, 0, 0); add_v(&v, s, -s, -s, 1, 0, 0); add_v(&v, s, s, -s, 1, 0, 0)
	add_v(&v, s, s, -s, 1, 0, 0); add_v(&v, s, s, s, 1, 0, 0); add_v(&v, s, -s, s, 1, 0, 0)

	add_v(&v, -s, s, s, 0, 1, 0); add_v(&v, s, s, s, 0, 1, 0); add_v(&v, s, s, -s, 0, 1, 0)
	add_v(&v, s, s, -s, 0, 1, 0); add_v(&v, -s, s, -s, 0, 1, 0); add_v(&v, -s, s, s, 0, 1, 0)

	add_v(&v, -s, -s, -s, 0, -1, 0); add_v(&v, s, -s, -s, 0, -1, 0); add_v(&v, s, -s, s, 0, -1, 0)
	add_v(&v, s, -s, s, 0, -1, 0); add_v(&v, -s, -s, s, 0, -1, 0); add_v(&v, -s, -s, -s, 0, -1, 0)

	return v[:]
}

generate_gizmo_tips :: proc() -> []f32 {
	tips := make([dynamic]f32)

	// Arrow tip
	cone := generate_cone(16, 0.05, 0.2)
	for v in cone do append(&tips, v)

	// Cube tip
	s: f32 = 0.05
	cube_edges := generate_cube_tip(s)
	for v in cube_edges do append(&tips, v)

	circle := generate_circle(32, 1.2)
	for i := 0; i < len(circle); i += 3 {
		append(&tips, circle[i], circle[i + 1], circle[1 + 2], 0, 0, 1)
	}

	return tips[:]
}

generate_circle :: proc(segments: i32, radius: f32) -> []f32 {
	circle := make([dynamic]f32)
	for i in 0 ..< segments {
		angle := f32(i) * 2.0 * math.PI / f32(segments)
		x := radius * math.cos(angle)
		y := radius * math.sin(angle)
		append(&circle, x, y, 0)
	}
	return circle[:]
}

main :: proc() {
	glfw.Init()
	window := glfw.CreateWindow(SCR_WIDTH, SCR_HEIGHT, "Blockbench Clone", nil, nil)
	glfw.MakeContextCurrent(window)
	gl.load_up_to(3, 3, glfw.gl_set_proc_address)

	glfw.SetFramebufferSizeCallback(window, framebuffer_size_callback)
	glfw.SetCursorPosCallback(window, mouse_callback)
	glfw.SetScrollCallback(window, scroll_callback)
	glfw.SetKeyCallback(window, key_callback)

	icon_width, icon_height, icon_channels: i32
	icon_pixels := image.load("icons/Icon.png", &icon_width, &icon_height, &icon_channels, 4)
	if icon_pixels != nil {
		icon_image := glfw.Image {
			width  = icon_width,
			height = icon_height,
			pixels = icon_pixels,
		}

		icon_arr := [?]glfw.Image{icon_image}
		glfw.SetWindowIcon(window, icon_arr[:])

		// Clean up the memory once it's uploaded to the window system
		image.image_free(icon_pixels)
	} else {
		fmt.println("Failed to load icon: icons/Icon.png")
	}

	ui_init(&ui, SCR_WIDTH, SCR_HEIGHT)
	defer ui_cleanup(&ui)

	scene_init(&scene)
	defer scene_cleanup(&scene)

	lua_init()
	defer lua_cleanup()

	uv_editor_init(&uv_editor, 20, 100, 400, 400)
	defer uv_editor_cleanup(&uv_editor)

	undo_init(100)
	defer undo_cleanup()

	anim_state_init(&anim_state)
	timeline_init(&timeline)
	defer anim_state_cleanup(&anim_state)

	// TODO: Remove this later
	anim_create(&anim_state, "Idle", 5.0)
	anim_state.current_anim = 0

	// Add a default cube
	scene_add_cube(&scene, {0, 0, 0}, {1, 1, 1}, {1, 1, 1, 1})

	grid_vertices := generate_grid(10, 1)
	stem_vertices := [?]f32{0, 0, 0, 0, 0, 1.0}
	tip_vertices := generate_gizmo_tips()
	// circle_vertices := generate_circle(64, 1.0)

	shaderProgram, _ := gl.load_shaders_file("./shaders/shader.vs", "./shaders/shader.fs")
	gridShader, _ := gl.load_shaders_file("./shaders/grid.vs", "./shaders/grid.fs")
	gizmoShader, _ := gl.load_shaders_file("./shaders/gizmos.vs", "./shaders/gizmos.fs")

	// Grid VAO
	gVAO, gVBO: u32
	gl.GenVertexArrays(1, &gVAO); gl.GenBuffers(1, &gVBO)
	gl.BindVertexArray(gVAO); gl.BindBuffer(gl.ARRAY_BUFFER, gVBO)
	gl.BufferData(gl.ARRAY_BUFFER, len(grid_vertices) * 4, raw_data(grid_vertices), gl.STATIC_DRAW)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)

	// Gizmo stem VAO
	sVAO, sVBO: u32
	gl.GenVertexArrays(1, &sVAO); gl.GenBuffers(1, &sVBO)
	gl.BindVertexArray(sVAO); gl.BindBuffer(gl.ARRAY_BUFFER, sVBO)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(stem_vertices), &stem_vertices[0], gl.STATIC_DRAW)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)

	// Gizmo tip VAO
	tVAO, tVBO: u32
	stride := i32(6 * size_of(f32))
	gl.GenVertexArrays(1, &tVAO); gl.GenBuffers(1, &tVBO)
	gl.BindVertexArray(tVAO); gl.BindBuffer(gl.ARRAY_BUFFER, tVBO)
	gl.BufferData(gl.ARRAY_BUFFER, len(tip_vertices) * 4, raw_data(tip_vertices), gl.STATIC_DRAW)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, stride, 0)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(1, 3, gl.FLOAT, gl.FALSE, stride, 3 * size_of(f32))
	gl.EnableVertexAttribArray(1)

	gl.Enable(gl.DEPTH_TEST)
	gl.Enable(gl.CULL_FACE)

	for !glfw.WindowShouldClose(window) {
		gl.ClearColor(0.1, 0.1, 0.1, 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

		ui_begin_frame(&ui, window)

		mx, my := glfw.GetCursorPos(window)
		nx, ny := f32((2.0 * mx) / f64(window_state.width) - 1.0), f32(1.0 - (2.0 * my) / f64(window_state.height))

		// Camera
		cam_pos := glsl.vec3 {
			camera_dist *
			glsl.cos(glsl.radians(camera_yaw)) *
			glsl.cos(glsl.radians(camera_pitch)),
			camera_dist * glsl.sin(glsl.radians(camera_pitch)),
			camera_dist *
			glsl.sin(glsl.radians(camera_yaw)) *
			glsl.cos(glsl.radians(camera_pitch)),
		}
		target := pan_offset
		actual_cam_pos := cam_pos + pan_offset
		view := glsl.mat4LookAt(actual_cam_pos, target, {0, 1, 0})
		proj := glsl.mat4Perspective(glsl.radians(f32(45.0)), SCR_WIDTH / SCR_HEIGHT, 0.1, 100.0)

		origin, dir := calculate_ray(nx, ny, proj, view)
		hover_axis := active_axis

		// Handle mouse interaction
		if !ui_is_mouse_over(&ui) {
			if glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS {
				if !is_dragging {
					switch edit_mode {
					case .OBJECT:
						// Check gizmo first
						if len(scene.selected_objects) > 0 && tool_mode != .SELECT {
							center := scene_get_selection_center(&scene)
							if test_ray_cube(
								origin,
								dir,
								center + {0, -0.1, -0.1},
								center + {1.5, 0.1, 0.1},
							) {
								hover_axis = .X
							} else if test_ray_cube(
								origin,
								dir,
								center + {-0.1, 0, -0.1},
								center + {0.1, 1.5, 0.1},
							) {
								hover_axis = .Y
							} else if test_ray_cube(
								origin,
								dir,
								center + {-0.1, -0.1, 0},
								center + {0.1, 0.1, 1.5},
							) {
								hover_axis = .Z
							}

							if hover_axis != .NONE {
								active_axis, is_dragging = hover_axis, true
								drag_start_pos = {f32(mx), f32(my)}
							}
						}

						// Otherwise select object
						if !is_dragging {
							hit_obj := scene_raycast(&scene, origin, dir)
							if hit_obj >= 0 {
								if glfw.GetKey(window, glfw.KEY_LEFT_SHIFT) == glfw.PRESS {
									scene_toggle_selection(&scene, hit_obj)
								} else {
									scene_select_object(&scene, hit_obj)
								}
							} else {
								scene_clear_selection(&scene)
							}
						}

					case .FACE:
						// Face selection
						hit_obj, hit_face := scene_raycast_face(&scene, origin, dir)
						if hit_obj >= 0 && hit_face >= 0 {
							selected_face = hit_face
							scene_select_object(&scene, hit_obj)
						}
					}
				}

				// Handle dragging
				if is_dragging && len(scene.selected_objects) > 0 {
					dx, dy := f32(mx - last_mouse_x) * 0.05, f32(last_mouse_y - my) * 0.05

					switch tool_mode {
					case .TRANSLATE:
						scene_translate_selected(&scene, active_axis, dx, dy)
					case .SCALE:
						scene_scale_selected(&scene, active_axis, dx + dy)
					case .ROTATE:
						scene_rotate_selected(&scene, active_axis, (dx + dy) * 2.0)
					case .PAINT:
						if glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS {
							obj_idx, face_idx, uv, hit_ok := scene_raycast_face_uv(
								&scene,
								origin,
								dir,
							)
							if hit_ok {
								paint_on_face(&scene, obj_idx, face_idx, uv)
								paint_state.painting = true
							}
						} else {
							paint_state.painting = false
						}
					case .SELECT, .EXTRUDE:
					}
				}
			} else {
				is_dragging, active_axis = false, .NONE
			}
		}
		last_mouse_x, last_mouse_y = mx, my

		// Render scene
		scene_render(&scene, shaderProgram, view, proj, edit_mode == .FACE ? selected_face : -1)

		// Render grid
		gl.UseProgram(gridShader)
		gl.UniformMatrix4fv(gl.GetUniformLocation(gridShader, "view"), 1, false, &view[0, 0])
		gl.UniformMatrix4fv(gl.GetUniformLocation(gridShader, "projection"), 1, false, &proj[0, 0])
		id := glsl.mat4(1.0)
		gl.UniformMatrix4fv(gl.GetUniformLocation(gridShader, "model"), 1, false, &id[0, 0])
		gl.BindVertexArray(gVAO)
		gl.DrawArrays(gl.LINES, 0, i32(len(grid_vertices) / 3))

		// Render gizmos
		if len(scene.selected_objects) > 0 && tool_mode != .SELECT && edit_mode == .OBJECT {
			center := scene_get_selection_center(&scene)
			gl.Disable(gl.DEPTH_TEST)
			draw_gizmo_axis(
				gizmoShader,
				sVAO,
				tVAO,
				center,
				{1, 0, 0},
				0,
				hover_axis == .X,
				view,
				proj,
				tool_mode,
			)
			draw_gizmo_axis(
				gizmoShader,
				sVAO,
				tVAO,
				center,
				{0, 1, 0},
				1,
				hover_axis == .Y,
				view,
				proj,
				tool_mode,
			)
			draw_gizmo_axis(
				gizmoShader,
				sVAO,
				tVAO,
				center,
				{0, 0, 1},
				2,
				hover_axis == .Z,
				view,
				proj,
				tool_mode,
			)
			gl.Enable(gl.DEPTH_TEST)
		}

		// Clear depth buffer before UI so UI is always on top
		gl.Clear(gl.DEPTH_BUFFER_BIT)
		ui_render_begin(&ui, SCR_WIDTH, SCR_HEIGHT)
		render_ui(&ui, &scene, &tool_mode, &edit_mode)
		last_time := f32(glfw.GetTime())
		if timeline.visible {
			timeline_render(&timeline, &anim_state, &scene, &ui)
			anim_update(&anim_state, &scene, f32(glfw.GetTime() - f64(last_time)))
		}

		if uv_editor.visible && len(scene.selected_objects) > 0 {
			obj := &scene.objects[scene.selected_objects[0]]
			uv_editor_render(&uv_editor, obj, &ui)
		}

		ui_render_end(&ui)

		ui_end_frame(&ui)

		glfw.SwapBuffers(window)
		glfw.PollEvents()
		lua_update_live()
	}
}

render_ui :: proc(ctx: ^UI_Context, scene: ^Scene, tool_mode: ^Tool_Mode, edit_mode: ^Edit_Mode) {
	ui_render_begin(ctx, SCR_WIDTH, SCR_HEIGHT)

	// === TOP TOOLBAR (like Blender) ===
	toolbar_height: f32 = 50
	ui_panel_begin(ctx, 0, 0, SCR_WIDTH, toolbar_height, "")

	// Tool buttons with icons (horizontal layout)
	ctx.cursor_x = 10
	ctx.cursor_y = 10

	button_size: f32 = 32

	// Mode selector
	if ui_icon_button(ctx, edit_mode^ == .OBJECT ? "cube" : "face", button_size) {
		edit_mode^ = edit_mode^ == .OBJECT ? .FACE : .OBJECT
	}
	ctx.cursor_x += button_size + 5
	ctx.cursor_y = 10

	// Separator
	batch_rect(ctx, UI_Rect{ctx.cursor_x, 5, 2, toolbar_height - 10}, ctx.style.border_color)
	ctx.cursor_x += 10

	// Transform tools
	if ui_icon_button(ctx, "translate", button_size) do tool_mode^ = .TRANSLATE
	ctx.cursor_x += button_size + 5
	ctx.cursor_y = 10

	if ui_icon_button(ctx, "scale", button_size) do tool_mode^ = .SCALE
	ctx.cursor_x += button_size + 5
	ctx.cursor_y = 10

	if ui_icon_button(ctx, "rotate", button_size) do tool_mode^ = .ROTATE
	ctx.cursor_x += button_size + 5
	ctx.cursor_y = 10

	// Separator
	batch_rect(ctx, UI_Rect{ctx.cursor_x, 5, 2, toolbar_height - 10}, ctx.style.border_color)
	ctx.cursor_x += 10

	// Add object button (text button)
	ctx.cursor_y = 13
	if ui_button(ctx, "+ Add Cube", 100) {
		scene_add_cube(scene, {0, 0, 0}, {1, 1, 1}, {1, 1, 1, 1})
	}

	ui_panel_end(ctx)

	// === LEFT SIDEBAR - TOOLS & PROPERTIES ===
	sidebar_width: f32 = 280
	sidebar_height := SCR_HEIGHT - toolbar_height

	ui_panel_begin(ctx, 0, toolbar_height, sidebar_width, sidebar_height, "")

	// Current tool indicator
	tool_display_name: string
	switch tool_mode^ {
	case .SELECT:
		tool_display_name = "Select"
	case .TRANSLATE:
		tool_display_name = "Move (G)"
	case .SCALE:
		tool_display_name = "Scale (S)"
	case .ROTATE:
		tool_display_name = "Rotate (R)"
	case .EXTRUDE:
		tool_display_name = "Extrude (E)"
	case .PAINT:
		tool_display_name = "Paint (P)"
	}

	// Tool header with colored background
	tool_header_rect := UI_Rect {
		ctx.cursor_x,
		ctx.cursor_y,
		sidebar_width - ctx.style.padding * 2,
		30,
	}
	batch_rect(ctx, tool_header_rect, UI_Color{0.25, 0.5, 0.8, 0.3})
	batch_text(
		ctx,
		fmt.tprintf("Tool: %s", tool_display_name),
		ctx.cursor_x + 8,
		ctx.cursor_y + 8,
		ctx.style.text_color,
	)
	ctx.cursor_y += 35

	ui_separator(ctx)

	// Transform section (collapsible style)
	if len(scene.selected_objects) > 0 {
		obj_idx := scene.selected_objects[0]
		obj := &scene.objects[obj_idx]

		// Object name header
		ui_label(ctx, fmt.tprintf("► Cube.%03d", obj_idx))
		ui_spacing(ctx, 4)

		// Position controls
		section_rect := UI_Rect {
			ctx.cursor_x,
			ctx.cursor_y,
			sidebar_width - ctx.style.padding * 2,
			20,
		}
		batch_rect(ctx, section_rect, UI_Color{0.18, 0.18, 0.22, 1.0})
		batch_text(
			ctx,
			"Location",
			ctx.cursor_x + 8,
			ctx.cursor_y + 3,
			UI_Color{0.7, 0.7, 0.75, 1.0},
		)
		ctx.cursor_y += 25

		ui_slider(ctx, &obj.position.x, -10, 10, "X")
		ui_slider(ctx, &obj.position.y, -10, 10, "Y")
		ui_slider(ctx, &obj.position.z, -10, 10, "Z")

		ui_spacing(ctx, 8)

		// Rotation controls
		section_rect = UI_Rect {
			ctx.cursor_x,
			ctx.cursor_y,
			sidebar_width - ctx.style.padding * 2,
			20,
		}
		batch_rect(ctx, section_rect, UI_Color{0.18, 0.18, 0.22, 1.0})
		batch_text(
			ctx,
			"Rotation",
			ctx.cursor_x + 8,
			ctx.cursor_y + 3,
			UI_Color{0.7, 0.7, 0.75, 1.0},
		)
		ctx.cursor_y += 25

		ui_slider(ctx, &obj.rotation.x, -180, 180, "X")
		ui_slider(ctx, &obj.rotation.y, -180, 180, "Y")
		ui_slider(ctx, &obj.rotation.z, -180, 180, "Z")

		ui_spacing(ctx, 8)

		// Scale controls
		section_rect = UI_Rect {
			ctx.cursor_x,
			ctx.cursor_y,
			sidebar_width - ctx.style.padding * 2,
			20,
		}
		batch_rect(ctx, section_rect, UI_Color{0.18, 0.18, 0.22, 1.0})
		batch_text(ctx, "Scale", ctx.cursor_x + 8, ctx.cursor_y + 3, UI_Color{0.7, 0.7, 0.75, 1.0})
		ctx.cursor_y += 25

		ui_slider(ctx, &obj.scale.x, 0.1, 5, "X")
		ui_slider(ctx, &obj.scale.y, 0.1, 5, "Y")
		ui_slider(ctx, &obj.scale.z, 0.1, 5, "Z")

		ui_spacing(ctx, 8)

		// Color section
		section_rect = UI_Rect {
			ctx.cursor_x,
			ctx.cursor_y,
			sidebar_width - ctx.style.padding * 2,
			20,
		}
		batch_rect(ctx, section_rect, UI_Color{0.18, 0.18, 0.22, 1.0})
		batch_text(ctx, "Color", ctx.cursor_x + 8, ctx.cursor_y + 3, UI_Color{0.7, 0.7, 0.75, 1.0})
		ctx.cursor_y += 25

		// Color preview square
		color_preview_rect := UI_Rect{ctx.cursor_x, ctx.cursor_y, 40, 40}
		batch_rect(ctx, color_preview_rect, UI_Color{obj.color.r, obj.color.g, obj.color.b, 1.0})
		batch_rect_outline(ctx, color_preview_rect, ctx.style.border_color, 2)

		ctx.cursor_x += 50
		old_y := ctx.cursor_y

		// Color sliders (compact)
		ctx.cursor_y = old_y
		ui_slider(ctx, &obj.color.r, 0, 1, "R")
		ui_slider(ctx, &obj.color.g, 0, 1, "G")
		ui_slider(ctx, &obj.color.b, 0, 1, "B")

		ctx.cursor_x = 8

		ui_spacing(ctx, 12)
		ui_separator(ctx)

		// Action buttons
		if ui_button(ctx, "Duplicate (Ctrl+D)", 0) {
			scene_duplicate_selected(scene)
		}

		if ui_button(ctx, "Delete (Del)", 0) {
			scene_delete_selected(scene)
		}

	} else {
		ui_spacing(ctx, 20)
		ui_label(ctx, "No object selected")
		ui_spacing(ctx, 10)
		ui_label(ctx, "Select an object to edit")
	}

	ui_panel_end(ctx)

	// === RIGHT SIDEBAR - OUTLINER ===
	outliner_width: f32 = 250
	outliner_x := SCR_WIDTH - outliner_width

	ui_panel_begin(ctx, outliner_x, toolbar_height, outliner_width, sidebar_height, "Outliner")

	if len(scene.objects) == 0 {
		ui_spacing(ctx, 20)
		ui_label(ctx, "Scene is empty")
		ui_spacing(ctx, 10)
		ui_label(ctx, "Press '+ Add Cube' to start")
	} else {
		ui_label(ctx, fmt.tprintf("Scene (%d objects)", len(scene.objects)))
		ui_separator(ctx)

		for _, i in scene.objects {
			is_selected := false
			for sel_idx in scene.selected_objects {
				if sel_idx == i {
					is_selected = true
					break
				}
			}

			// Custom button with icon-like appearance
			id := gen_id(ctx)
			w := outliner_width - ctx.style.padding * 2
			h: f32 = 28

			rect := UI_Rect{ctx.cursor_x, ctx.cursor_y, w, h}

			is_hot := point_in_rect(ctx.mouse_x, ctx.mouse_y, rect)
			if is_hot do ctx.hot_id = id

			if is_hot && ctx.mouse_pressed {
				scene_select_object(scene, i)
			}

			// Background color based on state
			bg_color := ctx.style.fg_color
			if is_selected {
				bg_color = UI_Color{0.3, 0.5, 0.8, 0.6}
			} else if is_hot {
				bg_color = ctx.style.hover_color
			}

			batch_rect(ctx, rect, bg_color)
			if is_selected {
				batch_rect_outline(ctx, rect, UI_Color{0.4, 0.6, 1.0, 1.0}, 2)
			}

			// Draw cube icon (simple square)
			icon_size: f32 = 16
			icon_rect := UI_Rect{ctx.cursor_x + 6, ctx.cursor_y + 6, icon_size, icon_size}
			batch_rect(ctx, icon_rect, UI_Color{0.6, 0.6, 0.65, 1.0})
			batch_rect_outline(ctx, icon_rect, ctx.style.border_color)

			// Object name
			label := fmt.tprintf("Cube.%03d", i)
			batch_text(ctx, label, ctx.cursor_x + 28, ctx.cursor_y + 7, ctx.style.text_color)

			ctx.cursor_y += h + 2
		}
	}

	ui_panel_end(ctx)

	// === BOTTOM STATUS BAR ===
	status_height: f32 = 24
	status_y := SCR_HEIGHT - status_height

	ui_panel_begin(ctx, 0, status_y, SCR_WIDTH, status_height, "")

	// Dark background for status bar
	status_bg := UI_Rect{0, status_y, SCR_WIDTH, status_height}
	batch_rect(ctx, status_bg, UI_Color{0.12, 0.12, 0.15, 1.0})

	// Status text (compact info)
	info_text := fmt.tprintf(
		"Objects: %d | Selected: %d | Mode: %s | LMB: Select | RMB: Orbit | Scroll: Zoom",
		len(scene.objects),
		len(scene.selected_objects),
		edit_mode^ == .OBJECT ? "Object" : "Face",
	)

	batch_text(ctx, info_text, 10, status_y + 5, UI_Color{0.7, 0.7, 0.75, 1.0})

	ui_panel_end(ctx)

	ui_render_end(ctx)
}
