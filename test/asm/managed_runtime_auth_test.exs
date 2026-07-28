defmodule ASM.ManagedRuntimeAuthTest do
  use ASM.SerialTestCase

  alias ASM.ManagedSession

  test "managed Codex admission pins account, generation, authority, workspace, and gateway refs" do
    session_id = unique_ref("managed-admission")
    bundle = managed_bundle(session_id)

    assert {:ok, session} = ASM.start_session(bundle.options)
    on_exit(fn -> ASM.stop_session(session) end)

    assert {:ok, info} = ASM.session_info(session)
    binding = info.runtime_auth.managed_binding

    assert binding.session_ref == bundle.session.session_ref
    assert binding.session_generation == bundle.session.generation
    assert binding.provider_account_ref == bundle.session.provider_account_ref
    assert binding.credential_generation == bundle.session.credential_generation
    assert binding.materialization_ref == bundle.session.materialization_ref
    assert binding.authority_ref == bundle.session.authority_ref
    assert binding.target_ref == bundle.session.target_ref
    assert binding.workspace_ref == bundle.workspace_ref
    assert binding.runtime_gateway_ref == bundle.session.runtime_gateway
    assert binding.fence == bundle.session.fence

    refute Keyword.has_key?(info.options, :codex_materialized_runtime)
    refute Keyword.has_key?(info.options, :workspace_root)
    refute Keyword.has_key?(info.options, :execution_environment)
    refute Keyword.has_key?(info.options, :execution_surface)
    refute String.contains?(inspect(info), bundle.config_root)
  end

  test "managed admission rejects account and lease-generation drift" do
    session_id = unique_ref("managed-drift")
    bundle = managed_bundle(session_id)

    materialization_request = Keyword.fetch!(bundle.options, :materialization_request)

    account_drift =
      put_in(materialization_request[:account][:account_ref], "provider-account://codex/other")

    assert {:error, account_error} =
             ASM.start_session(
               Keyword.put(bundle.options, :materialization_request, account_drift)
             )

    assert account_error.kind == :config_invalid
    assert account_error.cause.reason == :identity_mismatch
    assert account_error.cause.field == :request_account_ref

    secret_material = Keyword.fetch!(bundle.options, :secret_material)

    generation_drift =
      put_in(secret_material[:generation], bundle.session.credential_generation + 1)

    assert {:error, generation_error} =
             ASM.start_session(Keyword.put(bundle.options, :secret_material, generation_drift))

    assert generation_error.kind == :config_invalid
    assert generation_error.cause.reason == :identity_mismatch
    assert generation_error.cause.field == :material_generation
  end

  test "managed runs consume ASM-owned Codex materialization" do
    session_id = unique_ref("managed-run")
    bundle = managed_bundle(session_id)

    assert {:ok, session} = ASM.start_session(bundle.options)
    on_exit(fn -> ASM.stop_session(session) end)

    assert {:ok, result} =
             ASM.query(session, "trusted materialization",
               backend_module: ASM.TestSupport.FakeBackend
             )

    assert result.text == "trusted materialization"
  end

  test "managed runs still reject caller-supplied Codex materialization" do
    session_id = unique_ref("managed-run-override")
    bundle = managed_bundle(session_id)

    assert {:ok, session} = ASM.start_session(bundle.options)
    on_exit(fn -> ASM.stop_session(session) end)

    assert {:error, error} =
             ASM.query(session, "must not dispatch",
               backend_module: ASM.TestSupport.FakeBackend,
               codex_materialized_runtime: %{cwd: "/tmp/caller-override"}
             )

    assert error.kind == :config_invalid

    assert error.message ==
             "managed session rejects caller-supplied materialized provider runtime"
  end

  test "public opaque-id cleanup closes the materialization and rejects later work" do
    session_id = unique_ref("managed-cleanup")
    bundle = managed_bundle(session_id)

    assert {:ok, session} = ASM.start_session(bundle.options)
    on_exit(fn -> ASM.stop_session(session) end)

    assert :ok = ASM.cleanup_managed_session(session_id, :effect_scope_closed)
    assert {:ok, %{status: :stopped}} = ASM.session_info(session)

    assert {:error, error} =
             ASM.query(session, "must not dispatch", backend_module: ASM.TestSupport.FakeBackend)

    assert error.kind == :config_invalid
    assert error.cause.materialization_status == :cleaned
  end

  test "public opaque-id revocation validates the pinned lease scope before closing" do
    session_id = unique_ref("managed-revocation")
    bundle = managed_bundle(session_id)

    assert {:ok, session} = ASM.start_session(bundle.options)
    on_exit(fn -> ASM.stop_session(session) end)

    assert {:error, mismatch} =
             ASM.revoke_managed_session(session_id, %{
               lease_ref: "lease://jido/codex/other",
               workspace_ref: bundle.workspace_ref,
               lease_status: :revoked
             })

    assert mismatch.cause.reason == :revocation_mismatch
    assert {:ok, %{status: :ready}} = ASM.session_info(session)

    assert :ok =
             ASM.revoke_managed_session(session_id, %{
               lease_ref: bundle.lease_ref,
               workspace_ref: bundle.workspace_ref,
               lease_status: :revoked,
               lease_scope: %{
                 provider_account_ref: bundle.session.provider_account_ref,
                 credential_generation: bundle.session.credential_generation,
                 authority_ref: bundle.session.authority_ref
               }
             })

    assert {:ok, %{status: :stopped}} = ASM.session_info(session)
  end

  defp managed_bundle(session_id) do
    suffix = unique_ref("bundle")
    workspace_root = System.tmp_dir!()
    config_root = Path.join(workspace_root, "codex-home-#{suffix}")
    workspace_ref = "workspace://managed/#{suffix}"
    lease_ref = "lease://jido/codex/#{suffix}"
    issued_at = DateTime.add(DateTime.utc_now(), -1, :second)
    expires_at = DateTime.add(issued_at, 300, :second)

    session =
      ManagedSession.new!(
        session_ref: "session://asm/codex/#{suffix}",
        generation: 3,
        provider_account_ref: "provider-account://codex/#{suffix}",
        credential_generation: 7,
        materialization_ref: "materialization://jido/codex/#{suffix}",
        authority_ref: "grant://citadel/codex/#{suffix}",
        target_ref: "target://nshkr/local-process/#{suffix}",
        runtime_gateway: "gateway://cli-subprocess-core/local",
        status: :allocated,
        fence: 11
      )

    account = %{
      provider_family: :codex,
      account_ref: session.provider_account_ref,
      tenant_id: "tenant://nshkr/#{suffix}",
      connection_id: "connection://codex/#{suffix}",
      endpoint_ref: "endpoint://openai/codex/#{suffix}",
      quota_scope_ref: "quota://codex/#{suffix}",
      generation: session.credential_generation,
      fence: session.fence
    }

    materialization_request = %{
      materialization_ref: session.materialization_ref,
      lease_id: lease_ref,
      account: account,
      effect_ref: "effect://mezzanine/#{suffix}",
      operation_ref: "operation://codex/tool-effect/#{suffix}",
      authority_ref: session.authority_ref,
      endpoint_ref: account.endpoint_ref,
      target_ref: session.target_ref,
      issued_at: issued_at,
      expires_at: expires_at
    }

    secret_material = %{
      materialization_ref: session.materialization_ref,
      provider_family: :codex,
      account_ref: session.provider_account_ref,
      generation: session.credential_generation,
      payload: %{
        command: "/materialized/bin/codex",
        cwd: workspace_root,
        workspace_root: workspace_root,
        config_root: config_root,
        env: %{"CODEX_HOME" => config_root},
        clear_env?: true,
        target_auth_posture: :materialize_on_attach,
        native_auth_assertion: %{
          introspection_level: :auth_file_metadata,
          limits: %{secret_values: :not_read},
          redacted?: true
        }
      }
    }

    options = [
      session_id: session_id,
      provider: :codex,
      execution_mode: :local,
      workspace_root: workspace_root,
      workspace_ref: workspace_ref,
      runtime_auth_mode: :governed,
      runtime_auth_scope: :governed,
      execution_context_ref: "execution-context://nshkr/#{suffix}",
      connector_instance_ref: "connector-instance://codex/#{suffix}",
      connector_binding_ref: "connector-binding://codex/#{suffix}",
      provider_account_ref: session.provider_account_ref,
      provider_account_status: :asserted,
      authority_ref: session.authority_ref,
      credential_handle_ref: "credential-handle://jido/codex/#{suffix}",
      credential_lease_ref: lease_ref,
      native_auth_assertion_ref: "native-auth://codex/#{suffix}",
      target_ref: session.target_ref,
      operation_policy_ref: "operation-policy://codex/tool-effect/#{suffix}",
      runtime_gateway_ref: session.runtime_gateway,
      managed_session: session,
      materialization_request: materialization_request,
      secret_material: secret_material
    ]

    %{
      config_root: config_root,
      lease_ref: lease_ref,
      options: options,
      session: session,
      workspace_ref: workspace_ref
    }
  end

  defp unique_ref(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
