defmodule SymphonyElixir.DockerScriptsTest do
  use ExUnit.Case, async: true

  @router Path.expand("../docker/repository-router.sh", __DIR__)
  @review_watcher Path.expand("../docker/review-watcher.sh", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-docker-scripts-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "ATRS-123")
    bin = Path.join(root, "bin")
    token_file = Path.join(root, "jira-token")

    File.mkdir_p!(workspace)
    File.mkdir_p!(bin)
    File.write!(token_file, "test-token")

    on_exit(fn -> File.rm_rf!(root) end)

    env = [
      {"GITHUB_ORGANIZATION", "activeviam"},
      {"JIRA_ENDPOINT", "https://jira.example"},
      {"JIRA_PROJECT_KEY", "ATRS"},
      {"JIRA_API_TOKEN_FILE", token_file},
      {"JIRA_REPOSITORY_LABEL_PREFIX", "symphony-repo-"},
      {"PATH", "#{bin}:#{System.get_env("PATH")}"},
      {"SYMPHONY_ROUTING_STATE_DIR", Path.join(root, "routing-errors")}
    ]

    %{bin: bin, env: env, root: root, workspace: workspace}
  end

  test "repository router clones the single organization-scoped repository label", context do
    install_mock_curl(context.bin)
    install_mock_gh(context.bin)
    gh_log = Path.join(context.root, "gh.log")

    env =
      context.env ++
        [
          {"MOCK_GH_LOG", gh_log},
          {"MOCK_JIRA_ISSUE", ~s({"fields":{"labels":["symphony","symphony-repo-second-repo"]}})}
        ]

    assert {output, 0} = System.cmd("bash", [@router], cd: context.workspace, env: env)
    assert output =~ "ATRS-123: using activeviam/second-repo"
    assert File.dir?(Path.join(context.workspace, ".git"))
    assert File.read!(gh_log) =~ "repo clone activeviam/second-repo . -- --depth 1"
  end

  test "repository router rejects duplicate routing labels and comments once", context do
    install_mock_curl(context.bin)
    install_mock_gh(context.bin)
    jira_log = Path.join(context.root, "jira.log")

    env =
      context.env ++
        [
          {"MOCK_JIRA_LOG", jira_log},
          {"MOCK_JIRA_ISSUE", ~s({"fields":{"labels":["symphony-repo-one","symphony-repo-two"]}})}
        ]

    assert {output, 1} =
             System.cmd("bash", [@router], cd: context.workspace, env: env, stderr_to_stdout: true)

    assert output =~ "must have exactly one symphony-repo-<repository> label; found 2"
    assert File.read!(jira_log) =~ "/rest/api/3/issue/ATRS-123/comment"

    assert {_output, 1} =
             System.cmd("bash", [@router], cd: context.workspace, env: env, stderr_to_stdout: true)

    assert File.read!(jira_log) |> String.split("\n", trim: true) |> length() == 1
  end

  test "human-review watcher finds the PR in the Jira-selected repository", context do
    install_watcher_curl(context.bin)
    install_watcher_gh(context.bin)
    gh_log = Path.join(context.root, "gh.log")
    jira_log = Path.join(context.root, "jira.log")

    env =
      context.env ++
        [
          {"MOCK_GH_LOG", gh_log},
          {"MOCK_JIRA_LOG", jira_log},
          {"JIRA_HUMAN_REVIEW_STATE", "Human Review"},
          {"JIRA_REWORK_STATE", "In Progress"},
          {"JIRA_SYMPHONY_LABEL", "symphony"}
        ]

    assert {output, 0} = System.cmd("bash", [@review_watcher], env: env)
    assert output =~ "ATRS-123: moved to In Progress"

    gh_calls = File.read!(gh_log)
    assert gh_calls =~ "repo view activeviam/second-repo"
    assert gh_calls =~ "pr list --repo activeviam/second-repo --state open --head symphony/atrs-123"

    jira_calls = File.read!(jira_log)
    assert jira_calls =~ "/rest/api/3/search/jql"
    assert jira_calls =~ "/rest/api/3/issue/ATRS-123/transitions"
  end

  defp install_mock_curl(bin) do
    write_executable(Path.join(bin, "curl"), """
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "$*" == *"?fields=labels"* ]]; then
      printf '%s' "$MOCK_JIRA_ISSUE"
    elif [[ "$*" == *"/comment"* ]]; then
      if [[ -n "${MOCK_JIRA_LOG:-}" ]]; then
        printf '%s\n' "$*" >>"$MOCK_JIRA_LOG"
      fi
      printf '{}'
    else
      echo "Unexpected curl call: $*" >&2
      exit 1
    fi
    """)
  end

  defp install_mock_gh(bin) do
    write_executable(Path.join(bin, "gh"), """
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -n "${MOCK_GH_LOG:-}" ]]; then
      printf '%s\n' "$*" >>"$MOCK_GH_LOG"
    fi
    case "$*" in
      "repo view activeviam/"*) printf '%s\n' "${3}" ;;
      "repo clone "*) mkdir .git ;;
      *) echo "Unexpected gh call: $*" >&2; exit 1 ;;
    esac
    """)
  end

  defp install_watcher_curl(bin) do
    write_executable(Path.join(bin, "curl"), """
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%s\n' "$*" >>"$MOCK_JIRA_LOG"
    case "$*" in
      *"/rest/api/3/search/jql"*)
        printf '%s' '{"issues":[{"key":"ATRS-123","fields":{"labels":["symphony","symphony-repo-second-repo"]}}],"isLast":true}'
        ;;
      *"/rest/api/3/issue/ATRS-123?fields=status"*)
        printf '%s' '{"fields":{"status":{"name":"Human Review"}}}'
        ;;
      *"/rest/api/3/issue/ATRS-123/transitions"*)
        if [[ "$*" == *"--request GET"* ]]; then
          printf '%s' '{"transitions":[{"id":"42","to":{"name":"In Progress"}}]}'
        else
          printf '{}'
        fi
        ;;
      *"/rest/api/3/issue/ATRS-123/comment"*) printf '{}' ;;
      *) echo "Unexpected curl call: $*" >&2; exit 1 ;;
    esac
    """)
  end

  defp install_watcher_gh(bin) do
    write_executable(Path.join(bin, "gh"), """
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%s\n' "$*" >>"$MOCK_GH_LOG"
    case "$*" in
      "repo view activeviam/second-repo"*) printf '%s\n' 'activeviam/second-repo' ;;
      "pr list --repo activeviam/second-repo"*)
        printf '%s' '[{"number":7,"headRefName":"symphony/atrs-123","headRefOid":"abc123","url":"https://github.example/pr/7"}]'
        ;;
      "api graphql"*)
        printf '%s' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false}]},"reviews":{"nodes":[]},"commits":{"nodes":[{"commit":{"committedDate":"2026-07-17T08:00:00Z"}}]},"comments":{"nodes":[]}}}}}'
        ;;
      *) echo "Unexpected gh call: $*" >&2; exit 1 ;;
    esac
    """)
  end

  defp write_executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end
end
