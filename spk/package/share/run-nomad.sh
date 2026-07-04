#!/bin/sh
# Launcher for the Nomad agent, backgrounded by scripts/start-stop-status.
#
# It waits for the advertise interface to obtain an IPv4 address (e.g.
# tailscale0 after tailscaled connects — the address the config's advertise
# template resolves), then exec's Nomad so the PID start-stop-status recorded
# becomes Nomad's own. Nomad's stdout/stderr are captured to console.log
# because DSM's journald is volatile.
set -eu

PKG_ROOT="/var/packages/nomad"
ETC="${PKG_ROOT}/etc"
NOMAD="${PKG_ROOT}/target/bin/nomad"
CONSOLE="${PKG_ROOT}/var/logs/console.log"

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

echo "$(date '+%F %T'): launching nomad agent" >> "$CONSOLE" 2>/dev/null || true
exec "$NOMAD" agent \
    -config "${ETC}/nomad.hcl" \
    -config "${ETC}/conf.d" \
    >> "$CONSOLE" 2>&1
