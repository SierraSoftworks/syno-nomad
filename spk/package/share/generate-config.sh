#!/bin/sh
# Renders the initial Nomad configuration from the Synology install wizard's
# answers. DSM exports the wizard_* variables into the environment when this
# runs from postinst; every variable has a safe default so the script also
# works standalone (e.g. to regenerate a deleted config over SSH).
#
# Usage: generate-config.sh <etc-dir>
#
# Writes:
#   <etc-dir>/nomad.hcl          the agent configuration
#   <etc-dir>/listen-interface   interface name the start script should wait
#                                for before launching Nomad (may be empty)
set -eu

ETC="${1:?usage: generate-config.sh <etc-dir>}"

REGION="${wizard_region:-global}"
DATACENTER="${wizard_datacenter:-dc1}"
CLIENT_ONLY="${wizard_topology_client:-false}"
JOIN_ADDRESSES="${wizard_join_addresses:-}"

# /var/packages/nomad/var is a symlink onto the storage volume. Nomad's
# alloc-directory security check rejects task log / filesystem access with
# "Path escapes the alloc directory" when data_dir traverses a symlink, so
# resolve it to the real path (e.g. /volume1/@appdata/nomad/data).
VAR_REAL="$(readlink -f /var/packages/nomad/var 2>/dev/null || echo /var/packages/nomad/var)"
DATA_DIR="${VAR_REAL}/data"

# Optional base directory for dynamic host volumes (the built-in "mkdir"
# plugin). Trim surrounding whitespace and require an absolute path.
HOST_VOLUMES_DIR="$(printf '%s' "${wizard_host_volumes_dir:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
if [ -n "$HOST_VOLUMES_DIR" ]; then
    case "$HOST_VOLUMES_DIR" in
        /*) ;;
        *)
            echo "The dynamic host volumes directory must be an absolute path (e.g. /volume1/nomad/host-volumes)." >&2
            exit 1
            ;;
    esac
fi

# Resolve the advertise address: a literal IP for the custom option, or a
# go-sockaddr template that resolves the chosen interface's IP at startup.
IFACE=""
if [ "${wizard_iface_custom:-false}" = "true" ]; then
    ADVERTISE="${wizard_custom_ip:?a custom IP address was selected but none was provided}"
elif [ "${wizard_iface_tailscale:-false}" = "true" ]; then
    IFACE="tailscale0"
elif [ "${wizard_iface_eth1:-false}" = "true" ]; then
    IFACE="eth1"
elif [ "${wizard_iface_eth2:-false}" = "true" ]; then
    IFACE="eth2"
else
    IFACE="eth0"
fi
if [ -n "$IFACE" ]; then
    ADVERTISE="{{ GetInterfaceIP \\\"${IFACE}\\\" }}"
fi

# Turn "a, b,c" into: "a", "b", "c"
JOIN_LIST=""
OLDIFS="$IFS"
IFS=','
for addr in $JOIN_ADDRESSES; do
    addr="$(echo "$addr" | tr -d '[:space:]')"
    [ -n "$addr" ] || continue
    JOIN_LIST="${JOIN_LIST}${JOIN_LIST:+, }\"${addr}\""
done
IFS="$OLDIFS"

if [ "$CLIENT_ONLY" = "true" ] && [ -z "$JOIN_LIST" ]; then
    echo "Client-only mode requires at least one server address to join." >&2
    exit 1
fi

mkdir -p "$ETC/conf.d"
echo "$IFACE" > "$ETC/listen-interface"

{
    cat <<EOF
# Nomad agent configuration — generated once by the Synology package installer.
# This file is yours: edit it freely, then restart Nomad from Package Center.
# Package upgrades never overwrite it.
#
# Additional configuration can be dropped into conf.d/*.hcl, which is loaded
# after this file and can override any setting here.
# Reference: https://developer.hashicorp.com/nomad/docs/configuration

region     = "${REGION}"
datacenter = "${DATACENTER}"
data_dir   = "${DATA_DIR}"

# Send logs to syslog (DSM's Log Center / the system log) rather than a file.
# Nomad still writes to stderr, which the package captures to
# var/logs/console.log for quick inspection.
enable_syslog   = true
syslog_facility = "LOCAL0"

# Listen on all interfaces, but advertise a single address to the cluster.
# The advertise address may be a literal IP or a go-sockaddr template that is
# resolved when the agent starts.
bind_addr = "0.0.0.0"

advertise {
  http = "${ADVERTISE}"
  rpc  = "${ADVERTISE}"
  serf = "${ADVERTISE}"
}

EOF

    if [ "$CLIENT_ONLY" != "true" ]; then
        cat <<EOF
server {
  enabled = true

  # The number of servers expected in the cluster. Leave at 1 for a
  # standalone node; set it to the full server count (e.g. 3) if you add
  # more servers, and list their addresses under retry_join below.
  bootstrap_expect = 1
EOF
        if [ -n "$JOIN_LIST" ]; then
            cat <<EOF

  server_join {
    retry_join = [${JOIN_LIST}]
  }
EOF
        fi
        cat <<EOF
}

EOF
    fi

    cat <<EOF
client {
  enabled    = true
  node_class = "synology"
EOF
    if [ "$CLIENT_ONLY" = "true" ]; then
        cat <<EOF

  server_join {
    retry_join = [${JOIN_LIST}]
  }
EOF
    fi
    if [ -n "$HOST_VOLUMES_DIR" ]; then
        cat <<EOF

  # Dynamic host volumes: Nomad's built-in "mkdir" plugin creates on-demand
  # volumes as subdirectories under this path. Create one with
  #   nomad volume create <spec>   (spec sets plugin_id = "mkdir")
  # and mount it in a job's volume/volume_mount blocks. Creating volumes on a
  # Synology volume outside the package data directory needs privileged mode
  # (see the README) so Nomad can write here as root.
  host_volumes_dir = "${HOST_VOLUMES_DIR}"
EOF
    fi
    cat <<'EOF'
}

# The Docker and isolated exec ("exec") task drivers both need privileges DSM
# does not grant a sideloaded package. Enable "privileged mode" once (see the
# README: a root Task Scheduler boot task running enable-privileges.sh makes
# the Nomad binary setuid-root) and both drivers below start working. Until
# then Nomad runs as the unprivileged package user and fingerprints them as
# unavailable — the agent still runs, it just cannot place those workloads.

# Requires the "Container Manager" package from Package Center for the Docker
# daemon and its socket at /var/run/docker.sock.
plugin "docker" {
  config {
    allow_privileged = false

    # Allow jobs to bind-mount host paths (e.g. shared folders) into tasks.
    volumes {
      enabled = true
    }
  }
}
#
# The raw_exec driver (no isolation) is disabled by default. To enable it,
# create conf.d/raw-exec.hcl containing:
#
#   plugin "raw_exec" {
#     config {
#       enabled = true
#     }
#   }
EOF
} > "$ETC/nomad.hcl"

# Progress goes to stdout, which the caller redirects to the package install
# log — never to the DSM installer log, whose last line becomes the error text.
echo "Wrote ${ETC}/nomad.hcl (advertise: ${ADVERTISE})"
