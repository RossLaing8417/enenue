local M = {}

M.log = function(...)
	print("[enu] -", ...)
end

package.path = package.path .. ";./runtime/lua/?.lua;./runtime/lua/?/init.lua"

print(package.path)

require("stoof")

return M
