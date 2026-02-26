#!/usr/bin/env bash
set -euo pipefail

# Resolve Render deploy target from:
# - Manual override (workflow_dispatch input)
# - Changed file paths between base/head commits
#
# Expected env (all optional):
#   EVENT_NAME            GitHub event name (e.g. push, workflow_dispatch)
#   MANUAL_TARGET         auto | api | web | both
#   GITHUB_EVENT_BEFORE   github.event.before SHA for push events
#   GITHUB_OUTPUT         GitHub Actions output file path
#
# Emits:
#   target         none | api | web | both
#   reason         explanation string
#   changed_count  number of changed files (or 'manual')
#   changed_files  comma-separated preview (max 20) or 'manual override'

ZERO_SHA="0000000000000000000000000000000000000000"

EVENT_NAME="${EVENT_NAME:-}"
MANUAL_TARGET="${MANUAL_TARGET:-auto}"
GITHUB_EVENT_BEFORE="${GITHUB_EVENT_BEFORE:-}"
OUTPUT_FILE="${GITHUB_OUTPUT:-}"

emit_output() {
  local key="$1"
  local value="$2"

  if [ -n "$OUTPUT_FILE" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$OUTPUT_FILE"
  else
    printf '%s=%s\n' "$key" "$value"
  fi
}

emit_result() {
  local target="$1"
  local reason="$2"
  local changed_count="$3"
  local changed_files="$4"

  emit_output "target" "$target"
  emit_output "reason" "$reason"
  emit_output "changed_count" "$changed_count"
  emit_output "changed_files" "$changed_files"
}

if [ "$EVENT_NAME" = "workflow_dispatch" ] && [ "$MANUAL_TARGET" != "auto" ]; then
  case "$MANUAL_TARGET" in
    api|web|both)
      emit_result "$MANUAL_TARGET" "manual override" "manual" "manual override"
      exit 0
      ;;
    *)
      echo "error: invalid manual target: $MANUAL_TARGET" >&2
      exit 1
      ;;
  esac
fi

head_sha="$(git rev-parse HEAD)"

if [ "$EVENT_NAME" = "push" ] && [ -n "$GITHUB_EVENT_BEFORE" ] && [ "$GITHUB_EVENT_BEFORE" != "$ZERO_SHA" ]; then
  base_sha="$GITHUB_EVENT_BEFORE"
  changed_files="$(git diff --name-only "$base_sha" "$head_sha" || true)"
  reason="auto path routing (push diff ${base_sha:0:7}..${head_sha:0:7})"
elif git rev-parse "${head_sha}^" >/dev/null 2>&1; then
  base_sha="$(git rev-parse "${head_sha}^")"
  changed_files="$(git diff --name-only "$base_sha" "$head_sha" || true)"
  reason="auto path routing (diff ${base_sha:0:7}..${head_sha:0:7})"
else
  changed_files="$(git ls-tree -r --name-only "$head_sha" || true)"
  reason="auto path routing (initial commit snapshot)"
fi

deploy_api=false
deploy_web=false

while IFS= read -r file; do
  [ -n "$file" ] || continue

  case "$file" in
    backend/*)
      deploy_api=true
      ;;
    frontend/*)
      deploy_web=true
      ;;
    scripts/deploy.sh|scripts/resolve_deploy_target.sh|.github/workflows/deploy-render.yml)
      deploy_api=true
      deploy_web=true
      ;;
  esac
done <<< "$changed_files"

target="none"
if [ "$deploy_api" = true ] && [ "$deploy_web" = true ]; then
  target="both"
elif [ "$deploy_api" = true ]; then
  target="api"
elif [ "$deploy_web" = true ]; then
  target="web"
fi

changed_count="$(printf '%s\n' "$changed_files" | sed '/^$/d' | wc -l | tr -d ' ')"
changed_preview="$(printf '%s\n' "$changed_files" | sed '/^$/d' | head -n 20 | paste -sd ',' -)"
if [ -z "$changed_preview" ]; then
  changed_preview="(none)"
fi

emit_result "$target" "$reason" "$changed_count" "$changed_preview"
