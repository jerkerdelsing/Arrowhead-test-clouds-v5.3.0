// SPDX-License-Identifier: EPL-2.0
// Deployment launcher of the Go test cloud v5.3.0 for the primary LocalCloudManager-go (scratch image), 2026-11-11.
// The program is unchanged; this launcher only adapts its environment contract to the cloud's controls:
//
//   - J7, secrets only as files: for every NAME in SECRET_ENV it reads NAME_FILE and passes the value as NAME to the
//     child. LocalCloudManager-go reads AUTHENTICATION_PASSWORD and CONSOLE_PASSWORD_HASH from its environment only;
//     the values therefore never appear in the container's configuration (docker inspect), only in the child process.
//   - H1, the Docker socket only in the whitelisting docker-proxy: LocalCloudManager-go speaks HTTP over a Unix socket
//     (DOCKER_SOCKET). With DOCKER_PROXY_ADDR set, the launcher listens on DOCKER_SOCKET (tmpfs) and forwards each
//     connection to that TCP address, so every Docker call passes the proxy's allowlist.
//
// The child is /usr/local/bin/LocalCloudManager; SIGTERM and SIGINT are passed on, and the launcher exits with its code.
package main

import (
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func main() {
	env := os.Environ()
	for _, name := range strings.Split(os.Getenv("SECRET_ENV"), ",") {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		path := os.Getenv(name + "_FILE")
		if path == "" {
			log.Fatalf("launcher: %s_FILE is not set", name)
		}
		value, err := os.ReadFile(path)
		if err != nil {
			log.Fatalf("launcher: %s_FILE: %v", name, err)
		}
		env = append(env, name+"="+strings.TrimRight(string(value), "\r\n"))
	}
	if addr := os.Getenv("DOCKER_PROXY_ADDR"); addr != "" {
		socket := os.Getenv("DOCKER_SOCKET")
		if socket == "" {
			log.Fatal("launcher: DOCKER_PROXY_ADDR needs DOCKER_SOCKET")
		}
		_ = os.Remove(socket)
		ln, err := net.Listen("unix", socket)
		if err != nil {
			log.Fatalf("launcher: %v", err)
		}
		go forward(ln, addr)
	}
	cmd := exec.Command("/usr/local/bin/LocalCloudManager", os.Args[1:]...)
	cmd.Env, cmd.Stdin, cmd.Stdout, cmd.Stderr = env, nil, os.Stdout, os.Stderr
	if err := cmd.Start(); err != nil {
		log.Fatalf("launcher: %v", err)
	}
	signals := make(chan os.Signal, 2)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		for s := range signals {
			_ = cmd.Process.Signal(s)
		}
	}()
	err := cmd.Wait()
	if exit, ok := err.(*exec.ExitError); ok {
		os.Exit(exit.ExitCode())
	} else if err != nil {
		log.Fatalf("launcher: %v", err)
	}
}

func forward(ln net.Listener, addr string) {
	for {
		local, err := ln.Accept()
		if err != nil {
			log.Printf("launcher: docker socket: %v", err)
			return
		}
		go func() {
			defer local.Close()
			remote, err := net.DialTimeout("tcp", addr, 5*time.Second)
			if err != nil {
				log.Printf("launcher: docker proxy: %v", err)
				return
			}
			defer remote.Close()
			done := make(chan struct{}, 2)
			go func() { _, _ = io.Copy(remote, local); _ = remote.(*net.TCPConn).CloseWrite(); done <- struct{}{} }()
			go func() { _, _ = io.Copy(local, remote); done <- struct{}{} }()
			<-done
			<-done
		}()
	}
}
