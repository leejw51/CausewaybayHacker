// A parse error: the semicolon after the first statement never arrives.
#include <iostream>

int main() {
    int hits = 3
    std::cout << hits << "\n";
}
