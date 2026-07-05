#!/bin/sh
# Launcher for the Nomad agent, backgrounded by scripts/start-stop-status.
#
# It waits for the advertise interface to obtain an IPv4 address (e.g.
# tailscale0 after tailscaled connects — the address the config's advertise
# template resolves), then exec's Nomad so the PID start-stop-status recorded
# becomes Nomad's own. Nomad's stdout/stderr are captured to console.log
# because DSM's journald is volatile.
#
# Nomad is launched through the nomad-root helper: when privileged mode is
# enabled that helper is setuid-root and raises Nomad to real root (needed by
# the Docker and exec drivers); otherwise it transparently execs Nomad
# unprivileged.
set -eu

PKG_ROOT="/var/packages/nomad"
ETC="${PKG_ROOT}/etc"
CONSOLE="${PKG_ROOT}/var/logs/console.log"

# Prefer the persistent setuid launcher installed by enable-privileges.sh
# (privileged mode, survives upgrades); otherwise use the bundled one, which
# runs Nomad unprivileged.
LAUNCHER="${PKG_ROOT}/var/nomad-root"
[ -u "$LAUNCHER" ] || LAUNCHER="${PKG_ROOT}/target/libexec/nomad-root"

iface="$(cat "${ETC}/listen-interface" 2> /dev/null || true)"
if [ -n "$iface" ]; then
    i=0
    while [ "$i" -lt 60 ]; do
        if ip -4 addr show "$iface" 2> /dev/null | grep -q "inet "; then
            break
        fi
        i=$((i + 1))
        sleep 1
    done
fi

# Truncate on each launch: Nomad's durable logs go to syslog, so console.log
# only needs to hold the current run's stderr.
echo "$(date '+%F %T'): launching nomad agent" > "$CONSOLE" 2>/dev/null || true
exec "$LAUNCHER" agent \
    -config "${ETC}/nomad.hcl" \
    -config "${ETC}/conf.d" \
    >> "$CONSOLE" 2>&1
