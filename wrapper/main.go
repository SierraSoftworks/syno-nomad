// Command nomad-root launches the Nomad agent as *real* root.
//
// DSM 7 refuses to install a package that runs as root and launches the
// package service as an unprivileged user, so the package makes this small
// helper setuid-root. When Nomad is started through it, the helper raises its
// real/effective/saved uid to 0 and exec's Nomad, giving Nomad true root.
//
// Real root, rather than effective-only root (a setuid Nomad binary with euid=0
// but ruid!=0), avoids the effective-vs-real-uid pitfalls that some privileged
// operations hit — giving the Docker and exec drivers a clean root environment.
//
// Security notes:
//   - It only ever execs the hardcoded Nomad binary, never arbitrary commands.
//   - It strips LD_* from the environment so a caller cannot inject code into
//     the now-root, dynamically-linked Nomad via LD_PRELOAD / LD_LIBRARY_PATH.
//   - The package restricts execute permission to root and the package group
//     (mode 4750), so only the Nomad service account can invoke it.
//
// When the helper is not setuid (privileged mode not enabled), the uid changes
// fail harmlessly and Nomad is exec'd unprivileged — the same degraded mode as
// before opting in.
package main

import (
	"os"
	"strings"
	"syscall"
)

const nomadBin = "/var/packages/nomad/target/bin/nomad"

func main() {
	// Best-effort elevation to real root. These succeed only when this binary
	// is setuid-root (euid already 0); otherwise Nomad runs unprivileged.
	_ = syscall.Setgroups([]int{0})
	_ = syscall.Setgid(0)
	_ = syscall.Setuid(0)

	// Drop dynamic-linker variables before exec'ing the (dynamically linked)
	// Nomad binary now that it may run as root.
	env := os.Environ()
	clean := env[:0]
	for _, kv := range env {
		if strings.HasPrefix(kv, "LD_") {
			continue
		}
		clean = append(clean, kv)
	}

	argv := append([]string{nomadBin}, os.Args[1:]...)
	if err := syscall.Exec(nomadBin, argv, clean); err != nil {
		os.Stderr.WriteString("nomad-root: failed to exec " + nomadBin + ": " + err.Error() + "\n")
		os.Exit(73)
	}
}
