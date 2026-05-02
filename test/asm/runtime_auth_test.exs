defmodule ASM.RuntimeAuthTest do
  use ASM.TestCase

  alias ASM.TestSupport.FakeBackend

  test "default codex query records explicit standalone context and connector evidence" do
    session_id = "runtime-auth-standalone-" <> unique_suffix()

    assert {:ok, result} =
             ASM.query(:codex, "hello",
               session_id: session_id,
               backend_module: FakeBackend
             )

    metadata = result.metadata

    assert metadata.runtime_auth_mode == :standalone
    assert metadata.execution_context_ref == "asm-execution-context://standalone/#{session_id}"
    assert metadata.connector_instance_ref == "asm-connector-instance://standalone/codex/default"
    assert metadata.provider_account_ref == "provider-account://codex/unknown"
    refute metadata.connector_instance_ref == metadata.provider_account_ref

    assert metadata.runtime_auth.execution_context.ref == metadata.execution_context_ref
    assert metadata.runtime_auth.execution_context.scope == :standalone
    assert metadata.runtime_auth.connector_instance.ref == metadata.connector_instance_ref

    assert metadata.runtime_auth.connector_binding.execution_context_ref ==
             metadata.execution_context_ref

    evidence = metadata.connector_invocation_evidence
    assert evidence.evidence_type == :connector_invocation
    assert evidence.execution_context_ref == metadata.execution_context_ref
    assert evidence.connector_instance_ref == metadata.connector_instance_ref
    assert evidence.governed_authority == false

    refute ASM.RuntimeAuth.governed_authority?(metadata)
  end

  test "stream events carry protected runtime auth metadata" do
    session_id = "runtime-auth-event-" <> unique_suffix()
    connector_ref = "asm-connector-instance://standalone/codex/event"

    events =
      :codex
      |> start_query_session(session_id: session_id, connector_instance_ref: connector_ref)
      |> ASM.stream("hello",
        backend_module: FakeBackend,
        metadata: %{execution_context_ref: "overridden", caller_trace_ref: "trace-1"}
      )
      |> Enum.to_list()

    run_started = Enum.find(events, &(&1.kind == :run_started))

    assert run_started.metadata.execution_context_ref ==
             "asm-execution-context://standalone/#{session_id}"

    assert run_started.metadata.connector_instance_ref == connector_ref
    assert run_started.metadata.caller_trace_ref == "trace-1"
    refute ASM.RuntimeAuth.governed_authority?(run_started.metadata)
  end

  test "connector instance identity is distinct from redacted provider account identity" do
    session_id = "runtime-auth-distinct-" <> unique_suffix()
    connector_ref = "asm-connector-instance://standalone/codex/workstation-a"
    account_ref = "provider-account://codex/redacted-user"

    assert {:ok, result} =
             ASM.query(:codex, "hello",
               session_id: session_id,
               backend_module: FakeBackend,
               connector_instance_ref: connector_ref,
               connector_runtime_ref: "codex-cli:///opt/shared/bin/codex",
               provider_account_ref: account_ref,
               provider_account_status: :known_redacted,
               provider_account_evidence: %{account_label: "redacted"}
             )

    metadata = result.metadata

    assert metadata.connector_instance_ref == connector_ref
    assert metadata.provider_account_ref == account_ref
    refute metadata.connector_instance_ref == metadata.provider_account_ref
    assert metadata.runtime_auth.provider_account_identity.redacted? == true
    assert metadata.runtime_auth.provider_account_identity.evidence.account_label == "redacted"
  end

  test "two connector instances can share one runtime path without merging identity" do
    runtime_ref = "codex-cli:///opt/shared/bin/codex"

    assert {:ok, left} =
             ASM.query(:codex, "left",
               session_id: "runtime-auth-left-" <> unique_suffix(),
               backend_module: FakeBackend,
               connector_instance_ref: "asm-connector-instance://standalone/codex/left",
               connector_runtime_ref: runtime_ref
             )

    assert {:ok, right} =
             ASM.query(:codex, "right",
               session_id: "runtime-auth-right-" <> unique_suffix(),
               backend_module: FakeBackend,
               connector_instance_ref: "asm-connector-instance://standalone/codex/right",
               connector_runtime_ref: runtime_ref
             )

    assert left.metadata.runtime_auth.connector_instance.runtime_ref == runtime_ref
    assert right.metadata.runtime_auth.connector_instance.runtime_ref == runtime_ref
    refute left.metadata.connector_instance_ref == right.metadata.connector_instance_ref
  end

  test "provider account refs cannot be reused as connector instance refs" do
    same_ref = "identity://codex/same"

    assert {:error, error} =
             ASM.query(:codex, "hello",
               session_id: "runtime-auth-reject-" <> unique_suffix(),
               backend_module: FakeBackend,
               connector_instance_ref: same_ref,
               provider_account_ref: same_ref
             )

    assert error.kind == :config_invalid
    assert error.domain == :config
    assert error.message =~ "connector_instance_ref must be distinct"
  end

  test "standalone metadata cannot satisfy governed authority" do
    assert {:ok, result} =
             ASM.query(:codex, "hello",
               session_id: "runtime-auth-fx036-" <> unique_suffix(),
               backend_module: FakeBackend
             )

    refute ASM.RuntimeAuth.governed_authority?(result.metadata)
    refute result.metadata.governed_authority
  end

  defp start_query_session(provider, opts) do
    assert {:ok, session} = ASM.start_session(Keyword.put(opts, :provider, provider))

    on_exit(fn ->
      _ = ASM.stop_session(session)
    end)

    session
  end

  defp unique_suffix do
    System.unique_integer([:positive])
    |> Integer.to_string()
  end
end
