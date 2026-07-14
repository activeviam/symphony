defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, Linear.Client, Tracker}

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @jira_create_comment_tool "jira_create_comment"
  @jira_create_comment_description "Create a comment on a Jira issue in Symphony's configured project."
  @jira_create_comment_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_key", "body"],
    "properties" => %{
      "issue_key" => %{"type" => "string", "description" => "Jira issue key, for example ATRS-123."},
      "body" => %{"type" => "string", "description" => "Plain-text comment body."}
    }
  }

  @jira_transition_issue_tool "jira_transition_issue"
  @jira_transition_issue_description "Transition a Jira issue in Symphony's configured project to a named status."
  @jira_transition_issue_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_key", "state"],
    "properties" => %{
      "issue_key" => %{"type" => "string", "description" => "Jira issue key, for example ATRS-123."},
      "state" => %{"type" => "string", "description" => "Exact destination status name, for example Human Review."}
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @jira_create_comment_tool ->
        execute_jira_create_comment(arguments, opts)

      @jira_transition_issue_tool ->
        execute_jira_transition_issue(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @jira_create_comment_tool,
        "description" => @jira_create_comment_description,
        "inputSchema" => @jira_create_comment_input_schema
      },
      %{
        "name" => @jira_transition_issue_tool,
        "description" => @jira_transition_issue_description,
        "inputSchema" => @jira_transition_issue_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_jira_create_comment(arguments, opts) do
    jira_create_comment = Keyword.get(opts, :jira_create_comment, &Tracker.create_comment/2)

    with {:ok, issue_key, body} <- normalize_jira_arguments(arguments, "body"),
         :ok <- validate_jira_issue_key(issue_key),
         :ok <- jira_create_comment.(issue_key, body) do
      success_response(%{"issueKey" => issue_key, "operation" => "comment_created"})
    else
      {:error, reason} -> failure_response(jira_tool_error_payload(reason))
    end
  end

  defp execute_jira_transition_issue(arguments, opts) do
    jira_transition = Keyword.get(opts, :jira_transition, &Tracker.update_issue_state/2)

    with {:ok, issue_key, state} <- normalize_jira_arguments(arguments, "state"),
         :ok <- validate_jira_issue_key(issue_key),
         :ok <- jira_transition.(issue_key, state) do
      success_response(%{"issueKey" => issue_key, "operation" => "transitioned", "state" => state})
    else
      {:error, reason} -> failure_response(jira_tool_error_payload(reason))
    end
  end

  defp normalize_jira_arguments(arguments, value_key) when is_map(arguments) do
    with {:ok, issue_key} <- required_string(arguments, "issue_key"),
         {:ok, value} <- required_string(arguments, value_key) do
      {:ok, issue_key, value}
    end
  end

  defp normalize_jira_arguments(_arguments, _value_key), do: {:error, :invalid_jira_arguments}

  defp required_string(arguments, key) do
    value = Map.get(arguments, key) || Map.get(arguments, jira_argument_atom(key))

    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_jira_argument, key}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:missing_jira_argument, key}}
    end
  end

  defp jira_argument_atom("issue_key"), do: :issue_key
  defp jira_argument_atom("body"), do: :body
  defp jira_argument_atom("state"), do: :state

  defp validate_jira_issue_key(issue_key) do
    tracker = Config.settings!().tracker
    project_key = tracker.project_slug |> to_string() |> String.trim() |> String.upcase()

    cond do
      tracker.kind != "jira" ->
        {:error, :jira_tracker_not_configured}

      project_key == "" ->
        {:error, :missing_jira_project_key}

      Regex.match?(~r/^#{Regex.escape(project_key)}-\d+$/i, issue_key) ->
        :ok

      true ->
        {:error, {:jira_issue_outside_project, project_key}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp success_response(payload) do
    dynamic_tool_response(true, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp jira_tool_error_payload(:invalid_jira_arguments) do
    %{"error" => %{"message" => "Jira tools require a JSON object with the documented fields."}}
  end

  defp jira_tool_error_payload({:missing_jira_argument, key}) do
    %{"error" => %{"message" => "Jira tool argument `#{key}` must be a non-empty string."}}
  end

  defp jira_tool_error_payload(:jira_tracker_not_configured) do
    %{"error" => %{"message" => "Jira tools are unavailable because `tracker.kind` is not `jira`."}}
  end

  defp jira_tool_error_payload(:missing_jira_project_key) do
    %{"error" => %{"message" => "Jira tools require `tracker.project_slug` to scope writes."}}
  end

  defp jira_tool_error_payload({:jira_issue_outside_project, project_key}) do
    %{"error" => %{"message" => "Jira writes are restricted to project #{project_key}."}}
  end

  defp jira_tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Jira tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
