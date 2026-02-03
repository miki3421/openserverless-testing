# olaris-testing

Client per testare una installazione Nuvolaris su k3s usando un dominio wildcard.

## Requisiti
- `kubectl` configurato per il cluster k3s
- `ops` nel PATH
- accesso al namespace `nuvolaris`

## Esecuzione

```bash
./olaris-testing/run.sh "*.example.com"
```

Output: tabella di stato come nel README principale, con la colonna K3S popolata.

## Note
- I test `Nuv Win` e `Nuv Mac` sono marcati `N/A` (richiedono ambienti Windows/Mac).
- Se un componente non è installato (es. Redis, MongoDB, Postgres, Minio), il relativo test viene marcato `N/A`.
