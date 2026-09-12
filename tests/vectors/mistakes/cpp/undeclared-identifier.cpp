// A name that was never declared: `total` is spelled `totl` at the one place
// it is written. clang says "use of undeclared identifier", gcc says "was
// not declared in this scope" — the same mistake, two prose shapes.
#include <iostream>

int main() {
    int total = 0;
    for (int i = 1; i <= 4; ++i) {
        totl += i;
    }
    std::cout << total << "\n";
}
