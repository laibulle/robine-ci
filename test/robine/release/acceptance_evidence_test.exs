defmodule Robine.Release.AcceptanceEvidenceTest do
  use ExUnit.Case, async: true

  alias Robine.Release.AcceptanceEvidence

  test "accepts bounded first-pipeline timing with explicit non-overlapping exclusions" do
    assert {:ok, report} = AcceptanceEvidence.verify_first_pipeline(first_pipeline_evidence())
    assert report.result == "passed"
    assert report.gross_seconds == 720
    assert report.excluded_seconds == 150
    assert report.measured_seconds == 570
  end

  test "rejects slow, overlapping, and untrusted first-pipeline evidence" do
    slow =
      first_pipeline_evidence()
      |> Map.put("excluded_intervals", [])

    assert {:error, {:first_pipeline_too_slow, 720}} =
             AcceptanceEvidence.verify_first_pipeline(slow)

    overlapping =
      update_in(first_pipeline_evidence(), ["excluded_intervals"], fn [first, second] ->
        [first, Map.put(second, "started_at", "2026-08-09T10:02:30Z")]
      end)

    assert {:error, :overlapping_excluded_intervals} =
             AcceptanceEvidence.verify_first_pipeline(overlapping)

    wrong_host = put_in(first_pipeline_evidence(), ["host", "operating_system"], "Arch Linux")

    assert {:error, {:invalid_field, "host.operating_system"}} =
             AcceptanceEvidence.verify_first_pipeline(wrong_host)

    wrong_check =
      Map.put(first_pipeline_evidence(), "check_url", "https://example.com/acme/widget/runs/42")

    assert {:error, {:invalid_field, "check_url"}} =
             AcceptanceEvidence.verify_first_pipeline(wrong_check)
  end

  test "accepts a complete unfamiliar-tester screen-reader session" do
    assert {:ok, report} =
             AcceptanceEvidence.verify_accessibility(accessibility_evidence())

    assert report.result == "passed"
    assert length(report.journeys) == 6
    assert report.screen_reader == "NVDA 2026.1"
  end

  test "rejects missing journeys, familiar testers, blocking issues, and accepted major issues" do
    familiar =
      put_in(
        accessibility_evidence(),
        ["tester", "unfamiliar_with_implementation"],
        false
      )

    assert {:error, {:invalid_field, "unfamiliar_with_implementation"}} =
             AcceptanceEvidence.verify_accessibility(familiar)

    missing = update_in(accessibility_evidence(), ["journeys"], &tl/1)

    assert {:error, :incomplete_accessibility_journeys} =
             AcceptanceEvidence.verify_accessibility(missing)

    blocked =
      put_in(
        accessibility_evidence(),
        ["journeys", Access.at(0), "blocking_issues"],
        ["Focus is trapped"]
      )

    assert {:error, {:blocking_accessibility_issues, "first_run_setup"}} =
             AcceptanceEvidence.verify_accessibility(blocked)

    accepted_major =
      Map.put(accessibility_evidence(), "issues", [
        %{
          "severity" => "major",
          "description" => "Status is not announced",
          "resolution" => "accepted",
          "reference" => "issue-42"
        }
      ])

    assert {:error, {:invalid_field, "issue.resolution"}} =
             AcceptanceEvidence.verify_accessibility(accepted_major)
  end

  test "cryptographically binds regular evidence files to the released artifact manifest" do
    directory =
      Path.join(System.tmp_dir!(), "robine-acceptance-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    first = Path.join(directory, "first.json")
    accessibility = Path.join(directory, "accessibility.json")
    linked = Path.join(directory, "linked.json")
    manifest = Path.join(directory, "SHA256SUMS")
    artifact_digest = String.duplicate("c", 64)

    manifest_content =
      "#{artifact_digest}  robine-server-0.1.0-ubuntu-24.04-x86_64-pc-linux-gnu.tar.gz\n"

    manifest_digest = :crypto.hash(:sha256, manifest_content) |> Base.encode16(case: :lower)

    first_evidence =
      Map.put(first_pipeline_evidence(), "artifact_manifest_sha256", manifest_digest)

    File.write!(first, Jason.encode!(first_evidence))
    File.write!(accessibility, Jason.encode!(accessibility_evidence()))
    File.write!(manifest, manifest_content)
    File.ln_s!(first, linked)

    assert {:ok,
            %{
              mvp_external_acceptance: "passed",
              artifact_manifest: %{
                artifact: "robine-server-0.1.0-ubuntu-24.04-x86_64-pc-linux-gnu.tar.gz"
              }
            }} =
             AcceptanceEvidence.verify_files(first, accessibility, manifest)

    assert {:error, {:invalid_evidence_file_type, :symlink}} =
             AcceptanceEvidence.verify_files(linked, accessibility, manifest)

    File.write!(manifest, "tampered\n")

    assert {:error, {:artifact_manifest_digest_mismatch, ^manifest_digest, actual}} =
             AcceptanceEvidence.verify_files(first, accessibility, manifest)

    assert actual != manifest_digest
  end

  test "rejects a digest-bound file that is not the exact server release manifest" do
    directory =
      Path.join(System.tmp_dir!(), "robine-acceptance-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    manifest = Path.join(directory, "SHA256SUMS")
    invalid_content = "#{String.duplicate("d", 64)}  arbitrary-file.tar.gz\n"
    manifest_digest = :crypto.hash(:sha256, invalid_content) |> Base.encode16(case: :lower)
    first = Path.join(directory, "first.json")
    accessibility = Path.join(directory, "accessibility.json")

    File.write!(
      first,
      Jason.encode!(
        Map.put(first_pipeline_evidence(), "artifact_manifest_sha256", manifest_digest)
      )
    )

    File.write!(accessibility, Jason.encode!(accessibility_evidence()))
    File.write!(manifest, invalid_content)

    assert {:error, :invalid_server_artifact_manifest} =
             AcceptanceEvidence.verify_files(first, accessibility, manifest)
  end

  test "refuses the unedited public evidence templates" do
    first = Jason.decode!(File.read!("docs/acceptance/first-pipeline.template.json"))
    accessibility = Jason.decode!(File.read!("docs/acceptance/accessibility.template.json"))

    assert {:error, {:placeholder_evidence, "operator.id"}} =
             AcceptanceEvidence.verify_first_pipeline(first)

    assert {:error, {:placeholder_evidence, "tester.id"}} =
             AcceptanceEvidence.verify_accessibility(accessibility)
  end

  defp first_pipeline_evidence do
    %{
      "schema_version" => 1,
      "kind" => "first_pipeline",
      "operator" => %{"id" => "external-tester-01", "new_to_robine" => true},
      "host" => %{
        "started_empty" => true,
        "operating_system" => "Ubuntu Server 24.04 LTS",
        "architecture" => "x86_64"
      },
      "started_at" => "2026-08-09T10:00:00Z",
      "green_check_at" => "2026-08-09T10:12:00Z",
      "excluded_intervals" => [
        %{
          "category" => "external_approval",
          "started_at" => "2026-08-09T10:02:00Z",
          "finished_at" => "2026-08-09T10:03:00Z"
        },
        %{
          "category" => "image_download",
          "started_at" => "2026-08-09T10:07:00Z",
          "finished_at" => "2026-08-09T10:08:30Z"
        }
      ],
      "repository" => "acme/widget",
      "commit_sha" => String.duplicate("a", 40),
      "check_url" => "https://github.com/acme/widget/runs/42",
      "artifact_manifest_sha256" => String.duplicate("b", 64),
      "notes" => "Fresh-host acceptance session"
    }
  end

  defp accessibility_evidence do
    journeys =
      ~w(
        first_run_setup
        sign_in
        connect_repository
        inspect_running_pipeline
        diagnose_failed_job
        cancel_and_retry
      )
      |> Enum.map(fn id ->
        %{
          "id" => id,
          "completed" => true,
          "keyboard_only" => true,
          "announcements_understood" => true,
          "focus_order_logical" => true,
          "blocking_issues" => []
        }
      end)

    %{
      "schema_version" => 1,
      "kind" => "accessibility_smoke",
      "tested_at" => "2026-08-09T12:00:00Z",
      "tester" => %{
        "id" => "external-tester-02",
        "unfamiliar_with_implementation" => true
      },
      "environment" => %{
        "screen_reader" => "NVDA 2026.1",
        "browser" => "Firefox 142",
        "operating_system" => "Windows 11"
      },
      "journeys" => journeys,
      "issues" => [],
      "notes" => "Completed without coaching"
    }
  end
end
