# rinha-backend-26-v2

Submissão V2 para a [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026) — detecção de fraude por busca vetorial, em **Zig**.

**Status:** V2.1 (binary quant + int8 rerank): local p50 6.0 ms / p99 9.9 ms (vs V1 baseline p50 10.2 / p99 37.7 ms).

## Stack

- Zig 0.16
- LB próprio em Zig sobre `io_uring` (round-robin via unix sockets)
- API io_uring no Linux com fallback bloqueante no macOS
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
