package main

import "core:fmt"
import "core:math/linalg/glsl"
import "core:os"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

Texture_Atlas :: struct {
	texture_id:    u32,
	width, height: i32,
	pixel_data:    []u8,
}

create_texture_atlas :: proc(width, height: i32) -> Texture_Atlas {
	atlas := Texture_Atlas {
		width      = width,
		height     = height,
		pixel_data = make([]u8, width * height * 4), // RGBA
	}

	for i in 0 ..< (width * height * 4) {
		atlas.pixel_data[i] = 255
	}

	gl.GenTextures(1, &atlas.texture_id)
	gl.BindTexture(gl.TEXTURE_2D, atlas.texture_id)

	gl.GenTextures(1, &atlas.texture_id)
	gl.BindTexture(gl.TEXTURE_2D, atlas.texture_id)

	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.RGBA,
		width,
		height,
		0,
		gl.RGBA,
		gl.UNSIGNED_BYTE,
		raw_data(atlas.pixel_data),
	)

	return atlas
}

update_texture_atlas :: proc(atlas: ^Texture_Atlas) {
	gl.BindTexture(gl.TEXTURE_2D, atlas.texture_id)
	gl.TexSubImage2D(
		gl.TEXTURE_2D,
		0,
		0,
		0,
		atlas.width,
		atlas.height,
		gl.RGBA,
		gl.UNSIGNED_BYTE,
		raw_data(atlas.pixel_data),
	)
}

load_texture_from_file :: proc(atlas: ^Texture_Atlas, filepath: string) -> bool {
	width, height, channels: i32

	data := stbi.load(
		cstring(raw_data(filepath)),
		&width,
		&height,
		&channels,
		4, // Force RGBA
	)

	if data == nil {
		fmt.printf("ERROR: Faield to load texture: %s\n", filepath)
		return false
	}
	defer stbi.image_free(data)

	// Resize atlas if needed
	if width != atlas.width || height != atlas.height {
		delete(atlas.pixel_data)
		atlas.width = width
		atlas.height = height
		atlas.pixel_data = make([]u8, width * height * 4)
	}

	copy(atlas.pixel_data, data[:width * height * 4])

	gl.BindTexture(gl.TEXTURE_2D, atlas.texture_id)
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.RGBA,
		width,
		height,
		0,
		gl.RGBA,
		gl.UNSIGNED_BYTE,
		raw_data(atlas.pixel_data),
	)

	fmt.printf("Loaded texture: %dx%d from %s\n", width, height, filepath)
	return true
}

save_texture_to_file :: proc(atlas: ^Texture_Atlas, filepath: string) -> bool {
	// FIXME: Implement this
	fmt.printf("Saving texture to: %s\n", filepath)
	return true
}

paint_pixel :: proc(atlas: ^Texture_Atlas, x, y: i32, color: glsl.vec4) {
	if x < 0 || x >= atlas.width || y < 0 || y >= atlas.height do return

	idx := (y * atlas.width + x) * 4
	atlas.pixel_data[idx + 0] = u8(color.r * 255)
	atlas.pixel_data[idx + 1] = u8(color.g * 255)
	atlas.pixel_data[idx + 2] = u8(color.b * 255)
	atlas.pixel_data[idx + 3] = u8(color.a * 255)
}

paint_brush :: proc(atlas: ^Texture_Atlas, center_x, center_y, radius: i32, color: glsl.vec4) {
	for dy in -radius ..= radius {
		for dx in -radius ..= radius {
			if dx * dx + dy * dy <= radius * radius {
				paint_pixel(atlas, center_x + dx, center_y + dy, color)
			}
		}
	}
	update_texture_atlas(atlas)
}

get_face_uv_region :: proc(face_idx: Face_Index, texture_size: i32) -> (u0, v0, u1, v1: f32) {
	// Layout: 6 faces in a 3x2 grid
	// [Front] [Right] [Back]
	// [Left] [Top] [Bottom]

	grid_w := f32(1.0 / 3.0)
	grid_h := f32(1.0 / 2.0)

	switch face_idx {
	case .FRONT:
		return 0 * grid_w, 0 * grid_h, 1 * grid_w, 1 * grid_h
	case .RIGHT:
		return 1 * grid_w, 0 * grid_h, 2 * grid_w, 1 * grid_h
	case .BACK:
		return 2 * grid_w, 0 * grid_h, 3 * grid_w, 1 * grid_h
	case .LEFT:
		return 0 * grid_w, 1 * grid_h, 1 * grid_w, 2 * grid_h
	case .TOP:
		return 1 * grid_w, 1 * grid_h, 2 * grid_w, 2 * grid_h
	case .BOTTOM:
		return 2 * grid_w, 1 * grid_h, 3 * grid_w, 2 * grid_h
	}

	return 0, 0, 1, 1
}

generate_cube_with_uvs :: proc(allocator := context.allocator) -> []f32 {
	// 6 faces * 6 vertices per face * 8 floats per vertex (pos, normal, uv) = 288
	vertices := make([dynamic]f32, 0, 288, allocator)

	// Helper to reduce repetitive append calls
	add_vertex :: proc(v: ^[dynamic]f32, x, y, z, nx, ny, nz, u, v_coord: f32) {
		append(v, x, y, z, nx, ny, nz, u, v_coord)
	}

	// Front face (Z+)
	u0, v0, u1, v1 := get_face_uv_region(.FRONT, 0)
	add_vertex(&vertices, -0.5, -0.5, 0.5, 0.0, 0.0, 1.0, u0, v1)
	add_vertex(&vertices, 0.5, -0.5, 0.5, 0.0, 0.0, 1.0, u1, v1)
	add_vertex(&vertices, 0.5, 0.5, 0.5, 0.0, 0.0, 1.0, u1, v0)
	add_vertex(&vertices, 0.5, 0.5, 0.5, 0.0, 0.0, 1.0, u1, v0)
	add_vertex(&vertices, -0.5, 0.5, 0.5, 0.0, 0.0, 1.0, u0, v0)
	add_vertex(&vertices, -0.5, -0.5, 0.5, 0.0, 0.0, 1.0, u0, v1)

	// Back face (Z-)
	u0, v0, u1, v1 = get_face_uv_region(.BACK, 0)
	add_vertex(&vertices, 0.5, -0.5, -0.5, 0.0, 0.0, -1.0, u0, v1)
	add_vertex(&vertices, -0.5, -0.5, -0.5, 0.0, 0.0, -1.0, u1, v1)
	add_vertex(&vertices, -0.5, 0.5, -0.5, 0.0, 0.0, -1.0, u1, v0)
	add_vertex(&vertices, -0.5, 0.5, -0.5, 0.0, 0.0, -1.0, u1, v0)
	add_vertex(&vertices, 0.5, 0.5, -0.5, 0.0, 0.0, -1.0, u0, v0)
	add_vertex(&vertices, 0.5, -0.5, -0.5, 0.0, 0.0, -1.0, u0, v1)

	// Left face (X-)
	u0, v0, u1, v1 = get_face_uv_region(.LEFT, 0)
	add_vertex(&vertices, -0.5, -0.5, -0.5, -1.0, 0.0, 0.0, u0, v1)
	add_vertex(&vertices, -0.5, -0.5, 0.5, -1.0, 0.0, 0.0, u1, v1)
	add_vertex(&vertices, -0.5, 0.5, 0.5, -1.0, 0.0, 0.0, u1, v0)
	add_vertex(&vertices, -0.5, 0.5, 0.5, -1.0, 0.0, 0.0, u1, v0)
	add_vertex(&vertices, -0.5, 0.5, -0.5, -1.0, 0.0, 0.0, u0, v0)
	add_vertex(&vertices, -0.5, -0.5, -0.5, -1.0, 0.0, 0.0, u0, v1)

	// Right face (X+)
	u0, v0, u1, v1 = get_face_uv_region(.RIGHT, 0)
	add_vertex(&vertices, 0.5, -0.5, 0.5, 1.0, 0.0, 0.0, u0, v1)
	add_vertex(&vertices, 0.5, -0.5, -0.5, 1.0, 0.0, 0.0, u1, v1)
	add_vertex(&vertices, 0.5, 0.5, -0.5, 1.0, 0.0, 0.0, u1, v0)
	add_vertex(&vertices, 0.5, 0.5, -0.5, 1.0, 0.0, 0.0, u1, v0)
	add_vertex(&vertices, 0.5, 0.5, 0.5, 1.0, 0.0, 0.0, u0, v0)
	add_vertex(&vertices, 0.5, -0.5, 0.5, 1.0, 0.0, 0.0, u0, v1)

	// Top face (Y+)
	u0, v0, u1, v1 = get_face_uv_region(.TOP, 0)
	add_vertex(&vertices, -0.5, 0.5, 0.5, 0.0, 1.0, 0.0, u0, v1)
	add_vertex(&vertices, 0.5, 0.5, 0.5, 0.0, 1.0, 0.0, u1, v1)
	add_vertex(&vertices, 0.5, 0.5, -0.5, 0.0, 1.0, 0.0, u1, v0)
	add_vertex(&vertices, 0.5, 0.5, -0.5, 0.0, 1.0, 0.0, u1, v0)
	add_vertex(&vertices, -0.5, 0.5, -0.5, 0.0, 1.0, 0.0, u0, v0)
	add_vertex(&vertices, -0.5, 0.5, 0.5, 0.0, 1.0, 0.0, u0, v1)

	// Bottom face (Y-)
	u0, v0, u1, v1 = get_face_uv_region(.BOTTOM, 0)
	add_vertex(&vertices, -0.5, -0.5, -0.5, 0.0, -1.0, 0.0, u0, v1)
	add_vertex(&vertices, 0.5, -0.5, -0.5, 0.0, -1.0, 0.0, u1, v1)
	add_vertex(&vertices, 0.5, -0.5, 0.5, 0.0, -1.0, 0.0, u1, v0)
	add_vertex(&vertices, 0.5, -0.5, 0.5, 0.0, -1.0, 0.0, u1, v0)
	add_vertex(&vertices, -0.5, -0.5, 0.5, 0.0, -1.0, 0.0, u0, v0)
	add_vertex(&vertices, -0.5, -0.5, -0.5, 0.0, -1.0, 0.0, u0, v1)

	return vertices[:]
}

cleanup_texture_atlas :: proc(atlas: ^Texture_Atlas) {
	gl.DeleteTextures(1, &atlas.texture_id)
	delete(atlas.pixel_data)
}
