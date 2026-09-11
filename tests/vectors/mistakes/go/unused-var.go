// "declared and not used" — in Go this is an ERROR, not a warning.
package main

import "fmt"

func main() {
	leftover := 7
	fmt.Println("hello, causewaybay")
}
