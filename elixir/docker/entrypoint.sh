#!/usr/bin/env bash
set -euo pipefail

umask 077

if [[ -z "${GITHUB_APP_ID:-}" ]]; then
  echo "GITHUB_APP_ID is required" >&2
  exit 1
fi

if [[ -z "${GITHUB_APP_INSTALLATION_ID:-}" ]]; then
  echo "GITHUB_APP_INSTALLATION_ID is required" >&2
  exit 1
fi

if [[ ! -s "${GITHUB_APP_PRIVATE_KEY_FILE:-}" ]]; then
  echo "GitHub App private key file is missing or empty" >&2
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
git config --global --unset-all credential.https://github.com.helper || true
git config --global --add credential.https://github.com.helper ""
git config --global --add credential.https://github.com.helper "!/usr/local/bin/gh auth git-credential"
git config --global user.name "ActiveViam Symphony"
git config --global user.email "symphony@activeviam.com"

exec /usr/local/bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root /var/log/symphony \
  --port 8080 \
  "${WORKFLOW_PATH}"
