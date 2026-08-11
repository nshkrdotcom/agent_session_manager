defmodule ASM.Remote.RuntimeClientTest do
  use ASM.SerialTestCase

  alias ASM.ManagedSession
  alias CliSubprocessCore.RuntimeGateway
  alias ExecutionPlane.{ActiveExecution, ExecutionRef, ExecutionResult}
  alias ExecutionPlane.Runtime.{Error, Event, Status}

  defmodule FakeRuntimeClient.State do
    @moduledoc false
  end

  defmodule FakeRuntimeClient do
    @behaviour ExecutionPlane.Runtime.Client

    alias ASM.Remote.RuntimeClientTest.FakeRuntimeClient.State
    alias ExecutionPlane.{ActiveExecution, ExecutionRef, ExecutionResult}
    alias ExecutionPlane.Runtime.{Error, Event, Status}

    def start_state! do
      Agent.start_link(fn -> %{calls: [], executions: %{}} end, name: State)
    end

    def calls, do: Agent.get(State, &Enum.reverse(&1.calls))

    @impl true
    def start(request, opts) do
      binding = request.metadata["cli_subprocess_core"]
      ref = "execution://asm-runtime/#{token(binding["session_ref"])}"

      active =
        ActiveExecution.new!(%{
          execution_ref: ref,
          session_ref: binding["session_ref"],
          admission_decision_ref: "admission://asm-runtime/#{token(request.request_id)}",
          node_id: "effect-node@runtime-test",
          lane_id: "process",
          state: "accepted",
          started_at: DateTime.utc_now(),
          fence: binding["fence"]
        })

      execution = %{
        auto_complete?: Keyword.get(opts, :auto_complete?, true),
        input_open?: true,
        output_open?: true,
        receipt_ref: nil,
        sequence: 0,
        state: "accepted",
        subscriber: nil
      }

      update(fn state ->
        %{
          state
          | calls: [{:start, request, opts} | state.calls],
            executions: Map.put(state.executions, ref, execution)
        }
      end)

      notify(opts, {:runtime_started, request, active})
      {:ok, active}
    end

    @impl true
    def subscribe(%ExecutionRef{ref: ref}, subscriber, opts) do
      execution =
        update_execution(ref, fn execution ->
          %{execution | subscriber: subscriber, state: "running"}
        end)

      record({:subscribe, ref, opts})
      notify(opts, {:runtime_subscribed, ref})

      if execution.auto_complete? do
        complete(ref, "completed", "succeeded")
      else
        send_event(ref, "started", %{"family" => "process"})
      end

      :ok
    end

    @impl true
    def send_input(%ExecutionRef{ref: ref}, input, opts) do
      record({:send_input, ref, IO.iodata_to_binary(input), opts})
      :ok
    end

    @impl true
    def end_input(%ExecutionRef{ref: ref}, opts) do
      record({:end_input, ref, opts})
      complete(ref, "completed", "succeeded")
      :ok
    end

    @impl true
    def status(%ExecutionRef{ref: ref}, opts) do
      record({:status, ref, opts})

      case Agent.get(State, &Map.fetch(&1.executions, ref)) do
        {:ok, execution} ->
          {:ok,
           Status.new!(%{
             execution_ref: ref,
             state: execution.state,
             sequence: execution.sequence,
             input_open: execution.input_open?,
             output_open: execution.output_open?,
             receipt_ref: execution.receipt_ref
           })}

        :error ->
          {:error,
           Error.new!(
             category: "terminal",
             message: "runtime execution is unknown",
             retryable: false,
             ambiguous: false
           )}
      end
    end

    @impl true
    def cancel(%ExecutionRef{ref: ref}, opts) do
      record({:cancel, ref, opts})
      complete(ref, "cancelled", "cancelled")
      :ok
    end

    defp complete(ref, terminal_state, result_status) do
      execution =
        update_execution(ref, fn execution ->
          %{
            execution
            | input_open?: false,
              output_open?: false,
              receipt_ref: "receipt://asm-runtime/#{token(ref)}/#{terminal_state}",
              state: terminal_state
          }
        end)

      started =
        runtime_event(
          ref,
          execution.sequence + 1,
          "started",
          %{"family" => "process"}
        )

      result =
        ExecutionResult.new!(
          execution_ref: ref,
          status: result_status,
          output: %{"family" => "process", "terminal_state" => terminal_state}
        )

      receipt =
        runtime_event(ref, started.sequence + 1, "receipt", %{
          "receipt_ref" => execution.receipt_ref,
          "terminal_state" => terminal_state,
          "execution_result" => result
        })

      update_execution(ref, &%{&1 | sequence: receipt.sequence})
      Process.send_after(execution.subscriber, {:execution_plane_runtime, ref, started}, 10)
      Process.send_after(execution.subscriber, {:execution_plane_runtime, ref, receipt}, 20)
    end

    defp send_event(ref, kind, payload) do
      {subscriber, event} =
        Agent.get_and_update(State, fn state ->
          execution = Map.fetch!(state.executions, ref)
          event = runtime_event(ref, execution.sequence + 1, kind, payload)
          execution = %{execution | sequence: event.sequence}

          {{execution.subscriber, event},
           %{state | executions: Map.put(state.executions, ref, execution)}}
        end)

      send(subscriber, {:execution_plane_runtime, ref, event})
    end

    defp runtime_event(ref, sequence, kind, payload) do
      Event.new!(%{
        execution_ref: ref,
        sequence: sequence,
        kind: kind,
        emitted_at: DateTime.utc_now(),
        payload: payload
      })
    end

    defp update_execution(ref, fun) do
      Agent.get_and_update(State, fn state ->
        execution = state.executions |> Map.fetch!(ref) |> fun.()
        {execution, %{state | executions: Map.put(state.executions, ref, execution)}}
      end)
    end

    defp record(call), do: update(&%{&1 | calls: [call | &1.calls]})
    defp update(fun), do: Agent.update(State, fun)

    defp notify(opts, message) do
      case Keyword.get(opts, :test_pid) do
        pid when is_pid(pid) -> send(pid, message)
        _missing -> :ok
      end
    end

    defp token(value) do
      :crypto.hash(:sha256, value)
      |> Base.url_encode64(padding: false)
    end
  end

  setup do
    saved_env = capture_codex_env()
    clear_codex_env()
    {:ok, state} = FakeRuntimeClient.start_state!()

    on_exit(fn ->
      restore_codex_env(saved_env)
      if Process.alive?(state), do: Agent.stop(state)
    end)

    :ok
  end

  test "managed runtime route admits through the CLI RuntimeClient gateway without local fallback" do
    bundle = managed_runtime_bundle(unique_ref("runtime-route"))
    assert {:ok, session} = ASM.start_session(bundle.options)
    on_exit(fn -> ASM.stop_session(session) end)

    assert {:ok, result} = ASM.query(session, "execute through the effect node")
    assert is_nil(result.error)

    assert_receive {:runtime_started, admission, %ActiveExecution{}}
    assert admission.lane_id == "process"
    assert admission.operation == "process.start"
    assert admission.authority_ref.ref == bundle.session.authority_ref
    assert admission.authority_ref.audience == bundle.session.target_ref
    assert admission.sandbox_profile.profile_ref == bundle.runtime_profile_ref
    assert admission.acceptable_attestation.classes == ["local-erlexec-weak"]
    assert admission.placement.surface_kind == "runtime_client"
    assert admission.placement.family == "process"
    assert admission.provenance.kind == "node_admitted"
    assert %ExecutionPlane.Family.ProcessRequest{arguments: arguments} = admission.payload
    refute "--config" in arguments
    assert admission.metadata["managed_session_ref"] == bundle.session.session_ref
    assert admission.metadata["runtime_session_ref"] != bundle.session.session_ref

    inspected = inspect(admission)
    refute inspected =~ bundle.config_root
    refute inspected =~ "managed-runtime-secret"
  end

  test "runtime cancellation reaches the selected Runtime Client and completes the run" do
    run_id = unique_ref("cancel-run")
    bundle = managed_runtime_bundle(unique_ref("runtime-cancel"), auto_complete?: false)
    assert {:ok, session} = ASM.start_session(bundle.options)
    on_exit(fn -> ASM.stop_session(session) end)

    task =
      Task.async(fn ->
        session
        |> ASM.stream("hold until cancelled", run_id: run_id)
        |> Enum.to_list()
      end)

    assert_receive {:runtime_subscribed, execution_ref}
    assert :ok = ASM.interrupt(session, run_id)
    events = Task.await(task, 5_000)

    assert Enum.any?(events, &(&1.kind == :error))

    assert Enum.any?(FakeRuntimeClient.calls(), fn
             {:cancel, ^execution_ref, opts} ->
               Keyword.fetch!(opts, :fence) == bundle.session.fence

             _other ->
               false
           end)
  end

  test "sequential managed runs use distinct gateway sessions and exact Codex continuation" do
    bundle = managed_runtime_bundle(unique_ref("runtime-continuation"))
    assert {:ok, session} = ASM.start_session(bundle.options)
    on_exit(fn -> ASM.stop_session(session) end)

    assert {:ok, first_result} =
             ASM.query(session, "start managed work", run_id: "runtime-run-one")

    assert is_nil(first_result.error)
    assert_receive {:runtime_started, first_admission, %ActiveExecution{}}

    continuation = %{strategy: :exact, provider_session_id: "codex-thread-123"}

    assert {:ok, second_result} =
             ASM.query(session, "continue managed work",
               run_id: "runtime-run-two",
               continuation: continuation
             )

    assert is_nil(second_result.error)
    assert_receive {:runtime_started, second_admission, %ActiveExecution{}}

    assert first_admission.metadata["managed_session_ref"] ==
             second_admission.metadata["managed_session_ref"]

    refute first_admission.metadata["runtime_session_ref"] ==
             second_admission.metadata["runtime_session_ref"]

    assert %ExecutionPlane.Family.ProcessRequest{arguments: first_arguments} =
             first_admission.payload

    assert %ExecutionPlane.Family.ProcessRequest{arguments: second_arguments} =
             second_admission.payload

    assert Enum.take(first_arguments, 2) == ["exec", "--json"]
    assert Enum.take(second_arguments, 3) == ["exec", "resume", "--json"]
    assert "codex-thread-123" in second_arguments
    assert List.last(second_arguments) == "continue managed work"
    refute "--config" in second_arguments
  end

  test "Codex Runtime Client continuation fails closed when no exact session id is known" do
    bundle = managed_runtime_bundle(unique_ref("runtime-latest"))
    assert {:ok, session} = ASM.start_session(bundle.options)
    on_exit(fn -> ASM.stop_session(session) end)

    assert {:error, error} =
             ASM.query(session, "do not guess a continuation", continuation: %{strategy: :latest})

    assert error.kind == :config_invalid
    assert error.message =~ "requires an exact provider session id"
    assert FakeRuntimeClient.calls() == []
  end

  test "runtime mode rejects the local gateway before any provider process can start" do
    bundle =
      managed_runtime_bundle(unique_ref("runtime-downgrade"),
        runtime_gateway_module: RuntimeGateway.Local,
        runtime_gateway_ref: "runtime-gateway://cli-subprocess-core/local/v1"
      )

    assert {:ok, session} = ASM.start_session(bundle.options)
    on_exit(fn -> ASM.stop_session(session) end)

    assert {:error, error} = ASM.query(session, "must not run locally")
    assert error.kind == :runtime
    assert error.message =~ "invalid_runtime_gateway_route"
    assert FakeRuntimeClient.calls() == []
  end

  defp managed_runtime_bundle(session_id, overrides \\ []) do
    suffix = unique_ref("bundle")
    workspace_root = System.tmp_dir!()
    config_root = Path.join(workspace_root, "codex-home-#{suffix}")
    workspace_ref = "workspace://managed/#{suffix}"
    lease_ref = "lease://jido/codex/#{suffix}"
    issued_at = DateTime.add(DateTime.utc_now(), -1, :second)
    expires_at = DateTime.add(issued_at, 300, :second)

    gateway =
      Keyword.get(
        overrides,
        :runtime_gateway_module,
        RuntimeGateway.RuntimeClient
      )

    gateway_ref =
      Keyword.get(
        overrides,
        :runtime_gateway_ref,
        "runtime-gateway://cli-subprocess-core/runtime-client/v1"
      )

    session =
      ManagedSession.new!(
        session_ref: "session://asm/codex/#{suffix}",
        generation: 3,
        provider_account_ref: "provider-account://codex/#{suffix}",
        credential_generation: 7,
        materialization_ref: "materialization://jido/codex/#{suffix}",
        authority_ref: "grant://citadel/codex/#{suffix}",
        target_ref: "target://nshkr/local-process/#{suffix}",
        runtime_gateway: gateway_ref,
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
        env: %{
          "CODEX_HOME" => config_root,
          "NSHKR_TEST_SECRET" => "managed-runtime-secret"
        },
        clear_env?: true,
        target_auth_posture: :materialize_on_attach,
        native_auth_assertion: %{
          introspection_level: :auth_file_metadata,
          limits: %{secret_values: :not_read},
          redacted?: true
        }
      }
    }

    runtime_profile_ref = "runtime-profile://nshkr/codex/#{suffix}"

    governed_lower_envelope = %{
      lower_request_ref: "lower-request://nshkr/codex/#{suffix}",
      runtime_profile_ref: runtime_profile_ref,
      authority_decision_hash: "sha256:" <> String.duplicate("a", 64),
      capability_id: "codex.session.turn",
      action_id: "codex.session.turn",
      authority_ref: session.authority_ref,
      allowed_operations: ["codex.session.turn"]
    }

    runtime_client_opts = [
      fence: session.fence,
      test_pid: self(),
      auto_complete?: Keyword.get(overrides, :auto_complete?, true)
    ]

    options = [
      session_id: session_id,
      provider: :codex,
      execution_mode: :runtime,
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
      runtime_gateway_module: gateway,
      runtime_gateway_ref: gateway_ref,
      runtime_client: FakeRuntimeClient,
      runtime_client_opts: runtime_client_opts,
      runtime_attestation_classes: ["local-erlexec-weak"],
      governed_lower_envelope: governed_lower_envelope,
      managed_session: session,
      materialization_request: materialization_request,
      secret_material: secret_material
    ]

    %{
      config_root: config_root,
      options: options,
      runtime_profile_ref: runtime_profile_ref,
      session: session
    }
  end

  defp unique_ref(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp capture_codex_env do
    Map.new(codex_env_keys(), &{&1, ASM.Env.get(&1)})
  end

  defp clear_codex_env do
    Enum.each(codex_env_keys(), &ASM.Env.delete/1)
  end

  defp restore_codex_env(saved) do
    Enum.each(saved, fn
      {key, nil} -> ASM.Env.delete(key)
      {key, value} -> ASM.Env.put(key, value)
    end)
  end

  defp codex_env_keys do
    ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_HOME", "OPENAI_BASE_URL"]
  end
end
