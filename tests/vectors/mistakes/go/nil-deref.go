// Compiles. Panics at run time: nil pointer dereference.
package main

import "fmt"

type Node struct {
	Value int
}

func main() {
	var n *Node
	fmt.Println(n.Value)
}
