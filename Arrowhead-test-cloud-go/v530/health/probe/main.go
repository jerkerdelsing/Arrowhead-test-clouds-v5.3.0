// SPDX-License-Identifier: EPL-2.0
// Container health probe for the scratch-based Go systems: succeeds when a TCP connection to the given address opens.
// The systems require mutual TLS on every request, so the probe checks the listener only, not the API.
package main

import (
	"net"
	"os"
	"time"
)

func main() {
	if len(os.Args) != 2 {
		os.Stderr.WriteString("usage: ah-probe host:port\n")
		os.Exit(2)
	}
	c, e := net.DialTimeout("tcp", os.Args[1], 3*time.Second)
	if e != nil {
		os.Stderr.WriteString(e.Error() + "\n")
		os.Exit(1)
	}
	_ = c.Close()
}
