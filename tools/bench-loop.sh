#!/usr/bin/env bash
set -euo pipefail

# Run N k6 benches back-to-back against the already-running local stack.
# Prints a one-line summary per run + a min/max/median over the batch.
# Usage: tools/bench-loop.sh [N]

n="${1:-5}"
repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

results_file=".tmp/bench-loop-$(date +%s).log"
: >"${results_file}"

printf '%-3s  %-9s  %-12s  %s\n' "#" "p99(ms)" "score" "fp/fn/err"
printf '%s\n' "---"
for i in $(seq 1 "${n}"); do
    raw="$(./tools/run-local-k6.sh --no-build --keep 2>&1)"
    p99="$(printf '%s\n' "${raw}" | grep '"p99":' | head -1 | sed -E 's/.*"p99": "([0-9.]+)ms".*/\1/')"
    score="$(printf '%s\n' "${raw}" | grep '"final_score":' | head -1 | sed -E 's/.*"final_score": ([-0-9.]+).*/\1/')"
    fp="$(printf '%s\n' "${raw}" | grep '"false_positive_detections":' | head -1 | sed -E 's/.*: ([0-9]+).*/\1/')"
    fn="$(printf '%s\n' "${raw}" | grep '"false_negative_detections":' | head -1 | sed -E 's/.*: ([0-9]+).*/\1/')"
    err="$(printf '%s\n' "${raw}" | grep '"http_errors":' | head -1 | sed -E 's/.*: ([0-9]+).*/\1/')"
    line="$(printf '%-3s  %-9s  %-12s  %s/%s/%s\n' "${i}" "${p99:-?}" "${score:-?}" "${fp:-?}" "${fn:-?}" "${err:-?}")"
    printf '%s\n' "${line}"
    printf '%s\n' "${line}" >>"${results_file}"
done

printf '%s\n' "---"
printf 'log: %s\n' "${results_file}"
printf 'min p99: '; sort -g <(awk '{print $2}' "${results_file}") | head -1
printf 'max p99: '; sort -g <(awk '{print $2}' "${results_file}") | tail -1
printf 'median p99: '; sort -g <(awk '{print $2}' "${results_file}") | awk -v n="$(wc -l <"${results_file}" | tr -d ' ')" 'NR == int((n+1)/2)'
