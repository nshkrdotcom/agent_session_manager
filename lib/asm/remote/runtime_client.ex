defmodule ASM.Remote.RuntimeClient do
  @moduledoc """
  Process-family backend for one runtime-admitted managed ASM run.

  The worker owns the selected CLI RuntimeGateway lifecycle and keeps its
  opaque session handle private. Runtime Client placement, event delivery,
  cancellation, terminal receipt observation, and cleanup all stay on that
  gateway. No node selection or RPC is implemented in ASM.
  """

  use GenServer, restart: :temporary

  @behaviour ASM.ProviderBackend

  alias ASM.Error
  alias ASM.ProviderBackend.Event, as: BackendEvent
  alias ASM.ProviderBackend.Info, as: BackendInfo
  alias ASM.RuntimeAuth.CodexMaterialization
  alias ASM.RuntimeAuth.ManagedBinding
  alias CliSubprocessCore.GovernedAuthority
  alias CliSubprocessCore.RuntimeGateway.Session, as: GatewaySession
  alias CliSubprocessCore.RuntimeGateway.StartRequest
  alias CliSubprocessCore.RuntimeGateway.Status, as: GatewayStatus

  @impl true
  def start_run(config) when is_map(config) do
    case GenServer.start_link(__MODULE__, config) do
      {:ok, pid} -> {:ok, pid, GenServer.call(pid, :backend_info)}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, runtime_error("runtime gateway start failed", reason)}
    end
  end

  @impl true
  def send_input(worker, input, _opts \\ []) when is_pid(worker),
    do: GenServer.call(worker, {:send_input, input})

  @impl true
  def end_input(worker) when is_pid(worker), do: GenServer.call(worker, :end_input)

  @impl true
  def interrupt(worker) when is_pid(worker), do: GenServer.call(worker, :interrupt)

  @impl true
  def close(worker) when is_pid(worker) do
    GenServer.stop(worker, :normal)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def subscribe(worker, subscriber, subscription_ref)
      when is_pid(worker) and is_pid(subscriber) and is_reference(subscription_ref) do
    GenServer.call(worker, {:subscribe, subscriber, subscription_ref})
  end

  @impl true
  def info(worker) when is_pid(worker), do: GenServer.call(worker, :backend_info)

  @impl true
  def init(config) do
    with {:ok, route} <- runtime_route(config),
         {:ok, session_opts} <- ASM.ProviderBackend.Core.runtime_session_opts(config),
         {:ok, authority} <- governed_authority(route.binding, route.materialization),
         session_opts = bind_session_opts(session_opts, authority, route.binding),
         {:ok, run_session_ref} <- run_session_ref(route.binding, config),
         {:ok, request} <-
           start_request(route.binding, authority, route.gateway, run_session_ref),
         {:ok, admission} <- admission(route.binding, config, run_session_ref),
         :ok <-
           route.gateway.bind_start(
             request,
             session_opts: session_opts,
             admission: admission,
             runtime_client: route.client,
             runtime_client_opts: route.client_opts
           ),
         {:ok, %GatewaySession{} = session} <- route.gateway.start_session(request),
         :ok <- route.gateway.subscribe(session, self()) do
      {:ok,
       %{
         gateway: route.gateway,
         session: session,
         status: nil,
         provider: config.provider.name,
         capabilities: gateway_capabilities(session_opts),
         subscribers: initial_subscribers(config)
       }}
    else
      {:error, %Error{} = error} -> {:stop, error}
      {:error, reason} -> {:stop, runtime_error("runtime gateway admission failed", reason)}
    end
  end

  @impl true
  def handle_call(:backend_info, _from, state) do
    status =
      case state.gateway.info(state.session) do
        {:ok, %GatewayStatus{} = status} -> status
        _other -> state.status
      end

    {:reply, backend_info(%{state | status: status}), %{state | status: status}}
  end

  def handle_call({:subscribe, subscriber, subscription_ref}, _from, state) do
    {:reply, :ok,
     %{state | subscribers: Map.put(state.subscribers, subscription_ref, subscriber)}}
  end

  def handle_call({:send_input, input}, _from, state) do
    {:reply, state.gateway.send_input(state.session, input), state}
  end

  def handle_call(:end_input, _from, state) do
    {:reply, state.gateway.end_input(state.session), state}
  end

  def handle_call(:interrupt, _from, state) do
    {:reply, state.gateway.cancel(state.session, :user_cancelled), state}
  end

  @impl true
  def handle_info(
        {event_tag, %GatewaySession{} = session, %CliSubprocessCore.Event{} = event},
        state
      ) do
    if event_tag == state.gateway.event_message_tag() and same_session?(session, state.session) do
      Enum.each(state.subscribers, fn {subscription_ref, subscriber} ->
        send(subscriber, BackendEvent.new(subscription_ref, event))
      end)
    end

    {:noreply, state}
  end

  def handle_info(
        {terminal_tag, %GatewaySession{} = session, %GatewayStatus{} = status},
        state
      ) do
    if terminal_tag == state.gateway.terminal_message_tag() and
         same_session?(session, state.session) do
      {:noreply, %{state | session: session, status: status}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    if not GatewaySession.terminal?(state.session) do
      _ = state.gateway.terminate(state.session, reason)
    end

    :ok
  end

  defp runtime_route(config) do
    with %ManagedBinding{} = binding <- Map.get(config, :managed_binding),
         %CodexMaterialization{} = materialization <-
           Map.get(config, :codex_materialized_runtime),
         gateway when is_atom(gateway) <- Map.get(config, :runtime_gateway_module),
         client when is_atom(client) <- Map.get(config, :runtime_client),
         client_opts when is_list(client_opts) <- Map.get(config, :runtime_client_opts, []),
         true <- Keyword.keyword?(client_opts),
         true <- binding.runtime_gateway_module == gateway,
         false <- gateway == CliSubprocessCore.RuntimeGateway.Local,
         true <- runtime_gateway?(gateway),
         true <- runtime_client?(client) do
      {:ok,
       %{
         binding: binding,
         materialization: materialization,
         gateway: gateway,
         client: client,
         client_opts: client_opts
       }}
    else
      _other -> {:error, :invalid_runtime_gateway_route}
    end
  end

  defp governed_authority(%ManagedBinding{} = binding, %CodexMaterialization{} = materialization) do
    GovernedAuthority.new(%{
      authority_ref: binding.authority_ref,
      credential_lease_ref: binding.lease_ref,
      connector_instance_ref: binding.connector_instance_ref,
      connector_binding_ref: binding.connector_binding_ref,
      provider_account_ref: binding.provider_account_ref,
      native_auth_assertion_ref: binding.native_auth_assertion_ref,
      target_ref: binding.target_ref,
      operation_policy_ref: binding.operation_policy_ref,
      command: materialization.command,
      cwd: materialization.cwd,
      env: materialization.env,
      clear_env?: materialization.clear_env?,
      config_root: materialization.config_root,
      base_url: materialization.base_url,
      command_ref: command_ref(binding),
      redaction_ref: "redaction://asm/runtime-client/#{ref_token(binding.session_ref)}"
    })
  end

  defp start_request(binding, authority, gateway, run_session_ref) do
    StartRequest.new(%{
      session_ref: run_session_ref,
      generation: binding.session_generation,
      command_ref: authority.command_ref,
      command_digest: gateway.command_digest(authority),
      working_directory_ref: binding.workspace_ref,
      environment_materialization_ref: binding.materialization_ref,
      authority_ref: binding.authority_ref,
      target_ref: binding.target_ref,
      operation_ref: binding.operation_ref,
      deadline_at: binding.expires_at,
      fence: binding.fence
    })
  end

  defp admission(binding, config, run_session_ref) do
    envelope = contract_map(Map.get(config, :governed_lower_envelope))
    classes = Map.get(config, :runtime_attestation_classes, [])

    with {:ok, request_id} <- required_envelope_string(envelope, :lower_request_ref),
         {:ok, policy_hash} <-
           required_envelope_string(envelope, :authority_decision_hash),
         {:ok, profile_ref} <- required_envelope_string(envelope, :runtime_profile_ref),
         {:ok, classes} <- attestation_classes(classes) do
      {:ok,
       %{
         request_id: request_id,
         lane_id: "process",
         operation: "process.start",
         authority_ref: %{
           ref: binding.authority_ref,
           payload_hash: policy_hash,
           audience: binding.target_ref,
           expires_at: binding.expires_at
         },
         sandbox_profile: %{
           profile_ref: profile_ref,
           bundle_hash: policy_hash,
           opaque_bundle: envelope
         },
         acceptable_attestation: %{
           classes: classes,
           priority_order: classes
         },
         placement: %{
           surface_kind: "runtime_client",
           family: "process",
           metadata: %{"target_ref" => binding.target_ref}
         },
         provenance: %{
           kind: "node_admitted",
           owner: "agent_session_manager",
           details: %{"runtime_gateway" => binding.runtime_gateway_ref}
         },
         metadata: %{
           "consumer" => "agent_session_manager",
           "managed_session_ref" => binding.session_ref,
           "runtime_session_ref" => run_session_ref,
           "materialization_ref" => binding.materialization_ref,
           "provider_account_ref" => binding.provider_account_ref,
           "credential_generation" => binding.credential_generation
         }
       }}
    end
  end

  defp backend_info(state) do
    BackendInfo.new(
      provider: state.provider,
      lane: :core,
      backend: __MODULE__,
      runtime: state.gateway,
      session_pid: self(),
      capabilities: state.capabilities,
      raw_info: %{
        execution_mode: :runtime,
        execution_ref: state.session.execution_ref,
        session_ref: state.session.session_ref,
        status: state.status && state.status.state,
        receipt_ref: state.status && state.status.receipt_ref
      }
    )
  end

  defp initial_subscribers(config) do
    case {Map.get(config, :subscription_ref), Map.get(config, :subscriber_pid)} do
      {ref, pid} when is_reference(ref) and is_pid(pid) -> %{ref => pid}
      _other -> %{}
    end
  end

  defp bind_session_opts(session_opts, authority, binding) do
    metadata =
      session_opts
      |> Keyword.get(:metadata, %{})
      |> Map.put(:working_directory_ref, binding.workspace_ref)
      |> Map.put(:environment_materialization_ref, binding.materialization_ref)
      |> Map.put(:operation_ref, binding.operation_ref)

    session_opts
    |> Keyword.drop([:command, :cli_path, :cwd, :env, :clear_env?])
    |> remove_governed_config_injection()
    |> Keyword.put(:governed_authority, authority)
    |> Keyword.put(:metadata, metadata)
  end

  # Runtime Client admission owns launch policy. Codex renders catalog reasoning
  # as generic `--config` argv, so keep the resolved model identity while
  # removing those non-authoritative config overrides at this boundary.
  defp remove_governed_config_injection(session_opts) do
    Keyword.update(session_opts, :model_payload, nil, fn
      %CliSubprocessCore.ModelRegistry.Selection{} = payload ->
        %{
          payload
          | reasoning: nil,
            reasoning_effort: nil,
            normalized_reasoning_effort: nil
        }

      payload when is_map(payload) ->
        payload
        |> Map.put(:reasoning, nil)
        |> Map.put("reasoning", nil)
        |> Map.put(:reasoning_effort, nil)
        |> Map.put("reasoning_effort", nil)
        |> Map.put(:normalized_reasoning_effort, nil)
        |> Map.put("normalized_reasoning_effort", nil)

      payload ->
        payload
    end)
  end

  defp gateway_capabilities(session_opts) do
    case Keyword.get(session_opts, :profile) do
      profile when is_atom(profile) ->
        if function_exported?(profile, :capabilities, 0), do: profile.capabilities(), else: []

      _other ->
        []
    end
  end

  defp runtime_gateway?(module) do
    callbacks = [
      bind_start: 2,
      command_digest: 1,
      event_message_tag: 0,
      terminal_message_tag: 0,
      start_session: 1,
      send_input: 2,
      end_input: 1,
      info: 1,
      subscribe: 2,
      cancel: 2,
      terminate: 2
    ]

    Code.ensure_loaded?(module) and
      Enum.all?(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end)
  end

  defp runtime_client?(module) do
    callbacks = [start: 2, subscribe: 3, send_input: 3, end_input: 2, status: 2, cancel: 2]

    Code.ensure_loaded?(module) and
      Enum.all?(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end)
  end

  defp same_session?(left, right) do
    left.session_ref == right.session_ref and
      left.generation == right.generation and
      left.execution_ref == right.execution_ref and
      left.fence == right.fence
  end

  defp command_ref(binding),
    do: "command://asm/runtime-client/#{ref_token(binding.operation_ref)}"

  defp run_session_ref(binding, config) do
    case config |> Map.get(:metadata, %{}) |> value(:run_id) do
      run_id when is_binary(run_id) and run_id != "" ->
        {:ok, "session://asm/runtime-run/#{ref_token(binding.session_ref <> ":" <> run_id)}"}

      _missing ->
        {:error, :runtime_run_id_missing}
    end
  end

  defp contract_map(nil), do: %{}
  defp contract_map(%_{} = contract), do: Map.from_struct(contract)
  defp contract_map(contract) when is_map(contract), do: contract
  defp contract_map(_contract), do: %{}

  defp value(map, key, default \\ nil) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp required_envelope_string(envelope, key) do
    case value(envelope, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:governed_lower_envelope_missing, key}}
    end
  end

  defp attestation_classes(classes) when is_list(classes) do
    if classes != [] and
         Enum.all?(classes, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, Enum.uniq(classes)}
    else
      {:error, :runtime_attestation_classes_invalid}
    end
  end

  defp attestation_classes(_classes), do: {:error, :runtime_attestation_classes_invalid}

  defp ref_token(value) do
    :crypto.hash(:sha256, value)
    |> Base.url_encode64(padding: false)
  end

  defp runtime_error(message, reason) do
    Error.new(:runtime, :runtime, "#{message}: #{inspect(reason)}", cause: reason)
  end
end
