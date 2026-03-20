defmodule ASM.ProviderBackend.SDK do
  @moduledoc """
  Backend that runs provider SDK runtime kits when available locally.
  """

  @behaviour ASM.ProviderBackend

  alias ASM.{Error, Execution, Provider}
  alias ASM.ProviderBackend.SDK.SessionProxy

  @impl true
  def start_run(%{provider: %Provider{} = provider} = config) do
    with {:ok, %Execution.Config{execution_mode: :local}} <- fetch_execution_config(config),
         runtime when is_atom(runtime) <- provider.sdk_runtime,
         true <- Code.ensure_loaded?(runtime),
         {:ok, start_opts} <- build_start_opts(provider, config),
         {:ok, proxy, info} <- SessionProxy.start_link(runtime, start_opts, provider.name) do
      {:ok, proxy, %{lane: :sdk, provider: provider.name, session: info}}
    else
      {:ok, %Execution.Config{execution_mode: :remote_node}} ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "sdk lane is not supported for :remote_node execution"
         )}

      false ->
        {:error, Error.new(:config_invalid, :provider, "sdk runtime is unavailable")}

      nil ->
        {:error, Error.new(:config_invalid, :provider, "provider does not define an sdk runtime")}

      {:error, _reason} = error ->
        error

      other ->
        {:error,
         Error.new(:runtime, :runtime, "sdk backend start failed: #{inspect(other)}",
           cause: other
         )}
    end
  end

  @impl true
  def send_input(session, input, opts \\ []) when is_pid(session) do
    SessionProxy.send_input(session, input, opts)
  end

  @impl true
  def end_input(session) when is_pid(session) do
    SessionProxy.end_input(session)
  end

  @impl true
  def interrupt(session) when is_pid(session) do
    SessionProxy.interrupt(session)
  end

  @impl true
  def close(session) when is_pid(session) do
    SessionProxy.close(session)
  end

  @impl true
  def subscribe(session, pid, ref) when is_pid(session) and is_pid(pid) and is_reference(ref) do
    SessionProxy.subscribe(session, pid, ref)
  end

  @impl true
  def info(session) when is_pid(session) do
    SessionProxy.info(session)
  end

  defp fetch_execution_config(%{execution_config: %Execution.Config{} = config}),
    do: {:ok, config}

  defp fetch_execution_config(_config) do
    {:error, Error.new(:config_invalid, :config, "missing execution config for sdk backend")}
  end

  defp build_start_opts(%Provider{name: :claude, sdk_runtime: runtime}, config) do
    options =
      struct!(
        ClaudeAgentSDK.Options,
        %{
          cwd: kw(config, :cwd),
          env: kw(config, :env, %{}),
          path_to_claude_code_executable: kw(config, :cli_path),
          permission_mode: kw(config, :provider_permission_mode),
          model: kw(config, :model),
          max_turns: kw(config, :max_turns),
          system_prompt: kw(config, :system_prompt),
          append_system_prompt: kw(config, :append_system_prompt),
          include_partial_messages: true,
          output_format: :stream_json,
          timeout_ms: kw(config, :transport_timeout_ms),
          max_stderr_buffer_size: kw(config, :max_stderr_buffer_bytes)
        }
        |> drop_nil_values()
      )

    {:ok,
     sdk_start_opts(runtime, config,
       options: options,
       metadata: %{lane: :sdk, asm_provider: :claude}
     )}
  end

  defp build_start_opts(%Provider{name: :gemini, sdk_runtime: runtime}, config) do
    options =
      struct!(
        GeminiCliSdk.Options,
        %{
          model: kw(config, :model),
          yolo: kw(config, :provider_permission_mode) == :yolo,
          approval_mode: gemini_approval_mode(kw(config, :provider_permission_mode)),
          sandbox: kw(config, :sandbox, false),
          extensions: kw(config, :extensions, []),
          cwd: kw(config, :cwd),
          env: kw(config, :env, %{}),
          timeout_ms: kw(config, :transport_timeout_ms),
          max_stderr_buffer_bytes: kw(config, :max_stderr_buffer_bytes)
        }
        |> drop_nil_values()
      )

    {:ok,
     sdk_start_opts(runtime, config,
       prompt: Map.fetch!(config, :prompt),
       options: options,
       metadata: %{lane: :sdk, asm_provider: :gemini}
     )}
  end

  defp build_start_opts(%Provider{name: :amp, sdk_runtime: runtime}, config) do
    options =
      struct!(
        AmpSdk.Types.Options,
        %{
          cwd: kw(config, :cwd),
          mode: kw(config, :mode, "smart"),
          dangerously_allow_all: kw(config, :provider_permission_mode) == :dangerously_allow_all,
          env: kw(config, :env, %{}),
          thinking: kw(config, :include_thinking, false),
          stream_timeout_ms: kw(config, :transport_timeout_ms),
          max_stderr_buffer_bytes: kw(config, :max_stderr_buffer_bytes)
        }
        |> drop_nil_values()
      )

    {:ok,
     sdk_start_opts(runtime, config,
       input: Map.fetch!(config, :prompt),
       options: options,
       metadata: %{lane: :sdk, asm_provider: :amp}
     )}
  end

  defp build_start_opts(%Provider{name: :codex, sdk_runtime: runtime}, config) do
    with {:ok, codex_opts} <- Codex.Options.new(codex_option_attrs(config)),
         {:ok, thread_opts} <- Codex.Thread.Options.new(codex_thread_option_attrs(config)),
         {:ok, exec_opts} <- Codex.Exec.Options.new(codex_opts: codex_opts, thread: thread_opts) do
      {:ok,
       sdk_start_opts(runtime, config,
         input: Map.fetch!(config, :prompt),
         exec_opts: exec_opts,
         metadata: %{lane: :sdk, asm_provider: :codex}
       )}
    else
      {:error, reason} ->
        {:error,
         Error.new(:config_invalid, :config, "invalid codex sdk options: #{inspect(reason)}",
           cause: reason
         )}
    end
  end

  defp sdk_start_opts(_runtime, config, extra) do
    subscriber =
      case {Map.get(config, :subscriber_pid), Map.get(config, :subscription_ref)} do
        {pid, ref} when is_pid(pid) and is_reference(ref) -> {pid, ref}
        _ -> nil
      end

    extra
    |> Keyword.put(:subscriber, subscriber)
    |> Keyword.put(:session_event_tag, :cli_subprocess_core_session)
  end

  defp gemini_approval_mode(nil), do: nil
  defp gemini_approval_mode(:default), do: nil
  defp gemini_approval_mode(mode), do: mode

  defp codex_option_attrs(config) do
    %{
      model: kw(config, :model),
      reasoning_effort: kw(config, :reasoning_effort),
      codex_path_override: kw(config, :cli_path)
    }
    |> drop_nil_values()
  end

  defp codex_thread_option_attrs(config) do
    %{
      working_directory: kw(config, :cwd),
      full_auto: kw(config, :provider_permission_mode) == :auto_edit,
      dangerously_bypass_approvals_and_sandbox: kw(config, :provider_permission_mode) == :yolo,
      output_schema: kw(config, :output_schema)
    }
    |> drop_nil_values()
  end

  defp kw(config, key, default \\ nil) do
    config
    |> Map.get(:provider_opts, [])
    |> Keyword.get(key, default)
  end

  defp drop_nil_values(map) do
    Enum.reject(map, fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defmodule SessionProxy do
    @moduledoc false

    use GenServer

    defstruct [:runtime, :provider, :session, :session_ref, info: %{}]

    @type t :: %__MODULE__{
            runtime: module(),
            provider: atom(),
            session: pid(),
            session_ref: reference(),
            info: map()
          }

    @spec start_link(module(), keyword(), atom()) :: {:ok, pid(), map()} | {:error, term()}
    def start_link(runtime, start_opts, provider)
        when is_atom(runtime) and is_list(start_opts) and is_atom(provider) do
      ref = make_ref()

      case GenServer.start_link(__MODULE__, {runtime, start_opts, provider, self(), ref}) do
        {:ok, pid} ->
          receive do
            {:asm_sdk_proxy_started, ^ref, info} -> {:ok, pid, info}
          after
            5_000 -> {:error, :sdk_proxy_start_timeout}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    @spec send_input(pid(), iodata(), keyword()) :: :ok | {:error, term()}
    def send_input(proxy, input, opts) when is_pid(proxy),
      do: GenServer.call(proxy, {:send_input, input, opts})

    @spec end_input(pid()) :: :ok | {:error, term()}
    def end_input(proxy) when is_pid(proxy), do: GenServer.call(proxy, :end_input)

    @spec interrupt(pid()) :: :ok | {:error, term()}
    def interrupt(proxy) when is_pid(proxy), do: GenServer.call(proxy, :interrupt)

    @spec close(pid()) :: :ok
    def close(proxy) when is_pid(proxy) do
      GenServer.stop(proxy, :normal)
    catch
      :exit, _ -> :ok
    end

    @spec subscribe(pid(), pid(), reference()) :: :ok | {:error, term()}
    def subscribe(proxy, pid, ref) when is_pid(proxy) and is_pid(pid) and is_reference(ref) do
      GenServer.call(proxy, {:subscribe, pid, ref})
    end

    @spec info(pid()) :: map()
    def info(proxy) when is_pid(proxy), do: GenServer.call(proxy, :info)

    @impl true
    def init({runtime, start_opts, provider, caller, ref}) do
      case runtime.start_session(start_opts) do
        {:ok, session, info} ->
          send(caller, {:asm_sdk_proxy_started, ref, info})

          {:ok,
           %__MODULE__{
             runtime: runtime,
             provider: provider,
             session: session,
             session_ref: Process.monitor(session),
             info: normalize_info(info)
           }}

        {:error, reason} ->
          {:stop, reason}
      end
    end

    @impl true
    def handle_call({:send_input, input, opts}, _from, %__MODULE__{} = state) do
      {:reply, state.runtime.send_input(state.session, input, opts), state}
    end

    def handle_call(:end_input, _from, %__MODULE__{} = state) do
      {:reply, state.runtime.end_input(state.session), state}
    end

    def handle_call(:interrupt, _from, %__MODULE__{} = state) do
      {:reply, state.runtime.interrupt(state.session), state}
    end

    def handle_call({:subscribe, pid, ref}, _from, %__MODULE__{} = state) do
      {:reply, state.runtime.subscribe(state.session, pid, ref), state}
    end

    def handle_call(:info, _from, %__MODULE__{} = state) do
      {:reply, Map.put(state.info, :runtime, state.runtime), state}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{session_ref: ref} = state) do
      {:stop, reason, state}
    end

    @impl true
    def terminate(_reason, %__MODULE__{} = state) do
      _ = state.runtime.close(state.session)
      :ok
    end

    defp normalize_info(%{} = info), do: info
    defp normalize_info(other), do: %{session_info: other}
  end
end
