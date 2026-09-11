// Compiles. The runtime detects it: all goroutines are asleep - deadlock!
package main

import "fmt"

func main() {
	ch := make(chan int)
	fmt.Println(<-ch)
}
