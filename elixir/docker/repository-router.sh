#!/usr/bin/env bash
set -euo pipefail

github_organization="${GITHUB_ORGANIZATION:-}"
jira_endpoint="${JIRA_ENDPOINT:-}"
jira_project="${JIRA_PROJECT_KEY:-}"
jira_token_file="${JIRA_API_TOKEN_FILE:-}"
repository_label_prefix="${JIRA_REPOSITORY_LABEL_PREFIX:-symphony-repo-}"
issue_key="$(basename "${PWD}")"

if [[ ! "${github_organization}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
  echo "GITHUB_ORGANIZATION must be a GitHub organization name" >&2
  exit 1
fi

if [[ ! "${jira_project}" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
  echo "JIRA_PROJECT_KEY must be a Jira project key" >&2
  exit 1
fi

if [[ ! "${issue_key}" =~ ^([A-Za-z][A-Za-z0-9_]*)-[0-9]+$ ]]; then
  echo "Workspace name must be an issue key in ${jira_project}" >&2
  exit 1
fi
workspace_project="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')"
jira_project_upper="$(printf '%s' "${jira_project}" | tr '[:lower:]' '[:upper:]')"
if [[ "${workspace_project}" != "${jira_project_upper}" ]]; then
  echo "Workspace name must be an issue key in ${jira_project}" >&2
  exit 1
fi
issue_key="$(printf '%s' "${issue_key}" | tr '[:lower:]' '[:upper:]')"

if [[ -z "${jira_endpoint}" || ! -s "${jira_token_file}" ]]; then
  echo "JIRA_ENDPOINT and JIRA_API_TOKEN_FILE are required" >&2
  exit 1
fi

if [[ -z "${repository_label_prefix}" ]]; then
  echo "JIRA_REPOSITORY_LABEL_PREFIX must not be empty" >&2
  exit 1
fi

jira_endpoint="${jira_endpoint%/}"
jira_token="$(<"${jira_token_file}")"
case "${jira_token}" in
  Bearer\ *|Basic\ *) jira_authorization="${jira_token}" ;;
  *) jira_authorization="Bearer ${jira_token}" ;;
esac

jira_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local args=(
    --fail
    --silent
    --show-error
    --request "${method}"
    --header "Authorization: ${jira_authorization}"
    --header "Accept: application/json"
  )

  if [[ -n "${body}" ]]; then
    args+=(--header "Content-Type: application/json" --data "${body}")
  fi

  curl "${args[@]}" "${jira_endpoint}${path}"
}

routing_state_dir="${SYMPHONY_ROUTING_STATE_DIR:-$(dirname "${PWD}")/.symphony-routing-errors}"
routing_state_file="${routing_state_dir}/${issue_key}"

clear_routing_error() {
  rm -f "${routing_state_file}"
}

fail_routing() {
  local reason="$1"
  local comment="Symphony could not select a repository: ${reason}"
  local previous=""

  install -d -m 0700 "${routing_state_dir}"
  if [[ -f "${routing_state_file}" ]]; then
    previous="$(<"${routing_state_file}")"
  fi

  if [[ "${previous}" != "${reason}" ]]; then
    if jira_request POST "/rest/api/3/issue/${issue_key}/comment" \
      "$(jq -cn --arg text "${comment}" '{body:{type:"doc",version:1,content:[{type:"paragraph",content:[{type:"text",text:$text}]}]}}')" \
      >/dev/null; then
      printf '%s' "${reason}" >"${routing_state_file}"
    else
      echo "Could not add the repository-routing failure to ${issue_key}" >&2
    fi
  fi

  echo "${comment}" >&2
  exit 1
}

issue="$(jira_request GET "/rest/api/3/issue/${issue_key}?fields=labels")"
repository_labels="$(jq -cer --arg prefix "${repository_label_prefix}" \
  '[.fields.labels // [] | .[] | select(type == "string" and startswith($prefix))]' \
  <<<"${issue}")"
repository_label_count="$(jq -r 'length' <<<"${repository_labels}")"

if (( repository_label_count != 1 )); then
  fail_routing "${issue_key} must have exactly one ${repository_label_prefix}<repository> label; found ${repository_label_count}."
fi

repository_label="$(jq -r '.[0]' <<<"${repository_labels}")"
repository_name="${repository_label#"${repository_label_prefix}"}"
if [[ ! "${repository_name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  fail_routing "${repository_label} does not contain a valid repository name."
fi

repository="${github_organization}/${repository_name}"
if ! resolved_repository="$(gh repo view "${repository}" --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"; then
  fail_routing "${repository} is not accessible to the Symphony GitHub App installation."
fi

if [[ "${resolved_repository}" != "${repository}" ]]; then
  fail_routing "${repository} resolved unexpectedly to ${resolved_repository}."
fi

if [[ -d .git ]]; then
  current_repository="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
  if [[ "${current_repository}" != "${resolved_repository}" ]]; then
    fail_routing "this workspace already contains ${current_repository}, but ${issue_key} selects ${resolved_repository}."
  fi
else
  if [[ -n "$(find . -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    fail_routing "the workspace is not empty and does not contain a Git repository."
  fi
  gh repo clone "${resolved_repository}" . -- --depth 1
fi

clear_routing_error
echo "${issue_key}: using ${resolved_repository}"
