package main

import "core:fmt"
import "core:math"
import "core:math/linalg/glsl"
import "core:os"
import gl "vendor:OpenGL"
import "vendor:glfw"

// FIXME: Fix the render of the rotation gizmo.

SCR_WIDTH :: 800
SCR_HEIGHT :: 600

// --- Camera & Interaction State ---
camera_yaw: f32 = -45.0
camera_pitch: f32 = 30.0
camera_dist: f32 = 10.0
last_mouse_x: f64 = SCR_WIDTH / 2.0
last_mouse_y: f64 = SCR_HEIGHT / 2.0
first_mouse: bool = true

is_selected: bool = false
is_dragging: bool = false
cube_pos: glsl.vec3 = {0, 0, 0}
cube_scale: glsl.vec3 = {1, 1, 1}
cube_rotation: glsl.vec3 = {0, 0, 0} // Euler angles in degrees
gizmo_mode: enum {
	TRANSLATE,
	SCALE,
	ROTATE,
} = .TRANSLATE
active_axis: enum {
	NONE,
	X,
	Y,
	Z,
} = .NONE
drag_start_pos: glsl.vec2

ui: UI_Context

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
	mode: enum {
		TRANSLATE,
		SCALE,
		ROTATE,
	},
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
	// Rotate to align Z-forward geometry to X or Y axes
	if axis_type == 0 do model *= glsl.mat4Rotate({0, 1, 0}, glsl.radians(f32(90.0)))
	if axis_type == 1 do model *= glsl.mat4Rotate({1, 0, 0}, glsl.radians(f32(-90.0)))

	switch mode {
	case .TRANSLATE, .SCALE:
		// Draw Stem
		gl.LineWidth(5.0)
		gl.UniformMatrix4fv(m_loc, 1, false, &model[0, 0])
		gl.BindVertexArray(vao_stem)
		gl.DrawArrays(gl.LINES, 0, 2)

		// Draw Tip based on mode
		tip_model := model * glsl.mat4Translate({0, 0, 1.0})
		gl.UniformMatrix4fv(m_loc, 1, false, &tip_model[0, 0])
		gl.BindVertexArray(vao_tip)

		if mode == .TRANSLATE {
			gl.DrawArrays(gl.LINES, 0, 8) // Arrow tip
		} else {
			gl.DrawArrays(gl.LINES, 8, 12) // Cube tip (next 12 lines)
		}

	case .ROTATE:
		// Draw rotation circle
		gl.LineWidth(3.0)
		circle_model := model
		gl.UniformMatrix4fv(m_loc, 1, false, &circle_model[0, 0])
		gl.BindVertexArray(vao_tip)
		gl.DrawArrays(gl.LINE_LOOP, 20, 32) // Circle
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
	if action == glfw.PRESS {
		switch key {
		case glfw.KEY_G:
			gizmo_mode = .TRANSLATE
		case glfw.KEY_S:
			gizmo_mode = .SCALE
		case glfw.KEY_R:
			gizmo_mode = .ROTATE
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

generate_gizmo_tips :: proc() -> []f32 {
	tips := make([dynamic]f32)

	// Arrow tip (0-7 lines = 48 floats)
	arrow := [?]f32 {
		0,
		0,
		0.3,
		0.1,
		0,
		0,
		0,
		0,
		0.3,
		-0.1,
		0,
		0,
		0,
		0,
		0.3,
		0,
		0.1,
		0,
		0,
		0,
		0.3,
		0,
		-0.1,
		0,
		0.1,
		0,
		0,
		0,
		0.1,
		0,
		0,
		0.1,
		0,
		-0.1,
		0,
		0,
		-0.1,
		0,
		0,
		0,
		-0.1,
		0,
		0,
		-0.1,
		0,
		0.1,
		0,
		0,
	}
	for v in arrow do append(&tips, v)

	// Cube tip (8-19 lines = 72 floats) - 12 edges of a small cube
	s: f32 = 0.1
	cube_edges := [?]f32 {
		-s,
		-s,
		-s,
		s,
		-s,
		-s,
		s,
		-s,
		-s,
		s,
		s,
		-s,
		s,
		s,
		-s,
		-s,
		s,
		-s,
		-s,
		s,
		-s,
		-s,
		-s,
		-s,
		-s,
		-s,
		s,
		s,
		-s,
		s,
		s,
		-s,
		s,
		s,
		s,
		s,
		s,
		s,
		s,
		-s,
		s,
		s,
		-s,
		s,
		s,
		-s,
		-s,
		s,
		-s,
		-s,
		-s,
		-s,
		-s,
		s,
		s,
		-s,
		-s,
		s,
		-s,
		s,
		s,
		s,
		-s,
		s,
		s,
		s,
		-s,
		s,
		-s,
		-s,
		s,
		s,
	}
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
	window := glfw.CreateWindow(SCR_WIDTH, SCR_HEIGHT, "Blockfast", nil, nil)
	glfw.MakeContextCurrent(window)
	gl.load_up_to(3, 3, glfw.gl_set_proc_address)


	glfw.SetFramebufferSizeCallback(window, framebuffer_size_callback)
	glfw.SetCursorPosCallback(window, mouse_callback)
	glfw.SetScrollCallback(window, scroll_callback)
	glfw.SetKeyCallback(window, key_callback)

	ui_init(&ui, SCR_WIDTH, SCR_HEIGHT)
	defer ui_cleanup(&ui)

	grid_vertices := generate_grid(10, 1)
	stem_vertices := [?]f32{0, 0, 0, 0, 0, 1.0}
	tip_vertices := generate_gizmo_tips()
	circle_vertices := generate_circle(64, 1.0)

	shaderProgram, _ := gl.load_shaders_file("./shaders/shader.vs", "./shaders/shader.fs")
	gridShader, _ := gl.load_shaders_file("./shaders/grid.vs", "./shaders/grid.fs")
	gizmoShader, _ := gl.load_shaders_file("./shaders/gizmos.vs", "./shaders/gizmos.fs")

	VAO, VBO: u32
	gl.GenVertexArrays(1, &VAO); gl.GenBuffers(1, &VBO)
	gl.BindVertexArray(VAO); gl.BindBuffer(gl.ARRAY_BUFFER, VBO)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(cube), &cube[0], gl.STATIC_DRAW)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 6 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(1, 3, gl.FLOAT, gl.FALSE, 6 * size_of(f32), 3 * size_of(f32))
	gl.EnableVertexAttribArray(1)

	gVAO, gVBO: u32
	gl.GenVertexArrays(1, &gVAO); gl.GenBuffers(1, &gVBO)
	gl.BindVertexArray(gVAO); gl.BindBuffer(gl.ARRAY_BUFFER, gVBO)
	gl.BufferData(gl.ARRAY_BUFFER, len(grid_vertices) * 4, raw_data(grid_vertices), gl.STATIC_DRAW)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)

	sVAO, sVBO: u32
	gl.GenVertexArrays(1, &sVAO); gl.GenBuffers(1, &sVBO)
	gl.BindVertexArray(sVAO); gl.BindBuffer(gl.ARRAY_BUFFER, sVBO)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(stem_vertices), &stem_vertices[0], gl.STATIC_DRAW)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)

	tVAO, tVBO: u32
	gl.GenVertexArrays(1, &tVAO); gl.GenBuffers(1, &tVBO)
	gl.BindVertexArray(tVAO); gl.BindBuffer(gl.ARRAY_BUFFER, tVBO)
	gl.BufferData(gl.ARRAY_BUFFER, len(tip_vertices) * 4, raw_data(tip_vertices), gl.STATIC_DRAW)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)

	cVAO, cVBO: u32
	gl.GenVertexArrays(1, &cVAO); gl.GenBuffers(1, &cVBO)
	gl.BindVertexArray(cVAO); gl.BindBuffer(gl.ARRAY_BUFFER, cVBO)
	gl.BufferData(
		gl.ARRAY_BUFFER,
		len(circle_vertices) * 4,
		raw_data(circle_vertices),
		gl.STATIC_DRAW,
	)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)

	gl.Enable(gl.DEPTH_TEST)

	for !glfw.WindowShouldClose(window) {
		gl.ClearColor(0.1, 0.1, 0.1, 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

		ui_begin_frame(&ui, window)

		mx, my := glfw.GetCursorPos(window)
		nx, ny := f32((2.0 * mx) / SCR_WIDTH - 1.0), f32(1.0 - (2.0 * my) / SCR_HEIGHT)

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

		if !is_dragging && is_selected {
			if test_ray_cube(origin, dir, cube_pos + {0, -0.1, -0.1}, cube_pos + {1.5, 0.1, 0.1}) do hover_axis = .X
			else if test_ray_cube(origin, dir, cube_pos + {-0.1, 0, -0.1}, cube_pos + {0.1, 1.5, 0.1}) do hover_axis = .Y
			else if test_ray_cube(origin, dir, cube_pos + {-0.1, -0.1, 0}, cube_pos + {0.1, 0.1, 1.5}) do hover_axis = .Z
			else do hover_axis = .NONE
		}

		if glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS {
			if !is_dragging {
				if is_selected && hover_axis != .NONE {
					active_axis, is_dragging = hover_axis, true
					drag_start_pos = {f32(mx), f32(my)}
				} else {
					is_selected = test_ray_cube(
						origin,
						dir,
						cube_pos - 0.5 * cube_scale,
						cube_pos + 0.5 * cube_scale,
					)
				}
			}
			if is_dragging {
				dx, dy := f32(mx - last_mouse_x) * 0.05, f32(last_mouse_y - my) * 0.05

				switch gizmo_mode {
				case .TRANSLATE:
					switch active_axis {
					case .X:
						cube_pos.x += dx
					case .Y:
						cube_pos.y += dy
					case .Z:
						cube_pos.z += dx
					case .NONE:
						break
					}
				case .SCALE:
					scale_delta := (dx + dy) * 0.1
					switch active_axis {
					case .X:
						cube_scale.x = max(0.1, cube_scale.x + scale_delta)
					case .Y:
						cube_scale.y = max(0.1, cube_scale.y + scale_delta)
					case .Z:
						cube_scale.z = max(0.1, cube_scale.z + scale_delta)
					case .NONE:
						break
					}
				case .ROTATE:
					rotation_delta := (dx + dy) * 2.0
					switch active_axis {
					case .X:
						cube_rotation.x += rotation_delta
					case .Y:
						cube_rotation.y += rotation_delta
					case .Z:
						cube_rotation.z += rotation_delta
					case .NONE:
						break
					}
				}
			}
		} else {
			is_dragging, active_axis = false, .NONE
		}
		last_mouse_x, last_mouse_y = mx, my

		// Render Cube with transformations
		gl.UseProgram(shaderProgram)
		gl.UniformMatrix4fv(gl.GetUniformLocation(shaderProgram, "view"), 1, false, &view[0, 0])
		gl.UniformMatrix4fv(
			gl.GetUniformLocation(shaderProgram, "projection"),
			1,
			false,
			&proj[0, 0],
		)

		model := glsl.mat4Translate(cube_pos)
		model *= glsl.mat4Rotate({1, 0, 0}, glsl.radians(cube_rotation.x))
		model *= glsl.mat4Rotate({0, 1, 0}, glsl.radians(cube_rotation.y))
		model *= glsl.mat4Rotate({0, 0, 1}, glsl.radians(cube_rotation.z))
		model *= glsl.mat4Scale(cube_scale)

		gl.UniformMatrix4fv(gl.GetUniformLocation(shaderProgram, "model"), 1, false, &model[0, 0])
		gl.BindVertexArray(VAO); gl.DrawArrays(gl.TRIANGLES, 0, 36)

		// Render Grid
		gl.UseProgram(gridShader)
		gl.UniformMatrix4fv(gl.GetUniformLocation(gridShader, "view"), 1, false, &view[0, 0])
		gl.UniformMatrix4fv(gl.GetUniformLocation(gridShader, "projection"), 1, false, &proj[0, 0])
		id := glsl.mat4(1.0)
		gl.UniformMatrix4fv(gl.GetUniformLocation(gridShader, "model"), 1, false, &id[0, 0])
		gl.BindVertexArray(gVAO); gl.DrawArrays(gl.LINES, 0, i32(len(grid_vertices) / 3))

		// Render Gizmos
		if is_selected {
			gl.Disable(gl.DEPTH_TEST)
			draw_gizmo_axis(
				gizmoShader,
				sVAO,
				tVAO,
				cube_pos,
				{1, 0, 0},
				0,
				hover_axis == .X,
				view,
				proj,
				gizmo_mode,
			)
			draw_gizmo_axis(
				gizmoShader,
				sVAO,
				tVAO,
				cube_pos,
				{0, 1, 0},
				1,
				hover_axis == .Y,
				view,
				proj,
				gizmo_mode,
			)
			draw_gizmo_axis(
				gizmoShader,
				sVAO,
				tVAO,
				cube_pos,
				{0, 0, 1},
				2,
				hover_axis == .Z,
				view,
				proj,
				gizmo_mode,
			)
			gl.Enable(gl.DEPTH_TEST)
		}

		ui_render_begin(&ui, SCR_WIDTH, SCR_HEIGHT)

		ui_panel_begin(&ui, SCR_WIDTH - 290, 10, 280, 180, "Gizmo Mode")
		
		if ui_icon_button(&ui, "scale") do gizmo_mode = .SCALE
		if ui_icon_button(&ui, "translate") do gizmo_mode = .TRANSLATE
		if ui_icon_button(&ui, "scale") do gizmo_mode = .ROTATE
		
		ui_panel_end(&ui)

		ui_panel_begin(&ui, 10, 10, 280, 480, "Properties")



		ui_label(&ui, "Transform")
		ui_separator(&ui)

		ui_slider(&ui, &cube_pos.x, -10, 10, "Position X")
		ui_slider(&ui, &cube_pos.y, -10, 10, "Position Y")
		ui_slider(&ui, &cube_pos.z, -10, 10, "Position Z")

		ui_panel_end(&ui)

		ui_render_end(&ui)

		ui_end_frame(&ui)

		glfw.SwapBuffers(window); glfw.PollEvents()
	}
}
