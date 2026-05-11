# Autonomous mode log

Modo autônomo iniciado: 2026-05-10 ~22:25Z (BRT)

## Objetivo
Top 3 (~5853 pts).

## Histórico de submissões antes do modo autônomo

| Issue | Versão | Valid | Fail% | Score |
|---|---|---:|---:|---:|
| 3012 | Original leaky | 7508 | 76.88 | -6000 |
| 3024 | Fases A-D + keep-alive 1ª tentativa | 2424 | 95.58 | -6000 |
| 3043 | IVF probes=16 | 4662 | 91.58 | -6000 |
| 3048 | IVF probes=8 SIMD | 2895 | 94.75 | -6000 |
| 3068 | IVF probes=4 SIMD iters=3 | 3820 | 93.09 | -6000 |
| 3095 | AVX2 enabled | 4245 | 92.31 | -6000 |
| 3117 | SoA + @Vector(8) + FMA | 4487 | 91.88 | -6000 |

## Em fila (modo autônomo)

| Issue | Versão | Valid | Fail% | Score |
|---|---|---:|---:|---:|
| 3131 | pre-baked + keep-alive | 3621 | 93.43 | -6000 |
| 3140 | multi-thread 3 workers io_uring | **5393** | **90.23** | -6000 |

Melhor resultado até agora: #3140 com 5393 valid. Multi-thread funcionou.
Mas failure_rate ainda 90% > 15% cap → score travado em -6000.

Próximo passo: trocar LB Zig custom por nginx.

## Iteração 2 (modo autônomo)

- 2026-05-11 10:12Z: submission branch atualizada para nginx:1.27-alpine como LB (commit 682080f). Issue #3236 disparada. Fila vazia, deve processar rápido.
- 2026-05-11 10:15Z: #3236 fechado. nginx LB **piorou**: 1208 valid (vs 5393 com Zig LB). Revertendo submission para Zig LB (commit 5181508).

## Iteração 3

- 2026-05-11 10:35Z: H10 implementado — hand-written JSON parser (src/fast_parser.zig). Position-based, zero alocação, navega objetos aninhados via auto-descend em `{`. Issue #3244 disparada. Recall preservado em testes locais. Search bench local: 19μs.
- 2026-05-11 10:50Z: #3244 fechado. 5335 valid, 90.36% fail, -6000. JSON parser não melhorou (dentro da variance).
- 2026-05-11 10:55Z: Re-submeti mesma versão (#3248) para medir variance. 2417 valid, 95.6% fail. **Variance enorme do rig: 5335 → 2417 com MESMO código**.

## Iteração 4

- 2026-05-11 11:30Z: H8 bbox_repair implementado — index v4→v5 com bbox_min/max [k*dim]i8 por cluster. Search adiciona pass de bbox_repair quando fraud_count ∈ [1,4]: testa clusters não probados via lower bound bbox sq distance. Approved agreement local 99%→100%. Issue #3257 disparada.
- 2026-05-11 11:55Z: #3257 fechado. **589 valid, 98.93% fail, -6000** — REGRESSÃO drástica. bbox_repair adicionou trabalho por query (90% das queries triggeram).
- 2026-05-11 12:00Z: Revertido — bbox_repair desabilitado (mantém v5 format por simplicidade). Commit 0984b83. Issue #3271 disparada para verificar baseline restaurado.
- 2026-05-11 12:26Z: #3271 fechado. **5121 valid, 90.72% fail, -6000** — baseline restaurado para nível normal.

## Iteração 5 — BREAKTHROUGH POTENCIAL

- 2026-05-11 12:30Z: **DESCOBERTA CRÍTICA**: olhando resultados recentes da rinha, meu repo Go HNSW antigo (`steixeira93-go-hnsw`) scoreou **5818.9 pts HOJE** (top 4). Stack: HAProxy 2.9 + warmup container + Go HNSW API. **Mesma rig, mesmo dia, score 12000pts melhor que meu Zig V2 (-6000)**. Confirma que a rig NÃO está sobrecarregada — meu stack Zig V2 é que tem algo fundamentalmente errado.

- 2026-05-11 12:35Z: **H11 (warmup + HAProxy)**: Adotada arquitetura comprovada do Go HNSW: HAProxy 2.9-alpine como LB + warmup container (96 requests, 12 payloads variados antes do k6 começar) + meu API Zig multi-thread io_uring. Resources: api 0.38/145MB × 2, lb 0.20/30MB, warmup 0.04/12MB = 1.00/332MB. Issue #3283 disparada (commit submission ab917c0).

## Fases preparadas em standby

- H7: nginx LB (deploy/nginx.conf + deploy/docker-compose.nginx.yml committed)
- H8: bbox_repair no search (a implementar quando necessário)
- H9: per-cluster SoA + i16 quant (a implementar quando necessário)
