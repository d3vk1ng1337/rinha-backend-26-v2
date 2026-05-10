# Rinha Submission V2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Submeter a V2 Zig (binary quant + io_uring + LB próprio) ao rig oficial da Rinha de Backend 2026 — PR na branch `participants/` + issue `rinha/test`.

**Architecture:** Pré-construir `index.bin` no GitHub Actions e embuti-lo na imagem da API, eliminando o serviço `builder` do compose (orçamento cai de 2.0 CPU/420 MB para 1.00 CPU/330 MB). Branch `submission` reescrita como orphan contendo só `LICENSE`, `README.md`, `docker-compose.yml`, `info.json`. PR e issue abertos via `gh` após aprovação manual final.

**Tech Stack:** Zig 0.16, Docker buildx, GitHub Actions (`mlugg/setup-zig`), GHCR, `gh` CLI.

**Reference:** spec em `docs/superpowers/specs/2026-05-10-rinha-submission-design.md`.

---

## File Structure

**Modified:**
- `.github/workflows/build-and-publish.yml` — adiciona job `build-index`, remove `component=builder` da matrix, baixa o artifact `index.bin` no job `api`.
- `deploy/Dockerfile.api` — adiciona `COPY index.bin /index/index.bin` ao final do stage runtime.
- `info.json` — `stack` atualizado.
- `README.md` — corrigir menção a HAProxy.

**Created:**
- `LICENSE` — MIT, autor Samuel Teixeira.
- `deploy/docker-compose.submission.yml` — compose com imagens GHCR, sem builder, usado para smoke local antes da submissão.

**Submission branch (orphan, reescrita do zero):**
- `LICENSE` (cópia da `main`)
- `README.md` (curto, link para `main`)
- `docker-compose.yml` (cópia de `deploy/docker-compose.submission.yml`)
- `info.json` (cópia da `main`)

**External (rinha repo PR):**
- `participants/steixeira93.json` — adicionar entrada `steixeira93-zig-v2` ao array existente.

---

## Phase 1 — Preparar `main`

### Task 1: Adicionar LICENSE MIT

**Files:**
- Create: `LICENSE`

- [ ] **Step 1: Criar arquivo LICENSE**

```
MIT License

Copyright (c) 2026 Samuel Teixeira

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Commit**

```bash
git add LICENSE
git commit -m "chore: adicionar licença MIT (requisito da rinha)"
```

---

### Task 2: Atualizar `info.json`

**Files:**
- Modify: `info.json`

- [ ] **Step 1: Substituir conteúdo**

```json
{
  "participants": ["Samuel Teixeira"],
  "social": ["https://github.com/steixeira93"],
  "source-code-repo": "https://github.com/steixeira93/rinha-backend-26-v2",
  "stack": ["zig", "io_uring"],
  "open_to_work": false
}
```

- [ ] **Step 2: Commit**

```bash
git add info.json
git commit -m "chore(info): refletir stack atual (Zig + io_uring, sem HAProxy)"
```

---

### Task 3: README — remover menção a HAProxy

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Editar a seção Stack**

Substituir o bloco existente:

```markdown
## Stack

- Zig 0.14
- HAProxy 2.9 (load balancer, round-robin estrito via unix sockets)
- mmap shared index em volume Docker
```

por:

```markdown
## Stack

- Zig 0.16
- LB próprio em Zig sobre `io_uring` (round-robin via unix sockets)
- API io_uring no Linux com fallback bloqueante no macOS
- mmap shared index em volume Docker
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README reflete LB Zig próprio e Zig 0.16"
```

---

### Task 4: Dockerfile.api recebe `index.bin` embutido

**Files:**
- Modify: `deploy/Dockerfile.api`

Vamos fazer com que a imagem **opcionalmente** já contenha o `index.bin` (passado como build context). Se o arquivo não existir no contexto, criamos um placeholder vazio para o build não quebrar — mas em produção o CI sempre injeta o arquivo real.

- [ ] **Step 1: Substituir conteúdo do Dockerfile**

```dockerfile
# syntax=docker/dockerfile:1.7
FROM --platform=linux/amd64 alpine:3.20 AS build
RUN apk add --no-cache curl xz
ARG ZIG_VERSION=0.16.0
RUN curl -fsSL https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz \
    | tar -xJ -C /opt && mv /opt/zig-* /opt/zig
ENV PATH="/opt/zig:${PATH}"

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
COPY cmd ./cmd
RUN zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl

FROM --platform=linux/amd64 alpine:3.20
COPY --from=build /src/zig-out/bin/api /usr/local/bin/api
COPY deploy/index.bin /index/index.bin
ENTRYPOINT ["/usr/local/bin/api"]
```

- [ ] **Step 2: Criar placeholder local para o build não quebrar quando rodado fora do CI**

```bash
mkdir -p deploy
[ -f deploy/index.bin ] || echo "placeholder" > deploy/index.bin
```

- [ ] **Step 3: Adicionar `deploy/index.bin` ao `.gitignore`**

Editar `.gitignore` adicionando a linha:

```
deploy/index.bin
```

- [ ] **Step 4: Verificar se o build local ainda funciona com o placeholder**

```bash
docker buildx build --platform linux/amd64 -f deploy/Dockerfile.api -t rinha26-api:smoke .
```

Expected: build succeeds (image criada). O `index.bin` placeholder será sobrescrito pelo real no fluxo CI.

- [ ] **Step 5: Commit**

```bash
git add deploy/Dockerfile.api .gitignore
git commit -m "build(api): embutir index.bin (gerado em CI) na imagem"
```

---

### Task 5: CI — adicionar job `build-index`

**Files:**
- Modify: `.github/workflows/build-and-publish.yml`

Mudanças:
1. Adicionar job `build-index` que baixa o dataset, instala Zig, roda o builder e publica `index.bin` como artifact.
2. Remover `builder` da matrix do job `build` — não precisamos mais publicar imagem do builder.
3. No job `build`, quando `component == api`, baixar o artifact `index.bin` e colocá-lo em `deploy/index.bin` antes do `docker buildx build`.

- [ ] **Step 1: Substituir conteúdo do workflow**

```yaml
name: build-and-publish

on:
  push:
    branches: [main]
    tags: ['v*']
  workflow_dispatch:

permissions:
  contents: read
  packages: write

env:
  REGISTRY: ghcr.io
  IMAGE_OWNER: ${{ github.repository_owner }}
  RINHA_RAW: https://raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/main/resources

jobs:
  build-index:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: mlugg/setup-zig@v1
        with:
          version: 0.16.0

      - name: Download rinha reference dataset
        run: |
          mkdir -p data
          curl -fsSL "$RINHA_RAW/references.json.gz" -o data/references.json.gz
          curl -fsSL "$RINHA_RAW/mcc_risk.json"      -o data/mcc_risk.json
          curl -fsSL "$RINHA_RAW/normalization.json" -o data/normalization.json
          ls -lh data/

      - name: Build index
        run: |
          mkdir -p deploy
          zig build -Doptimize=ReleaseFast run-builder -- \
            data/references.json.gz deploy/index.bin
          ls -lh deploy/index.bin

      - uses: actions/upload-artifact@v4
        with:
          name: index-bin
          path: deploy/index.bin
          retention-days: 1

  build:
    needs: build-index
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        component: [api, lb]
    steps:
      - uses: actions/checkout@v4

      - if: matrix.component == 'api'
        uses: actions/download-artifact@v4
        with:
          name: index-bin
          path: deploy/

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_OWNER }}/rinha-backend-26-v2-${{ matrix.component }}
          tags: |
            type=raw,value=latest,enable={{is_default_branch}}
            type=sha,format=long
            type=ref,event=tag

      - uses: docker/build-push-action@v6
        with:
          context: .
          file: deploy/Dockerfile.${{ matrix.component }}
          platforms: linux/amd64
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha,scope=${{ matrix.component }}
          cache-to: type=gha,mode=max,scope=${{ matrix.component }}
```

- [ ] **Step 2: Validar sintaxe YAML local**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-and-publish.yml'))" && echo OK
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build-and-publish.yml
git commit -m "ci: pré-construir index.bin e embutir na imagem da API"
```

---

### Task 6: Push para `main` e validar CI

- [ ] **Step 1: Push**

```bash
git push origin main
```

- [ ] **Step 2: Acompanhar a execução**

```bash
gh run watch --exit-status
```

Expected: `build-index` succeeds, `build (api)` and `build (lb)` succeed.

- [ ] **Step 3: Confirmar imagens publicadas**

```bash
gh api user/packages?package_type=container --jq '.[] | select(.name | startswith("rinha-backend-26-v2")) | {name, visibility}'
```

Expected: pelo menos `rinha-backend-26-v2-api` e `rinha-backend-26-v2-lb` listados (provavelmente com `visibility: "private"` — corrigido na Task 7).

---

## Phase 2 — Tornar pacotes GHCR públicos

### Task 7: Mudar visibilidade dos pacotes para `public`

GHCR cria pacotes privados por padrão; o rig precisa fazer pull anônimo.

- [ ] **Step 1: Listar pacotes com visibilidade atual**

```bash
gh api user/packages?package_type=container --jq '.[] | select(.name | startswith("rinha-backend-26-v2")) | "\(.name) -> \(.visibility)"'
```

- [ ] **Step 2: Tornar `rinha-backend-26-v2-api` público**

```bash
gh api -X PATCH /user/packages/container/rinha-backend-26-v2-api/visibility -f visibility=public
```

Expected: HTTP 204, sem corpo.

- [ ] **Step 3: Tornar `rinha-backend-26-v2-lb` público**

```bash
gh api -X PATCH /user/packages/container/rinha-backend-26-v2-lb/visibility -f visibility=public
```

Expected: HTTP 204.

- [ ] **Step 4: Confirmar pull anônimo funciona**

```bash
docker logout ghcr.io
docker pull ghcr.io/steixeira93/rinha-backend-26-v2-api:latest
docker pull ghcr.io/steixeira93/rinha-backend-26-v2-lb:latest
```

Expected: ambos os pulls succeed.

---

## Phase 3 — Compose de submissão + smoke local

### Task 8: Criar `deploy/docker-compose.submission.yml`

**Files:**
- Create: `deploy/docker-compose.submission.yml`

- [ ] **Step 1: Criar o arquivo**

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

- [ ] **Step 2: Validar soma dos limites**

```bash
python3 -c "
import yaml
c = yaml.safe_load(open('deploy/docker-compose.submission.yml'))
total_cpu = sum(float(s['deploy']['resources']['limits']['cpus']) for s in c['services'].values())
total_mem = sum(int(s['deploy']['resources']['limits']['memory'].rstrip('M')) for s in c['services'].values())
print(f'CPU={total_cpu} MEM={total_mem}M')
assert total_cpu <= 1.0 and total_mem <= 350, 'over budget'
print('within rinha budget')
"
```

Expected: `CPU=1.0 MEM=330M` + `within rinha budget`.

- [ ] **Step 3: Commit**

```bash
git add deploy/docker-compose.submission.yml
git commit -m "build: docker-compose para submissão (imagens GHCR, sem builder)"
git push origin main
```

---

### Task 9: Smoke local end-to-end (replicar o que o rig faz)

- [ ] **Step 1: Subir o stack a partir das imagens GHCR**

```bash
docker compose -f deploy/docker-compose.submission.yml pull
docker compose -f deploy/docker-compose.submission.yml up -d
```

- [ ] **Step 2: Esperar `/ready`**

```bash
for i in $(seq 1 30); do
  if curl -fsS http://localhost:9999/ready; then echo " OK after $i tries"; break; fi
  sleep 2
done
```

Expected: `OK after N tries` (geralmente N ≤ 5).

- [ ] **Step 3: Rodar `smoke.js` da rinha**

```bash
mkdir -p /tmp/rinha-smoke && cd /tmp/rinha-smoke
curl -fsSL https://raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/main/test/smoke.js -o smoke.js
k6 run smoke.js
```

Expected: `checks.....: 100.00%`, `http_req_failed.....: 0.00%`. Se `k6` não estiver instalado: `brew install k6`.

- [ ] **Step 4: Smoke test customizado (payload de produção)**

```bash
cd /Users/samuel/Documents/Personal/rinha-backend-26-v2
curl -fsS http://localhost:9999/fraud-score -X POST \
  -H 'Content-Type: application/json' -d @data/sample.json | jq
```

Expected: JSON `{"approved": ..., "fraud_score": ...}`.

- [ ] **Step 5: Verificar uso real de memória**

```bash
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}'
```

Expected: cada API < 150 MB, LB < 30 MB.

- [ ] **Step 6: Derrubar o stack**

```bash
docker compose -f deploy/docker-compose.submission.yml down -v
```

---

## Phase 4 — Reescrever branch `submission`

A branch atual tem código-fonte (regra explícita: não pode). Vamos recriá-la como **orphan** com só os arquivos mínimos.

### Task 10: Criar nova `submission` orphan

- [ ] **Step 1: Garantir working tree limpo**

```bash
git status
```

Expected: `nothing to commit, working tree clean`.

- [ ] **Step 2: Backup da branch atual (precaução)**

```bash
git branch submission-backup-$(date +%Y%m%d) origin/submission
```

- [ ] **Step 3: Criar orphan branch**

```bash
git checkout --orphan submission-new
git rm -rf --cached . 2>/dev/null || true
git clean -fdx
```

- [ ] **Step 4: Restaurar arquivos necessários do `main`**

```bash
git checkout main -- LICENSE info.json deploy/docker-compose.submission.yml
mv deploy/docker-compose.submission.yml docker-compose.yml
rmdir deploy 2>/dev/null || true
```

- [ ] **Step 5: Criar README.md curto**

Conteúdo:

```markdown
# rinha-backend-26-v2 — submission

Branch de submissão para a [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026).

Código-fonte e documentação na branch [`main`](https://github.com/steixeira93/rinha-backend-26-v2/tree/main).

Stack: Zig 0.16, io_uring, mmap shared index. Imagens em [ghcr.io/steixeira93](https://github.com/steixeira93?tab=packages&repo_name=rinha-backend-26-v2).
```

- [ ] **Step 6: Confirmar conteúdo e commitar**

```bash
ls -la
```

Expected: ver apenas `LICENSE`, `README.md`, `docker-compose.yml`, `info.json` (e `.git`).

```bash
git add LICENSE README.md docker-compose.yml info.json
git commit -m "submission: V2 — imagens GHCR, sem builder"
```

- [ ] **Step 7: Renomear branch e force-push**

```bash
git branch -D submission 2>/dev/null || true
git branch -m submission
git push origin submission --force-with-lease
```

Expected: push succeeds.

- [ ] **Step 8: Voltar para `main`**

```bash
git checkout main
```

- [ ] **Step 9: Validar a branch remota**

```bash
gh api repos/steixeira93/rinha-backend-26-v2/contents?ref=submission --jq '.[].name'
```

Expected: apenas `LICENSE`, `README.md`, `docker-compose.yml`, `info.json`.

---

## Phase 5 — PR no rinha repo

### Task 11: Fork + branch + edit

> **Não modificamos o repo `rinha-backend-26` (Go HNSW)** — ele é de uma submissão diferente. O PR substitui a entrada antiga pela V2 no JSON do rinha; os resultados históricos do Go HNSW seguem preservados no repo de resultados (que é keyed por `[participant][submission_id]`, separado do `participants/`).

- [ ] **Step 1: Verificar/criar fork**

```bash
gh repo view steixeira93/rinha-de-backend-2026 >/dev/null 2>&1 \
  || gh repo fork zanfranceschi/rinha-de-backend-2026 --clone=false --remote=false
```

Expected: fork existe ou é criado.

- [ ] **Step 2: Clonar fork em local temporário e sincronizar**

```bash
mkdir -p /tmp/rinha-pr && cd /tmp/rinha-pr
gh repo clone steixeira93/rinha-de-backend-2026 .
git remote add upstream https://github.com/zanfranceschi/rinha-de-backend-2026.git
git fetch upstream main
git checkout main
git reset --hard upstream/main
git push origin main
```

- [ ] **Step 3: Criar branch para o PR**

```bash
git checkout -b add-steixeira93-zig-v2
```

- [ ] **Step 4: Substituir `participants/steixeira93.json` pela Zig V2**

Substituir o conteúdo inteiro por:

```json
[
  {
    "id": "steixeira93-zig-v2",
    "repo": "https://github.com/steixeira93/rinha-backend-26-v2"
  }
]
```

> A entrada antiga `steixeira93-go-hnsw` é removida do JSON da rinha. O repo `rinha-backend-26` em si não é tocado — só sua referência aqui sai. Resultados históricos do Go HNSW continuam no repo de resultados.

- [ ] **Step 5: Validar JSON contra o schema do auto-merge workflow**

```bash
jq -e '
  type == "array"
  and length > 0
  and all(.[];
    type == "object"
    and (keys | sort) == ["id", "repo"]
    and (.id | type == "string") and (.id | length > 0)
    and (.repo | type == "string") and (.repo | test("^(https?://|git@)"))
  )' participants/steixeira93.json
```

Expected: imprime `true`.

- [ ] **Step 6: Commit + push**

```bash
git add participants/steixeira93.json
git commit -m "Add steixeira93-zig-v2 submission"
git push origin add-steixeira93-zig-v2
```

---

### Task 12: Abrir PR (gate de aprovação humana)

- [ ] **Step 1: Mostrar diff completo para revisão final**

```bash
cd /tmp/rinha-pr
git diff main..add-steixeira93-zig-v2
```

Expected: diff toca **apenas** `participants/steixeira93.json`. Se tocar mais arquivos, `auto-merge` rejeita.

- [ ] **Step 2: Pedir aprovação explícita do usuário antes de continuar.**

Mostrar o diff acima e o body abaixo, perguntar "posso abrir o PR?".

- [ ] **Step 3 (após aprovação): Criar o PR**

```bash
cd /tmp/rinha-pr
gh pr create \
  --repo zanfranceschi/rinha-de-backend-2026 \
  --base main \
  --head steixeira93:add-steixeira93-zig-v2 \
  --title "Add steixeira93-zig-v2 submission" \
  --body "Adds the V2 Zig submission (binary quant + io_uring API + custom Zig LB) to my participants entry. Source: https://github.com/steixeira93/rinha-backend-26-v2"
```

Expected: URL do PR é impressa.

- [ ] **Step 4: Acompanhar smoke-test do PR**

```bash
PR_URL=$(gh pr view --repo zanfranceschi/rinha-de-backend-2026 --json url -q .url)
echo "$PR_URL"
gh pr checks --repo zanfranceschi/rinha-de-backend-2026 --watch
```

Expected: `validate`, `smoke-test`, `merge` todos com `pass`. Se `smoke-test` falhar, ler logs:

```bash
gh run list --repo zanfranceschi/rinha-de-backend-2026 --limit 3
gh run view <run-id> --repo zanfranceschi/rinha-de-backend-2026 --log-failed
```

— corrigir, push em `main`/`submission` do nosso repo, esperar imagens novas no GHCR, push novo no PR (re-roda validação).

- [ ] **Step 5: Confirmar merge**

```bash
gh pr view --repo zanfranceschi/rinha-de-backend-2026 --json state,mergedAt
```

Expected: `state: "MERGED"`.

---

## Phase 6 — Disparar teste de produção

### Task 13: Abrir issue `rinha/test` (gate de aprovação humana)

- [ ] **Step 1: Pedir aprovação explícita do usuário antes de abrir a issue.**

A issue dispara o teste de carga real no rig. Mostrar título e body abaixo, perguntar "posso abrir?".

- [ ] **Step 2 (após aprovação): Criar a issue**

```bash
gh issue create \
  --repo zanfranceschi/rinha-de-backend-2026 \
  --title "rinha/test steixeira93-zig-v2" \
  --body "rinha/test steixeira93-zig-v2"
```

Expected: URL da issue é impressa.

- [ ] **Step 3: Acompanhar o resultado**

A engine da rinha vai comentar o resultado e fechar a issue automaticamente. Para acompanhar:

```bash
ISSUE_NUM=$(gh issue list --repo zanfranceschi/rinha-de-backend-2026 --author steixeira93 --search "rinha/test steixeira93-zig-v2 in:title" --limit 1 --json number -q '.[0].number')
echo "Issue #$ISSUE_NUM"
gh issue view "$ISSUE_NUM" --repo zanfranceschi/rinha-de-backend-2026 --comments
```

Expected: aguardar comentário com resultado JSON (`score_p99`, `score_det`, total). Quando a issue fechar, o resultado oficial está disponível.

- [ ] **Step 4: Registrar resultado no nosso repo**

Anotar o resultado em `docs/superpowers/notes/` ou no README, dependendo do score. Esta etapa é manual e fica fora do plano.

---

## Critérios de "feito"

- [ ] CI publica `api:latest` e `lb:latest` com `index.bin` real embutido na API.
- [ ] Pacotes GHCR `rinha-backend-26-v2-api` e `rinha-backend-26-v2-lb` com `visibility: public`.
- [ ] Smoke local (`docker compose -f deploy/docker-compose.submission.yml up -d` + `smoke.js`) passa 100%.
- [ ] Branch `submission` contém apenas `LICENSE`, `README.md`, `docker-compose.yml`, `info.json`.
- [ ] PR no rinha passa `validate` + `smoke-test` + `merge`.
- [ ] Issue `rinha/test steixeira93-zig-v2` recebe comentário com resultado oficial.
