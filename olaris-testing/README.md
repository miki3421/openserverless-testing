# olaris-testing

Client to test a Nuvolaris installation on k3s using a wildcard domain.

## Requirements
- `kubectl` configured for the k3s cluster
- `ops` in PATH
- access to the `nuvolaris` namespace
- TCP connectivity to:
  - public API host on `443`
  - Kubernetes API server (typically `6443`)
- optional: `.env` with `APIHOST` and/or SSH tunnel variables

## Run

```bash
./olaris-testing/run.sh "*.example.com"
```

Output: status table (K3S column populated) matching the main README.

## Ops task
If `ops testing run` reads `opsfile.yml` from the current directory:

```bash
cd /root/Testing/olaris-testing
ops testing run "https://49.13.136.198.nip.io"
```

## Notes
- `Nuv Win` and `Nuv Mac` are reported as `N/A` (require Windows/Mac environments).
- If a component is not installed (Redis, MongoDB, Postgres, Minio), the corresponding test is `N/A`.
- If kubeconfig points to `localhost:6443` and it is not reachable, you can create an SSH tunnel by setting:
  - `SSH_TUNNEL_HOST`
  - optional: `SSH_TUNNEL_USER`, `SSH_TUNNEL_KEY`
