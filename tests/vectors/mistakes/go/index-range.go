// Compiles. Panics at run time: index out of range.
package main

import (
	"fmt"
	"strconv"
)

func main() {
	v := []int{1, 2, 3}
	i, _ := strconv.Atoi("5")
	fmt.Println(v[i])
}
