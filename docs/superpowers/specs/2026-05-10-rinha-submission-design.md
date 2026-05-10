# Rinha 2026 — Submissão V2 Zig

Desenho da submissão da V2.1+ (binary quant + io_uring API + LB Zig próprio) ao [repo oficial](https://github.com/zanfranceschi/rinha-de-backend-2026).

## Objetivo

Submeter a V2 ao rig de produção da rinha com:

- Pull request adicionando entrada nova em `participants/steixeira93.json`.
- Branch `submission` enxuta, com `docker-compose.yml` apontando para imagens públicas.
- Issue `rinha/test steixeira93-zig-v2` para disparar o teste de carga oficial.

## Restrições da rinha

Resumo das regras relevantes (de `docs/br/{ARQUITETURA,SUBMISSAO,FAQ}.md`):

1. Soma dos limites de recursos no compose ≤ **1 CPU + 350 MB**.
2. Pelo menos 1 LB + 2 APIs distribuindo round-robin; LB sem lógica de negócio.
3. Imagens públicas, `linux/amd64`, modo `bridge`, sem `host`/`privileged`.
4. Porta 9999 no LB.
5. Branch `main` com fonte; branch `submission` SEM fonte, apenas o necessário para rodar o teste; `docker-compose.yml` na raiz.
6. Repositório público, com licença MIT.
7. `info.json` na raiz com `participants`, `social`, `source-code-repo`, `stack`, `open_to_work`.
8. Validação automática do PR aceita exatamente 1 arquivo modificado: `participants/<author>.json`.

## Estado atual e gaps

Branch `submission` atual viola 1, 5, e parcialmente 7. O repo não tem LICENSE.

| Gap | Solução |
|---|---|
| Soma 2.0 CPU / 420 MB (builder pesa 1.0/200) | Eliminar serviço builder do compose; pré-construir índice no CI e embutir na imagem da API |
| Compose com `build:` | Apontar para `ghcr.io/steixeira93/rinha-backend-26-v2-{api,lb}:latest` (CI já publica) |
| Branch `submission` tem `src/`, `cmd/`, `build.zig` | Limpar: deixar só `docker-compose.yml`, `info.json`, `LICENSE`, `README.md` |
| Sem `LICENSE` MIT | Adicionar `LICENSE` MIT em `main` |
| `info.json.stack` ainda lista `haproxy` | Substituir por `["zig", "io_uring"]` |
| `participants/steixeira93.json` no rinha aponta só pro Go HNSW antigo | Adicionar entrada `steixeira93-zig-v2` ao array existente |

## Arquitetura final

### Build do índice no CI

O workflow `build-and-publish.yml` ganha um job antes do build da API:

1. Faz download de `references.json.gz`, `mcc_risk.json` e `normalization.json` do repo oficial via raw URL.
2. Compila e roda o builder Zig contra esses arquivos, gerando `index.bin` (~48 MB).
3. Publica `index.bin` como artifact do job.

O Dockerfile da API recebe esse `index.bin` como build context e copia para `/index/index.bin` dentro da imagem. Imagem final tem ~50–60 MB e é self-contained.

### Compose final na branch `submission`

```yaml
services:
  api1:
    image: ghcr.io/steixeira93/rinha-backend-26-v2-api:latest
    command: ["/sockets/api1.sock", "/index/index.bin"]
    volumes:
      - sockets:/sockets
    deploy:
      resources:
        limits:
          cpus: "0.45"
          memory: "150M"

  api2:
    image: ghcr.io/steixeira93/rinha-backend-26-v2-api:latest
    command: ["/sockets/api2.sock", "/index/index.bin"]
    volumes:
      - sockets:/sockets
    deploy:
      resources:
        limits:
          cpus: "0.45"
          memory: "150M"

  lb:
    image: ghcr.io/steixeira93/rinha-backend-26-v2-lb:latest
    command: ["0.0.0.0:9999", "/sockets/api1.sock", "/sockets/api2.sock"]
    volumes:
      - sockets:/sockets:ro
    ports:
      - "9999:9999"
    depends_on: [api1, api2]
    deploy:
      resources:
        limits:
          cpus: "0.10"
          memory: "30M"

volumes:
  sockets:
```

Total: **1.00 CPU / 330 MB**.

### CI — mudanças

Workflow `.github/workflows/build-and-publish.yml`:

- Novo job `build-index` (rodando antes do `build`):
  - Baixa os 3 arquivos do repo da rinha (`raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/main/resources/...`).
  - Compila o Zig builder (toolchain Zig 0.14 via `goto-bus-stop/setup-zig` ou tarball).
  - Roda o builder; sobe `index.bin` como artifact.
- Job `build` da matrix:
  - Para `component=api`: baixa o artifact `index.bin` antes do `docker buildx build`, passa via `--build-arg` ou copia para o build context.
  - Para `component=lb`: sem mudança.
  - **Remove `component=builder`** da matrix — não é mais necessário.

O Dockerfile.api ganha:

```dockerfile
COPY index.bin /index/index.bin
```

(Posicionado depois do build do binário Zig, para preservar cache.)

### Branch submission

Conteúdo final:

```
submission/
├── LICENSE
├── README.md          # leve, só apontando para main
├── docker-compose.yml
└── info.json
```

Sem `src/`, sem `cmd/`, sem `build.zig`, sem `data/`, sem Dockerfiles. Resetada a partir de uma orphan branch nova ou via `rm -rf` + commit.

### `info.json`

```json
{
  "participants": ["Samuel Teixeira"],
  "social": ["https://github.com/steixeira93"],
  "source-code-repo": "https://github.com/steixeira93/rinha-backend-26-v2",
  "stack": ["zig", "io_uring"],
  "open_to_work": false
}
```

### Entrada no rinha repo

`participants/steixeira93.json` (mantém a entrada antiga + adiciona a nova):

```json
[
  {
    "id": "steixeira93-go-hnsw",
    "repo": "https://github.com/steixeira93/rinha-backend-26"
  },
  {
    "id": "steixeira93-zig-v2",
    "repo": "https://github.com/steixeira93/rinha-backend-26-v2"
  }
]
```

## GHCR — visibilidade

Por padrão GHCR cria pacotes privados. Após o primeiro push, é necessário trocar a visibilidade dos 2 pacotes (`rinha-backend-26-v2-api`, `rinha-backend-26-v2-lb`) para **public** via UI do GitHub ou `gh api`. Sem isso o rig não consegue dar pull.

## Fluxo de submissão

1. Mudanças no `main` (CI + Dockerfile + info.json + LICENSE) — commit + push, esperar CI publicar imagens.
2. Tornar pacotes GHCR públicos.
3. Smoke local: `docker compose -f deploy/docker-compose-submission.yml up -d` (versão de teste apontando pro ghcr); `curl /ready`; rodar `smoke.js` do rinha.
4. Reescrever branch `submission`: orphan branch com só `LICENSE`, `README.md`, `docker-compose.yml`, `info.json`. Force-push.
5. Fork do repo oficial via `gh repo fork`; branch `add-steixeira93-zig-v2`; editar `participants/steixeira93.json`; PR via `gh pr create`.
6. Aguardar smoke-test do CI da rinha passar e auto-merge.
7. Abrir issue com título e body `rinha/test steixeira93-zig-v2`.
8. Engine roda o teste de carga, comenta resultado, fecha a issue.

## Riscos

1. **Toolchain Zig no GitHub Actions:** precisa Zig 0.14. Usar `goto-bus-stop/setup-zig@v2` com `version: '0.14.0'`.
2. **Tempo do builder no CI:** lê 3M floats × 14 dim = ~168 MB em RAM, ordena para mediana. Estimativa: 30–60s. Cabível dentro do runner ubuntu-latest (7 GB RAM).
3. **Dataset > limites de download durante o build:** raw.githubusercontent.com aceita o `.gz` direto (16 MB), tranquilo.
4. **Imagem da API com 48 MB de índice embutido:** pull no rig do Mac Mini é razoável (rede do organizador é boa).
5. **Smoke test do PR auto-merge falhar:** se isso acontecer, fix + push, validação roda de novo.
6. **Image pull rate-limit do GHCR:** GHCR é generoso com pulls anônimos para pacotes públicos. Sem risco prático.

## Critérios de "feito"

- [ ] CI publica `api:latest` e `lb:latest` com `index.bin` embutido na API.
- [ ] Pacotes GHCR públicos.
- [ ] Smoke local (`docker compose up -d` + `smoke.js`) passa.
- [ ] Branch `submission` contém só compose + info + LICENSE + README.
- [ ] PR no rinha passa o auto-merge workflow.
- [ ] Issue `rinha/test steixeira93-zig-v2` retorna resultado oficial.
