#!/usr/bin/env bash
set -euo pipefail

repository="${GITHUB_REPOSITORY:-}"
jira_endpoint="${JIRA_ENDPOINT:-}"
jira_project="${JIRA_PROJECT_KEY:-}"
jira_token_file="${JIRA_API_TOKEN_FILE:-}"
human_review_state="${JIRA_HUMAN_REVIEW_STATE:-Human Review}"
rework_state="${JIRA_REWORK_STATE:-In Progress}"

if [[ ! "${repository}" =~ ^[^/]+/[^/]+$ ]]; then
  echo "GITHUB_REPOSITORY must use owner/repository format" >&2
  exit 1
fi

if [[ -z "${jira_endpoint}" || -z "${jira_project}" || ! -s "${jira_token_file}" ]]; then
  echo "JIRA_ENDPOINT, JIRA_PROJECT_KEY, and JIRA_API_TOKEN_FILE are required" >&2
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

owner="${repository%%/*}"
name="${repository#*/}"
# The GraphQL variable references are intentionally passed through literally.
# shellcheck disable=SC2016
graphql_query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){nodes{isResolved isOutdated}}reviews(last:100){nodes{state commit{oid}}}commits(last:1){nodes{commit{committedDate}}}comments(last:100){nodes{createdAt author{__typename} authorAssociation}}}}}'

while IFS=$'\t' read -r number branch head_oid pr_url; do
  [[ -n "${number}" ]] || continue
  if [[ ! "${branch}" =~ ^symphony/([A-Za-z]+-[0-9]+)$ ]]; then
    continue
  fi

  issue_key="${BASH_REMATCH[1]^^}"
  if [[ "${issue_key%%-*}" != "${jira_project^^}" ]]; then
    continue
  fi

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
done < <(gh api --paginate "repos/${repository}/pulls?state=open&per_page=100" \
  --jq '.[] | [.number, .head.ref, .head.sha, .html_url] | @tsv')
