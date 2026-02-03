# olaris-testing

Client per testare una installazione Nuvolaris su k3s usando un dominio wildcard.

## Requisiti
- `kubectl` configurato per il cluster k3s
- `ops` nel PATH
- accesso al namespace `nuvolaris`
 - connettività TCP verso:
   - API host pubblico su `443`
   - API server Kubernetes (tipicamente `6443`)
 - opzionale: `.env` con `APIHOST` e/o tunnel SSH

## Esecuzione

```bash
./olaris-testing/run.sh "*.example.com"
```

Output: tabella di stato come nel README principale, con la colonna K3S popolata.

## Ops task
Se `ops testing run` legge `opsfile.yml` dalla directory corrente:

```bash
cd /root/Testing/olaris-testing
ops testing run "https://49.13.136.198.nip.io"
```


## Note
- I test `Nuv Win` e `Nuv Mac` sono marcati `N/A` (richiedono ambienti Windows/Mac).
- Se un componente non è installato (es. Redis, MongoDB, Postgres, Minio), il relativo test viene marcato `N/A`.
- Se il kubeconfig punta a `localhost:6443` e non è raggiungibile, puoi creare un tunnel SSH impostando:
  - `SSH_TUNNEL_HOST`
  - opzionali: `SSH_TUNNEL_USER`, `SSH_TUNNEL_KEY`
