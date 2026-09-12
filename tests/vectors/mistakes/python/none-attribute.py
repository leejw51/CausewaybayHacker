# Runs, then dies: the stall is not on the board, the lookup says None, and
# the next line asks None for its price. The market's boss, in four lines.
class Stall:
    def __init__(self, price):
        self.price = price


board = {"tofu": Stall(12)}
stall = board.get("choy sum")
print(stall.price)
