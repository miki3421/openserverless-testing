# Plugin ops testing

Run Nuvolaris test suite against a K3S installation.

## Synopsis

```text
Usage:
    testing run [<apihost>] [--verbose]
```

## Commands

```
  testing run   execute tests against the given API host or wildcard domain
```

## Options

```
  <apihost>     API host URL or wildcard domain (e.g. https://host or *.example.com). Optional if APIHOST is set in .env
  --verbose     print `ops setup nuvolaris status` before running tests
```

## Examples

```
# Direct host
ops testing run https://49.13.136.198.nip.io

# Wildcard domain
ops testing run "*.example.com"

# Using .env (APIHOST)
APIHOST="https://49.13.136.198.nip.io" ops testing run

# SSH tunnel for kubeconfig pointing to localhost:6443
SSH_TUNNEL_HOST=your.ssh.host \
SSH_TUNNEL_USER=ubuntu \
SSH_TUNNEL_KEY=~/.ssh/id_rsa \
ops testing run https://49.13.136.198.nip.io

# Verbose mode (prints ops setup nuvolaris status)
ops testing run --verbose
```
