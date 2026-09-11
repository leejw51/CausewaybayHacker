// "cannot use ... as ... value" — Go's E0308.
package main

import "fmt"

func main() {
	var n int = "42"
	fmt.Println(n)
}
