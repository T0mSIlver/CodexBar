#!/usr/bin/env bash
# Runs `cost --provider codex` against synthetic Codex sessions in a throwaway home.
# Guards #4672: the static musl CLI crashed (SIGSEGV) on any non-empty session file.

set -euo pipefail

BIN="${1:-}"
if [[ -z "$BIN" || ! -x "$BIN" ]]; then
  printf 'Usage: %s <CodexBarCLI binary>\n' "$(basename "$0")" >&2
  exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

day_dir="$(date -u +%Y/%m/%d)"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

run_case() {
  local name="$1"
  local contents="$2"
  local home="$work/$name"
  local sessions="$home/.codex/sessions/$day_dir"
  mkdir -p "$sessions"
  if [[ -n "$contents" ]]; then
    printf '%s\n' "$contents" > "$sessions/rollout-smoke.jsonl"
  fi

  local status=0
  HOME="$home" CODEX_HOME="$home/.codex" XDG_CONFIG_HOME="$home/.config" XDG_CACHE_HOME="$home/.cache" \
    timeout 120 "$BIN" cost --provider codex --json > "$home/out.json" 2> "$home/err.txt" || status=$?
  if [[ "$status" -ne 0 ]]; then
    printf 'cost --provider codex failed for the %s session (exit %s)\n' "$name" "$status" >&2
    cat "$home/err.txt" >&2 || true
    exit 1
  fi
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$home/out.json"
  printf 'ok: %s session\n' "$name"
}

run_case empty ""
run_case object '{}'
run_case usage "$(printf '%s\n%s\n%s' \
  '{"type":"session_meta","payload":{"id":"smoke-session"}}' \
  "{\"type\":\"turn_context\",\"timestamp\":\"$now\",\"payload\":{\"model\":\"gpt-5.2-codex\"}}" \
  "{\"type\":\"event_msg\",\"timestamp\":\"$now\",\"payload\":{\"type\":\"token_count\",\"info\":{\"model\":\"gpt-5.2-codex\",\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":0,\"output_tokens\":10,\"reasoning_output_tokens\":0}}}}")"
