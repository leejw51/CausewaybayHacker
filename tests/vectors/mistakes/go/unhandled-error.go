// The error from Open is thrown away. `go build` is perfectly happy; only a
// checker notices. See expected.json for which one, and whether it ships.
package main

import (
	"fmt"
	"os"
)

func main() {
	f, _ := os.Open("nope.txt")
	fmt.Println(f)
}
