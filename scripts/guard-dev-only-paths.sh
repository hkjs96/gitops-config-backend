#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────
# CI Guard: dev overlay만 변경 허용
# stg/prd overlay 변경 시 즉시 실패 → PR + Manual Sync 플로우 강제
# 사용: BASE_REF=origin/main ./scripts/guard-dev-only-paths.sh
# ──────────────────────────────────────────────────────────
set -euo pipefail

BASE_REF="${BASE_REF:-origin/main}"

CHANGED="$(git diff --name-only "${BASE_REF}...HEAD" || true)"
if [[ -z "${CHANGED}" ]]; then
  echo "[OK] 변경 파일 없음"
  exit 0
fi

# dev overlay values만 허용
ALLOWED_REGEX='^apps/(user-service|order-service|api-gateway)/overlays/dev/values\.ya?ml$'

DISALLOWED="$(echo "${CHANGED}" | grep -Ev "${ALLOWED_REGEX}" || true)"
if [[ -n "${DISALLOWED}" ]]; then
  echo "[DENY] dev overlay 외 파일이 변경됨. stg/prd 변경은 별도 PR + 승인 필요."
  echo "변경된 파일:"
  echo "${DISALLOWED}"
  exit 1
fi

echo "[OK] dev overlay만 변경됨 — 자동 배포 허용"
