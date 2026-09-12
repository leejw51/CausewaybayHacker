# Runs, then dies: a real object, but not one that has the attribute asked
# for — the duck does not quack. Distinct from the None case: this object
# exists, it just is not the shape the caller assumed.
class Stall:
    def __init__(self, name):
        self.name = name


s = Stall("tofu")
print(s.price)
