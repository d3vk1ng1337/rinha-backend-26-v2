# rinha-backend-26-v2

Submissão V2 para a [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026) — detecção de fraude por busca vetorial, em **Zig**.

**Status:** V1 baseline (int8 brute-force, mmap-shared index, HAProxy LB).

## Stack

- Zig 0.14
- HAProxy 2.9 (load balancer, round-robin estrito via unix sockets)
- mmap shared index em volume Docker

Design completo: `docs/superpowers/specs/`. Plano V1: `docs/superpowers/plans/2026-05-10-rinha-v1-zig.md`.

## Como rodar

```sh
make data       # baixa references.json.gz
make build      # compila imagens Docker
make up         # sobe stack (builder + lb + 2 apis)
curl http://localhost:9999/ready
make smoke      # testa /fraud-score com payload de exemplo
make down
```
