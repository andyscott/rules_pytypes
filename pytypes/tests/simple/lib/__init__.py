from dataclasses import dataclass
@dataclass(frozen=True)
class Lib:
    def some_method(self):
        print("Lib::some_method")
