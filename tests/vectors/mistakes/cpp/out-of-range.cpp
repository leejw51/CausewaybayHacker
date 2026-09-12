// Compiles. `at()` is the one indexing that checks, and it throws
// std::out_of_range; uncaught, the runtime prints the exception's type and
// aborts. (`v[5]` would be undefined behaviour and might print anything.)
#include <iostream>
#include <vector>

int main() {
    std::vector<int> stalls{3, 1, 4};
    std::cout << stalls.at(5) << "\n";
}
