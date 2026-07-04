#!/bin/sh
# Opt-in privilege escalation for Nomad on DSM 7.2+.
#
# DSM refuses to install a sideloaded (unsigned) package that requests root or
# Linux capabilities, and it launches the package's service as an unprivileged
# package user. In that state the Docker and isolated exec task drivers cannot
# perform the privileged work they need.
#
# Running this script AS ROOT makes the Nomad binary setuid-root, so the agent
# runs with full privileges and every task driver works. The package volume is
# not mounted "nosuid", and the setuid bit survives reboots; it only needs
# reapplying after a package upgrade replaces the binary.
#
# The intended way to opt in is a Task Scheduler boot-up task:
#   Control Panel -> Task Scheduler -> Create -> Triggered Task -> Boot-up
#   User: root
#   Command: /var/packages/nomad/target/share/enable-privileges.sh
# Run that task once now (Task Scheduler -> select task -> Run) to enable it
# immediately; it also re-runs on every boot (which re-applies it after an
# upgrade).
#
# Usage (as root):
#   enable-privileges.sh enable     grant privileges and restart Nomad
#   enable-privileges.sh disable    revoke privileges and restart Nomad
#   enable-privileges.sh reapply    re-grant if previously enabled (no restart)
#   enable-privileges.sh status     show the current state
set -eu

# The package target is a symlink onto a volume that synopkg restart may swap
# out from under us; run from a stable directory to avoid getcwd errors.
cd / 2> /dev/null || true

PKG_ROOT="/var/packages/nomad"
BINARY="${PKG_ROOT}/target/bin/nomad"
CLI_LINK="/usr/local/bin/nomad"
MARKER="${PKG_ROOT}/etc/.privileged-mode"

require_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "This must be run as root (e.g. from a root Task Scheduler task)." >&2
        exit 1
    fi
}

apply() {
    chown root:root "$BINARY"
    chmod u+s "$BINARY"
    # We are root here, so also provide the CLI on PATH (postinst, running as
    # the package user, cannot create this).
    ln -sf "$BINARY" "$CLI_LINK" 2> /dev/null || true
}

restart() {
    if command -v synopkg > /dev/null 2>&1; then
        synopkg restart nomad > /dev/null 2>&1 || true
    fi
}

case "${1:-enable}" in
    enable)
        require_root
        apply
        : > "$MARKER"
        restart
        echo "Privileged mode enabled: ${BINARY} is now setuid-root."
        echo "Nomad has been restarted; check '${CLI_LINK} node status -self' for driver health."
        ;;
    disable)
        require_root
        chmod u-s "$BINARY" 2> /dev/null || true
        rm -f "$MARKER"
        restart
        echo "Privileged mode disabled: Nomad now runs as the unprivileged package user."
        ;;
    reapply)
        # Invoked by postinst/postupgrade. Re-grant only if run as root and the
        # user previously opted in; an upgrade replaces the binary and resets it.
        [ "$(id -u)" = "0" ] || exit 0
        [ -f "$MARKER" ] || exit 0
        apply || exit 0
        ;;
    status)
        if [ -f "$MARKER" ]; then
            echo "opt-in:  enabled"
        else
            echo "opt-in:  disabled"
        fi
        if [ -u "$BINARY" ]; then
            echo "binary:  setuid-root (privileged)"
        else
            echo "binary:  unprivileged"
        fi
        ls -l "$BINARY"
        ;;
    *)
        echo "usage: $0 {enable|disable|reapply|status}" >&2
        exit 1
        ;;
esac
