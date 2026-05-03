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

  test "standalone runtime auth cannot be upgraded to governed for a run" do
    assert {:ok, runtime_auth} =
             ASM.RuntimeAuth.new("runtime-auth-no-upgrade-" <> unique_suffix(), :codex)

    assert {:error, error} =
             ASM.RuntimeAuth.for_run(runtime_auth, "run-no-upgrade",
               runtime_auth_mode: :governed,
               runtime_auth_scope: :governed,
               authority_ref: "citadel-authority://decision/1",
               credential_lease_ref: "jido-credential-lease://lease/1",
               native_auth_assertion_ref: "codex-native-auth://assertion/1",
               provider_account_ref: "provider-account://codex/account-1"
             )

    assert error.kind == :config_invalid
    assert error.message =~ "standalone runtime_auth cannot be upgraded"
  end

  test "governed runtime auth requires lease and native auth assertion evidence" do
    assert {:error, error} =
             ASM.RuntimeAuth.new("runtime-auth-governed-missing-" <> unique_suffix(), :codex,
               runtime_auth_mode: :governed,
               runtime_auth_scope: :governed,
               execution_context_ref: "asm-execution-context://governed/missing",
               connector_instance_ref: "jido-connector-instance://codex/instance-1",
               connector_binding_ref: "jido-connector-binding://codex/binding-1",
               provider_account_ref: "provider-account://codex/account-1",
               authority_ref: "citadel-authority://decision/1"
             )

    assert error.kind == :config_invalid
    assert error.message =~ "governed runtime_auth requires"
  end

  test "complete governed runtime auth satisfies governed authority" do
    assert {:ok, runtime_auth} =
             ASM.RuntimeAuth.new("runtime-auth-governed-" <> unique_suffix(), :codex,
               runtime_auth_mode: :governed,
               runtime_auth_scope: :governed,
               execution_context_ref: "asm-execution-context://governed/session-1",
               connector_instance_ref: "jido-connector-instance://codex/instance-1",
               connector_binding_ref: "jido-connector-binding://codex/binding-1",
               provider_account_ref: "provider-account://codex/account-1",
               authority_ref: "citadel-authority://decision/1",
               credential_lease_ref: "jido-credential-lease://lease/1",
               native_auth_assertion_ref: "codex-native-auth://assertion/1"
             )

    assert ASM.RuntimeAuth.governed_authority?(runtime_auth)
    assert ASM.RuntimeAuth.governed_authority?(ASM.RuntimeAuth.to_metadata(runtime_auth))
  end

  test "ambient env cannot fill governed runtime auth evidence for provider families" do
    env = %{
      "ASM_AUTHORITY_REF" => "citadel-authority://env/decision",
      "ASM_CREDENTIAL_LEASE_REF" => "jido-credential-lease://env/lease",
      "ASM_NATIVE_AUTH_ASSERTION_REF" => "native-auth://env/assertion",
      "ASM_CONNECTOR_INSTANCE_REF" => "jido-connector-instance://env/instance",
      "ASM_PROVIDER_ACCOUNT_REF" => "provider-account://env/account",
      "ASM_TARGET_REF" => "execution-target://env/target"
    }

    with_env(env, fn ->
      for provider <- [:codex, :claude, :gemini, :amp] do
        assert {:error, error} =
                 ASM.RuntimeAuth.new("runtime-auth-env-missing-" <> to_string(provider), provider,
                   runtime_auth_mode: :governed,
                   runtime_auth_scope: :governed
                 )

        assert error.kind == :config_invalid
        assert error.message =~ "governed runtime_auth requires"
        assert is_nil(Map.get(error.cause, :authority_ref))
        assert is_nil(Map.get(error.cause, :credential_lease_ref))
        assert is_nil(Map.get(error.cause, :native_auth_assertion_ref))
        assert is_nil(Map.get(error.cause, :target_ref))
      end
    end)
  end

  test "ambient env cannot override explicit governed runtime auth refs" do
    env = %{
      "ASM_CONNECTOR_INSTANCE_REF" => "jido-connector-instance://env/instance",
      "ASM_PROVIDER_ACCOUNT_REF" => "provider-account://env/account",
      "ASM_TARGET_REF" => "execution-target://env/target",
      "ASM_AUTHORITY_REF" => "citadel-authority://env/decision"
    }

    with_env(env, fn ->
      for provider <- [:codex, :claude, :gemini, :amp] do
        assert {:ok, runtime_auth} =
                 ASM.RuntimeAuth.new("runtime-auth-explicit-" <> to_string(provider), provider,
                   runtime_auth_mode: :governed,
                   runtime_auth_scope: :governed,
                   execution_context_ref: "asm-execution-context://governed/#{provider}",
                   connector_instance_ref: "jido-connector-instance://#{provider}/explicit",
                   connector_binding_ref: "jido-connector-binding://#{provider}/explicit",
                   provider_account_ref: "provider-account://#{provider}/explicit",
                   authority_ref: "citadel-authority://decision/#{provider}",
                   credential_lease_ref: "jido-credential-lease://lease/#{provider}",
                   native_auth_assertion_ref: "native-auth://assertion/#{provider}",
                   target_ref: "execution-target://#{provider}/explicit"
                 )

        assert runtime_auth.connector_instance.ref ==
                 "jido-connector-instance://#{provider}/explicit"

        assert runtime_auth.provider_account_identity.ref ==
                 "provider-account://#{provider}/explicit"

        assert runtime_auth.connector_binding.target_ref ==
                 "execution-target://#{provider}/explicit"

        assert runtime_auth.connector_binding.authority_ref ==
                 "citadel-authority://decision/#{provider}"
      end
    end)
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

  defp with_env(env, fun) when is_map(env) and is_function(fun, 0) do
    saved = Map.new(env, fn {key, _value} -> {key, System.get_env(key)} end)

    try do
      Enum.each(env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      fun.()
    after
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
