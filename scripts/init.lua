Scene.clear()

local grid_size = 5
local cubes = {}

Scene.addQuad({
  position = {0, 0, 0},
  size = {1, 1, 1},
  color = {0, 1, 0},
})

for x = -grid_size, grid_size do

for z = -grid_size, grid_size do
  local c = Cube.new()

  c:move(x * 1.5, z * 1.5)

  local dist = math.sqrt(x*x + z*z)
  c:color(dist/grid_size, 0.3, 1.0 - (dist/grid_size))

  table.insert(cubes, c)
end

end
