// The argument has the wrong type. Overload resolution finds nothing that
// takes a string literal, and both compilers report it the same way:
// "no matching function for call to 'add'".
#include <iostream>

int add(int a, int b) { return a + b; }

int main() {
    std::cout << add("one", 2) << "\n";
}
