package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg/glsl"
import gl "vendor:OpenGL"
import "vendor:glfw"

SCR_WIDTH :: 1280
SCR_HEIGHT :: 720

// Camera
camera_yaw: f32 = -45.0
camera_pitch: f32 = 30.0
camera_dist: f32 = 10.0
last_mouse_x: f64 = SCR_WIDTH / 2.0
last_mouse_y: f64 = SCR_HEIGHT / 2.0
first_mouse: bool = true

// Scene
scene: Scene
ui: UI_Context
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
		gl.DrawArrays(gl.TRIANGLES, 96, 256)

	case .ROTATE:
		gl.LineWidth(3.0)
		gl.UniformMatrix4fv(m_loc, 1, false, &model[0, 0])
		gl.BindVertexArray(vao_tip)
		gl.DrawArrays(gl.LINE_LOOP, 20, 32)

	case .SELECT, .EXTRUDE, .PAINT:
	// No gizmo for these modes
	}
}

framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
	gl.Viewport(0, 0, width, height)
}

mouse_callback :: proc "c" (window: glfw.WindowHandle, xpos, ypos: f64) {
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
}

scroll_callback :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
	camera_dist -= f32(yoffset) * 0.5
	camera_dist = clamp(camera_dist, 1.0, 50.0)
}

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	context = runtime.default_context()
	if action == glfw.PRESS {
		switch key {
		case glfw.KEY_G:
			tool_mode = .TRANSLATE
		case glfw.KEY_S:
			if mods == glfw.MOD_CONTROL {
				// TODO: Save
			} else {
				tool_mode = .SCALE
			}
		case glfw.KEY_R:
			tool_mode = .ROTATE
		case glfw.KEY_E:
			tool_mode = .EXTRUDE
		case glfw.KEY_P:
			tool_mode = .PAINT
		case glfw.KEY_T:
			if len(scene.selected_objects) > 0 {
				obj := &scene.objects[scene.selected_objects[0]]
				obj.use_texture = !obj.use_texture
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
			scene_delete_selected(&scene)
		case glfw.KEY_D:
			if mods == glfw.MOD_CONTROL {
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

	for i in 0..< segments {
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

	add_v(&v, -s, -s,  s, 0, 0, 1); add_v(&v,  s, -s,  s, 0, 0, 1); add_v(&v,  s,  s,  s, 0, 0, 1)
	add_v(&v,  s,  s,  s, 0, 0, 1); add_v(&v, -s,  s,  s, 0, 0, 1); add_v(&v, -s, -s,  s, 0, 0, 1)

	add_v(&v,  s, -s, -s, 0, 0,-1); add_v(&v, -s, -s, -s, 0, 0,-1); add_v(&v, -s,  s, -s, 0, 0,-1)
	add_v(&v, -s,  s, -s, 0, 0,-1); add_v(&v,  s,  s, -s, 0, 0,-1); add_v(&v,  s, -s, -s, 0, 0,-1)

	add_v(&v, -s, -s, -s, -1, 0, 0); add_v(&v, -s, -s,  s, -1, 0, 0); add_v(&v, -s,  s,  s, -1, 0, 0)
	add_v(&v, -s,  s,  s, -1, 0, 0); add_v(&v, -s,  s, -s, -1, 0, 0); add_v(&v, -s, -s, -s, -1, 0, 0)

	add_v(&v,  s, -s,  s, 1, 0, 0); add_v(&v,  s, -s, -s, 1, 0, 0); add_v(&v,  s,  s, -s, 1, 0, 0)
	add_v(&v,  s,  s, -s, 1, 0, 0); add_v(&v,  s,  s,  s, 1, 0, 0); add_v(&v,  s, -s,  s, 1, 0, 0)

	add_v(&v, -s,  s,  s, 0, 1, 0); add_v(&v,  s,  s,  s, 0, 1, 0); add_v(&v,  s,  s, -s, 0, 1, 0)
	add_v(&v,  s,  s, -s, 0, 1, 0); add_v(&v, -s,  s, -s, 0, 1, 0); add_v(&v, -s,  s,  s, 0, 1, 0)

	add_v(&v, -s, -s, -s, 0, -1, 0); add_v(&v,  s, -s, -s, 0, -1, 0); add_v(&v,  s, -s,  s, 0, -1, 0)
	add_v(&v,  s, -s,  s, 0, -1, 0); add_v(&v, -s, -s,  s, 0, -1, 0); add_v(&v, -s, -s, -s, 0, -1, 0)

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

	ui_init(&ui, SCR_WIDTH, SCR_HEIGHT)
	defer ui_cleanup(&ui)

	scene_init(&scene)
	defer scene_cleanup(&scene)

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
		nx, ny := f32((2.0 * mx) / SCR_WIDTH - 1.0), f32(1.0 - (2.0 * my) / SCR_HEIGHT)

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
		view := glsl.mat4LookAt(cam_pos, {0, 0, 0}, {0, 1, 0})
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
		// ui_render_begin(&ui, SCR_WIDTH, SCR_HEIGHT)
		// render_ui(&ui, &scene, &tool_mode, &edit_mode)
		// ui_render_end(&ui)

		// ui_end_frame(&ui)

		glfw.SwapBuffers(window)
		glfw.PollEvents()
	}
}

render_ui :: proc(ctx: ^UI_Context, scene: ^Scene, tool_mode: ^Tool_Mode, edit_mode: ^Edit_Mode) {
	ui_render_begin(ctx, SCR_WIDTH, SCR_HEIGHT)

	// Tools Panel
	ui_panel_begin(ctx, 10, 10, 150, 420, "Tools")

	tool_label := "Current: "
	switch tool_mode^ {
	case .SELECT:
		tool_label = "Current: Select"
	case .TRANSLATE:
		tool_label = "Current: Move (G)"
	case .SCALE:
		tool_label = "Current: Scale (S)"
	case .ROTATE:
		tool_label = "Current: Rotate (R)"
	case .EXTRUDE:
		tool_label = "Current: Extrude (E)"
	case .PAINT:
		tool_label = "Current: Paint (P)"
	}
	ui_label(ctx, tool_label)
	ui_separator(ctx)

	if ui_button(ctx, "Move (G)", 0) do tool_mode^ = .TRANSLATE
	if ui_button(ctx, "Scale (S)", 0) do tool_mode^ = .SCALE
	if ui_button(ctx, "Rotate (R)", 0) do tool_mode^ = .ROTATE

	ui_separator(ctx)

	if ui_button(ctx, "Add Cube", 0) {
		scene_add_cube(scene, {0, 0, 0}, {1, 1, 1}, {1, 1, 1, 1})
	}

	if ui_button(ctx, "Duplicate (Ctrl+D)", 0) {
		scene_duplicate_selected(scene)
	}

	if ui_button(ctx, "Delete (Del)", 0) {
		scene_delete_selected(scene)
	}

	ui_separator(ctx)

	mode_text := edit_mode^ == .OBJECT ? "Mode: Object" : "Mode: Face"
	if ui_button(ctx, mode_text, 0) {
		edit_mode^ = edit_mode^ == .OBJECT ? .FACE : .OBJECT
	}

	ui_label(ctx, "(Press Tab to toggle)")

	ui_panel_end(ctx)

	// Properties Panel
	if len(scene.selected_objects) > 0 {
		obj_idx := scene.selected_objects[0]
		obj := &scene.objects[obj_idx]

		ui_panel_begin(ctx, 170, 10, 280, 580, "Properties")

		ui_label(ctx, fmt.tprintf("Object: Cube %d", obj_idx))
		ui_separator(ctx)

		ui_label(ctx, "Transform")
		ui_separator(ctx)

		ui_slider(ctx, &obj.position.x, -10, 10, "Position X")
		ui_slider(ctx, &obj.position.y, -10, 10, "Position Y")
		ui_slider(ctx, &obj.position.z, -10, 10, "Position Z")

		ui_spacing(ctx)

		ui_slider(ctx, &obj.scale.x, 0.1, 5, "Scale X")
		ui_slider(ctx, &obj.scale.y, 0.1, 5, "Scale Y")
		ui_slider(ctx, &obj.scale.z, 0.1, 5, "Scale Z")

		ui_spacing(ctx)

		ui_slider(ctx, &obj.rotation.x, -180, 180, "Rotation X")
		ui_slider(ctx, &obj.rotation.y, -180, 180, "Rotation Y")
		ui_slider(ctx, &obj.rotation.z, -180, 180, "Rotation Z")

		ui_spacing(ctx)
		ui_label(ctx, "Color")
		ui_separator(ctx)

		ui_slider(ctx, &obj.color.r, 0, 1, "Red")
		ui_slider(ctx, &obj.color.g, 0, 1, "Green")
		ui_slider(ctx, &obj.color.b, 0, 1, "Blue")

		ui_panel_end(ctx)
	}

	// Outliner Panel
	ui_panel_begin(ctx, SCR_WIDTH - 290, 10, 280, 400, "Outliner")

	if len(scene.objects) == 0 {
		ui_label(ctx, "No objects in scene")
	} else {
		ui_label(ctx, fmt.tprintf("Objects: %d", len(scene.objects)))
		ui_separator(ctx)

		for _, i in scene.objects {
			is_selected := false
			for sel_idx in scene.selected_objects {
				if sel_idx == i {
					is_selected = true
					break
				}
			}

			label := fmt.tprintf("%sCube %d", is_selected ? "[*] " : "   ", i)
			if ui_button(ctx, label, 0) {
				scene_select_object(scene, i)
			}
		}
	}

	ui_panel_end(ctx)

	ui_panel_begin(ctx, 10, SCR_HEIGHT - 110, SCR_WIDTH - 20, 100, "Controls")

	ui_label(ctx, "Camera: Right-Click + Drag to orbit | Scroll to zoom")
	ui_label(ctx, "Selection: Left-Click object | Shift+Click for multi-select")
	ui_label(
		ctx,
		"Shortcuts: G=Move | S=Scale | R=Rotate | Tab=Face Mode | Ctrl+D=Duplicate | Del=Delete",
	)

	ui_panel_end(ctx)

	ui_render_end(ctx)
}
