package main

import "core:math"
import "core:math/linalg/glsl"

// cube := [?]f32{
// // Positions          // Colors
// -0.5, -0.5, -0.5,  1.0, 0.0, 0.0,
//  0.5, -0.5, -0.5,  1.0, 0.0, 0.0,
//  0.5,  0.5, -0.5,  1.0, 0.0, 0.0,
//  0.5,  0.5, -0.5,  1.0, 0.0, 0.0,
// -0.5,  0.5, -0.5,  1.0, 0.0, 0.0,
// -0.5, -0.5, -0.5,  1.0, 0.0, 0.0,

// -0.5, -0.5,  0.5,  0.0, 1.0, 0.0,
//  0.5, -0.5,  0.5,  0.0, 1.0, 0.0,
//  0.5,  0.5,  0.5,  0.0, 1.0, 0.0,
//  0.5,  0.5,  0.5,  0.0, 1.0, 0.0,
// -0.5,  0.5,  0.5,  0.0, 1.0, 0.0,
// -0.5, -0.5,  0.5,  0.0, 1.0, 0.0,

// -0.5,  0.5,  0.5,  0.0, 0.0, 1.0,
// -0.5,  0.5, -0.5,  0.0, 0.0, 1.0,
// -0.5, -0.5, -0.5,  0.0, 0.0, 1.0,
// -0.5, -0.5, -0.5,  0.0, 0.0, 1.0,
// -0.5, -0.5,  0.5,  0.0, 0.0, 1.0,
// -0.5,  0.5,  0.5,  0.0, 0.0, 1.0,

//  0.5,  0.5,  0.5,  1.0, 1.0, 0.0,
//  0.5,  0.5, -0.5,  1.0, 1.0, 0.0,
//  0.5, -0.5, -0.5,  1.0, 1.0, 0.0,
//  0.5, -0.5, -0.5,  1.0, 1.0, 0.0,
//  0.5, -0.5,  0.5,  1.0, 1.0, 0.0,
//  0.5,  0.5,  0.5,  1.0, 1.0, 0.0,

// -0.5, -0.5, -0.5,  0.0, 1.0, 1.0,
//  0.5, -0.5, -0.5,  0.0, 1.0, 1.0,
//  0.5, -0.5,  0.5,  0.0, 1.0, 1.0,
//  0.5, -0.5,  0.5,  0.0, 1.0, 1.0,
// -0.5, -0.5,  0.5,  0.0, 1.0, 1.0,
// -0.5, -0.5, -0.5,  0.0, 1.0, 1.0,

// -0.5,  0.5, -0.5,  1.0, 0.0, 1.0,
//  0.5,  0.5, -0.5,  1.0, 0.0, 1.0,
//  0.5,  0.5,  0.5,  1.0, 0.0, 1.0,
//  0.5,  0.5,  0.5,  1.0, 0.0, 1.0,
// -0.5,  0.5,  0.5,  1.0, 0.0, 1.0,
// -0.5,  0.5, -0.5,  1.0, 0.0, 1.0,
// }

// REFERENCE: https://www.scratchapixel.com/lessons/3d-basic-rendering/minimal-ray-tracer-rendering-simple-shapes/ray-box-intersection.html
// Simplified AABB ray intersection for gizmos
test_ray_cube :: proc(ray_origin, ray_dir: glsl.vec3, cube_min, cube_max: glsl.vec3) -> bool {
	tmin := (cube_min.x - ray_origin.x) / ray_dir.x
	tmax := (cube_max.x - ray_origin.x) / ray_dir.x
	if tmin > tmax do tmin, tmax = tmax, tmin

	tymin := (cube_min.y - ray_origin.y) / ray_dir.y
	tymax := (cube_max.y - ray_origin.y) / ray_dir.y
	if tymin > tymax do tymin, tymax = tymax, tymin

	if (tmin > tymax) || (tymin > tmax) do return false
	if tymin > tmin do tmin = tymin
	if tymax > tmax do tmax = tymax

	tzmin := (cube_min.z - ray_origin.z) / ray_dir.z
	tzmax := (cube_max.z - ray_origin.z) / ray_dir.z
	if tzmin > tzmax do tzmin, tzmax = tzmax, tzmin

	if (tmin > tzmax) || (tzmin > tmax) do return false
	return true
}
