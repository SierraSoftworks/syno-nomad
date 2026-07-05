# nomad-tailscale-connector

A small daemon that publishes Nomad native services as
[Tailscale Services](https://tailscale.com/docs/features/tailscale-services),
driven by Traefik-style service tags (`tailscale.enable=true`,
`tailscale.https=443`, …).

Built on [tsnet](https://tailscale.com/docs/reference/tsnet-server-api), the
connector joins the tailnet as its own userspace device and hosts Services
in-process via `Server.ListenService`: it watches the Nomad event stream,
opens a Service listener for each tagged service scheduled on its node (tsnet
terminates TLS), and reverse-proxies the traffic to the allocation's address
and port. When Nomad deregisters a service the advertisement is withdrawn
immediately — while `shutdown_delay` keeps the task serving — and in-flight
connections get a grace period to finish.

It currently lives in the syno-nomad repository and is deployed as a Nomad
system job (see [jobs/tailscale-connector.nomad.hcl](../jobs/tailscale-connector.nomad.hcl)),
but it has no Synology-specific dependencies: it needs only a reachable
Nomad agent and a way onto your tailnet (a tagged auth key), and is intended
to graduate into its own project.

Full usage and setup documentation: [docs/tailscale-services.md](../docs/tailscale-services.md).

## Building

```sh
go build -o nomad-tailscale-connector .
go test ./...
```

Releases are built by the
[Connector Release workflow](../.github/workflows/connector-release.yml)
and tagged `connector-v<version>`, separate from the Nomad package releases.
