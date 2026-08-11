defmodule ASM.ProviderBackend.Core do
  @moduledoc """
  Backend that runs the shared CLI runtime from `cli_subprocess_core`.
  """

  @behaviour ASM.ProviderBackend

  alias ASM.Error
  alias ASM.Execution
  alias ASM.Options
  alias ASM.Provider
  alias ASM.ProviderBackend.Proxy
  alias ASM.RuntimeAuth
  alias ASM.RuntimeAuth.CodexMaterialization
  alias CliSubprocessCore.ProviderCLI.Error, as: ProviderCLIError
  alias CliSubprocessCore.RecoveryEnvelope
  alias CliSubprocessCore.Session

  @impl true
  def start_run(%{provider: %Provider{} = provider} = config) do
    with {:ok, execution_config} <- fetch_execution_config(config),
         :ok <- validate_local_execution(execution_config),
         :ok <- validate_approval_posture(execution_config),
         {:ok, session_opts} <- runtime_session_opts(config),
         {:ok, proxy, info} <-
           Proxy.start_link(
             starter: fn subscriber ->
               do_start_run(execution_config, Keyword.put(session_opts, :subscriber, subscriber))
             end,
             runtime_api: Session,
             runtime: Session,
             provider: provider.name,
             lane: :core,
             backend: __MODULE__,
             capabilities: core_capabilities(provider),
             initial_subscribers: initial_subscribers(config)
           ) do
      {:ok, proxy, info}
    else
      {:error, %ProviderCLIError{} = error} ->
        {:error, provider_cli_error(provider.name, error)}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:runtime, :runtime, "core backend start failed: #{inspect(reason)}",
           cause: reason
         )}
    end
  end

  @doc false
  @spec runtime_session_opts(map()) :: {:ok, keyword()} | {:error, term()}
  def runtime_session_opts(%{provider: %Provider{} = provider} = config) do
    with {:ok, execution_config} <- fetch_execution_config(config),
         :ok <- validate_approval_posture(execution_config) do
      build_session_opts(provider, config, execution_config)
    end
  end

  @impl true
  def send_input(session, input, opts \\ []) when is_pid(session) do
    Proxy.send_input(session, input, opts)
  end

  @impl true
  def end_input(session) when is_pid(session), do: Proxy.end_input(session)

  @impl true
  def interrupt(session) when is_pid(session), do: Proxy.interrupt(session)

  @impl true
  def close(session) when is_pid(session), do: Proxy.close(session)

  @impl true
  def subscribe(session, pid, ref) when is_pid(session) and is_pid(pid) and is_reference(ref) do
    Proxy.subscribe(session, pid, ref)
  end

  @impl true
  def info(session) when is_pid(session), do: Proxy.info(session)

  defp fetch_execution_config(%{execution_config: %Execution.Config{} = config}),
    do: {:ok, config}

  defp fetch_execution_config(_config) do
    {:error, Error.new(:config_invalid, :config, "missing execution config for core backend")}
  end

  defp validate_local_execution(%Execution.Config{execution_mode: :local}), do: :ok

  defp validate_local_execution(%Execution.Config{}) do
    {:error,
     Error.new(
       :config_invalid,
       :config,
       "provider backends accept only local execution; use Runtime Client admission for placement"
     )}
  end

  defp do_start_run(%Execution.Config{execution_mode: :local}, session_opts) do
    Session.start_session(session_opts)
  end

  defp build_session_opts(provider, config, execution_config) do
    metadata =
      Map.merge(
        %{lane: :core, asm_provider: provider.name},
        Map.get(config, :metadata, %{})
      )

    with {:ok, provider_opts} <-
           Options.finalize_provider_opts(
             provider.name,
             effective_provider_opts(config, execution_config)
           ),
         {:ok, provider_opts} <- put_continuation_opts(provider, config, provider_opts),
         {:ok, materialization} <-
           authorize_provider_runtime(provider, config, provider_opts) do
      provider_opts =
        provider_opts
        |> Keyword.put(:prompt, Map.fetch!(config, :prompt))
        |> put_codex_materialization_opts(materialization)
        |> maybe_put_cli_path()

      {:ok,
       [
         provider: provider.name,
         profile: provider.core_profile,
         metadata: metadata
       ] ++
         execution_surface_opts(execution_config) ++
         provider_opts}
    end
  end

  defp effective_provider_opts(config, execution_config) when is_map(execution_config) do
    execution_environment = Execution.Config.to_execution_environment(execution_config)

    config
    |> Map.get(:provider_opts, [])
    |> maybe_put(:permission_mode, execution_environment.permission_mode)
    |> maybe_put(
      :provider_permission_mode,
      Map.get(execution_config, :provider_permission_mode)
    )
  end

  defp execution_surface_opts(%Execution.Config{} = execution_config) do
    [execution_surface: Execution.Config.to_execution_surface(execution_config)]
  end

  defp maybe_put_cli_path(provider_opts) do
    case Keyword.get(provider_opts, :cli_path) do
      path when is_binary(path) and path != "" ->
        provider_opts
        |> Keyword.put(:command, path)
        |> Keyword.delete(:cli_path)

      _ ->
        provider_opts
    end
  end

  defp put_codex_materialization_opts(provider_opts, nil), do: provider_opts

  defp put_codex_materialization_opts(provider_opts, %CodexMaterialization{} = materialization) do
    provider_opts
    |> Keyword.put(:command, materialization.command)
    |> Keyword.put(:cwd, materialization.cwd)
    |> Keyword.put(:env, materialization.env)
    |> Keyword.put(:clear_env?, materialization.clear_env?)
  end

  # A continuation names the provider thread to carry on. Translating it for
  # Codex alone meant every other lane dropped it silently: a Claude resume
  # never carried `--resume`, so both the failure-recovery resume and a steer
  # started a brand new session with no memory of the work, while every layer
  # above reported a successful resume. `antigravity` takes the same treatment
  # through `--conversation`.
  #
  # Fail closed rather than continuing without it. A caller that asked to
  # resume a specific thread and silently got a fresh one is the failure this
  # replaces, and it is not improved by being quiet.
  @continuation_options %{claude: :resume, codex: :resume, antigravity: :conversation}

  defp put_continuation_opts(%Provider{name: name}, config, provider_opts)
       when is_map_key(@continuation_options, name) do
    case Map.get(config, :continuation) do
      nil ->
        {:ok, provider_opts}

      %{strategy: :exact, provider_session_id: provider_session_id}
      when is_binary(provider_session_id) and provider_session_id != "" ->
        {:ok,
         Keyword.put(provider_opts, Map.fetch!(@continuation_options, name), provider_session_id)}

      %{strategy: :latest} ->
        {:error, continuation_error(name, "requires an exact provider session id")}

      continuation ->
        {:error, continuation_error(name, "is invalid: #{inspect(continuation)}")}
    end
  end

  defp put_continuation_opts(%Provider{name: name}, config, provider_opts) do
    case Map.get(config, :continuation) do
      nil ->
        {:ok, provider_opts}

      _continuation ->
        {:error,
         continuation_error(name, "is not supported; this lane cannot resume a provider thread")}
    end
  end

  defp continuation_error(provider, detail) do
    Error.new(:config_invalid, :config, "#{provider} core continuation #{detail}")
  end

  defp authorize_provider_runtime(%Provider{name: :codex}, config, provider_opts) do
    CodexMaterialization.authorize_config(config, provider_opts)
  end

  defp authorize_provider_runtime(%Provider{name: provider}, config, provider_opts) do
    with :ok <- RuntimeAuth.authorize_governed_provider_runtime(provider, config, provider_opts) do
      {:ok, nil}
    end
  end

  defp validate_approval_posture(execution_config) when is_map(execution_config) do
    if Execution.Config.to_execution_environment(execution_config).approval_posture == :none do
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "approval_posture :none is not supported for runtime start"
       )}
    else
      :ok
    end
  end

  defp provider_cli_error(provider, %ProviderCLIError{} = error) do
    Error.new(:cli_not_found, :provider, Exception.message(error),
      cause: error,
      provider: provider,
      retryable: false,
      recovery:
        RecoveryEnvelope.from_runtime_failure(%CliSubprocessCore.ProviderCLI.ErrorRuntimeFailure{
          kind: :cli_not_found,
          provider: provider,
          message: Exception.message(error),
          context: %{provider: provider},
          cause: error
        })
    )
  end

  defp core_capabilities(%Provider{core_profile: profile}) when is_atom(profile) do
    if function_exported?(profile, :capabilities, 0) do
      profile.capabilities()
    else
      []
    end
  end

  defp initial_subscribers(config) do
    case {Map.get(config, :subscription_ref), Map.get(config, :subscriber_pid)} do
      {ref, pid} when is_reference(ref) and is_pid(pid) -> %{ref => pid}
      _ -> %{}
    end
  end

  defp maybe_put(provider_opts, _key, nil), do: provider_opts
  defp maybe_put(provider_opts, key, value), do: Keyword.put(provider_opts, key, value)
end
