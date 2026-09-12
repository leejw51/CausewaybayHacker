# Runs, then dies: a recursion with no base case, stopped by the interpreter
# at its default depth of 1000 — the hacker land's last boss.
def depth(n):
    return 1 + depth(n + 1)


print(depth(0))
