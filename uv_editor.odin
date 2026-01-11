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
	last_mouse_x:      f32,
	last_mouse_y:      f32,
	selected_vertex:   i32,
	is_dragging:       bool,
	show_grid:         bool,
	show_texture:      bool,
	grid_shader:       u32,
	uv_shader:         u32,
	grid_vao:          u32,
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
	editor.selected_vertex = -1
	editor.show_grid = true
	editor.show_texture = true

	// Create shaders
	editor.uv_shader, _ = gl.load_shaders_source(uv_vertex_shader, uv_fragment_shader)
	editor.grid_shader, _ = gl.load_shaders_source(grid_vertex_shader, grid_fragment_shader)

	// Create grid
	uv_editor_create_grid(editor)
}

uv_editor_cleanup :: proc(editor: ^UV_Editor) {
	gl.DeleteProgram(editor.uv_shader)
	gl.DeleteProgram(editor.grid_shader)
	gl.DeleteVertexArrays(1, &editor.grid_vao)
	gl.DeleteVertexArrays(1, &editor.uv_mesh_vao)
	gl.DeleteBuffers(1, &editor.uv_mesh_vbo)
}

uv_editor_create_grid :: proc(editor: ^UV_Editor) {
	grid_lines := make([dynamic]f32)
	defer delete(grid_lines)

	// Create grid lines from 0 to 1
	divisions := 10
	for i in 0 ..= divisions {
		t := f32(i) / f32(divisions)
		// Vertical lines
		append(&grid_lines, t, 0.0)
		append(&grid_lines, t, 1.0)
		// Horizontal lines
		append(&grid_lines, 0.0, t)
		append(&grid_lines, 1.0, t)
	}

	// Create VAO/VBO for grid
	vbo: u32
	gl.GenVertexArrays(1, &editor.grid_vao)
	gl.GenBuffers(1, &vbo)
	
	gl.BindVertexArray(editor.grid_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(grid_lines) * size_of(f32), 
		raw_data(grid_lines), gl.STATIC_DRAW)
	
	gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 2 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)
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
	mouse_pressed: bool, middle_pressed: bool) {
	
	// Convert mouse to UV editor space
	local_x := f32(mouse_x) - editor.x
	local_y := f32(mouse_y) - editor.y

	// Check if mouse is inside editor
	if local_x < 0 || local_x > editor.width || 
	   local_y < 0 || local_y > editor.height {
		editor.is_panning = false
		editor.is_dragging = false
		return
	}

	// Pan with middle mouse or shift+left mouse
	if middle_pressed {
		if !editor.is_panning {
			editor.is_panning = true
			editor.last_mouse_x = local_x
			editor.last_mouse_y = local_y
		} else {
			dx := local_x - editor.last_mouse_x
			dy := local_y - editor.last_mouse_y
			editor.pan_x += dx / (editor.width * editor.zoom)
			editor.pan_y -= dy / (editor.height * editor.zoom)
			editor.last_mouse_x = local_x
			editor.last_mouse_y = local_y
		}
	} else {
		editor.is_panning = false
	}

	// Vertex selection and dragging
	if mouse_pressed && !editor.is_panning {
		// TODO: Implement vertex selection and dragging
		// This would involve converting mouse coords to UV space
		// and checking proximity to vertices
	} else {
		editor.is_dragging = false
	}
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

	// Set up viewport for UV editor
	gl.Viewport(i32(editor.x), i32(SCR_HEIGHT - editor.y - editor.height), 
		i32(editor.width), i32(editor.height))
	
	gl.Scissor(i32(editor.x), i32(SCR_HEIGHT - editor.y - editor.height), 
		i32(editor.width), i32(editor.height))
	gl.Enable(gl.SCISSOR_TEST)

	// Calculate transform matrix
	aspect := editor.width / editor.height
	projection := glsl.mat4Ortho3d(
		-aspect * editor.zoom + editor.pan_x,
		aspect * editor.zoom + editor.pan_x,
		-editor.zoom + editor.pan_y,
		editor.zoom + editor.pan_y,
		-1, 1
	)

	// Draw texture if available and enabled
	if editor.show_texture && obj != nil && obj.texture_atlas != nil && obj.use_texture {
		// Draw textured quad
		gl.UseProgram(editor.uv_shader)
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, obj.texture_atlas.texture_id)
		
		proj_loc := gl.GetUniformLocation(editor.uv_shader, "projection")
		gl.UniformMatrix4fv(proj_loc, 1, false, &projection[0, 0])
		
		tex_loc := gl.GetUniformLocation(editor.uv_shader, "useTexture")
		gl.Uniform1i(tex_loc, 1)
		
		// Draw full UV space quad with texture
		uv_editor_draw_background_quad(editor)
	}

	// Draw grid
	if editor.show_grid {
		gl.UseProgram(editor.grid_shader)
		proj_loc := gl.GetUniformLocation(editor.grid_shader, "projection")
		gl.UniformMatrix4fv(proj_loc, 1, false, &projection[0, 0])
		
		color_loc := gl.GetUniformLocation(editor.grid_shader, "color")
		gl.Uniform4f(color_loc, 0.3, 0.3, 0.35, 1.0)
		
		gl.BindVertexArray(editor.grid_vao)
		gl.DrawArrays(gl.LINES, 0, 44) // 22 lines * 2 vertices
	}

	// Draw UV mesh
	if obj != nil && editor.uv_mesh_vao != 0 {
		gl.UseProgram(editor.grid_shader)
		proj_loc := gl.GetUniformLocation(editor.grid_shader, "projection")
		gl.UniformMatrix4fv(proj_loc, 1, false, &projection[0, 0])
		
		// Draw edges in bright color
		color_loc := gl.GetUniformLocation(editor.grid_shader, "color")
		gl.Uniform4f(color_loc, 1.0, 0.7, 0.2, 1.0)
		
		gl.LineWidth(2.0)
		gl.BindVertexArray(editor.uv_mesh_vao)
		gl.DrawArrays(gl.LINE_LOOP, 0, editor.vertex_count)
		gl.LineWidth(1.0)

		// Draw vertices as points
		gl.PointSize(6.0)
		gl.Uniform4f(color_loc, 1.0, 1.0, 0.3, 1.0)
		gl.DrawArrays(gl.POINTS, 0, editor.vertex_count)
		gl.PointSize(1.0)
	}

	gl.Disable(gl.SCISSOR_TEST)
	
	// Reset viewport
	gl.Viewport(0, 0, SCR_WIDTH, SCR_HEIGHT)

	// Draw UI elements on top
	uv_editor_render_ui(editor, ctx)
}

uv_editor_draw_background_quad :: proc(editor: ^UV_Editor) {
	// Simple quad covering UV space (0,0) to (1,1)
	quad_vertices := [?]f32{
		0.0, 0.0,  0.0, 0.0,
		1.0, 0.0,  1.0, 0.0,
		1.0, 1.0,  1.0, 1.0,
		0.0, 0.0,  0.0, 0.0,
		1.0, 1.0,  1.0, 1.0,
		0.0, 1.0,  0.0, 1.0,
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

// Shaders
uv_vertex_shader := `#version 330 core
layout (location = 0) in vec2 aPos;
layout (location = 1) in vec2 aTexCoord;

uniform mat4 projection;

out vec2 TexCoord;

void main() {
    gl_Position = projection * vec4(aPos, 0.0, 1.0);
    TexCoord = aTexCoord;
}
`

uv_fragment_shader := `#version 330 core
in vec2 TexCoord;
out vec4 FragColor;

uniform sampler2D texture1;
uniform int useTexture;

void main() {
    if (useTexture == 1) {
        FragColor = texture(texture1, TexCoord);
    } else {
        FragColor = vec4(0.2, 0.2, 0.25, 1.0);
    }
}
`

grid_vertex_shader := `#version 330 core
layout (location = 0) in vec2 aPos;

uniform mat4 projection;

void main() {
    gl_Position = projection * vec4(aPos, 0.0, 1.0);
}
`

grid_fragment_shader := `#version 330 core
out vec4 FragColor;

uniform vec4 color;

void main() {
    FragColor = color;
}
`