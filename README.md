# Nomad for Synology DSM

A Synology package (SPK) that runs a [HashiCorp Nomad](https://developer.hashicorp.com/nomad)
agent on your NAS, with support for running workloads via the **Docker** and
**isolated fork/exec** task drivers, and first-class support for cluster
peering over **Tailscale**.

New releases are published automatically whenever HashiCorp ships a new
stable Nomad version — the package version always matches the Nomad version
it contains.

## Requirements

- DSM **7.2 or later**
- An `x86_64` NAS (e.g. DS923+, DS920+, and most plus-series models) or an
  `aarch64` (ARM) model
- For the Docker driver: the **Container Manager** package from Package Center
- For Tailscale peering: the [Tailscale package](https://pkgs.tailscale.com/stable/#spks)
  running on your NAS

## Installation

1. Download the `.spk` for your architecture from the
   [latest release](https://github.com/SierraSoftworks/syno-nomad/releases/latest)
   (`x86_64` or `aarch64`; verify against the release's `SHA256SUMS` if you like).
2. In DSM, open **Package Center → Manual Install** and select the file.
   DSM will warn that the package is from a third-party publisher and that it
   requires root — both are expected.
3. Complete the install wizard:
   - **Topology** — *Server + client* runs a standalone single-node cluster
     that other nodes can join. *Client only* attaches the NAS to an existing
     cluster and requires at least one server address.
   - **Region** — the Nomad region for this node (default `global`);
     federating servers must share a region.
   - **Datacenter** — the Nomad datacenter name for this node (default `dc1`).
   - **Servers to join** — comma-separated addresses; required for
     client-only mode.
   - **Advertise address** — the interface whose IP is advertised to the
     cluster: `eth0`–`eth2`, `tailscale0` for Tailscale peering, or a custom
     IP address.
4. Once started, the Nomad UI is available at `http://<nas-address>:4646`
   (Package Center's *Open* button takes you there).

## Configuration

The installer generates the agent configuration **once**; after that it is
yours and upgrades never touch it:

| Path | Purpose |
|------|---------|
| `/var/packages/nomad/etc/nomad.hcl` | Main agent configuration (generated from wizard answers) |
| `/var/packages/nomad/etc/conf.d/*.hcl` | Drop-in overrides, loaded after `nomad.hcl` |
| `/var/packages/nomad/var/data` | Nomad data directory |
| `/var/packages/nomad/var/logs/nomad.log` | Agent log (rotated) |

After editing configuration, restart the package from Package Center (or
`synopkg restart nomad` over SSH). Nomad's own output is captured to
`/var/packages/nomad/var/logs/console.log`, which is the first place to look
if the agent won't start.

The `nomad` CLI is at `/var/packages/nomad/target/bin/nomad`. Enabling
privileged mode (below) also symlinks it to `/usr/local/bin/nomad` for
convenient SSH use; until then, call it by its full path.

### How the package runs (privileges) — important

DSM 7.2 refuses to install a sideloaded package that asks to run as `root` or
that requests Linux capabilities, so Nomad installs and runs as an
unprivileged **`nomad`** package user. In that state **the agent runs but the
Docker and isolated exec drivers do not work** — they need privileges DSM will
not hand a package. Nomad may even show as stopped in Package Center until you
complete the opt-in step below.

To run real workloads, opt into **privileged mode**, which makes the Nomad
binary setuid-root so the agent runs with full privileges (the same class of
approach Tailscale and WireGuard use on DSM 7). This is a deliberate, explicit
step — the package never escalates on its own.

**Enable privileged mode (one time):**

1. **Control Panel → Task Scheduler → Create → Triggered Task → User-defined script**.
2. **Event: Boot-up**, **User: root**.
3. Task settings → **Run command**:
   ```sh
   /var/packages/nomad/target/share/enable-privileges.sh
   ```
4. Select the task and click **Run** to apply it now (it also re-runs on every
   boot). Nomad restarts automatically and now runs as root.

The setuid bit survives reboots; the boot task exists so it is re-applied after
a package **upgrade** replaces the binary (the package also re-applies it
automatically on upgrade once you have opted in). To check or revert over SSH:

```sh
sudo /var/packages/nomad/target/share/enable-privileges.sh status
sudo /var/packages/nomad/target/share/enable-privileges.sh disable
```

### Task drivers

| Driver | Status | Notes |
|--------|--------|-------|
| `docker` | Works in privileged mode | Requires Container Manager; running as root gives access to `/var/run/docker.sock` |
| `exec` | Works in privileged mode | Isolated fork/exec; needs root for chroot/cgroups/namespaces |
| `raw_exec` | Disabled | No isolation — opt in via `conf.d` (see below) |

Confirm driver health after enabling privileged mode:

```sh
sudo /usr/local/bin/nomad node status -self
```

To enable `raw_exec`, create `/var/packages/nomad/etc/conf.d/raw-exec.hcl`:

```hcl
plugin "raw_exec" {
  config {
    enabled = true
  }
}
```

### Dynamic host volumes

If you set a **Dynamic host volumes directory** in the install wizard, the
config sets Nomad's `client { host_volumes_dir = "..." }` to that path.
Nomad's built-in **`mkdir`** plugin then carves out on-demand host volumes as
subdirectories there — a convenient way to give jobs persistent storage on a
Synology volume without pre-declaring each one.

Create a volume and mount it in a job:

```hcl
# volume.hcl
type      = "host"
name      = "postgres-data"
plugin_id = "mkdir"
```

```sh
sudo /usr/local/bin/nomad volume create volume.hcl
```

```hcl
# in a job's group block
volume "data" {
  type   = "host"
  source = "postgres-data"
}
task "db" {
  volume_mount {
    volume      = "data"
    destination = "/var/lib/postgresql/data"
  }
}
```

Nomad creates and writes these volume directories as its own unprivileged
**`nomad`** package user, so the least-privilege way to make this work is to
grant that user access to the folder rather than elevating Nomad. Use a
**shared-folder ACL**:

- **Control Panel → Shared Folder →** select the folder **→ Edit →
  Permissions**, switch the user dropdown to **System internal user**, find
  **`nomad`**, and grant **Read/Write** — or do the same via **File Station →
  right-click the folder → Properties → Permission**.

With that ACL in place, dynamic host volumes work **without privileged mode**.
This is the recommended approach: it's how DSM expects folder access to be
granted (the package can't `chown` volumes itself), and it keeps Nomad
unprivileged. Enabling privileged mode (below) is an alternative — Nomad then
runs as root and can write anywhere — but it's broader than this feature
needs. Leaving the wizard field blank uses Nomad's default location under the
package data directory, which needs neither. The `mkdir` plugin does not
enforce `capacity_min`/`capacity_max` — size is bounded only by the underlying
Synology volume.

### Tailscale peering

Selecting *Tailscale* in the wizard advertises the NAS's tailnet IP using a
go-sockaddr template:

```hcl
advertise {
  http = "{{ GetInterfaceIP \"tailscale0\" }}"
  rpc  = "{{ GetInterfaceIP \"tailscale0\" }}"
  serf = "{{ GetInterfaceIP \"tailscale0\" }}"
}
```

Because `tailscale0` only receives its address once `tailscaled` has
connected, the package waits (up to 60 seconds) for the interface to hold an
IPv4 address before launching Nomad.

Make sure your tailnet ACLs (and, if you run DSM's firewall, its rules) allow
the Nomad ports between cluster members: **4646/tcp** (HTTP API), **4647/tcp**
(RPC), and **4648/tcp+udp** (Serf gossip). The package does not modify the DSM
firewall, so add these rules under **Control Panel → Security → Firewall** if
you have it enabled.

## Uninstalling

Uninstalling removes the package and binaries. Configuration under
`/var/packages/nomad/etc` and data under `/var/packages/nomad/var` follow
DSM's package-data handling; if configuration survives and you reinstall
later, the installer keeps the existing `nomad.hcl` rather than regenerating
it from the wizard.

## Building locally

```sh
./build.sh 2.0.3 x86_64        # → dist/nomad-2.0.3-1-x86_64.spk
./build.sh 2.0.3 aarch64 2     # package revision 2
```

The script downloads the official Nomad binary from
`releases.hashicorp.com`, verifies its SHA256 checksum, and assembles the
SPK with plain `tar` — no Synology toolkit required.

## Release automation

The [Release workflow](.github/workflows/release.yml) runs daily: it asks the
HashiCorp releases API for the latest stable Nomad version and, if it hasn't
been packaged yet, builds both SPKs, creates a `v<version>` GitHub release,
and uploads the artifacts. It can also be dispatched manually to package a
specific version or to publish a new package revision (`v<version>-<rev>`)
for packaging-only fixes.

## License

This packaging is [MIT licensed](LICENSE). Nomad itself is licensed by
HashiCorp under the [BUSL](https://github.com/hashicorp/nomad/blob/main/LICENSE);
this project redistributes the unmodified official binaries. HashiCorp and
Nomad are trademarks of HashiCorp, Inc. — this is a community package, not
affiliated with or endorsed by HashiCorp or Synology.
