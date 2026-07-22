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
    - Blocked
    - AI Review
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

{% if issue.comments != empty %}
Jira comments (oldest to newest):
{% for comment in issue.comments %}
- {{ comment.created_at }} — {{ comment.author }}: {{ comment.body }}
{% endfor %}
{% endif %}

This is an unattended prototype run. Work only in the provided repository copy and never merge a
pull request. The issue has already passed Symphony's `symphony` label gate.

1. Inspect the repository instructions and current state before editing.
2. If the issue is in `Selected for Development`, use `jira_transition_issue` to move it to
   `In Progress` before implementation.
3. Look for an existing pull request whose head is
   `symphony/{{ issue.identifier | downcase }}`. If it exists, check it out and read all current
   AI-review comments, human reviews, and unresolved review threads before changing code.
4. Reproduce the issue or review finding, then implement the smallest complete fix. Address every
   actionable finding and resolve only the GitHub review threads that the new code actually fixes.
5. Run the repository's relevant validation and review the resulting diff.
6. Create or update the focused branch `symphony/{{ issue.identifier | downcase }}`, commit the
   change, push it, and create or update its draft pull request with `gh`. Never merge it.
7. Use `jira_create_comment` to leave one concise handoff comment containing the pull request URL,
   validation performed, fixed review findings, and any residual risk.
8. After the pull request is updated and validation passes, use `jira_transition_issue` to move
   the issue to `AI Review`. Never move it directly to `Human Review` or `Done`.

If a missing permission, secret, external dependency, or human decision prevents completion, do
not invent a workaround or repeatedly retry it. Leave one precise Jira comment describing what is
blocked, its impact, and the human action needed, then move the issue to `Blocked`. When a human
returns it to `Selected for Development`, read and apply the newest Jira guidance before doing any
new work.
