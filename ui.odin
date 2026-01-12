package main

import "core:fmt"
import "core:math/linalg/glsl"
import "core:os"
import "core:strings"
import gl "vendor:OpenGL"
import "vendor:glfw"
import stbi "vendor:stb/image"
import stbtt "vendor:stb/truetype"

UI_Rect :: struct {
	x, y, w, h: f32,
}

UI_Color :: struct {
	r, g, b, a: f32,
}

UI_Style :: struct {
	bg_color:     UI_Color,
	fg_color:     UI_Color,
	border_color: UI_Color,
	text_color:   UI_Color,
	hover_color:  UI_Color,
	active_color: UI_Color,
	padding:      f32,
	rounding:     f32,
}

UI_Panel_State :: struct {
	scroll_offset: f32,
	content_height: f32,
	max_scroll: f32,
	is_scrolling: bool,
	scroll_bar_hot: bool,
	scroll_bar_active: bool,
}

Font_Atlas :: struct {
	width, height: i32,
	texture:       u32,
	char_data:     [96]stbtt.bakedchar,
}

UI_Image :: struct {
	texture:       u32,
	width, height: i32,
}

Icon_Cache :: struct {
	images: map[string]UI_Image,
}

Draw_Command_Type :: enum {
	RECT_FILLED,
	RECT_OUTLINE,
	TEXT,
	IMAGE,
}

Draw_Command :: struct {
	type:          Draw_Command_Type,
	rect:          UI_Rect,
	color:         UI_Color,
	text:          string,
	thickness:     f32,
	image_name:    string,
	vertex_count:  i32,
	vertex_offset: i32,
}

Render_Batch :: struct {
	shape_vertices: [dynamic]f32,
	shape_indices:  [dynamic]u32,
	text_vertices:  [dynamic]f32,
	image_vertices: [dynamic]f32,
	commands:       [dynamic]Draw_Command,
}

UI_Context :: struct {
	mouse_x, mouse_y:     f32,
	mouse_down:           bool,
	mouse_pressed:        bool,
	mouse_released:       bool,
	prev_mouse_down:      bool,
	hot_id:               u64,
	active_id:            u64,
	clip_rect:            UI_Rect,
	panel_state: UI_Panel_State,
	screen_height: i32,
	panels: [dynamic]UI_Rect,
	current_panel_idx: int,
	current_panel:        UI_Rect,
	cursor_x, cursor_y:   f32,
	row_height:           f32,

	// Rendering
	shader:               u32,
	text_shader:          u32,
	image_shader:         u32,
	vao, vbo, ebo:        u32,
	text_vao, text_vbo:   u32,
	image_vao, image_vbo: u32,

	// Font
	font:                 Font_Atlas,
	font_size:            f32,
	icon_cache:           Icon_Cache,
	style:                UI_Style,
	id_counter:           u64,
	batch:                Render_Batch,
	projection:           glsl.mat4,
}

default_style :: proc() -> UI_Style {
	return UI_Style {
		bg_color = {0.2, 0.2, 0.25, 0.95},
		fg_color = {0.3, 0.3, 0.35, 1.0},
		border_color = {0.4, 0.4, 0.45, 1.0},
		text_color = {0.9, 0.9, 0.95, 1.0},
		hover_color = {0.35, 0.35, 0.4, 1.0},
		active_color = {0.25, 0.5, 0.8, 1.0},
		padding = 8.0,
		rounding = 4.0,
	}
}

load_font :: proc(atlas: ^Font_Atlas, font_size: f32) -> bool {
	font_paths := [?]string {
		"fonts/Roboto-Regular.ttf",
		"fonts/Arial.ttf",
		"C:/Windows/Fonts/arial.ttf",
		"C:/Windows/Fonts/segoeui.ttf",
		"/System/Library/Fonts/Helvetica.ttc",
		"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	}

	font_data: []u8
	ok: bool

	for path in font_paths {
		font_data, ok = os.read_entire_file(path)
		if ok {
			fmt.printf("Loaded font from: %s\n", path)
			break
		}
	}

	if !ok {
		fmt.println("ERROR: Could not load any font file!")
		return false
	}
	defer delete(font_data)

	atlas.width = 512
	atlas.height = 512

	temp_bitmap := make([]u8, atlas.width * atlas.height)
	defer delete(temp_bitmap)

	result := stbtt.BakeFontBitmap(
		raw_data(font_data),
		0,
		font_size,
		raw_data(temp_bitmap),
		atlas.width,
		atlas.height,
		32,
		96,
		raw_data(atlas.char_data[:]),
	)

	if result <= 0 {
		fmt.println("ERROR: Font baking failed!")
		return false
	}

	gl.GenTextures(1, &atlas.texture)
	gl.BindTexture(gl.TEXTURE_2D, atlas.texture)
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.RED,
		atlas.width,
		atlas.height,
		0,
		gl.RED,
		gl.UNSIGNED_BYTE,
		raw_data(temp_bitmap),
	)

	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

	return true
}

ui_load_icon :: proc(ctx: ^UI_Context, name, filepath: string) -> bool {
	if name in ctx.icon_cache.images {
		return true
	}

	width, height, channels: i32

	data := stbi.load(
		strings.clone_to_cstring(filepath),
		&width,
		&height,
		&channels,
		4, // Force RGBA
	)

	if data == nil {
		fmt.printf("ERROR: Failed to load icon: %s\n", filepath)
		return false
	}
	defer stbi.image_free(data)

	// Create OpenGL texture
	texture: u32
	gl.GenTextures(1, &texture)
	gl.BindTexture(gl.TEXTURE_2D, texture)

	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, data)

	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

	// Store in cache
	image := UI_Image {
		texture = texture,
		width   = width,
		height  = height,
	}
	ctx.icon_cache.images[name] = image

	fmt.printf("Loaded icon '%s': %dx%d\n", name, width, height)
	return true
}

ui_load_icons_from_directory :: proc(ctx: ^UI_Context, dir: string) {
	icon_files := [?]string {
		"translate.png",
		"scale.png",
		"rotate.png",
		"camera.png",
		"grid.png",
		"settings.png",
		"Icon.png",
	}

	for icon_file in icon_files {
		path := fmt.tprintf("%s/%s", dir, icon_file)
		name := strings.trim_suffix(icon_file, ".png")
		ui_load_icon(ctx, name, path)
	}
}

ui_init :: proc(ctx: ^UI_Context, screen_width, screen_height: i32) {
	ctx.style = default_style()
	ctx.row_height = 24.0
	ctx.font_size = 16.0
	ctx.screen_height = screen_height

	if !load_font(&ctx.font, ctx.font_size) {
		fmt.println("WARNING: Running without font support")
	}

	// Initialize icon cache
	ctx.icon_cache.images = make(map[string]UI_Image)

	// Initialize batching system
	ctx.batch.shape_vertices = make([dynamic]f32, 0, 4096)
	ctx.batch.shape_indices = make([dynamic]u32, 0, 2048)
	ctx.batch.text_vertices = make([dynamic]f32, 0, 4096)
	ctx.batch.image_vertices = make([dynamic]f32, 0, 2048)
	ctx.batch.commands = make([dynamic]Draw_Command, 0, 256)

	// Create main shader for shapes
	vertex_shader := `#version 330 core
layout (location = 0) in vec2 aPos;
layout (location = 1) in vec4 aColor;

out vec4 vertexColor;
uniform mat4 projection;

void main() {
	gl_Position = projection * vec4(aPos, 0.0, 1.0);
	vertexColor = aColor;
}
`

	fragment_shader := `#version 330 core
in vec4 vertexColor;
out vec4 FragColor;

void main() {
	FragColor = vertexColor;
}
`

	ctx.shader = compile_ui_shader(vertex_shader, fragment_shader)

	// Create text shader
	text_vertex_shader := `#version 330 core
layout (location = 0) in vec2 aPos;
layout (location = 1) in vec2 aTexCoord;

out vec2 TexCoord;
uniform mat4 projection;

void main() {
	gl_Position = projection * vec4(aPos, 0.0, 1.0);
	TexCoord = aTexCoord;
}
`

	text_fragment_shader := `#version 330 core
in vec2 TexCoord;
out vec4 FragColor;

uniform sampler2D fontTexture;
uniform vec4 textColor;

void main() {
	float alpha = texture(fontTexture, TexCoord).r;
	FragColor = vec4(textColor.rgb, textColor.a * alpha);
}
`

	ctx.text_shader = compile_ui_shader(text_vertex_shader, text_fragment_shader)

	// Create image shader
	image_vertex_shader := `#version 330 core
layout (location = 0) in vec2 aPos;
layout (location = 1) in vec2 aTexCoord;

out vec2 TexCoord;
uniform mat4 projection;

void main() {
	gl_Position = projection * vec4(aPos, 0.0, 1.0);
	TexCoord = aTexCoord;
}
`

	image_fragment_shader := `#version 330 core
in vec2 TexCoord;
out vec4 FragColor;

uniform sampler2D imageTexture;
uniform vec4 tintColor;

void main() {
	vec4 texColor = texture(imageTexture, TexCoord);
	FragColor = texColor * tintColor;
}
`

	ctx.image_shader = compile_ui_shader(image_vertex_shader, image_fragment_shader)

	// Create buffers for shapes
	gl.GenVertexArrays(1, &ctx.vao)
	gl.GenBuffers(1, &ctx.vbo)
	gl.GenBuffers(1, &ctx.ebo)

	gl.BindVertexArray(ctx.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, ctx.vbo)
	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ctx.ebo)

	gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 6 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(1, 4, gl.FLOAT, gl.FALSE, 6 * size_of(f32), 2 * size_of(f32))
	gl.EnableVertexAttribArray(1)

	// Create buffers for text
	gl.GenVertexArrays(1, &ctx.text_vao)
	gl.GenBuffers(1, &ctx.text_vbo)

	gl.BindVertexArray(ctx.text_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, ctx.text_vbo)

	gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 4 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 4 * size_of(f32), 2 * size_of(f32))
	gl.EnableVertexAttribArray(1)

	// Create buffers for images
	gl.GenVertexArrays(1, &ctx.image_vao)
	gl.GenBuffers(1, &ctx.image_vbo)

	gl.BindVertexArray(ctx.image_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, ctx.image_vbo)

	gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 4 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 4 * size_of(f32), 2 * size_of(f32))
	gl.EnableVertexAttribArray(1)

	// Try to load icons
	ui_load_icons_from_directory(ctx, "icons")
}

compile_ui_shader :: proc(vertex_src, fragment_src: string) -> u32 {
	vs := gl.CreateShader(gl.VERTEX_SHADER)
	vs_cstr := cstring(raw_data(vertex_src))
	vs_len := i32(len(vertex_src))
	gl.ShaderSource(vs, 1, &vs_cstr, &vs_len)
	gl.CompileShader(vs)

	fs := gl.CreateShader(gl.FRAGMENT_SHADER)
	fs_cstr := cstring(raw_data(fragment_src))
	fs_len := i32(len(fragment_src))
	gl.ShaderSource(fs, 1, &fs_cstr, &fs_len)
	gl.CompileShader(fs)

	program := gl.CreateProgram()
	gl.AttachShader(program, vs)
	gl.AttachShader(program, fs)
	gl.LinkProgram(program)

	gl.DeleteShader(vs)
	gl.DeleteShader(fs)

	return program
}

// === Input Handling ===

ui_begin_frame :: proc(ctx: ^UI_Context, window: glfw.WindowHandle, scroll_delta: f32 = 0) {
	mx, my := glfw.GetCursorPos(window)
	ctx.mouse_x = f32(mx)
	ctx.mouse_y = f32(my)

	current_down := glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS
	ctx.mouse_pressed = current_down && !ctx.prev_mouse_down
	ctx.mouse_released = !current_down && ctx.prev_mouse_down
	ctx.mouse_down = current_down
	ctx.prev_mouse_down = current_down

	if ctx.mouse_released {
		ctx.active_id = 0
	}

	ctx.hot_id = 0

	clear(&ctx.panels)
	ctx.current_panel_idx = -1

	if scroll_delta != 0 {
		ctx.active_id = 0
	}

	// Clear batch data
	clear(&ctx.batch.shape_vertices)
	clear(&ctx.batch.shape_indices)
	clear(&ctx.batch.text_vertices)
	clear(&ctx.batch.image_vertices)
	clear(&ctx.batch.commands)
}

ui_end_frame :: proc(ctx: ^UI_Context) {
	ctx.cursor_x = 0
	ctx.cursor_y = 0
}

// === Utility Functions ===

point_in_rect :: proc(x, y: f32, rect: UI_Rect) -> bool {
	return x >= rect.x && x <= rect.x + rect.w && y >= rect.y && y <= rect.y + rect.h
}

gen_id :: proc(ctx: ^UI_Context) -> u64 {
	ctx.id_counter += 1
	return ctx.id_counter
}

// === Batched Drawing Functions ===

batch_rect :: proc(ctx: ^UI_Context, rect: UI_Rect, color: UI_Color) {
	vertex_start := u32(len(ctx.batch.shape_vertices) / 6)

	append(&ctx.batch.shape_vertices, rect.x, rect.y, color.r, color.g, color.b, color.a)
	append(&ctx.batch.shape_vertices, rect.x + rect.w, rect.y, color.r, color.g, color.b, color.a)
	append(
		&ctx.batch.shape_vertices,
		rect.x + rect.w,
		rect.y + rect.h,
		color.r,
		color.g,
		color.b,
		color.a,
	)
	append(&ctx.batch.shape_vertices, rect.x, rect.y + rect.h, color.r, color.g, color.b, color.a)

	append(&ctx.batch.shape_indices, vertex_start + 0, vertex_start + 1, vertex_start + 2)
	append(&ctx.batch.shape_indices, vertex_start + 0, vertex_start + 2, vertex_start + 3)
}

batch_rect_outline :: proc(
	ctx: ^UI_Context,
	rect: UI_Rect,
	color: UI_Color,
	thickness: f32 = 1.0,
) {
	t := thickness / 2.0

	batch_rect(ctx, UI_Rect{rect.x - t, rect.y - t, rect.w + thickness, thickness}, color)
	batch_rect(ctx, UI_Rect{rect.x + rect.w - t, rect.y - t, thickness, rect.h + thickness}, color)
	batch_rect(ctx, UI_Rect{rect.x - t, rect.y + rect.h - t, rect.w + thickness, thickness}, color)
	batch_rect(ctx, UI_Rect{rect.x - t, rect.y - t, thickness, rect.h + thickness}, color)
}

batch_text :: proc(ctx: ^UI_Context, text: string, x, y: f32, color: UI_Color) -> f32 {
	if ctx.font.texture == 0 do return 0

	cursor_x := x
	cursor_y := y

	vertex_start := len(ctx.batch.text_vertices)

	for ch in text {
		if ch < 32 || ch > 127 do continue

		char_index := int(ch) - 32
		q: stbtt.aligned_quad

		stbtt.GetBakedQuad(
			raw_data(ctx.font.char_data[:]),
			ctx.font.width,
			ctx.font.height,
			i32(char_index),
			&cursor_x,
			&cursor_y,
			&q,
			true,
		)

		append(&ctx.batch.text_vertices, q.x0, q.y0, q.s0, q.t0)
		append(&ctx.batch.text_vertices, q.x1, q.y0, q.s1, q.t0)
		append(&ctx.batch.text_vertices, q.x1, q.y1, q.s1, q.t1)

		append(&ctx.batch.text_vertices, q.x0, q.y0, q.s0, q.t0)
		append(&ctx.batch.text_vertices, q.x1, q.y1, q.s1, q.t1)
		append(&ctx.batch.text_vertices, q.x0, q.y1, q.s0, q.t1)
	}

	vertex_count := i32(len(ctx.batch.text_vertices) - vertex_start) / 4

	cmd := Draw_Command {
		type          = .TEXT,
		color         = color,
		text          = text,
		vertex_count  = vertex_count * 6,
		vertex_offset = i32(vertex_start / 4),
	}
	append(&ctx.batch.commands, cmd)

	return cursor_x - x
}

batch_image :: proc(ctx: ^UI_Context, name: string, rect: UI_Rect, tint: UI_Color = {1, 1, 1, 1}) {
	_, ok := ctx.icon_cache.images[name]
	if !ok do return

	vertex_start := len(ctx.batch.image_vertices)

	// Two triangles for the image quad
	append(&ctx.batch.image_vertices, rect.x, rect.y, 0, 0)
	append(&ctx.batch.image_vertices, rect.x + rect.w, rect.y, 1, 0)
	append(&ctx.batch.image_vertices, rect.x + rect.w, rect.y + rect.h, 1, 1)

	append(&ctx.batch.image_vertices, rect.x, rect.y, 0, 0)
	append(&ctx.batch.image_vertices, rect.x + rect.w, rect.y + rect.h, 1, 1)
	append(&ctx.batch.image_vertices, rect.x, rect.y + rect.h, 0, 1)

	cmd := Draw_Command {
		type          = .IMAGE,
		color         = tint,
		image_name    = name,
		vertex_count  = 6,
		vertex_offset = i32(vertex_start / 4),
	}
	append(&ctx.batch.commands, cmd)
}

get_text_width :: proc(ctx: ^UI_Context, text: string) -> f32 {
	if ctx.font.texture == 0 do return f32(len(text)) * 8

	x: f32 = 0
	y: f32 = 0

	for ch in text {
		if ch < 32 || ch > 127 do continue
		char_index := int(ch) - 32
		q: stbtt.aligned_quad
		stbtt.GetBakedQuad(
			raw_data(ctx.font.char_data[:]),
			ctx.font.width,
			ctx.font.height,
			i32(char_index),
			&x,
			&y,
			&q,
			true,
		)
	}

	return x
}

// === Widget Functions ===
ui_push_clip :: proc(ctx: ^UI_Context, rect: UI_Rect, screen_height: i32) {
	ctx.clip_rect = rect
	gl.Enable(gl.SCISSOR_TEST)

	scissor_y := ctx.screen_height - i32(rect.y + rect.h)

	gl.Scissor(
		i32(rect.x),
		scissor_y,
		i32(rect.w),
		i32(rect.h),
	)
}

ui_pop_clip :: proc() {
	gl.Disable(gl.SCISSOR_TEST)
}

ui_panel_begin :: proc(ctx: ^UI_Context, x, y, w, h: f32, title: string) {
	ctx.current_panel = UI_Rect{x, y, w, h}

	append(&ctx.panels, ctx.current_panel)
	ctx.current_panel_idx = len(ctx.panels) - 1

	ctx.panel_state.content_height = 0
	ctx.panel_state.max_scroll = 0

//	ctx.cursor_x = x + ctx.style.padding
//	ctx.cursor_y = y + ctx.style.padding

	batch_rect(ctx, ctx.current_panel, ctx.style.bg_color)
	batch_rect_outline(ctx, ctx.current_panel, ctx.style.border_color, 2.0)

	title_height: f32 = 0
	if len(title) > 0 {
		title_height = 28
		title_rect := UI_Rect{x, y, w, title_height}
		batch_rect(ctx, title_rect, {0.15, 0.15, 0.2, 1.0})
		batch_text(ctx, title, x + ctx.style.padding, y + 6, {0.9, 0.9, 0.95, 1.0})
		ctx.cursor_y += 32
	}

	content_y := y + title_height
	content_h := h - title_height

	content_rect := UI_Rect{x, content_y, w, content_h}
	ui_push_clip(ctx, content_rect, ctx.screen_height)

	ctx.cursor_x = x + ctx.style.padding
	ctx.cursor_y = content_y + ctx.style.padding - ctx.panel_state.scroll_offset
}

ui_panel_end :: proc(ctx: ^UI_Context) {
	ui_pop_clip()

	panel_top := ctx.current_panel.y + 28
	panel_bottom :=  ctx.current_panel.y + ctx.current_panel.h
	current_bottom := ctx.cursor_y + ctx.panel_state.scroll_offset

	ctx.panel_state.content_height = current_bottom - panel_top

	// Max scroll calc
	visible_height := panel_bottom - panel_top - ctx.style.padding * 2
	ctx.panel_state.max_scroll = max(0, ctx.panel_state.content_height - visible_height)

	if ctx.panel_state.max_scroll > 0 {
		draw_scrollbar(ctx)
	}

	handle_scroll_input(ctx)
}

draw_scrollbar :: proc(ctx: ^UI_Context) {
	panel := ctx.current_panel
	scrollbar_width: f32 = 6
	scrollbar_padding: f32 = 2

	track_x := panel.x + panel.w - scrollbar_width - scrollbar_padding
	track_y := panel.y + 28 + scrollbar_padding
	track_w := scrollbar_width
	track_h := panel.h - 28 - scrollbar_padding * 2

	track_rect := UI_Rect{track_x, track_y, track_w, track_h}

	batch_rect(ctx, track_rect, {0.15, 0.15, 0.2, 0.8})

	visible_height := track_h
	content_h := ctx.panel_state.content_height

	handle_height := max(20, (visible_height / content_h) * track_h)

	scroll_ratio := ctx.panel_state.scroll_offset / ctx.panel_state.max_scroll
	max_handle_y := track_h - handle_height
	handle_y := track_y + scroll_ratio * max_handle_y

	handle_rect := UI_Rect {track_x + 2, handle_y, track_w - 4, handle_height}

	is_hot := point_in_rect(ctx.mouse_x, ctx.mouse_y, handle_rect)
	ctx.panel_state.scroll_bar_hot = is_hot

	handle_color := ctx.style.fg_color
	if ctx.panel_state.scroll_bar_active {
		handle_color = ctx.style.active_color
	} else if is_hot {
		handle_color = ctx.style.hover_color
	}

	batch_rect(ctx, handle_rect, handle_color)
	batch_rect_outline(ctx, handle_rect, ctx.style.border_color, 1.0)
}

handle_scroll_input :: proc(ctx: ^UI_Context) {
	if ctx.panel_state.max_scroll <= 0 do return

	panel := ctx.current_panel

	is_over_panel := point_in_rect(ctx.mouse_x, ctx.mouse_y, panel)

	if ctx.panel_state.scroll_bar_hot && ctx.mouse_pressed {
		ctx.panel_state.scroll_bar_active = true
	}

	if ctx.mouse_released {
		ctx.panel_state.scroll_bar_active = false
	}

	if ctx.panel_state.scroll_bar_active && ctx.mouse_down {
		// calculate scroll from mouse pos
		track_y := panel.y + 28 + 2
		track_h := panel.h - 28 - 4

		visible_height := track_h
		handle_height := max(20, (visible_height / ctx.panel_state.content_height) * track_h)
		max_handle_y := track_h - handle_height

		mouse_offset := ctx.mouse_y - track_y
		scroll_ratio := clamp(mouse_offset / max_handle_y, 0, 1)

		ctx.panel_state.scroll_offset = scroll_ratio * ctx.panel_state.max_scroll
	}
}

ui_scroll_wheel :: proc(ctx: ^UI_Context, scroll_delta: f32) {
	if ctx.panel_state.max_scroll <= 0 do return

	if point_in_rect(ctx.mouse_x, ctx.mouse_y, ctx.current_panel) {
		scroll_speed: f32 = 20.0
		ctx.panel_state.scroll_offset -= scroll_delta * scroll_speed
		ctx.panel_state.scroll_offset = clamp(ctx.panel_state.scroll_offset, 0, ctx.panel_state.max_scroll)
	}
}

ui_button :: proc(ctx: ^UI_Context, text: string, width: f32 = 0) -> bool {
	id := gen_id(ctx)

	w := width > 0 ? width : ctx.current_panel.w - ctx.style.padding * 2
	h := ctx.row_height

	rect := UI_Rect{ctx.cursor_x, ctx.cursor_y, w, h}

	is_hot := point_in_rect(ctx.mouse_x, ctx.mouse_y, rect) && ui_is_mouse_over_current_panel(ctx)
	if is_hot do ctx.hot_id = id

	is_active := ctx.active_id == id
	clicked := false

	if is_hot {
		if ctx.mouse_pressed {
			ctx.active_id = id
		}
		if ctx.mouse_released && is_active {
			clicked = true
		}
	}

	color := ctx.style.fg_color
	if is_active do color = ctx.style.active_color
	else if is_hot do color = ctx.style.hover_color

	batch_rect(ctx, rect, color)
	batch_rect_outline(ctx, rect, ctx.style.border_color)

	text_width := get_text_width(ctx, text)
	text_x := rect.x + (rect.w - text_width) / 2
	text_y := rect.y + (rect.h - ctx.font_size) / 2
	batch_text(ctx, text, text_x, text_y, ctx.style.text_color)

	ctx.cursor_y += h + ctx.style.padding / 2

	return clicked
}

ui_icon_button :: proc(ctx: ^UI_Context, icon_name: string, width: f32 = 0) -> bool {
	id := gen_id(ctx)

	w := width > 0 ? width : ctx.row_height
	h := ctx.row_height

	rect := UI_Rect{ctx.cursor_x, ctx.cursor_y, w, h}

	is_hot := point_in_rect(ctx.mouse_x, ctx.mouse_y, rect) && ui_is_mouse_over_current_panel(ctx)
	if is_hot do ctx.hot_id = id

	is_active := ctx.active_id == id
	clicked := false

	if is_hot {
		if ctx.mouse_pressed {
			ctx.active_id = id
		}
		if ctx.mouse_released && is_active {
			clicked = true
		}
	}

	color := ctx.style.fg_color
	if is_active do color = ctx.style.active_color
	else if is_hot do color = ctx.style.hover_color

	batch_rect(ctx, rect, color)
	batch_rect_outline(ctx, rect, ctx.style.border_color)

	// Draw icon centered with padding
	icon_size := h - ctx.style.padding * 2
	icon_rect := UI_Rect {
		rect.x + (w - icon_size) / 2,
		rect.y + (h - icon_size) / 2,
		icon_size,
		icon_size,
	}
	batch_image(ctx, icon_name, icon_rect, ctx.style.text_color)

	ctx.cursor_y += h + ctx.style.padding / 2

	return clicked
}

ui_label :: proc(ctx: ^UI_Context, text: string) {
	h := ctx.row_height * 0.7
	batch_text(ctx, text, ctx.cursor_x, ctx.cursor_y, ctx.style.text_color)
	ctx.cursor_y += h + ctx.style.padding / 4
}

ui_image :: proc(ctx: ^UI_Context, name: string, width: f32 = 0, height: f32 = 0) {
	w := width > 0 ? width : ctx.current_panel.w - ctx.style.padding * 2
	h := height > 0 ? height : w

	rect := UI_Rect{ctx.cursor_x, ctx.cursor_y, w, h}
	batch_image(ctx, name, rect)

	ctx.cursor_y += h + ctx.style.padding / 2
}

ui_slider :: proc(
	ctx: ^UI_Context,
	value: ^f32,
	min_val, max_val: f32,
	label: string = "",
) -> bool {
	id := gen_id(ctx)

	if len(label) > 0 {
		ui_label(ctx, label)
	}

	w := ctx.current_panel.w - ctx.style.padding * 2
	h := ctx.row_height * 0.8

	rect := UI_Rect{ctx.cursor_x, ctx.cursor_y, w, h}

	is_hot := point_in_rect(ctx.mouse_x, ctx.mouse_y, rect)
	if is_hot do ctx.hot_id = id

	is_active := ctx.active_id == id
	changed := false

	if is_hot && ctx.mouse_pressed {
		ctx.active_id = id
	}

	if is_active && ctx.mouse_down {
		t := clamp((ctx.mouse_x - rect.x) / rect.w, 0, 1)
		new_value := min_val + t * (max_val - min_val)
		if new_value != value^ {
			value^ = new_value
			changed = true
		}
	}

	bg_color := is_hot ? ctx.style.hover_color : ctx.style.fg_color
	batch_rect(ctx, rect, bg_color)
	batch_rect_outline(ctx, rect, ctx.style.border_color)

	t := (value^ - min_val) / (max_val - min_val)
	fill_rect := UI_Rect{rect.x, rect.y, rect.w * t, rect.h}
	batch_rect(ctx, fill_rect, ctx.style.active_color)

	handle_x := rect.x + rect.w * t
	handle_rect := UI_Rect{handle_x - 4, rect.y - 2, 8, rect.h + 4}
	batch_rect(ctx, handle_rect, {0.9, 0.9, 0.95, 1.0})
	batch_rect_outline(ctx, handle_rect, ctx.style.border_color, 2.0)

	buf: [32]u8
	value_text := fmt.bprintf(buf[:], "%.2f", value^)
	value_width := get_text_width(ctx, string(value_text))
	batch_text(
		ctx,
		string(value_text),
		rect.x + rect.w - value_width - 4,
		rect.y + 2,
		ctx.style.text_color,
	)

	ctx.cursor_y += h + ctx.style.padding

	return changed
}

ui_separator :: proc(ctx: ^UI_Context) {
	y := ctx.cursor_y + 4
	rect := UI_Rect{ctx.cursor_x, y, ctx.current_panel.w - ctx.style.padding * 2, 1}
	batch_rect(ctx, rect, ctx.style.border_color)
	ctx.cursor_y += 12
}

ui_spacing :: proc(ctx: ^UI_Context, amount: f32 = 0) {
	spacing := amount > 0 ? amount : ctx.style.padding
	ctx.cursor_y += spacing
}

// === Rendering - BATCHED DRAW CALLS ===

ui_render_begin :: proc(ctx: ^UI_Context, screen_width, screen_height: i32) {
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

	ctx.projection = glsl.mat4Ortho3d(0, f32(screen_width), f32(screen_height), 0, -1, 1)
}

ui_flush_shapes :: proc(ctx: ^UI_Context) {
	if len(ctx.batch.shape_vertices) == 0 do return

	gl.UseProgram(ctx.shader)
	gl.UniformMatrix4fv(
		gl.GetUniformLocation(ctx.shader, "projection"),
		1,
		false,
		&ctx.projection[0, 0],
	)
	gl.BindVertexArray(ctx.vao)

	gl.BindBuffer(gl.ARRAY_BUFFER, ctx.vbo)
	gl.BufferData(
		gl.ARRAY_BUFFER,
		len(ctx.batch.shape_vertices) * size_of(f32),
		raw_data(ctx.batch.shape_vertices),
		gl.DYNAMIC_DRAW,
	)

	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ctx.ebo)
	gl.BufferData(
		gl.ELEMENT_ARRAY_BUFFER,
		len(ctx.batch.shape_indices) * size_of(u32),
		raw_data(ctx.batch.shape_indices),
		gl.DYNAMIC_DRAW,
	)

	gl.DrawElements(gl.TRIANGLES, i32(len(ctx.batch.shape_indices)), gl.UNSIGNED_INT, nil)
}

ui_flush_text :: proc(ctx: ^UI_Context) {
	if len(ctx.batch.text_vertices) == 0 do return

	gl.UseProgram(ctx.text_shader)
	gl.UniformMatrix4fv(
		gl.GetUniformLocation(ctx.text_shader, "projection"),
		1,
		false,
		&ctx.projection[0, 0],
	)
	gl.BindVertexArray(ctx.text_vao)

	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, ctx.font.texture)
	gl.Uniform1i(gl.GetUniformLocation(ctx.text_shader, "fontTexture"), 0)

	gl.BindBuffer(gl.ARRAY_BUFFER, ctx.text_vbo)
	gl.BufferData(
		gl.ARRAY_BUFFER,
		len(ctx.batch.text_vertices) * size_of(f32),
		raw_data(ctx.batch.text_vertices),
		gl.DYNAMIC_DRAW,
	)

	for cmd in ctx.batch.commands {
		if cmd.type != .TEXT do continue

		gl.Uniform4f(
			gl.GetUniformLocation(ctx.text_shader, "textColor"),
			cmd.color.r,
			cmd.color.g,
			cmd.color.b,
			cmd.color.a,
		)

		gl.DrawArrays(gl.TRIANGLES, cmd.vertex_offset, cmd.vertex_count)
	}
}

ui_flush_images :: proc(ctx: ^UI_Context) {
	if len(ctx.batch.image_vertices) == 0 do return

	gl.UseProgram(ctx.image_shader)
	gl.UniformMatrix4fv(
		gl.GetUniformLocation(ctx.image_shader, "projection"),
		1,
		false,
		&ctx.projection[0, 0],
	)
	gl.BindVertexArray(ctx.image_vao)

	gl.ActiveTexture(gl.TEXTURE0)
	gl.Uniform1i(gl.GetUniformLocation(ctx.image_shader, "imageTexture"), 0)

	gl.BindBuffer(gl.ARRAY_BUFFER, ctx.image_vbo)
	gl.BufferData(
		gl.ARRAY_BUFFER,
		len(ctx.batch.image_vertices) * size_of(f32),
		raw_data(ctx.batch.image_vertices),
		gl.DYNAMIC_DRAW,
	)

	for cmd in ctx.batch.commands {
		if cmd.type != .IMAGE do continue

		image, ok := ctx.icon_cache.images[cmd.image_name]
		if !ok do continue

		gl.BindTexture(gl.TEXTURE_2D, image.texture)
		gl.Uniform4f(
			gl.GetUniformLocation(ctx.image_shader, "tintColor"),
			cmd.color.r,
			cmd.color.g,
			cmd.color.b,
			cmd.color.a,
		)

		gl.DrawArrays(gl.TRIANGLES, cmd.vertex_offset, cmd.vertex_count)
	}
}

ui_render_end :: proc(ctx: ^UI_Context) {
	ui_flush_shapes(ctx)
	ui_flush_text(ctx)
	ui_flush_images(ctx)

	gl.Disable(gl.BLEND)
	gl.Enable(gl.DEPTH_TEST)
	gl.Enable(gl.CULL_FACE)
}

// === Cleanup ===

ui_cleanup :: proc(ctx: ^UI_Context) {
	delete(ctx.batch.shape_vertices)
	delete(ctx.batch.shape_indices)
	delete(ctx.batch.text_vertices)
	delete(ctx.batch.image_vertices)
	delete(ctx.batch.commands)
	delete(ctx.panels)

	// Clean up icon textures
	for _, image in ctx.icon_cache.images {
		i := image
		gl.DeleteTextures(1, &i.texture)
	}
	delete(ctx.icon_cache.images)

	gl.DeleteVertexArrays(1, &ctx.vao)
	gl.DeleteBuffers(1, &ctx.vbo)
	gl.DeleteBuffers(1, &ctx.ebo)
	gl.DeleteVertexArrays(1, &ctx.text_vao)
	gl.DeleteBuffers(1, &ctx.text_vbo)
	gl.DeleteVertexArrays(1, &ctx.image_vao)
	gl.DeleteBuffers(1, &ctx.image_vbo)
	gl.DeleteProgram(ctx.shader)
	gl.DeleteProgram(ctx.text_shader)
	gl.DeleteProgram(ctx.image_shader)
	gl.DeleteTextures(1, &ctx.font.texture)
}

// === Helper to check if mouse is over any UI ===

ui_is_mouse_over :: proc(ctx: ^UI_Context) -> bool {
	if ctx.hot_id != 0 || ctx.active_id != 0 do return true

	if uv_editor.visible {
		mx := ctx.mouse_x
		my := ctx.mouse_y
		if mx >= uv_editor.x && mx <= uv_editor.x + uv_editor.width &&
			my >= uv_editor.y && my <= uv_editor.y + uv_editor.height {
				return true
		}
	}

	for panel in ctx.panels {
		if point_in_rect(ctx.mouse_x, ctx.mouse_y, panel) {
			return true
		}
	}

	return false
}

ui_is_mouse_over_current_panel :: proc(ctx: ^UI_Context) -> bool {
	if ctx.current_panel_idx < 0 do return false
	return point_in_rect(ctx.mouse_x, ctx.mouse_y, ctx.current_panel)
}
