---
tracker:
  kind: jira
  endpoint: https://activeviam.atlassian.net
  api_key_file: $JIRA_API_TOKEN_FILE
  project_slug: ATRS
  required_labels:
    - symphony
  active_states:
    - Selected for Development
    - In Progress
  terminal_states:
    - Human Review
    - Done
    - Cancelled
    - Canceled
    - Duplicate
polling:
  interval_ms: 30000
workspace:
  root: /workspaces
hooks:
  after_create: |
    gh repo clone activeviam/atoti-risk-admin-dashboard . -- --depth 1
agent:
  max_concurrent_agents: 1
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---

You are implementing Jira issue `{{ issue.identifier }}` in
`activeviam/atoti-risk-admin-dashboard`.

Issue title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

{% if issue.description %}
{{ issue.description }}
{% else %}
No description was provided.
{% endif %}

This is an unattended prototype run. Work only in the provided repository copy and never merge a
pull request. The issue has already passed Symphony's `symphony` label gate.

1. Inspect the repository instructions and current state before editing.
2. If the issue is in `Selected for Development`, use `jira_transition_issue` to move it to
   `In Progress` before implementation.
3. Reproduce or otherwise establish the current behavior, then implement the smallest complete
   change that satisfies the issue.
4. Run the repository's relevant validation and review the resulting diff.
5. Create a focused branch named `symphony/{{ issue.identifier | downcase }}`, commit the change,
   push it, and open a draft pull request with `gh`. Never merge it.
6. Use `jira_create_comment` to leave one concise handoff comment containing the pull request URL,
   validation performed, and any residual risk.
7. After the pull request exists and validation passes, use `jira_transition_issue` to move the
   issue to `Human Review`. Do not move it to `Done`.

If a missing permission, secret, or requirement prevents completion, do not invent a workaround.
Comment with the exact blocker and leave the issue in `In Progress` for a human to resolve.
