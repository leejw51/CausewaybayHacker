// "missing return" is in no row of the §7.1 table. It must be stored as
// `other` with whatever identity Go gives it, never dropped.
package main

import "fmt"

func pick(flag bool) int {
	if flag {
		return 1
	}
}

func main() {
	fmt.Println(pick(true))
}
