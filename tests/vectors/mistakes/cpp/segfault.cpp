// Compiles. Dies at run time with SIGSEGV: a write through a null pointer.
//
// The pointer is loaded through `volatile` so the optimiser cannot see that
// it is null: at -O2 a store through a pointer the compiler *knows* is null
// is undefined behaviour it is free to fold away or turn into a trap
// instruction, and a trap is SIGILL or SIGTRAP, not the segfault this
// fixture exists for. The load is real, the store goes to address 0.
#include <iostream>

struct Node {
    int value;
};

int main() {
    Node* volatile slot = nullptr;
    Node* node = slot;
    node->value = 42;
    std::cout << node->value << "\n";
}
