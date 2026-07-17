#!/usr/bin/env bash
set -euo pipefail

github_organization="${GITHUB_ORGANIZATION:-}"
jira_endpoint="${JIRA_ENDPOINT:-}"
jira_project="${JIRA_PROJECT_KEY:-}"
jira_token_file="${JIRA_API_TOKEN_FILE:-}"
repository_label_prefix="${JIRA_REPOSITORY_LABEL_PREFIX:-symphony-repo-}"
symphony_label="${JIRA_SYMPHONY_LABEL:-symphony}"
human_review_state="${JIRA_HUMAN_REVIEW_STATE:-Human Review}"
rework_state="${JIRA_REWORK_STATE:-In Progress}"

if [[ ! "${github_organization}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
  echo "GITHUB_ORGANIZATION must be a GitHub organization name" >&2
  exit 1
fi

if [[ ! "${jira_project}" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
  echo "JIRA_PROJECT_KEY must be a Jira project key" >&2
  exit 1
fi

if [[ -z "${repository_label_prefix}" || -z "${symphony_label}" ]]; then
  echo "JIRA_REPOSITORY_LABEL_PREFIX and JIRA_SYMPHONY_LABEL must not be empty" >&2
  exit 1
fi

if [[ -z "${jira_endpoint}" || ! -s "${jira_token_file}" ]]; then
  echo "JIRA_ENDPOINT and JIRA_API_TOKEN_FILE are required" >&2
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

transition_to_rework() {
  local issue_key="$1"
  local pr_url="$2"
  local status transition_id comment

  status="$(jira_request GET "/rest/api/3/issue/${issue_key}?fields=status" | jq -r '.fields.status.name')"
  if [[ "${status}" != "${human_review_state}" ]]; then
    return
  fi

  transition_id="$(jira_request GET "/rest/api/3/issue/${issue_key}/transitions" \
    | jq -er --arg state "${rework_state}" '[.transitions[] | select(.to.name == $state) | .id][0]')"

  jira_request POST "/rest/api/3/issue/${issue_key}/transitions" \
    "$(jq -cn --arg id "${transition_id}" '{transition:{id:$id}}')" >/dev/null

  comment="Human review added unresolved findings on ${pr_url}. Symphony returned this ticket to ${rework_state}."
  jira_request POST "/rest/api/3/issue/${issue_key}/comment" \
    "$(jq -cn --arg text "${comment}" '{body:{type:"doc",version:1,content:[{type:"paragraph",content:[{type:"text",text:$text}]}]}}')" >/dev/null
  echo "${issue_key}: moved to ${rework_state} for unresolved human review findings"
}

# The GraphQL variable references are intentionally passed through literally.
# shellcheck disable=SC2016
graphql_query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){nodes{isResolved isOutdated}}reviews(last:100){nodes{state commit{oid}}}commits(last:1){nodes{commit{committedDate}}}comments(last:100){nodes{createdAt author{__typename} authorAssociation}}}}}'

inspect_pull_request() {
  local issue_key="$1"
  local repository="$2"
  local number="$3"
  local head_oid="$4"
  local pr_url="$5"
  local owner name review_data unresolved_threads current_changes_requested current_human_comments

  owner="${repository%%/*}"
  name="${repository#*/}"
  review_data="$(gh api graphql \
    -F owner="${owner}" \
    -F name="${name}" \
    -F number="${number}" \
    -f query="${graphql_query}")"

  unresolved_threads="$(jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false and .isOutdated == false)] | length' <<<"${review_data}")"
  current_changes_requested="$(jq --arg oid "${head_oid}" '[.data.repository.pullRequest.reviews.nodes[] | select(.state == "CHANGES_REQUESTED" and .commit.oid == $oid)] | length' <<<"${review_data}")"
  current_human_comments="$(jq '[.data.repository.pullRequest as $pr | $pr.comments.nodes[] | select(
    .author.__typename == "User" and
    (.authorAssociation == "OWNER" or .authorAssociation == "MEMBER" or .authorAssociation == "COLLABORATOR") and
    .createdAt > $pr.commits.nodes[0].commit.committedDate
  )] | length' <<<"${review_data}")"

  if (( unresolved_threads > 0 || current_changes_requested > 0 || current_human_comments > 0 )); then
    transition_to_rework "${issue_key}" "${pr_url}"
  fi
}

inspect_issue() {
  local issue_json="$1"
  local issue_key repository_labels repository_label_count repository_label
  local branch_issue_key repository_name repository resolved_repository pull_requests

  issue_key="$(jq -er '.key' <<<"${issue_json}")"
  branch_issue_key="$(printf '%s' "${issue_key}" | tr '[:upper:]' '[:lower:]')"
  repository_labels="$(jq -cer --arg prefix "${repository_label_prefix}" \
    '[.fields.labels // [] | .[] | select(type == "string" and startswith($prefix))]' \
    <<<"${issue_json}")"
  repository_label_count="$(jq -r 'length' <<<"${repository_labels}")"

  if (( repository_label_count != 1 )); then
    echo "${issue_key}: expected exactly one ${repository_label_prefix}<repository> label; skipping" >&2
    return
  fi

  repository_label="$(jq -r '.[0]' <<<"${repository_labels}")"
  repository_name="${repository_label#"${repository_label_prefix}"}"
  if [[ ! "${repository_name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "${issue_key}: ${repository_label} is not a valid repository label; skipping" >&2
    return
  fi

  repository="${github_organization}/${repository_name}"
  if ! resolved_repository="$(gh repo view "${repository}" --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"; then
    echo "${issue_key}: ${repository} is not accessible to the Symphony GitHub App; skipping" >&2
    return
  fi
  if [[ "${resolved_repository}" != "${repository}" ]]; then
    echo "${issue_key}: ${repository} resolved unexpectedly to ${resolved_repository}; skipping" >&2
    return
  fi

  pull_requests="$(gh pr list \
    --repo "${resolved_repository}" \
    --state open \
    --head "symphony/${branch_issue_key}" \
    --json number,headRefName,headRefOid,url)"

  while IFS=$'\t' read -r number branch head_oid pr_url; do
    [[ -n "${number}" ]] || continue
    [[ "${branch}" == "symphony/${branch_issue_key}" ]] || continue
    inspect_pull_request "${issue_key}" "${resolved_repository}" "${number}" "${head_oid}" "${pr_url}"
  done < <(jq -r '.[] | [.number, .headRefName, .headRefOid, .url] | @tsv' <<<"${pull_requests}")
}

jql_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  printf '%s' "${value//\"/\\\"}"
}

jql="project = ${jira_project} AND status = \"$(jql_escape "${human_review_state}")\" AND labels = \"$(jql_escape "${symphony_label}")\""
next_page_token=""

while :; do
  search_body="$(jq -cn \
    --arg jql "${jql}" \
    --arg next_page_token "${next_page_token}" \
    '{jql:$jql,fields:["labels"],maxResults:100} + if $next_page_token == "" then {} else {nextPageToken:$next_page_token} end')"
  search_result="$(jira_request POST "/rest/api/3/search/jql" "${search_body}")"

  while IFS= read -r encoded_issue; do
    [[ -n "${encoded_issue}" ]] || continue
    issue_json="$(printf '%s' "${encoded_issue}" | base64 -d)"
    if ! inspect_issue "${issue_json}"; then
      echo "Could not inspect human review findings for $(jq -r '.key // "unknown issue"' <<<"${issue_json}")" >&2
    fi
  done < <(jq -r '.issues[] | @base64' <<<"${search_result}")

  if [[ "$(jq -r '.isLast // false' <<<"${search_result}")" == "true" ]]; then
    break
  fi
  next_page_token="$(jq -r '.nextPageToken // empty' <<<"${search_result}")"
  [[ -n "${next_page_token}" ]] || break
done
