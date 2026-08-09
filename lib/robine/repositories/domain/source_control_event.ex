defmodule Robine.Repositories.Domain.SourceControlEvent do
  @moduledoc "Pure normalization of authenticated provider deliveries into Robine triggers."

  alias Robine.Repositories.Domain.Delivery

  @github_pull_actions ~w(opened reopened synchronize ready_for_review)
  @gitlab_merge_actions ~w(open reopen update)
  @forgejo_pull_actions ~w(opened reopened synchronize synchronized)

  @spec normalize(Delivery.t()) :: {:ok, map()} | {:ignore, term()} | {:error, term()}
  def normalize(%Delivery{provider: :github, event: event, payload: payload}),
    do: github(event, payload)

  def normalize(%Delivery{provider: :gitlab, event: event, payload: payload}),
    do: gitlab(event, payload)

  def normalize(%Delivery{provider: :forgejo, event: event, payload: payload}),
    do: forgejo(event, payload)

  def normalize(%Delivery{event: event}), do: {:ignore, {:unsupported_event, event}}

  defp github(
         "push",
         %{
           "repository" => %{"id" => repository_id},
           "after" => sha,
           "ref" => "refs/heads/" <> branch
         } = payload
       )
       when is_integer(repository_id) and is_binary(sha),
       do: event(:push, repository_id, sha, branch, actor(:github, payload))

  defp github(
         "push",
         %{
           "repository" => %{"id" => repository_id},
           "after" => sha,
           "ref" => "refs/tags/" <> tag
         } = payload
       )
       when is_integer(repository_id) and is_binary(sha),
       do:
         event(
           :tag,
           repository_id,
           tag_commit_sha(payload, sha),
           tag,
           actor(:github, payload)
         )

  defp github("pull_request", %{"action" => action}) when action not in @github_pull_actions,
    do: {:ignore, :pull_request_action}

  defp github("pull_request", %{"pull_request" => %{"draft" => true}}),
    do: {:ignore, :draft_pull_request}

  defp github("pull_request", payload) do
    with %{"repository" => %{"id" => repository_id}, "pull_request" => pull_request} <- payload,
         %{
           "head" => %{"sha" => sha, "repo" => %{"full_name" => head_name}},
           "base" => %{"ref" => branch, "repo" => %{"full_name" => base_name}}
         } <- pull_request do
      if head_name == base_name,
        do: event(:pull_request, repository_id, sha, branch, actor(:github, payload)),
        else: {:ignore, :fork_pull_request}
    else
      _invalid -> {:error, {:invalid_webhook, :pull_request_payload}}
    end
  end

  defp github(event, _payload), do: {:ignore, {:unsupported_event, event}}

  defp gitlab(
         event_name,
         %{
           "project" => %{"id" => repository_id},
           "after" => sha,
           "ref" => "refs/heads/" <> branch
         } = payload
       )
       when event_name in ["push", "Push Hook"] and is_integer(repository_id) and
              is_binary(sha),
       do: event(:push, repository_id, sha, branch, actor(:gitlab, payload))

  defp gitlab(event_name, payload) when event_name in ["merge_request", "Merge Request Hook"] do
    with %{
           "project" => %{"id" => repository_id},
           "object_attributes" => attributes
         } <- payload,
         action when action in @gitlab_merge_actions <- attributes["action"],
         false <- attributes["draft"] == true or draft_title?(attributes["title"]),
         source when is_integer(source) <- attributes["source_project_id"],
         target when is_integer(target) <- attributes["target_project_id"],
         true <- source == target,
         sha when is_binary(sha) <- get_in(attributes, ["last_commit", "id"]),
         branch when is_binary(branch) <- attributes["target_branch"] do
      event(:pull_request, repository_id, sha, branch, actor(:gitlab, payload))
    else
      action when is_binary(action) and action not in @gitlab_merge_actions ->
        {:ignore, :pull_request_action}

      true ->
        {:ignore, :draft_or_fork_pull_request}

      _invalid ->
        {:error, {:invalid_webhook, :merge_request_payload}}
    end
  end

  defp gitlab(event, _payload), do: {:ignore, {:unsupported_event, event}}

  defp forgejo(
         "push",
         %{
           "repository" => %{"id" => repository_id},
           "after" => sha,
           "ref" => "refs/heads/" <> branch
         } = payload
       )
       when is_integer(repository_id) and is_binary(sha),
       do: event(:push, repository_id, sha, branch, actor(:forgejo, payload))

  defp forgejo("pull_request", %{"action" => action}) when action not in @forgejo_pull_actions,
    do: {:ignore, :pull_request_action}

  defp forgejo("pull_request", payload) do
    with %{"repository" => %{"id" => repository_id}, "pull_request" => pull_request} <- payload,
         false <- pull_request["draft"] == true,
         %{
           "head" => %{"sha" => sha, "repo" => %{"full_name" => head_name}},
           "base" => %{"ref" => branch, "repo" => %{"full_name" => base_name}}
         } <- pull_request do
      if head_name == base_name,
        do: event(:pull_request, repository_id, sha, branch, actor(:forgejo, payload)),
        else: {:ignore, :fork_pull_request}
    else
      true -> {:ignore, :draft_pull_request}
      _invalid -> {:error, {:invalid_webhook, :pull_request_payload}}
    end
  end

  defp forgejo(event, _payload), do: {:ignore, {:unsupported_event, event}}

  defp event(type, repository_id, sha, branch, actor)
       when is_integer(repository_id) and is_binary(branch) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha) and byte_size(branch) in 1..255,
      do:
        {:ok, %{type: type, repository_id: repository_id, sha: sha, branch: branch, actor: actor}},
      else: {:error, {:invalid_webhook, :commit}}
  end

  defp actor(:github, %{"sender" => %{"login" => value}}), do: actor_value(:github, value)
  defp actor(:github, %{"pusher" => %{"name" => value}}), do: actor_value(:github, value)
  defp actor(:gitlab, %{"user_username" => value}), do: actor_value(:gitlab, value)
  defp actor(:gitlab, %{"user" => %{"username" => value}}), do: actor_value(:gitlab, value)
  defp actor(:forgejo, %{"sender" => %{"login" => value}}), do: actor_value(:forgejo, value)
  defp actor(provider, _payload), do: "#{provider}:unknown"

  defp actor_value(provider, value) when is_binary(value) and value != "",
    do: "#{provider}:#{String.slice(value, 0, 240)}"

  defp actor_value(provider, _value), do: "#{provider}:unknown"

  defp tag_commit_sha(%{"head_commit" => %{"id" => commit_sha}}, _tag_object_sha)
       when is_binary(commit_sha),
       do: commit_sha

  defp tag_commit_sha(_payload, tag_object_sha), do: tag_object_sha

  defp draft_title?(value) when is_binary(value),
    do: String.starts_with?(String.downcase(value), ["draft:", "wip:"])

  defp draft_title?(_value), do: false
end
