// Two goroutines write one int with no synchronisation. `go run` usually
// prints a number; `go run -race` reports WARNING: DATA RACE.
package main

import (
	"fmt"
	"sync"
)

func main() {
	total := 0
	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			total++
		}()
	}
	wg.Wait()
	fmt.Println(total)
}
