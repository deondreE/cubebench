package main

import "base:runtime"
import "core:fmt"
import "core:math/linalg/glsl"
import "core:os"
import "core:strings"
import "core:time"
import "vendor:glfw"
import lua "vendor:lua/5.4"

Lua_State :: struct {
	L:            ^lua.State,
	script_error: string,
	last_write_time: time.Time,
	script_path: string,
}

lua_state: Lua_State

lua_init :: proc() -> bool {
	lua_state.L = lua.L_newstate()
	if lua_state.L == nil {
		fmt.println("ERROR: Failed to create Lua state")
		return false
	}


	lua.L_openlibs(lua_state.L)

	lua_sandbox(lua_state.L)

	lua_register_api(lua_state.L)

	// TODO: Make sure UI dialog make new scripts in the scripts foleder.
	if (os.exists("scripts/init.lua")) {
		lua_state.script_path = "scripts/init.lua"
		lua_run_file("scripts/init.lua")
	}

	info, err := os.stat("scripts/init.lua")
	if err == os.ERROR_NONE {
		lua_state.last_write_time = info.modification_time
	}

	fmt.println("Lua scripting initialized")
	return true
}

lua_cleanup :: proc() {
	if lua_state.L != nil {
		lua.close(lua_state.L)
	}
}

lua_update_live :: proc() {
	info, err := os.stat(lua_state.script_path)
	if err != os.ERROR_NONE do return

	if time.diff(info.modification_time, lua_state.last_write_time) > 0 {
		lua_state.last_write_time = info.modification_time

		success := lua_run_file(lua_state.script_path)
		glfw.PostEmptyEvent()

		if success {
			lua_state.script_error = ""
		}

	}
}

lua_sandbox :: proc(L: ^lua.State) {
	// We dont want to use STD libs we want to control the process of input.
	dangerous := []string{"os", "io", "debug", "package", "dofile", "loadfile"}

	for lib in dangerous {
		lua.pushnil(L)
		lua.setglobal(L, cstring(raw_data(lib)))
	}

	fmt.println("Lua sandbox - diabled: os, io, debug, package, dofile, loadfile")
}

lua_register_api :: proc(L: ^lua.State) {
	// Scene API
	lua_register_global_table(L, "Scene")
	lua_register_method(L, "Scene", "addCube", lua_scene_add_cube)
	lua_register_method(L, "Scene", "addQuad", lua_scene_add_quad)
	lua_register_method(L, "Scene", "count", lua_scene_count)
	lua_register_method(L, "Scene", "clear", lua_scene_clear)
	lua_register_method(L, "Scene", "selected", lua_scene_selected)
	lua_register_method(L, "Scene", "selectedAll", lua_scene_select_all)
	lua_register_method(L, "Scene", "selectNone", lua_scene_select_none)

	// Cube API
	lua_register_global_table(L, "Cube")
	lua_register_method(L, "Cube", "new", lua_cube_new)

	// Utility API
	lua_register_global_table(L, "Random")
	lua_register_method(L, "Random", "range", lua_random_range)
	lua_register_method(L, "Random", "color", lua_random_color)
	lua_register_method(L, "Random", "vector", lua_random_vector)

	lua_register_global_table(L, "Vector")
	lua_register_method(L, "Vector", "new", lua_vector_new)

	lua.register(L, "print", lua_print)

	lua_register_object_metatable(L)

	fmt.println("Lua API registered")
}

lua_register_global_table :: proc(L: ^lua.State, table_name: string) {
	lua.newtable(L)
	lua.setglobal(L, cstring(raw_data(table_name)))
}

lua_register_method :: proc(
	L: ^lua.State,
	table_name: string,
	method_name: string,
	fn: lua.CFunction,
) {
	lua.getglobal(L, cstring(raw_data(table_name)))
	lua.pushcfunction(L, fn)
	lua.setfield(L, -2, cstring(raw_data(method_name)))
	lua.pop(L, 1)
}

// Object metatable for object methods
lua_register_object_metatable :: proc(L: ^lua.State) {
	lua.L_newmetatable(L, "CubeObject")

	lua.pushstring(L, "__index")
	lua.newtable(L)

	// Object methods
	lua.pushcfunction(L, lua_object_position)
	lua.setfield(L, -2, "position")

	lua.pushcfunction(L, lua_object_size)
	lua.setfield(L, -2, "size")

	lua.pushcfunction(L, lua_object_color)
	lua.setfield(L, -2, "color")

	lua.pushcfunction(L, lua_object_rotation)
	lua.setfield(L, -2, "rotate")

	lua.pushcfunction(L, lua_object_position)
	lua.setfield(L, -2, "move")

	lua.pushcfunction(L, lua_object_delete)
	lua.setfield(L, -2, "delete")

	lua.settable(L, -3)
	lua.pop(L, 1)
}

lua_run_file :: proc(filepath: string) -> bool {
	L := lua_state.L

	if lua.L_loadfile(L, cstring(raw_data(filepath))) != .OK {
		error := lua.tostring(L, -1)
		lua_state.script_error = fmt.tprintf("Load Error: %s", error)
		fmt.println(lua_state.script_error)
		lua.pop(L, 1)
		return false
	}

	if lua.pcall(L, 0, lua.MULTRET, 0) != 0 {
		error := lua.tostring(L, -1)
		lua_state.script_error = fmt.tprintf("Runtime error: %s", error)
		fmt.println(lua_state.script_error)
		lua.pop(L, 1)
		return false
	}

	return true
}

lua_run_string :: proc(code: string) -> bool {
	L := lua_state.L

	if lua.L_loadstring(L, cstring(raw_data(code))) != .OK {
		error := lua.tostring(L, -1)
		lua_state.script_error = fmt.tprintf("Syntax error: %s", error)
		fmt.println(lua_state.script_error)
		lua.pop(L, 1)
		return false
	}

	if lua.pcall(L, 0, lua.MULTRET, 0) != 0 {
		error := lua.tostring(L, -1)
		lua_state.script_error = fmt.tprintf("Runtime error: %s", error)
		fmt.println(lua_state.script_error)
		lua.pop(L, 1)
		return false
	}

	return true
}

lua_scene_add_cube :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()

	if !lua.istable(L, 1) {
		lua.pushstring(L, "Expected table argument")
		lua.error(L)
		return 0
	}

	pos := glsl.vec3{0, 0, 0}
	size := glsl.vec3{1, 1, 1}
	color := glsl.vec4{1, 1, 1, 1}

	lua.getfield(L, 1, "position")
	if lua.istable(L, -1) {
		lua.rawgeti(L, -1, 1); pos.x = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
		lua.rawgeti(L, -1, 2); pos.y = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
		lua.rawgeti(L, -1, 3); pos.z = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
	}
	lua.pop(L, 1)

	lua.getfield(L, 1, "size")
	if lua.istable(L, -1) {
		lua.rawgeti(L, -1, 1); size.x = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
		lua.rawgeti(L, -1, 2); size.y = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
		lua.rawgeti(L, -1, 3); size.z = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
	}
	lua.pop(L, 1)

	lua.getfield(L, 1, "color")
	if lua.istable(L, -1) {
		lua.rawgeti(L, -1, 1); color.r = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
		lua.rawgeti(L, -1, 2); color.g = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
		lua.rawgeti(L, -1, 3); color.b = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
	}
	lua.pop(L, 1)

	obj_idx := scene_add_cube(&scene, pos, size, color)

	lua.pushinteger(L, lua.Integer(obj_idx))

	return 1
}


lua_scene_add_quad :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()

	if !lua.istable(L, 1) {
		lua.pushstring(L, "Expected table argument")
		lua.error(L)
		return 0
	}

	pos := glsl.vec3{0, 0, 0}
	size := glsl.vec3{1, 1, 1}
	color := glsl.vec4{1, 1, 1, 1}

	lua.getfield(L, 1, "position")
	if lua.istable(L, -1) {
		lua.rawgeti(L, -1, 1); pos.x = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
		lua.rawgeti(L, -1, 2); pos.y = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
		lua.rawgeti(L, -1, 3); pos.z = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
	}
	lua.pop(L, 1)

	lua.getfield(L, 1, "size")
	if lua.istable(L, -1) {
		lua.rawgeti(L, -1, 1); size.x = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
		lua.rawgeti(L, -1, 2); size.y = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
		lua.rawgeti(L, -1, 3); size.z = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
	}
	lua.pop(L, 1)

	lua.getfield(L, 1, "color")
	if lua.istable(L, -1) {
		lua.rawgeti(L, -1, 1); color.r = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
		lua.rawgeti(L, -1, 2); color.g = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
		lua.rawgeti(L, -1, 3); color.b = f32(lua.tonumber(L, -1)); lua.pop(L, 1)
	}
	lua.pop(L, 1)

	obj_idx := scene_add_quad(&scene, pos, size, color)

	lua.pushinteger(L, lua.Integer(obj_idx))

	return 1
}


lua_scene_count :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()
	lua.pushinteger(L, lua.Integer(len(scene.objects)))
	return 1
}

lua_scene_clear :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()

	for i := len(scene.objects) - 1; i >= 0; i -= 1 {
		scene_delete_cube(&scene, i)
	}
	return 0
}

lua_scene_selected :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()

	lua.newtable(L)
	for idx, i in scene.selected_objects {
		lua.pushinteger(L, lua.Integer(idx))
		lua.pushinteger(L, lua.Integer(i))
		lua.settable(L, -3)
	}

	return 1
}

lua_scene_select_all :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()
	clear(&scene.selected_objects)
	for i in 0 ..< len(scene.objects) {
		append(&scene.selected_objects, i)
	}
	return 0
}

lua_scene_select_none :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()
	clear(&scene.selected_objects)
	return 0
}

lua_cube_new :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()

	obj_idx := scene_add_cube(&scene, {0, 0, 1}, {1, 1, 1}, {1, 1, 1, 1})

	ud := cast(^i32)lua.newuserdata(L, size_of(i32))
	ud^ = i32(obj_idx)

	lua.L_getmetatable(L, "CubeObject")
	lua.setmetatable(L, -2)

	return 1
}

lua_object_size :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()

	obj_idx := (cast(^i32)lua.touserdata(L, 1))^
	x := f32(lua.tonumber(L, 2))
	y := f32(lua.tonumber(L, 3))
	z := f32(lua.tonumber(L, 4))

	if obj_idx >= 0 && obj_idx < i32(len(scene.objects)) {
		scene.objects[obj_idx].position = {x, y, z}
	}

	return 0
}

lua_object_color :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()

	obj_idx := (cast(^i32)lua.touserdata(L, 1))^
	r := f32(lua.tonumber(L, 2))
	g := f32(lua.tonumber(L, 3))
	b := f32(lua.tonumber(L, 4))

	if obj_idx >= 0 && obj_idx < i32(len(scene.objects)) {
		scene.objects[obj_idx].color = {r, g, b, 1}
	}

	return 0
}

lua_object_position :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()

	obj_idx := (cast(^i32)lua.touserdata(L, 1))^
	dx := f32(lua.tonumber(L, 2))
	dy := f32(lua.tonumber(L, 3))
	dz := f32(lua.tonumber(L, 4))

	if obj_idx >= 0 && obj_idx < i32(len(scene.objects)) {
		scene.objects[obj_idx].position += {dx, dy, dz}
	}

	return 0
}

lua_object_rotation :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()

	obj_idx := (cast(^i32)lua.touserdata(L, 1))^
	rx := f32(lua.tonumber(L, 2))
	ry := f32(lua.tonumber(L, 3))
	rz := f32(lua.tonumber(L, 4))

	if obj_idx >= 0 && obj_idx < i32(len(scene.objects)) {
		scene.objects[obj_idx].rotation += {rx, ry, rz}
	}

	return 0
}

lua_object_delete :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()

	obj_idx := (cast(^i32)lua.touserdata(L, 1))^

	if obj_idx >= 0 && obj_idx < i32(len(scene.objects)) {
		scene_delete_selected(&scene)
	}

	return 0
}

import "core:math/rand"
lua_random_range :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()

	min := f32(lua.tonumber(L, 1))
	max := f32(lua.tonumber(L, 2))

	value := min + rand.float32() * (max - min)

	lua.pushnumber(L, lua.Number(value))

	return 1
}

lua_random_color :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()

	lua.newtable(L)
	lua.pushnumber(L, lua.Number(rand.float32())); lua.rawseti(L, -2, 1)
	lua.pushnumber(L, lua.Number(rand.float32())); lua.rawseti(L, -2, 2)
	lua.pushnumber(L, lua.Number(rand.float32())); lua.rawseti(L, -2, 3)

	return 1
}

lua_random_vector :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()

	min := f32(lua.tonumber(L, 1))
	max := f32(lua.tonumber(L, 2))

	lua.newtable(L)
	lua.pushnumber(L, lua.Number(min + rand.float32() * (max - min))); lua.rawseti(L, -2, 1)
	lua.pushnumber(L, lua.Number(min + rand.float32() * (max - min))); lua.rawseti(L, -2, 2)
	lua.pushnumber(L, lua.Number(min + rand.float32() * (max - min))); lua.rawseti(L, -2, 3)

	return 1
}

lua_vector_new :: proc "c" (L: ^lua.State) -> i32 {
	x := f32(lua.tonumber(L, 1))
	y := f32(lua.tonumber(L, 2))
	z := f32(lua.tonumber(L, 3))

	lua.newtable(L)
	lua.pushnumber(L, lua.Number(x)); lua.rawseti(L, -2, 1)
	lua.pushnumber(L, lua.Number(y)); lua.rawseti(L, -2, 2)
	lua.pushnumber(L, lua.Number(z)); lua.rawseti(L, -2, 3)

	return 1
}

lua_print :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()

	n := lua.gettop(L)
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	for i in 1 ..= n {
		if i > 1 do strings.write_string(&builder, "\t")

		if lua.isstring(L, i32(i)) != false {
			s := lua.tostring(L, i32(i))
			strings.write_string(&builder, string(s))
		} else {
			lua.getglobal(L, "tostring")
			lua.pushvalue(L, i32(i))
			lua.call(L, 1, 1)
			s := lua.tostring(L, -1)
			strings.write_string(&builder, string(s))
			lua.pop(L, 1)
		}
	}

	output := strings.to_string(builder)
	fmt.println("[Lua]", output)

	return 0
}
