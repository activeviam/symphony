#!/usr/bin/env bash
set -euo pipefail

umask 077

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "GH_TOKEN is required for the temporary pilot" >&2
  exit 1
fi

if [[ -z "${AWS_REGION:-}" ]]; then
  echo "AWS_REGION is required for the Amazon Bedrock provider" >&2
  exit 1
fi

if [[ ! -s "${WORKFLOW_PATH}" ]]; then
  echo "Workflow file not found or empty: ${WORKFLOW_PATH}" >&2
  exit 1
fi

install -d -m 0700 "${CODEX_HOME}"

gh auth setup-git
git config --global user.name "ActiveViam Symphony"
git config --global user.email "symphony@activeviam.com"

exec /usr/local/bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root /var/log/symphony \
  --port 8080 \
  "${WORKFLOW_PATH}"
