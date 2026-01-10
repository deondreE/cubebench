package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:math/linalg/glsl"

Scene_Object_Data :: struct {
	position: [3]f32,
	rotation: [3]f32,
	scale: [3]f32,
	color: [4]f32,
	face_colors: [6][4]f32,
	use_per_face_colors: bool,
	use_texture: bool,
}

Scene_Save_Data :: struct {
	objects: []Scene_Object_Data,
	texture_width: i32,
	texture_height: i32,
	project_version: i32,
}

scene_object_to_data :: proc(obj: Scene_Object) -> Scene_Object_Data {
	data := Scene_Object_Data {
		position = [3]f32 {obj.position.x, obj.position.y, obj.position.z},
		rotation = [3]f32 {obj.rotation.x, obj.rotation.y, obj.rotation.z},
		scale    = [3]f32 {obj.scale.x, obj.scale.y, obj.scale.z},
		color    = [4]f32 {obj.color.r, obj.color.g, obj.color.b, obj.color.a},
		use_per_face_colors = obj.use_per_face_colors,
		use_texture = obj.use_texture,
	}

	for i in 0 ..< 6 {
		data.face_colors[i] = [4]f32 {
			obj.face_colors[i].r,
			obj.face_colors[i].g,
			obj.face_colors[i].b,
			obj.face_colors[i].a,
		}
	}

	return data
}

restore_object_from_data :: proc(scene: ^Scene, data: Scene_Object_Data) -> int {
	pos := glsl.vec3{data.position.x, data.position.y, data.position.z}
	scale := glsl.vec3{data.scale.x, data.scale.y, data.scale.z}
	color := glsl.vec4{data.color[0], data.color[1], data.color[2], data.color[3]}

	obj_idx := scene_add_cube(scene, pos, scale, color)

	obj := &scene.objects[obj_idx]
	obj.rotation = glsl.vec3{data.rotation.x, data.rotation.y, data.rotation.z}
	obj.use_per_face_colors = data.use_per_face_colors
	obj.use_texture = data.use_texture

	for i in 0..<6 {
		obj.face_colors[i] = glsl.vec4 {
			data.face_colors[i][0],
			data.face_colors[i][1],
			data.face_colors[i][2],
			data.face_colors[i][3],
		}
	}

	return obj_idx
}

save_scene_to_file :: proc(scene: ^Scene, filename: string) -> bool {
	objects_data := make([dynamic]Scene_Object_Data, 0, len(scene.objects))
	defer delete(objects_data)

	for obj in scene.objects {
		append(&objects_data, scene_object_to_data(obj))
	}

	scene_data := Scene_Save_Data {
		objects = objects_data[:],
		texture_width = scene.default_atlas.width,
		texture_height  = scene.default_atlas.height,
		project_version = 1.0,
	}

	// TODO: Maybe change to .ini or .yml
	json_data, err := json.marshal(scene_data, {pretty = true})
	if err != nil {
		fmt.printf("Failed to serialize scene: %s\n", filename)
		return false
	}
	defer(delete(json_data))

	if !os.write_entire_file(filename, json_data) {
		fmt.printf("Failed to write file: %s\n", filename)
		return false
	}
	fmt.printf("Scene saved to: %s (%d objects)\n", filename, len(scene.objects))

	if len(filename) > 5 {
		texture_filename := fmt.tprintf("%s.png", filename[:len(filename)-5])
		if save_texture_to_file(&scene.default_atlas, texture_filename) {
			fmt.printf("Texture saved to: %s\n", texture_filename)
		}
	}

	return true
}

load_scene_from_file :: proc(scene: ^Scene, filepath: string) -> bool {
	data, success := os.read_entire_file(filepath)
	if !success {
		fmt.printf("Failed to read file: %s\n", filepath)
		return false
	}
	defer delete(data)

	scene_data: Scene_Save_Data
	err := json.unmarshal(data, &scene_data)
	if err != nil {
		fmt.printf("Failed to parse JSON: %v\n", err)
		return false
	}
	defer delete(scene_data.objects)

	if scene_data.texture_width > 0 && scene_data.texture_height > 0 {
		if scene_data.texture_width != scene.default_atlas.width ||
			scene_data.texture_height != scene.default_atlas.height {
			cleanup_texture_atlas(&scene.default_atlas)
			scene.default_atlas = create_texture_atlas(scene_data.texture_width, scene_data.texture_height)
		}
	}

	texture_filename := fmt.tprintf("%s.png", filepath[:len(filepath)-5])
	if load_texture_from_file(&scene.default_atlas, texture_filename) {
		fmt.printf("Texture loaded from: %s", texture_filename)
	}

	for obj_data in scene_data.objects {
		restore_object_from_data(scene, obj_data)
	}

	fmt.printf("Scene loaded from: %s (%d object)\n", filepath, len(scene_data.objects))

	return true
}
