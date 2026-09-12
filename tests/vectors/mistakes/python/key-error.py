# Runs, then dies: the key is not in the dict, and `[]` (unlike `.get`)
# says so by raising.
board = {"tofu": 12, "egg": 8}
print(board["choy sum"])
