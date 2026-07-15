#!/usr/bin/env bash
set -euo pipefail

app_id="${GITHUB_APP_ID:-}"
installation_id="${GITHUB_APP_INSTALLATION_ID:-}"
private_key_file="${GITHUB_APP_PRIVATE_KEY_FILE:-}"

if [[ ! "${app_id}" =~ ^[0-9]+$ ]]; then
  echo "GITHUB_APP_ID must be numeric" >&2
  exit 1
fi

if [[ ! "${installation_id}" =~ ^[0-9]+$ ]]; then
  echo "GITHUB_APP_INSTALLATION_ID must be numeric" >&2
  exit 1
fi

if [[ ! -s "${private_key_file}" ]]; then
  echo "GitHub App private key file is missing or empty" >&2
  exit 1
fi

base64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

now="$(date +%s)"
issued_at="$((now - 60))"
expires_at="$((now + 540))"
header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64url)"
payload="$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "${issued_at}" "${expires_at}" "${app_id}" | base64url)"
unsigned_token="${header}.${payload}"
signature="$(printf '%s' "${unsigned_token}" | openssl dgst -binary -sha256 -sign "${private_key_file}" | base64url)"
jwt="${unsigned_token}.${signature}"

curl -fsS \
  --request POST \
  --header "Authorization: Bearer ${jwt}" \
  --header "Accept: application/vnd.github+json" \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${installation_id}/access_tokens" \
  | jq -er '.token'
