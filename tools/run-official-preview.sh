#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

compose_file="${COMPOSE_FILE:-deploy/docker-compose.submission.yml}"
project_name="${COMPOSE_PROJECT_NAME:-rinha_preview}"
official_ref="${OFFICIAL_REF:-main}"
submission_ref="${SUBMISSION_REF:-}"
work_dir="${WORK_DIR:-.tmp/official-preview}"
k6_image="${K6_IMAGE:-grafana/k6:latest}"
keep_stack="${KEEP_STACK:-0}"
skip_pull="${SKIP_PULL:-0}"
verbose_k6="${VERBOSE_K6:-0}"
allow_non_amd64="${ALLOW_NON_AMD64:-0}"

official_raw="https://raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/${official_ref}"
stats_pid=""

log() {
  printf 'official-preview: %s\n' "$*"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

cleanup() {
  if [[ -n "${stats_pid}" ]]; then
    kill "${stats_pid}" >/dev/null 2>&1 || true
    wait "${stats_pid}" >/dev/null 2>&1 || true
  fi

  if [[ "${keep_stack}" != "1" ]]; then
    docker compose -p "${project_name}" -f "${compose_file}" down -v --remove-orphans >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

need_cmd docker
need_cmd curl
need_cmd jq

if [[ "$(uname -m)" != "x86_64" && "${allow_non_amd64}" != "1" ]]; then
  cat >&2 <<'EOF'
This benchmark must run on linux/amd64 to be comparable with the Rinha runner.
Set ALLOW_NON_AMD64=1 only for smoke tests. ARM/Mac Docker is not a valid latency proxy here.
EOF
  exit 1
fi

log "compose=${compose_file} project=${project_name} official_ref=${official_ref}"
log "host: $(uname -a)"
if command -v lsb_release >/dev/null 2>&1; then
  lsb_release -a 2>/dev/null | sed 's/^/official-preview: os: /'
elif [[ -r /etc/os-release ]]; then
  sed 's/^/official-preview: os: /' /etc/os-release
fi
if command -v lscpu >/dev/null 2>&1; then
  lscpu | sed -n '1,22p' | sed 's/^/official-preview: cpu: /'
fi
docker version --format 'official-preview: docker: client={{.Client.Version}} server={{.Server.Version}}' || true
docker compose version | sed 's/^/official-preview: compose: /'

if [[ ! -f "${compose_file}" ]]; then
  printf 'compose file not found: %s\n' "${compose_file}" >&2
  exit 1
fi

mkdir -p "${work_dir}/test"
if [[ -n "${submission_ref}" ]]; then
  mkdir -p "${work_dir}/submission"
  git show "${submission_ref}:docker-compose.yml" >"${work_dir}/submission/docker-compose.yml"
  compose_file="${work_dir}/submission/docker-compose.yml"
  log "using docker-compose.yml from git ref ${submission_ref}"
fi

log "downloading official preview files"
curl -fsSL "${official_raw}/config.json" -o "${work_dir}/config.json"
curl -fsSL "${official_raw}/run.sh" -o "${work_dir}/run.sh"
curl -fsSL "${official_raw}/test/test.js" -o "${work_dir}/test/test.js"
curl -fsSL "${official_raw}/test/test-data.json" -o "${work_dir}/test/test-data.json"
chmod +x "${work_dir}/run.sh"
chmod -R 777 "${work_dir}"

health_endpoint="$(jq -r '.submission_health_check_endpoint' "${work_dir}/config.json")"
health_retries="$(jq -r '.submission_health_check_retries' "${work_dir}/config.json")"
health_interval_ms="$(jq -r '.submission_health_check_interval_ms' "${work_dir}/config.json")"
max_cpu="$(jq -r '.max_cpu' "${work_dir}/config.json")"
max_memory_mb="$(jq -r '.max_memory_mb' "${work_dir}/config.json")"

log "official limits: max_cpu=${max_cpu} max_memory_mb=${max_memory_mb}"
log "healthcheck: endpoint=${health_endpoint} retries=${health_retries} interval_ms=${health_interval_ms}"
log "dataset: $(wc -c <"${work_dir}/test/test-data.json") bytes"

log "resolved compose config"
docker compose -p "${project_name}" -f "${compose_file}" config >"${work_dir}/compose.resolved.yml"
sed 's/^/official-preview: compose: /' "${work_dir}/compose.resolved.yml"
docker compose -p "${project_name}" -f "${compose_file}" config --format json >"${work_dir}/compose.resolved.json" 2>/dev/null || true

docker compose -p "${project_name}" -f "${compose_file}" down -v --remove-orphans >/dev/null 2>&1 || true
if [[ "${skip_pull}" != "1" ]]; then
  log "pulling participant images"
  docker compose -p "${project_name}" -f "${compose_file}" pull
  log "pulling k6 image ${k6_image}"
  docker pull "${k6_image}" >/dev/null
fi

log "starting participant stack"
docker compose -p "${project_name}" -f "${compose_file}" up -d

log "waiting for readiness"
ready_start="$(date +%s)"
for attempt in $(seq 1 "${health_retries}"); do
  if curl -fsS --max-time 1 "${health_endpoint}" >/dev/null; then
    ready_end="$(date +%s)"
    log "ready after $((ready_end - ready_start))s"
    break
  fi

  if [[ "${attempt}" == "${health_retries}" ]]; then
    log "readiness failed"
    docker compose -p "${project_name}" -f "${compose_file}" ps
    docker compose -p "${project_name}" -f "${compose_file}" logs --no-color --tail=300
    exit 1
  fi

  sleep "$(awk "BEGIN { printf \"%.3f\", ${health_interval_ms}/1000 }")"
done

log "container resource config"
docker compose -p "${project_name}" -f "${compose_file}" ps
docker compose -p "${project_name}" -f "${compose_file}" ps -q \
  | xargs docker inspect --format 'inspect {{.Name}} image={{.Config.Image}} nanocpus={{.HostConfig.NanoCpus}} mem={{.HostConfig.Memory}} cpuquota={{.HostConfig.CpuQuota}} cpuperiod={{.HostConfig.CpuPeriod}}'

log "container cgroup limits"
while IFS= read -r cid; do
  name="$(docker inspect --format '{{.Name}}' "${cid}" | sed 's#^/##')"
  printf 'official-preview: cgroup %s ' "${name}"
  docker exec "${cid}" sh -c 'printf "cpu.max="; cat /sys/fs/cgroup/cpu.max 2>/dev/null || printf "n/a\n"; printf "memory.max="; cat /sys/fs/cgroup/memory.max 2>/dev/null || printf "n/a\n"' || true
done < <(docker compose -p "${project_name}" -f "${compose_file}" ps -q)

stats_log="${work_dir}/docker-stats.log"
(
  while true; do
    date -u '+stats-ts %Y-%m-%dT%H:%M:%SZ'
    docker stats --no-stream --format 'stats {{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}} pids={{.PIDs}}'
    sleep 2
  done
) >"${stats_log}" 2>&1 &
stats_pid="$!"

log "running official k6 preview script"
k6_exit=0
if [[ "${verbose_k6}" == "1" ]]; then
  docker run --rm --network host -w /work \
    -v "${repo_root}/${work_dir}:/work" \
    "${k6_image}" run test/test.js || k6_exit="$?"
else
  docker run --rm --network host -w /work \
    -v "${repo_root}/${work_dir}:/work" \
    "${k6_image}" run test/test.js >/dev/null || k6_exit="$?"
fi

kill "${stats_pid}" >/dev/null 2>&1 || true
wait "${stats_pid}" >/dev/null 2>&1 || true
stats_pid=""

if [[ ! -f "${work_dir}/test/results.json" ]]; then
  log "k6 did not create results.json"
  docker compose -p "${project_name}" -f "${compose_file}" logs --no-color --tail=300
  exit "${k6_exit:-1}"
fi

log "official result"
jq . "${work_dir}/test/results.json"

log "stats during test"
cat "${stats_log}"

log "participant logs"
docker compose -p "${project_name}" -f "${compose_file}" logs --no-color --tail=300

if [[ "${k6_exit}" != "0" ]]; then
  log "k6 exited with status ${k6_exit}"
  exit "${k6_exit}"
fi
