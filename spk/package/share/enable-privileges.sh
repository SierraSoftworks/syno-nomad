#!/bin/sh
# Opt-in privilege escalation for Nomad on DSM 7.2+.
#
# DSM refuses to install a sideloaded (unsigned) package that requests root or
# Linux capabilities, and it launches the package's service as an unprivileged
# package user. In that state the Docker and isolated exec task drivers, and
# bridge networking, cannot do the privileged work they need.
#
# Running this script AS ROOT installs a setuid-root copy of the nomad-root
# launcher into the package's persistent var/ directory. The service then
# starts Nomad as real root (real, not just effective, so the Docker and exec
# drivers get a clean root environment without effective-vs-real-uid pitfalls).
#
# The launcher lives in var/ (@appdata) rather than target/ (@appstore) on
# purpose: package upgrades replace target/ and would clear a setuid bit there,
# but var/ is preserved — so privileged mode survives upgrades with no action.
# The launcher is stable (it only ever setuid()s and exec's Nomad), so a copy
# made once keeps working across Nomad versions; it is refreshed on reboot.
#
# The intended way to opt in is a Task Scheduler boot-up task:
#   Control Panel -> Task Scheduler -> Create -> Triggered Task -> Boot-up
#   User: root
#   Command: /var/packages/nomad/target/share/enable-privileges.sh
# Run that task once now (Task Scheduler -> select task -> Run) to enable it.
#
# Usage (as root):
#   enable-privileges.sh enable     grant privileges and restart Nomad
#   enable-privileges.sh disable    revoke privileges and restart Nomad
#   enable-privileges.sh reapply    re-grant if previously enabled (as needed)
#   enable-privileges.sh status     show the current state
set -eu

# The package target is a symlink onto a volume that synopkg restart may swap
# out from under us; run from a stable directory to avoid getcwd errors.
cd / 2> /dev/null || true

PKG_ROOT="/var/packages/nomad"
BUNDLED="${PKG_ROOT}/target/libexec/nomad-root"     # shipped, replaced on upgrade
LAUNCHER="${PKG_ROOT}/var/nomad-root"               # persistent, setuid, survives upgrades
NOMAD_BIN="${PKG_ROOT}/target/bin/nomad"
CLI_LINK="/usr/local/bin/nomad"
PKG_GROUP="nomad"
MARKER="${PKG_ROOT}/etc/.privileged-mode"

require_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "This must be run as root (e.g. from a root Task Scheduler task)." >&2
        exit 1
    fi
}

# Install/refresh the persistent setuid launcher. Uses a temp file + rename so
# a currently-running launcher (busy inode) isn't overwritten in place.
apply() {
    tmp="${LAUNCHER}.new.$$"
    cp -f "$BUNDLED" "$tmp"
    if chown "root:${PKG_GROUP}" "$tmp" 2> /dev/null; then
        chmod 4750 "$tmp"   # setuid-root, executable only by root + package group
    else
        chown root:root "$tmp" 2> /dev/null || true
        chmod 4755 "$tmp"
    fi
    mv -f "$tmp" "$LAUNCHER"
    ln -sf "$NOMAD_BIN" "$CLI_LINK" 2> /dev/null || true
}

# True if the persistent launcher is missing, not setuid, or stale relative to
# the version shipped in the (possibly just-upgraded) package.
needs_apply() {
    [ ! -u "$LAUNCHER" ] || ! cmp -s "$BUNDLED" "$LAUNCHER"
}

restart() {
    if command -v synopkg > /dev/null 2>&1; then
        synopkg restart nomad > /dev/null 2>&1 || true
    fi
}

# Bring the launcher up to date and restart Nomad only if something changed —
# so the boot task is a cheap no-op on a normal boot.
ensure() {
    if needs_apply; then
        apply
        restart
    fi
}

case "${1:-enable}" in
    enable)
        require_root
        : > "$MARKER"
        ensure
        echo "Privileged mode enabled: ${LAUNCHER} is setuid-root and persists across upgrades."
        echo "Nomad runs as root; check '${CLI_LINK} node status -self'."
        ;;
    disable)
        require_root
        rm -f "$LAUNCHER" "$MARKER"
        restart
        echo "Privileged mode disabled: Nomad now runs as the unprivileged package user."
        ;;
    reapply)
        # Called by postinst/postupgrade. A no-op unless run as root and the
        # user previously opted in. Because the launcher lives in var/ it
        # normally survives upgrades untouched, so this rarely does anything.
        [ "$(id -u)" = "0" ] || exit 0
        [ -f "$MARKER" ] || exit 0
        ensure
        ;;
    status)
        if [ -f "$MARKER" ]; then
            echo "opt-in:   enabled"
        else
            echo "opt-in:   disabled"
        fi
        if [ -u "$LAUNCHER" ]; then
            echo "launcher: setuid-root at ${LAUNCHER} (privileged, persistent)"
            ls -l "$LAUNCHER"
        else
            echo "launcher: unprivileged — Nomad runs as the package user"
        fi
        ;;
    *)
        echo "usage: $0 {enable|disable|reapply|status}" >&2
        exit 1
        ;;
esac
