-- Recursion with no base case worth the name.
local function depth(n)
  return 1 + depth(n + 1)
end
print(depth(0))
