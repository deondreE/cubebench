package main

import "core:fmt"
import "core:math"
import "core:math/linalg/glsl"
import gl "vendor:OpenGL"

UV_Editor :: struct {
	visible:           bool,
	width:             f32,
	height:            f32,
	x:                 f32,
	y:                 f32,
	zoom:              f32,
	pan_x:             f32,
	pan_y:             f32,
	is_panning:        bool,
	is_painting: bool,
	last_mouse_x:      f32,
	last_mouse_y:      f32,
	selected_vertex:   i32,
	selected_face: i32,
	is_dragging:       bool,
	show_grid:         bool,
	show_texture:      bool,
	grid_shader:       u32,
	uv_shader:         u32,
	grid_vao:         u32,
	quad_vao, quad_vbo: u32,
	paint_brush_size:  i32,
	paint_color:       glsl.vec4,
	uv_mesh_vao:       u32,
	uv_mesh_vbo:       u32,
	vertex_count:      i32,
}

uv_editor_init :: proc(editor: ^UV_Editor, x, y, width, height: f32) {
	editor.x = x
	editor.y = y
	editor.width = width
	editor.height = height
	editor.zoom = 1.0
	editor.pan_x = 0.0
	editor.pan_y = 0.0
	editor.visible = false
	editor.show_grid = true
	editor.show_texture = true
	editor.selected_face = -1
	editor.paint_brush_size = 5
	editor.paint_color = {1, 0, 0, 1}

	// Create shaders
	editor.uv_shader, _ = gl.load_shaders_source(uv_vertex_shader, uv_fragment_shader)

	// uv_editor_create_grid(editor)
	uv_editor_create_quad(editor)
}

uv_editor_cleanup :: proc(editor: ^UV_Editor) {
	gl.DeleteProgram(editor.uv_shader)
	gl.DeleteVertexArrays(1, &editor.quad_vao)
	gl.DeleteBuffers(1, &editor.quad_vbo)
}

uv_editor_create_quad :: proc(editor: ^UV_Editor) {
	quad_vertices := [?]f32 {
		0.0, 0.0, 0.0, 1.0,
		1.0, 0.0, 1.0, 1.0,
		1.0, 1.0, 1.0, 1.0,
		1.0, 1.0, 1.0, 1.0,
		0.0, 1.0, 0.0, 1.0,
		0.0, 0.0, 0.0, 0.0,
	}

	gl.GenVertexArrays(1, &editor.quad_vao)
	gl.GenBuffers(1, &editor.quad_vbo)

	gl.BindVertexArray(editor.quad_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, editor.quad_vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(quad_vertices), &quad_vertices[0], gl.STATIC_DRAW)

	gl.VertexAttribPointer(0, 2, gl.FLOAT, gl. FALSE, 4 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)

	gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 4 * size_of(f32), 2 * size_of(f32))
	gl.EnableVertexAttribArray(1)
}

uv_editor_screen_to_uv :: proc(editor: ^UV_Editor, screen_x, screen_y: f32, face_idx: i32) -> (uv: glsl.vec2, valid: bool) {
	col :=  face_idx % 3
	row := face_idx / 3

	face_width := editor.width / 3.0
	face_height := editor.height / 2.0

	face_x := editor.x + f32(col) * face_width
	face_y := editor.y + f32(row) * face_height

	local_x := screen_x - face_x
	local_y := screen_y - face_y

	if local_x < 0 || local_x > face_width || local_y < 0 || local_y > face_height {
		return {0, 0}, false
	}

	uv.x = local_x / face_width
	uv.y = local_y / face_height

	return uv, true
}

uv_editor_get_face_at_pos :: proc(editor: ^UV_Editor, screen_x, screen_y: f32) -> i32 {
	for i in 0..<6 {
		_, valid := uv_editor_screen_to_uv(editor, screen_x, screen_y, i32(i))
		if valid do return i32(i)
	}
	return -1
}

uv_editor_update_mesh :: proc(editor: ^UV_Editor, obj: ^Scene_Object) {
	if obj.texture_atlas == nil do return

	// Extract UV coordinates from the cube vertices
	// Format: pos(3) + normal(3) + uv(2) = 8 floats per vertex
	vertex_data := generate_cube_with_uvs()
	defer delete(vertex_data)

	uv_data := make([dynamic]f32)
	defer delete(uv_data)

	// Extract just the UV coordinates (every 8 floats, take index 6 and 7)
	for i := 0; i < len(vertex_data); i += 8 {
		append(&uv_data, vertex_data[i + 6]) // U
		append(&uv_data, vertex_data[i + 7]) // V
	}

	editor.vertex_count = i32(len(uv_data) / 2)

	// Create/update VAO for UV mesh
	if editor.uv_mesh_vao == 0 {
		gl.GenVertexArrays(1, &editor.uv_mesh_vao)
		gl.GenBuffers(1, &editor.uv_mesh_vbo)
	}

	gl.BindVertexArray(editor.uv_mesh_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, editor.uv_mesh_vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(uv_data) * size_of(f32),
		raw_data(uv_data), gl.DYNAMIC_DRAW)

	gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 2 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)
}

uv_editor_handle_input :: proc(editor: ^UV_Editor, mouse_x, mouse_y: f64,
	left_pressed: bool, middle_pressed: bool, obj: ^Scene_Object) {

	screen_x := f32(mouse_x)
	screen_y := f32(mouse_y)

	if screen_x < editor.x || screen_x > editor.x + editor.width ||
		screen_y < editor.y || screen_y > editor.y + editor.height {
			editor.is_panning = false
			editor.is_painting = false
			return
	}

	if left_pressed && obj != nil && obj.texture_atlas != nil {
		face_idx := uv_editor_get_face_at_pos(editor, screen_x, screen_y)
		if face_idx >= 0 {
			uv, valid := uv_editor_screen_to_uv(editor, screen_x, screen_y, face_idx)
			if valid {
				uv_editor_paint_at_uv(editor, obj, Face_Index(face_idx), uv)
				editor.is_painting = true
			}
		}
	} else {
		editor.is_painting = false
	}

	if middle_pressed {
		if !editor.is_panning {
			editor.is_panning = true
			editor.last_mouse_x = screen_x
			editor.last_mouse_y = screen_y
		} else {
			dx := screen_x - editor.last_mouse_x
			dy := screen_y - editor.last_mouse_y
			editor.pan_x += dx / (editor.width * editor.zoom)
			editor.pan_y -= dy / (editor.height * editor.zoom)
			editor.last_mouse_x = screen_x
			editor.last_mouse_y = screen_y
		}
	} else {
		editor.is_panning = false
	}
}

uv_editor_paint_at_uv :: proc(editor: ^UV_Editor, obj: ^Scene_Object, face_idx: Face_Index, uv: glsl.vec2) {
	if obj.texture_atlas == nil do return

	u0, v0, u1, v1 := get_face_uv_region(face_idx, obj.texture_atlas.width)
	texture_u := u0 + uv.x * (u1 - u0)
	texture_v := v0 + uv.y * (v1 - v0)

	pixel_x := i32(texture_u * f32(obj.texture_atlas.width))
	pixel_y := i32(texture_v * f32(obj.texture_atlas.height))

	paint_brush(
		obj.texture_atlas,
		pixel_x,
		pixel_y,
		editor.paint_brush_size,
		editor.paint_color,
	)
}

uv_editor_handle_scroll :: proc(editor: ^UV_Editor, mouse_x, mouse_y: f64,
	yoffset: f64) {

	local_x := f32(mouse_x) - editor.x
	local_y := f32(mouse_y) - editor.y

	// Only zoom if mouse is inside editor
	if local_x >= 0 && local_x <= editor.width &&
	   local_y >= 0 && local_y <= editor.height {
		old_zoom := editor.zoom
		editor.zoom *= 1.0 + f32(yoffset) * 0.1
		editor.zoom = clamp(editor.zoom, 0.1, 10.0)
	}
}

uv_editor_render :: proc(editor: ^UV_Editor, obj: ^Scene_Object, ctx: ^UI_Context) {
	if !editor.visible do return

	// Draw background panel
	panel_rect := UI_Rect{editor.x, editor.y, editor.width, editor.height}
	batch_rect(ctx, panel_rect, UI_Color{0.15, 0.15, 0.18, 1.0})
	batch_rect_outline(ctx, panel_rect, ctx.style.border_color, 2)

	// Draw header
	header_height: f32 = 30
	header_rect := UI_Rect{editor.x, editor.y, editor.width, header_height}
	batch_rect(ctx, header_rect, UI_Color{0.2, 0.2, 0.24, 0.95})
	batch_text(ctx, "UV Editor - Paint on Faces", editor.x + 10, editor.y + 8, ctx.style.text_color)

	// Close button
	close_size: f32 = 20
	close_x := editor.x + editor.width - close_size - 5
	close_y := editor.y + 5
	close_rect := UI_Rect{close_x, close_y, close_size, close_size}

	is_close_hover := point_in_rect(ctx.mouse_x, ctx.mouse_y, close_rect)
	close_color := is_close_hover ? UI_Color{0.8, 0.3, 0.3, 1.0} : UI_Color{0.5, 0.5, 0.5, 1.0}

	batch_rect(ctx, close_rect, close_color)
	batch_text(ctx, "X", close_x + 6, close_y + 3, UI_Color{1, 1, 1, 1})

	if is_close_hover && ctx.mouse_pressed {
		editor.visible = false
	}

	// Set up viewport for UV editor content area
	content_y := editor.y + header_height
	content_height := editor.height - header_height - 60 // Leave space for controls

	face_names := [6]string{"Front", "Right", "Back", "Left", "Top", "Bottom"}

	face_screen_width := editor.width / 3.0
	face_screen_height := content_height / 2.0

	gl.Viewport(i32(editor.x), i32(SCR_HEIGHT - content_y - content_height),
		i32(editor.width), i32(content_height))

	gl.Scissor(i32(editor.x), i32(SCR_HEIGHT - content_y - content_height),
		i32(editor.width), i32(content_height))
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.Enable(gl.SCISSOR_TEST)

	gl.UseProgram(editor.uv_shader)

	if obj != nil && obj.texture_atlas != nil {
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, obj.texture_atlas.texture_id)

		tex_loc := gl.GetUniformLocation(editor.uv_shader, "textureSampler")
		gl.Uniform1i(tex_loc, 0)
	}

	for face_idx in 0..<6 {
		col := face_idx % 3  // 0, 1, 2 for columns
		row := face_idx / 3  // 0 for top row, 1 for bottom row

		x_normalized := f32(col) / 3.0
		y_normalized := 0.5 if row == 0.0 else 0.0

		model := glsl.mat4Scale({1.0 / 3.0, 1.0 / 2.0, 1.0})
		model = glsl.mat4Translate({x_normalized, f32(y_normalized), 0.0}) * model

		projection := glsl.mat4Ortho3d(0, 1, 0, 1, -1, 1)

		mvp := projection * model

		mvp_loc := gl.GetUniformLocation(editor.uv_shader, "mvp")
		gl.UniformMatrix4fv(mvp_loc, 1, false, &mvp[0, 0])

		u0, v0, u1, v1 := get_face_uv_region(Face_Index(face_idx), 0)

		uv_loc := gl.GetUniformLocation(editor.uv_shader, "uvRegion")
		gl.Uniform4f(uv_loc, u0, v0, u1, v1)

		gl.BindVertexArray(editor.quad_vao)
		gl.DrawArrays(gl.LINE_LOOP, 0, 6)
	}

	gl.Disable(gl.SCISSOR_TEST)
	gl.Enable(gl.DEPTH_TEST)
	gl.Enable(gl.CULL_FACE)
	gl.Viewport(0, 0, SCR_WIDTH, SCR_HEIGHT)

	for face_idx in 0..<6 {
		col := face_idx % 3
		row := face_idx / 3

		border_x := editor.x + f32(col) * face_screen_width
		border_y := content_y + f32(row) * face_screen_height

		border_rect := UI_Rect{border_x, border_y, face_screen_width, face_screen_height}
		batch_rect_outline(ctx, border_rect, UI_Color{0.4, 0.4, 0.45, 1.0}, 2)

		label_bg := UI_Rect{border_x + 4, border_y + 4, 60, 18}
		batch_rect(ctx, label_bg, UI_Color{0.0, 0.0, 0.0, 0.7})
		batch_text(ctx, face_names[face_idx], border_x + 7, border_y + 7,
			UI_Color{1.0, 1.0, 1.0, 1.0})
	}

	uv_editor_render_controls(editor, ctx, obj)
}

uv_editor_render_controls :: proc(editor: ^UV_Editor, ctx: ^UI_Context, obj: ^Scene_Object) {
	controls_y := editor.y + editor.height - 55
	controls_height: f32 = 55

	// Controls background
	controls_bg := UI_Rect{editor.x, controls_y, editor.width, controls_height}
	batch_rect(ctx, controls_bg, UI_Color{0.18, 0.18, 0.22, 1.0})

	ctx.cursor_x = editor.x + 10
	ctx.cursor_y = controls_y + 5

	// Color picker
	ui_label(ctx, "Brush Color:")

	// Color preview
	color_size: f32 = 30
	color_rect := UI_Rect{ctx.cursor_x, ctx.cursor_y, color_size, color_size}
	batch_rect(ctx, color_rect, UI_Color{editor.paint_color.r, editor.paint_color.g, editor.paint_color.b, 1})
	batch_rect_outline(ctx, color_rect, ctx.style.border_color, 2)

	ctx.cursor_x += color_size + 10

	quick_colors := [?]glsl.vec4{
		{1, 0, 0, 1}, // Red
		{0, 1, 0, 1}, // Green
		{0, 0, 1, 1}, // Blue
		{1, 1, 0, 1}, // Yellow
		{1, 1, 1, 1}, // White
		{0, 0, 0, 1}, // Black
	}

	swatch_size: f32 = 20
	for color, i in quick_colors {
		swatch_rect := UI_Rect{ctx.cursor_x + f32(i) * (swatch_size + 2), ctx.cursor_y + 5, swatch_size, swatch_size}

		is_hover := point_in_rect(ctx.mouse_x, ctx.mouse_y, swatch_rect)
		if is_hover {
			batch_rect_outline(ctx, swatch_rect, UI_Color{1, 1, 1, 1}, 2)
			if ctx.mouse_pressed {
				editor.paint_color = color
			}
		}

		batch_rect(ctx, swatch_rect, UI_Color{color.r, color.g, color.b, 1})
		batch_rect_outline(ctx, swatch_rect, ctx.style.border_color, 1)
	}

	ctx.cursor_x = editor.x + 10
	ctx.cursor_y += 35

	ui_label(ctx, fmt.tprintf("Brush Size: %d", editor.paint_brush_size))

	slider_width: f32 = 200
	slider_height: f32 = 20
	slider_rect := UI_Rect{ctx.cursor_x, ctx.cursor_y, slider_width, slider_height}

	batch_rect(ctx, slider_rect, UI_Color{0.2, 0.2, 0.25, 1})
	batch_rect_outline(ctx, slider_rect, ctx.style.border_color, 1)

	// Slider handle
	brush_range: f32 = 20.0 // 1 to 20
	normalized := (f32(editor.paint_brush_size) - 1.0) / brush_range
	handle_x := ctx.cursor_x + normalized * slider_width
	handle_rect := UI_Rect{handle_x - 5, ctx.cursor_y - 2, 10, slider_height + 4}

	is_slider_hover := point_in_rect(ctx.mouse_x, ctx.mouse_y, slider_rect)
	handle_color := is_slider_hover ? ctx.style.hover_color : ctx.style.border_color

	batch_rect(ctx, handle_rect, handle_color)

	if is_slider_hover && ctx.mouse_pressed {
		local_x := ctx.mouse_x - ctx.cursor_x
		normalized = clamp(local_x / slider_width, 0, 1)
		editor.paint_brush_size = i32(normalized * brush_range) + 1
	}
}

uv_editor_draw_background_quad :: proc(editor: ^UV_Editor) {
	quad_vertices := [?]f32{
		0.0, 0.0,  0.0, 0.0,
		1.0, 0.0,  1.0, 0.0,
		1.0, 1.0,  1.0, 1.0,
		1.0, 1.0,  1.0, 1.0,
		0.0, 1.0,  0.0, 1.0,
		0.0, 0.0,  0.0, 0.0,
	}

	vao, vbo: u32
	gl.GenVertexArrays(1, &vao)
	gl.GenBuffers(1, &vbo)

	gl.BindVertexArray(vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(quad_vertices), &quad_vertices[0], gl.STATIC_DRAW)

	gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 4 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 4 * size_of(f32), 2 * size_of(f32))
	gl.EnableVertexAttribArray(1)

	gl.DrawArrays(gl.TRIANGLES, 0, 6)

	gl.DeleteVertexArrays(1, &vao)
	gl.DeleteBuffers(1, &vbo)
}

uv_editor_render_ui :: proc(editor: ^UV_Editor, ctx: ^UI_Context) {
	// Header
	header_height: f32 = 30
	header_rect := UI_Rect{editor.x, editor.y, editor.width, header_height}
	batch_rect(ctx, header_rect, UI_Color{0.2, 0.2, 0.24, 0.95})
	batch_text(ctx, "UV Editor", editor.x + 10, editor.y + 8, ctx.style.text_color)

	// Close button
	close_size: f32 = 20
	close_x := editor.x + editor.width - close_size - 5
	close_y := editor.y + 5
	close_rect := UI_Rect{close_x, close_y, close_size, close_size}

	is_close_hover := point_in_rect(ctx.mouse_x, ctx.mouse_y, close_rect)
	close_color := is_close_hover ? UI_Color{0.8, 0.3, 0.3, 1.0} : UI_Color{0.5, 0.5, 0.5, 1.0}

	batch_rect(ctx, close_rect, close_color)
	batch_text(ctx, "X", close_x + 6, close_y + 3, UI_Color{1, 1, 1, 1})

	if is_close_hover && ctx.mouse_pressed {
		editor.visible = false
	}

	// Tool buttons
	tool_y := editor.y + header_height + 5
	button_width: f32 = 80

	ctx.cursor_x = editor.x + 5
	ctx.cursor_y = tool_y

	if ui_button(ctx, editor.show_grid ? "Grid: ON" : "Grid: OFF", button_width) {
		editor.show_grid = !editor.show_grid
	}

	ctx.cursor_x += button_width + 5
	if ui_button(ctx, editor.show_texture ? "Tex: ON" : "Tex: OFF", button_width) {
		editor.show_texture = !editor.show_texture
	}

	ctx.cursor_x += button_width + 5
	if ui_button(ctx, "Reset View", button_width) {
		editor.zoom = 1.0
		editor.pan_x = 0.0
		editor.pan_y = 0.0
	}
}

// SHADERS
uv_vertex_shader := `#version 330 core
layout (location = 0) in vec2 aPos;
layout (location = 1) in vec2 aTexCoord;

uniform mat4 mvp;
uniform vec4 uvRegion; // u0, v0, u1, v1

out vec2 TexCoord;

void main() {
    gl_Position = mvp * vec4(aPos, 0.0, 1.0);

    // Map texture coordinates to the face's UV region
    float u = uvRegion.x + aTexCoord.x * (uvRegion.z - uvRegion.x);
    float v = uvRegion.y + (1.0 - aTexCoord.y) * (uvRegion.w - uvRegion.y);
    TexCoord = vec2(u, v);
}
`

uv_fragment_shader := `#version 330 core
in vec2 TexCoord;
out vec4 FragColor;

uniform sampler2D textureSampler;

void main() {
    FragColor = texture(textureSampler, TexCoord);
}
`
