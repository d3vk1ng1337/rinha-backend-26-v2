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

- 2026-05-11 13:01Z: #3283 fechado. **977 valid, 98.05% fail, -6000** — REGRESSÃO. HAProxy+warmup piorou vs baseline Zig LB.
- 2026-05-11 13:10Z: **H12**: mmap populate=true → populate=false. Hipótese: pre-fault síncrono de 46MB atrasava listen do unix socket, HAProxy/warmup hammeravam antes da API ficar pronta. Issue #3299 disparada (commit d20535b).
- 2026-05-11 14:40Z: #3299 fechado. **~1635 respostas válidas, 94.5% fail, -6000** — `populate=false` isolado não resolveu. Ainda HAProxy+warmup, mesmas APIs com múltiplos workers.

## Iteração 6 — estabilização HTTP antes de ANN

- 2026-05-11 14:29Z: **H13 preparado**: voltar para Zig LB, corrigir partial writes no proxy TCP, permitir tuning de workers da API e testar `1` worker por API. Hipótese: a taxa de HTTP errors vem de combinação de oversubscription (`3` workers competindo por 0.40 CPU) + proxy sem tratamento de writes parciais. Compose H13: api1/api2 `0.40 CPU / 160MB`, lb `0.20 CPU / 30MB`, total `1.00 CPU / 350MB`, comandos API com terceiro argumento `"1"`.
- Local Docker no Mac arm64/OrbStack não serve como smoke de runtime para esta imagem linux/amd64: a API carrega o índice e falha em `io_uring` com `SystemOutdated`. Validação local fica restrita a build/test/compose; resultado oficial segue sendo a fonte de verdade.
- Check offline do índice H13 publicado: `run-check .tmp/index-h13.bin 200 42` → busca média **19.2us**, approved agreement **98.5%** contra brute force int8. ANN não é o gargalo primário neste momento.
- 2026-05-11 15:06Z: #3318 ainda aberta, fila oficial avançou só até #3309. Branch `submission` mantida congelada para não trocar o snapshot antes do runner processar H13.
- Repo Go de referência (`/Users/samuel/Documents/Personal/rinha-backend-26`) confirmado como baseline operacional: HAProxy TCP + warmup + servidor Go bloqueante por conexão + `idx.Warmup()` antes de escutar. A versão #3303 marcou **5592.06** com 1 HTTP error; isso isola o problema Zig V2 em estabilidade HTTP/runtime, não no limite geral da competição.

## Próxima hipótese pronta — H14

- 2026-05-11 16:00Z: #3318 fechado. **p99 2001.82ms, 48.300 HTTP errors, 89.74% fail, -6000** — H13 não apareceu no resultado oficial.
- Diagnóstico remoto em GitHub Actions com as mesmas imagens `latest` publicadas:
  - Node keep-alive, 54.100 payloads oficiais, 250 conexões: **54.100 HTTP 200**, p99 ~100ms.
  - k6 oficial (`test/test.js`, 120s ramping-arrival-rate): **0 HTTP errors**, p99 **0.41ms**, final score local **3355.25**.
  - Containers no diagnóstico tinham `NanoCpus` correto (api 0.40/0.40, lb 0.20) e mem limits corretos.
- Hipótese raiz atual: uso de `:latest` permitiu cache/stale image no runner oficial. O resultado oficial reporta o commit `submission`, mas não reporta digest de imagem. Como a compose apontava `latest`, o runner pode ter executado imagem antiga apesar do compose novo.
- **H14 executado**: branch `submission` atualizado para usar tags imutáveis `sha-c086938da1bff1d1ac160f91a06c3ce4d544c1e8` em API e LB. Issue #3340 aberta.
- Critério de sucesso #3340: sair do padrão ~5k valid / ~48k HTTP errors. Se #3340 continuar igual, a hipótese de cache cai e o próximo passo volta para arquitetura HTTP sob runner oficial.

## Simulação do ambiente oficial

- 2026-05-11 16:35Z: confirmado nos docs oficiais: o preview público usa `run.sh` + `test/test.js` + `test/test-data.json`; o limite declarado é 1 CPU / 350MB; o runner oficial é Mac Mini Late 2014, 2.6GHz, 8GB, Ubuntu 24.04.
- Não existe forma de obter p99 "exato" em Mac ARM/OrbStack nem em GitHub Actions moderno. Eles reproduzem o script e a carga, mas não a mesma CPU/cache/kernel/host contention do Mac Mini oficial.
- Adicionado `tools/run-official-preview.sh`: harness local que baixa os artefatos oficiais, exporta `docker-compose.yml` de `SUBMISSION_REF=submission`, sobe a compose, roda o k6 oficial e coleta Docker/cgroup/stats/logs. Para comparabilidade, rodar em Linux amd64; para equivalência máxima, rodar num Mac Mini Late 2014 com Ubuntu 24.04.

## Fases preparadas em standby

- H7: nginx LB (deploy/nginx.conf + deploy/docker-compose.nginx.yml committed)
- H8: bbox_repair no search (a implementar quando necessário)
- H9: per-cluster SoA + i16 quant (a implementar quando necessário)
