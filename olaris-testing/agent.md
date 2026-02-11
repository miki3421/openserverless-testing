# Agent Change Log

## Regola
Tutte le modifiche al progetto devono essere registrate in questo file come change log, con data, file impattati e sintesi.

## 2026-02-11
- Creato `spec.md` con nuova specifica basata su `README.md`.
- Aggiunto requisito `clean` in `ops testing run` (on-demand + esecuzione finale automatica).
- Aggiunto requisito fix protocollo SeaweedFS basato su `ops config status`.
- Aggiunti prerequisiti obbligatori: `OPS_BRANCH=main`, `ops config apihost`, `ops config smil` per cluster slim, file `.ops/tmp/config`.
- Introdotta la regola di tracciamento modifiche in `agent.md`.
- Implementato task `clean` in `opsfile.yml` (`ops testing clean`) con esecuzione on-demand.
- Implementata cleanup automatica a fine `ops testing run` in `run.sh` tramite `trap` EXIT.
- Implementata cleanup idempotente degli oggetti demo (utenti demo + package admin `hello`) in `run.sh`.
- Implementata fix SeaweedFS in `run.sh` con protocollo dedotto da `ops config status` e fallback loggato a `http`.
- Implementati prerequisiti in `run.sh` per test run: `OPS_BRANCH=main`, `ops config apihost`, file `.ops/tmp/config`, check `ops config slim/smil` se cluster slim.
- Aggiornata documentazione comandi in `docopts.md` aggiungendo `ops testing clean`.
- Fix prerequisito config in `run.sh`: percorso corretto su `$HOME/.ops/tmp/config` con fallback a `$HOME/.kube/config`.
