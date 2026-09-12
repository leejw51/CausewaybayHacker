// Writing through const. clang: "cannot assign to variable 'hits' with
// const-qualified type"; gcc: "assignment of read-only variable 'hits'".
#include <iostream>

int main() {
    const int hits = 0;
    hits = hits + 1;
    std::cout << hits << "\n";
}
