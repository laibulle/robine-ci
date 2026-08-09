defmodule Robine.Release.AcceptanceEvidence do
  @moduledoc """
  Strict validation for the two external MVP acceptance attestations.

  The verifier deliberately validates evidence shape and internally consistent
  timings. It does not claim that a local JSON file proves an external event;
  release reviewers must still open the recorded GitHub check and review the
  named manual accessibility session.
  """

  @max_file_bytes 1_048_576
  @supported_hosts ["Ubuntu Server 24.04 LTS", "Ubuntu Server 26.04 LTS"]
  @supported_architectures ["x86_64", "arm64"]
  @excluded_categories ["external_approval", "image_download"]
  @journeys ~w(
    first_run_setup
    sign_in
    connect_repository
    inspect_running_pipeline
    diagnose_failed_job
    cancel_and_retry
  )

  @type error :: {:error, atom() | tuple()}

  @spec verify_files(Path.t(), Path.t(), Path.t()) :: {:ok, map()} | error()
  def verify_files(first_pipeline_path, accessibility_path, artifact_manifest_path) do
    with {:ok, first_pipeline} <- read_json(first_pipeline_path),
         {:ok, first_report} <- verify_first_pipeline(first_pipeline),
         {:ok, manifest_digest, manifest_content} <- digest_regular_file(artifact_manifest_path),
         :ok <- manifest_matches(first_pipeline["artifact_manifest_sha256"], manifest_digest),
         {:ok, artifact} <- validate_artifact_manifest(manifest_content),
         {:ok, accessibility} <- read_json(accessibility_path),
         {:ok, accessibility_report} <- verify_accessibility(accessibility) do
      {:ok,
       %{
         schema_version: 1,
         mvp_external_acceptance: "passed",
         first_pipeline: first_report,
         accessibility: accessibility_report,
         artifact_manifest: %{sha256: manifest_digest, artifact: artifact}
       }}
    end
  end

  @spec verify_first_pipeline(map()) :: {:ok, map()} | error()
  def verify_first_pipeline(evidence) when is_map(evidence) do
    required = ~w(
      schema_version kind operator host started_at green_check_at excluded_intervals
      repository commit_sha check_url artifact_manifest_sha256
    )

    with :ok <- exact_keys(evidence, required, ["notes"]),
         :ok <- exact_value(evidence, "schema_version", 1),
         :ok <- exact_value(evidence, "kind", "first_pipeline"),
         :ok <- validate_operator(evidence["operator"]),
         :ok <- validate_host(evidence["host"]),
         {:ok, started_at} <- timestamp(evidence["started_at"], "started_at"),
         {:ok, green_at} <- timestamp(evidence["green_check_at"], "green_check_at"),
         :ok <- ordered(started_at, green_at, "green_check_at"),
         {:ok, excluded_seconds} <-
           excluded_seconds(evidence["excluded_intervals"], started_at, green_at),
         {:ok, repository} <- repository(evidence["repository"]),
         :ok <- commit_sha(evidence["commit_sha"]),
         :ok <- github_check_url(evidence["check_url"], repository),
         :ok <- sha256(evidence["artifact_manifest_sha256"], "artifact_manifest_sha256") do
      gross_seconds = DateTime.diff(green_at, started_at, :second)
      measured_seconds = gross_seconds - excluded_seconds

      if measured_seconds <= 600 do
        {:ok,
         %{
           result: "passed",
           measured_seconds: measured_seconds,
           gross_seconds: gross_seconds,
           excluded_seconds: excluded_seconds,
           repository: repository,
           commit_sha: evidence["commit_sha"],
           check_url: evidence["check_url"]
         }}
      else
        {:error, {:first_pipeline_too_slow, measured_seconds}}
      end
    end
  end

  def verify_first_pipeline(_evidence), do: {:error, :invalid_first_pipeline_evidence}

  @spec verify_accessibility(map()) :: {:ok, map()} | error()
  def verify_accessibility(evidence) when is_map(evidence) do
    required = ~w(schema_version kind tested_at tester environment journeys issues)

    with :ok <- exact_keys(evidence, required, ["notes"]),
         :ok <- exact_value(evidence, "schema_version", 1),
         :ok <- exact_value(evidence, "kind", "accessibility_smoke"),
         {:ok, tested_at} <- timestamp(evidence["tested_at"], "tested_at"),
         :ok <- accessibility_tester(evidence["tester"]),
         :ok <- accessibility_environment(evidence["environment"]),
         :ok <- accessibility_journeys(evidence["journeys"]),
         :ok <- accessibility_issues(evidence["issues"]) do
      {:ok,
       %{
         result: "passed",
         tested_at: DateTime.to_iso8601(tested_at),
         tester_id: evidence["tester"]["id"],
         screen_reader: evidence["environment"]["screen_reader"],
         journeys: @journeys
       }}
    end
  end

  def verify_accessibility(_evidence), do: {:error, :invalid_accessibility_evidence}

  defp read_json(path) when is_binary(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes <-
           File.lstat(path),
         {:ok, content} <- File.read(path),
         {:ok, evidence} when is_map(evidence) <- Jason.decode(content) do
      {:ok, evidence}
    else
      {:ok, %File.Stat{type: :regular, size: size}} ->
        {:error, {:evidence_file_too_large, size}}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:invalid_evidence_file_type, type}}

      {:ok, _other} ->
        {:error, :invalid_evidence_document}

      {:error, %Jason.DecodeError{}} ->
        {:error, :invalid_evidence_json}

      {:error, reason} ->
        {:error, {:evidence_file, reason}}
    end
  end

  defp read_json(_path), do: {:error, :invalid_evidence_path}

  defp digest_regular_file(path) when is_binary(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes <-
           File.lstat(path),
         {:ok, content} <- File.read(path) do
      {:ok, :crypto.hash(:sha256, content) |> Base.encode16(case: :lower), content}
    else
      {:ok, %File.Stat{type: :regular, size: size}} ->
        {:error, {:artifact_manifest_too_large, size}}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:invalid_artifact_manifest_type, type}}

      {:error, reason} ->
        {:error, {:artifact_manifest_file, reason}}
    end
  end

  defp digest_regular_file(_path), do: {:error, :invalid_artifact_manifest_path}

  defp manifest_matches(expected, actual) do
    if expected == actual,
      do: :ok,
      else: {:error, {:artifact_manifest_digest_mismatch, expected, actual}}
  end

  defp validate_artifact_manifest(content) when is_binary(content) do
    pattern =
      ~r/\A([0-9a-f]{64})  (robine-server-0\.1\.0-ubuntu-(?:24\.04|26\.04)-[A-Za-z0-9][A-Za-z0-9._-]*\.tar\.gz)\n\z/

    case Regex.run(pattern, content) do
      [_, digest, artifact] ->
        if digest == String.duplicate("0", 64),
          do: {:error, :invalid_server_artifact_manifest},
          else: {:ok, artifact}

      _invalid ->
        {:error, :invalid_server_artifact_manifest}
    end
  end

  defp validate_operator(operator) do
    with :ok <- exact_keys(operator, ~w(id new_to_robine), []),
         :ok <- evidence_text(operator["id"], "operator.id"),
         :ok <- exact_value(operator, "new_to_robine", true) do
      :ok
    end
  end

  defp validate_host(host) do
    with :ok <- exact_keys(host, ~w(started_empty operating_system architecture), []),
         :ok <- exact_value(host, "started_empty", true),
         :ok <- member(host["operating_system"], @supported_hosts, "host.operating_system"),
         :ok <- member(host["architecture"], @supported_architectures, "host.architecture") do
      :ok
    end
  end

  defp excluded_seconds(intervals, started_at, green_at) when is_list(intervals) do
    intervals
    |> Enum.reduce_while({:ok, []}, fn interval, {:ok, parsed} ->
      case excluded_interval(interval, started_at, green_at) do
        {:ok, value} -> {:cont, {:ok, [value | parsed]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> sum_non_overlapping(parsed)
      {:error, _reason} = error -> error
    end
  end

  defp excluded_seconds(_intervals, _started_at, _green_at),
    do: {:error, {:invalid_field, "excluded_intervals"}}

  defp excluded_interval(interval, started_at, green_at) do
    with :ok <- exact_keys(interval, ~w(category started_at finished_at), ["notes"]),
         :ok <- member(interval["category"], @excluded_categories, "excluded.category"),
         {:ok, interval_start} <- timestamp(interval["started_at"], "excluded.started_at"),
         {:ok, interval_end} <- timestamp(interval["finished_at"], "excluded.finished_at"),
         :ok <- ordered(interval_start, interval_end, "excluded.finished_at"),
         true <- DateTime.compare(interval_start, started_at) in [:eq, :gt],
         true <- DateTime.compare(interval_end, green_at) in [:eq, :lt] do
      {:ok, {interval_start, interval_end}}
    else
      false -> {:error, :excluded_interval_outside_measurement}
      {:error, _reason} = error -> error
    end
  end

  defp sum_non_overlapping(intervals) do
    intervals
    |> Enum.sort_by(fn {started_at, _finished_at} ->
      DateTime.to_unix(started_at, :microsecond)
    end)
    |> Enum.reduce_while({:ok, nil, 0}, fn {started_at, finished_at}, {:ok, prior_end, sum} ->
      if prior_end && DateTime.compare(started_at, prior_end) == :lt do
        {:halt, {:error, :overlapping_excluded_intervals}}
      else
        seconds = DateTime.diff(finished_at, started_at, :second)
        {:cont, {:ok, finished_at, sum + seconds}}
      end
    end)
    |> case do
      {:ok, _last_end, seconds} -> {:ok, seconds}
      {:error, _reason} = error -> error
    end
  end

  defp repository(value) when is_binary(value) do
    if value != "owner/repository" and
         Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, value),
       do: {:ok, value},
       else: {:error, {:invalid_field, "repository"}}
  end

  defp repository(_value), do: {:error, {:invalid_field, "repository"}}

  defp commit_sha(value) when is_binary(value) do
    if value != String.duplicate("0", 40) and Regex.match?(~r/\A[0-9a-f]{40}\z/, value),
      do: :ok,
      else: {:error, {:invalid_field, "commit_sha"}}
  end

  defp commit_sha(_value), do: {:error, {:invalid_field, "commit_sha"}}

  defp github_check_url(value, repository) when is_binary(value) do
    uri = URI.parse(value)
    expected_path = ~r{\A/#{Regex.escape(repository)}/runs/[1-9][0-9]*\z}

    if uri.scheme == "https" and uri.host == "github.com" and
         is_binary(uri.path) and Regex.match?(expected_path, uri.path),
       do: :ok,
       else: {:error, {:invalid_field, "check_url"}}
  end

  defp github_check_url(_value, _repository), do: {:error, {:invalid_field, "check_url"}}

  defp sha256(value, field) when is_binary(value) do
    if value != String.duplicate("0", 64) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
      do: :ok,
      else: {:error, {:invalid_field, field}}
  end

  defp sha256(_value, field), do: {:error, {:invalid_field, field}}

  defp accessibility_tester(tester) do
    with :ok <- exact_keys(tester, ~w(id unfamiliar_with_implementation), []),
         :ok <- evidence_text(tester["id"], "tester.id"),
         :ok <- exact_value(tester, "unfamiliar_with_implementation", true) do
      :ok
    end
  end

  defp accessibility_environment(environment) do
    with :ok <- exact_keys(environment, ~w(screen_reader browser operating_system), []),
         :ok <- evidence_text(environment["screen_reader"], "environment.screen_reader"),
         :ok <- evidence_text(environment["browser"], "environment.browser"),
         :ok <- evidence_text(environment["operating_system"], "environment.operating_system") do
      :ok
    end
  end

  defp accessibility_journeys(journeys) when is_list(journeys) do
    with true <- length(journeys) == length(@journeys),
         :ok <- Enum.reduce_while(journeys, :ok, &accessibility_journey/2),
         true <- Enum.sort(Enum.map(journeys, & &1["id"])) == Enum.sort(@journeys) do
      :ok
    else
      false -> {:error, :incomplete_accessibility_journeys}
      {:error, _reason} = error -> error
    end
  end

  defp accessibility_journeys(_journeys), do: {:error, :incomplete_accessibility_journeys}

  defp accessibility_journey(journey, :ok) do
    with :ok <-
           exact_keys(
             journey,
             ~w(id completed keyboard_only announcements_understood focus_order_logical blocking_issues),
             ["notes"]
           ),
         :ok <- member(journey["id"], @journeys, "journey.id"),
         :ok <- exact_value(journey, "completed", true),
         :ok <- exact_value(journey, "keyboard_only", true),
         :ok <- exact_value(journey, "announcements_understood", true),
         :ok <- exact_value(journey, "focus_order_logical", true),
         true <- journey["blocking_issues"] == [] do
      {:cont, :ok}
    else
      false -> {:halt, {:error, {:blocking_accessibility_issues, journey["id"]}}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp accessibility_issues(issues) when is_list(issues) do
    Enum.reduce_while(issues, :ok, fn issue, :ok ->
      with :ok <- exact_keys(issue, ~w(severity description resolution reference), []),
           :ok <- member(issue["severity"], ~w(minor moderate major critical), "issue.severity"),
           :ok <- non_empty(issue["description"], "issue.description"),
           :ok <- issue_resolution(issue["severity"], issue["resolution"]),
           :ok <- non_empty(issue["reference"], "issue.reference") do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp accessibility_issues(_issues), do: {:error, {:invalid_field, "issues"}}

  defp issue_resolution(severity, "fixed") when severity in ~w(minor moderate major critical),
    do: :ok

  defp issue_resolution(severity, "accepted") when severity in ~w(minor moderate), do: :ok

  defp issue_resolution(_severity, _resolution),
    do: {:error, {:invalid_field, "issue.resolution"}}

  defp exact_keys(map, required, optional) when is_map(map) do
    keys = Map.keys(map) |> Enum.sort()
    allowed = Enum.sort(required ++ optional)

    cond do
      Enum.any?(required, &(not Map.has_key?(map, &1))) -> {:error, :missing_evidence_field}
      Enum.all?(keys, &(&1 in allowed)) -> :ok
      true -> {:error, :unknown_evidence_field}
    end
  end

  defp exact_keys(_map, _required, _optional), do: {:error, :invalid_evidence_object}

  defp exact_value(map, key, value) do
    if map[key] == value, do: :ok, else: {:error, {:invalid_field, key}}
  end

  defp non_empty(value, _field) when is_binary(value) and byte_size(value) in 1..512, do: :ok
  defp non_empty(_value, field), do: {:error, {:invalid_field, field}}

  defp evidence_text(value, field) do
    with :ok <- non_empty(value, field),
         false <- String.starts_with?(value, "replace-") do
      :ok
    else
      true -> {:error, {:placeholder_evidence, field}}
      {:error, _reason} = error -> error
    end
  end

  defp member(value, allowed, field) do
    if value in allowed, do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp timestamp(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> {:ok, timestamp}
      {:error, _reason} -> {:error, {:invalid_timestamp, field}}
    end
  end

  defp timestamp(_value, field), do: {:error, {:invalid_timestamp, field}}

  defp ordered(started_at, finished_at, field) do
    if DateTime.compare(finished_at, started_at) in [:eq, :gt],
      do: :ok,
      else: {:error, {:invalid_timestamp_order, field}}
  end
end
