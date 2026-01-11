Scene.clear()

local grid_size = 5
local cubes = {}

for x = -grid_size, grid_size do

for z = -grid_size, grid_size do
  local c = Cube.new()

  c:move(x * 1.5, z * 1.5)

  local dist = math.sqrt(x*x + z*z)
  c:color(dist/grid_size, 0.3, 1.0 - (dist/grid_size))

  table.insert(cubes, c)
end

end
