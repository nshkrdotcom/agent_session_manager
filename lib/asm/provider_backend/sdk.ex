defmodule ASM.ProviderBackend.SDK do
  @moduledoc """
  Backend that runs provider SDK runtime kits when available locally.
  """

  @behaviour ASM.ProviderBackend

  alias ASM.{Error, Execution, Options, Provider}
  alias ASM.ProviderBackend.Proxy

  @claude_options_module Module.concat(["ClaudeAgentSDK", "Options"])
  @gemini_options_module Module.concat(["GeminiCliSdk", "Options"])
  @amp_options_module Module.concat(["AmpSdk", "Types", "Options"])
  @codex_options_module Module.concat(["Codex", "Options"])
  @codex_thread_options_module Module.concat(["Codex", "Thread", "Options"])
  @codex_exec_options_module Module.concat(["Codex", "Exec", "Options"])

  @impl true
  def start_run(%{provider: %Provider{} = provider} = config) do
    with {:ok, execution_config = %Execution.Config{execution_mode: :local}} <-
           fetch_execution_config(config),
         :ok <- validate_approval_posture(execution_config),
         runtime when is_atom(runtime) <- provider.sdk_runtime,
         true <- Code.ensure_loaded?(runtime),
         {:ok, start_opts} <- build_start_opts(provider, config),
         {:ok, proxy, info} <-
           Proxy.start_link(
             starter: fn subscriber ->
               runtime.start_session(Keyword.put(start_opts, :subscriber, subscriber))
             end,
             runtime_api: runtime,
             runtime: runtime,
             provider: provider.name,
             lane: :sdk,
             backend: __MODULE__,
             capabilities: runtime_capabilities(runtime),
             initial_subscribers: initial_subscribers(config)
           ) do
      {:ok, proxy, info}
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
    Proxy.send_input(session, input, opts)
  end

  @impl true
  def end_input(session) when is_pid(session) do
    Proxy.end_input(session)
  end

  @impl true
  def interrupt(session) when is_pid(session) do
    Proxy.interrupt(session)
  end

  @impl true
  def close(session) when is_pid(session) do
    Proxy.close(session)
  end

  @impl true
  def subscribe(session, pid, ref) when is_pid(session) and is_pid(pid) and is_reference(ref) do
    Proxy.subscribe(session, pid, ref)
  end

  @impl true
  def info(session) when is_pid(session) do
    Proxy.info(session)
  end

  defp fetch_execution_config(%{execution_config: %Execution.Config{} = config}),
    do: {:ok, config}

  defp fetch_execution_config(_config) do
    {:error, Error.new(:config_invalid, :config, "missing execution config for sdk backend")}
  end

  defp build_start_opts(%Provider{name: :claude, sdk_runtime: runtime}, config) do
    with {:ok, provider_opts} <-
           Options.finalize_provider_opts(
             :claude,
             effective_provider_opts(config, Map.get(config, :execution_config))
           ),
         config = Map.put(config, :provider_opts, provider_opts),
         model_payload = Keyword.fetch!(provider_opts, :model_payload),
         {:ok, options} <-
           new_sdk_struct(
             @claude_options_module,
             claude_option_attrs(config, model_payload),
             "claude"
           ) do
      {:ok,
       sdk_start_opts(runtime, config,
         options: options,
         max_stderr_buffer_size: kw(config, :max_stderr_buffer_bytes),
         metadata: %{lane: :sdk, asm_provider: :claude}
       )}
    end
  end

  defp build_start_opts(%Provider{name: :gemini, sdk_runtime: runtime}, config) do
    with {:ok, provider_opts} <-
           Options.finalize_provider_opts(
             :gemini,
             effective_provider_opts(config, Map.get(config, :execution_config))
           ),
         config = Map.put(config, :provider_opts, provider_opts),
         model_payload = Keyword.fetch!(provider_opts, :model_payload),
         {:ok, options} <-
           build_sdk_struct(
             @gemini_options_module,
             gemini_option_attrs(config, model_payload),
             "gemini"
           ),
         {:ok, options} <- validate_sdk_struct(@gemini_options_module, options, "gemini") do
      {:ok,
       sdk_start_opts(runtime, config,
         prompt: Map.fetch!(config, :prompt),
         options: options,
         metadata: %{lane: :sdk, asm_provider: :gemini}
       )}
    end
  end

  defp build_start_opts(%Provider{name: :amp, sdk_runtime: runtime}, config) do
    with {:ok, provider_opts} <-
           Options.finalize_provider_opts(
             :amp,
             effective_provider_opts(config, Map.get(config, :execution_config))
           ),
         config = Map.put(config, :provider_opts, provider_opts),
         model_payload = Keyword.fetch!(provider_opts, :model_payload),
         {:ok, options} <-
           build_sdk_struct(@amp_options_module, amp_option_attrs(config, model_payload), "amp") do
      {:ok,
       sdk_start_opts(runtime, config,
         input: Map.fetch!(config, :prompt),
         options: options,
         metadata: %{lane: :sdk, asm_provider: :amp}
       )}
    end
  end

  defp build_start_opts(%Provider{name: :codex, sdk_runtime: runtime}, config) do
    with {:ok, provider_opts} <-
           Options.finalize_provider_opts(
             :codex,
             effective_provider_opts(config, Map.get(config, :execution_config))
           ),
         config = Map.put(config, :provider_opts, provider_opts),
         model_payload = Keyword.fetch!(provider_opts, :model_payload),
         {:ok, codex_opts} <-
           new_sdk_struct(
             @codex_options_module,
             codex_option_attrs(config, model_payload),
             "codex"
           ),
         {:ok, thread_opts} <-
           new_sdk_struct(
             @codex_thread_options_module,
             codex_thread_option_attrs(config, model_payload),
             "codex"
           ),
         {:ok, exec_opts} <-
           new_sdk_struct(
             @codex_exec_options_module,
             codex_exec_option_attrs(codex_opts, thread_opts, config),
             "codex"
           ) do
      {:ok,
       sdk_start_opts(runtime, config,
         input: Map.fetch!(config, :prompt),
         exec_opts: exec_opts,
         metadata: %{lane: :sdk, asm_provider: :codex}
       )}
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp sdk_start_opts(_runtime, config, extra) do
    metadata =
      Map.merge(
        Map.get(config, :metadata, %{}),
        Keyword.get(extra, :metadata, %{})
      )

    extra
    |> Keyword.put(:metadata, metadata)
  end

  defp validate_approval_posture(execution_config) when is_map(execution_config) do
    if Map.get(execution_config, :approval_posture) == :none do
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

  defp validate_approval_posture(_execution_config), do: :ok

  defp effective_provider_opts(config, execution_config) when is_map(execution_config) do
    config
    |> Map.get(:provider_opts, [])
    |> maybe_put_new(:cwd, Map.get(execution_config, :workspace_root))
    |> maybe_put(:permission_mode, Map.get(execution_config, :permission_mode))
    |> maybe_put(
      :provider_permission_mode,
      Map.get(execution_config, :provider_permission_mode)
    )
  end

  defp effective_provider_opts(config, _execution_config), do: Map.get(config, :provider_opts, [])

  defp gemini_approval_mode(nil), do: nil
  defp gemini_approval_mode(:default), do: nil
  defp gemini_approval_mode(mode), do: mode

  defp claude_option_attrs(config, model_payload) do
    [
      cwd: kw(config, :cwd),
      env: kw(config, :env, %{}),
      path_to_claude_code_executable: kw(config, :cli_path),
      permission_mode: kw(config, :provider_permission_mode),
      model_payload: model_payload,
      model: model_payload_value(model_payload, :resolved_model),
      max_turns: kw(config, :max_turns),
      system_prompt: kw(config, :system_prompt),
      append_system_prompt: kw(config, :append_system_prompt),
      include_partial_messages: true,
      output_format: :stream_json,
      timeout_ms: kw(config, :transport_timeout_ms)
    ]
    |> drop_nil_values()
  end

  defp gemini_option_attrs(config, model_payload) do
    [
      model_payload: model_payload,
      model: model_payload_value(model_payload, :resolved_model),
      yolo: kw(config, :provider_permission_mode) == :yolo,
      approval_mode: gemini_approval_mode(kw(config, :provider_permission_mode)),
      sandbox: kw(config, :sandbox, false),
      extensions: kw(config, :extensions, []),
      cwd: kw(config, :cwd),
      env: kw(config, :env, %{}),
      timeout_ms: kw(config, :transport_timeout_ms),
      max_stderr_buffer_bytes: kw(config, :max_stderr_buffer_bytes)
    ]
    |> drop_nil_values()
  end

  defp amp_option_attrs(config, model_payload) do
    [
      model_payload: model_payload,
      cwd: kw(config, :cwd),
      mode: kw(config, :mode, "smart"),
      dangerously_allow_all: kw(config, :provider_permission_mode) == :dangerously_allow_all,
      env: kw(config, :env, %{}),
      thinking: kw(config, :include_thinking, false),
      stream_timeout_ms: kw(config, :transport_timeout_ms),
      max_stderr_buffer_bytes: kw(config, :max_stderr_buffer_bytes),
      no_ide: true,
      no_notifications: true
    ]
    |> drop_nil_values()
  end

  defp codex_option_attrs(config, model_payload) do
    [
      model_payload: model_payload,
      model: model_payload_value(model_payload, :resolved_model),
      reasoning_effort: reasoning_atom(model_payload_value(model_payload, :reasoning)),
      codex_path_override: kw(config, :cli_path)
    ]
    |> drop_nil_values()
  end

  defp codex_thread_option_attrs(config, model_payload) do
    [
      working_directory: kw(config, :cwd),
      oss: codex_payload_oss?(model_payload),
      local_provider: codex_payload_oss_provider(model_payload),
      model_provider: codex_payload_model_provider(model_payload),
      full_auto: kw(config, :provider_permission_mode) == :auto_edit,
      dangerously_bypass_approvals_and_sandbox: kw(config, :provider_permission_mode) == :yolo,
      output_schema: kw(config, :output_schema)
    ]
    |> drop_nil_values()
  end

  defp codex_exec_option_attrs(codex_opts, thread_opts, config) do
    [
      codex_opts: codex_opts,
      thread: thread_opts,
      timeout_ms: kw(config, :transport_timeout_ms),
      max_stderr_buffer_bytes: kw(config, :max_stderr_buffer_bytes)
    ]
    |> drop_nil_values()
  end

  defp new_sdk_struct(module, attrs, provider_name) when is_atom(module) do
    with :ok <- ensure_sdk_module(module, provider_name),
         true <- function_exported?(module, :new, 1) do
      case module.new(attrs) do
        {:ok, value} ->
          {:ok, value}

        {:error, reason} ->
          {:error, invalid_sdk_options(provider_name, reason)}

        value ->
          {:ok, value}
      end
    else
      false ->
        build_sdk_struct(module, attrs, provider_name)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  rescue
    error ->
      {:error, invalid_sdk_options(provider_name, error)}
  end

  defp build_sdk_struct(module, attrs, provider_name) when is_atom(module) do
    with :ok <- ensure_sdk_module(module, provider_name) do
      {:ok, struct(module, attrs)}
    end
  rescue
    error in [ArgumentError] ->
      {:error, invalid_sdk_options(provider_name, error)}
  end

  defp validate_sdk_struct(module, options, provider_name) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :validate!, 1) do
      {:ok, module.validate!(options)}
    else
      {:ok, options}
    end
  rescue
    error in [ArgumentError] ->
      {:error, invalid_sdk_options(provider_name, error)}
  end

  defp ensure_sdk_module(module, provider_name) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      :ok
    else
      {:error,
       Error.new(
         :config_invalid,
         :provider,
         "sdk module is unavailable for #{provider_name}: #{inspect(module)}",
         cause: module
       )}
    end
  end

  defp kw(config, key, default \\ nil) do
    config
    |> Map.get(:provider_opts, [])
    |> Keyword.get(key, default)
  end

  defp maybe_put(provider_opts, _key, nil), do: provider_opts
  defp maybe_put(provider_opts, key, value), do: Keyword.put(provider_opts, key, value)

  defp maybe_put_new(provider_opts, _key, nil), do: provider_opts
  defp maybe_put_new(provider_opts, key, value), do: Keyword.put_new(provider_opts, key, value)

  defp drop_nil_values(attrs) when is_list(attrs) do
    Enum.reject(attrs, fn {_key, value} -> is_nil(value) end)
  end

  defp model_payload_value(
         %CliSubprocessCore.ModelRegistry.Selection{} = payload,
         key
       )
       when is_atom(key) do
    Map.get(payload, key)
  end

  defp reasoning_atom(nil), do: nil
  defp reasoning_atom(value) when is_atom(value), do: value
  defp reasoning_atom(value) when is_binary(value), do: String.to_atom(value)

  defp codex_payload_oss?(payload) when is_map(payload) do
    model_payload_value(payload, :provider_backend) in [:oss, "oss"]
  end

  defp codex_payload_oss_provider(payload) when is_map(payload) do
    payload
    |> codex_payload_backend_metadata()
    |> Map.get("oss_provider")
  end

  defp codex_payload_model_provider(payload) when is_map(payload) do
    payload
    |> codex_payload_backend_metadata()
    |> Map.get("model_provider")
  end

  defp codex_payload_backend_metadata(payload) when is_map(payload) do
    Map.get(payload, :backend_metadata, Map.get(payload, "backend_metadata", %{}))
  end

  defp invalid_sdk_options(provider_name, reason) do
    Error.new(
      :config_invalid,
      :config,
      "invalid #{provider_name} sdk options: #{inspect(reason)}",
      cause: reason
    )
  end

  defp runtime_capabilities(runtime) when is_atom(runtime) do
    if Code.ensure_loaded?(runtime) and function_exported?(runtime, :capabilities, 0) do
      runtime.capabilities()
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
end
