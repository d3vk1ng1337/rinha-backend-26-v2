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

## Fases preparadas em standby

- H7: nginx LB (deploy/nginx.conf + deploy/docker-compose.nginx.yml committed)
- H8: bbox_repair no search (a implementar quando necessário)
- H9: per-cluster SoA + i16 quant (a implementar quando necessário)
