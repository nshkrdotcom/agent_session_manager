defmodule ASM.ProviderBackend.SDK do
  @moduledoc """
  Backend that runs provider SDK runtime kits when available locally.
  """

  @behaviour ASM.ProviderBackend

  alias ASM.{Error, Execution, HostTool, Options, Provider, RuntimeAuth}
  alias ASM.ProviderBackend.Proxy
  alias ASM.ProviderBackend.SDK.CodexAppServer
  alias ASM.RuntimeAuth.CodexMaterialization
  @claude_options_module :"Elixir.ClaudeAgentSDK.Options"
  @gemini_options_module :"Elixir.GeminiCliSdk.Options"
  @amp_options_module :"Elixir.AmpSdk.Types.Options"
  @codex_module :"Elixir.Codex"
  @codex_options_module :"Elixir.Codex.Options"
  @codex_thread_options_module :"Elixir.Codex.Thread.Options"
  @codex_thread_runner_module :"Elixir.Codex.Thread"
  @codex_exec_options_module :"Elixir.Codex.Exec.Options"
  @codex_app_server_module :"Elixir.Codex.AppServer"

  @impl true
  def start_run(%{provider: %Provider{} = provider} = config) do
    with {:ok, execution_config = %Execution.Config{execution_mode: :local}} <-
           fetch_execution_config(config),
         {:ok, execution_surface} <- execution_surface_from_config(execution_config),
         config = Map.put(config, :execution_surface, execution_surface),
         :ok <- validate_approval_posture(execution_config) do
      case codex_app_server_mode(provider, config) do
        :app_server -> start_codex_app_server_run(provider, config)
        :exec -> start_runtime_proxy(provider, config)
      end
    else
      {:ok, %Execution.Config{execution_mode: :remote_node}} ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "sdk lane is not supported for :remote_node execution"
         )}

      {:error, _reason} = error ->
        error

      other ->
        {:error,
         Error.new(:runtime, :runtime, "sdk backend start failed: #{inspect(other)}",
           cause: other
         )}
    end
  end

  defp start_runtime_proxy(%Provider{} = provider, config) do
    with runtime when is_atom(runtime) <- provider.sdk_runtime,
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
    execution_surface = Map.fetch!(config, :execution_surface)

    with {:ok, provider_opts} <-
           Options.finalize_provider_opts(
             :claude,
             effective_provider_opts(config, Map.get(config, :execution_config))
           ),
         :ok <- RuntimeAuth.authorize_governed_provider_runtime(:claude, config, provider_opts),
         config = Map.put(config, :provider_opts, provider_opts),
         model_payload = Keyword.fetch!(provider_opts, :model_payload),
         {:ok, options} <-
           new_sdk_struct(
             @claude_options_module,
             claude_option_attrs(config, model_payload, execution_surface),
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
    execution_surface = Map.fetch!(config, :execution_surface)

    with {:ok, provider_opts} <-
           Options.finalize_provider_opts(
             :gemini,
             effective_provider_opts(config, Map.get(config, :execution_config))
           ),
         :ok <- RuntimeAuth.authorize_governed_provider_runtime(:gemini, config, provider_opts),
         config = Map.put(config, :provider_opts, provider_opts),
         model_payload = Keyword.fetch!(provider_opts, :model_payload),
         {:ok, options} <-
           build_sdk_struct(
             @gemini_options_module,
             gemini_option_attrs(config, model_payload, execution_surface),
             "gemini"
           ) do
      {:ok,
       sdk_start_opts(runtime, config,
         prompt: Map.fetch!(config, :prompt),
         options: options,
         metadata: %{lane: :sdk, asm_provider: :gemini}
       )}
    end
  end

  defp build_start_opts(%Provider{name: :amp, sdk_runtime: runtime}, config) do
    execution_surface = Map.fetch!(config, :execution_surface)

    with {:ok, provider_opts} <-
           Options.finalize_provider_opts(
             :amp,
             effective_provider_opts(config, Map.get(config, :execution_config))
           ),
         :ok <- RuntimeAuth.authorize_governed_provider_runtime(:amp, config, provider_opts),
         config = Map.put(config, :provider_opts, provider_opts),
         model_payload = Keyword.fetch!(provider_opts, :model_payload),
         {:ok, options} <-
           build_sdk_struct(
             @amp_options_module,
             amp_option_attrs(config, model_payload, execution_surface),
             "amp"
           ) do
      {:ok,
       sdk_start_opts(runtime, config,
         input: Map.fetch!(config, :prompt),
         options: options,
         metadata: %{lane: :sdk, asm_provider: :amp}
       )}
    end
  end

  defp build_start_opts(%Provider{name: :codex, sdk_runtime: runtime}, config) do
    execution_surface = Map.fetch!(config, :execution_surface)

    with {:ok, provider_opts} <-
           Options.finalize_provider_opts(
             :codex,
             effective_provider_opts(config, Map.get(config, :execution_config))
           ),
         config = Map.put(config, :provider_opts, provider_opts),
         {:ok, materialization} <- CodexMaterialization.authorize_config(config, provider_opts),
         config = put_codex_materialization(config, materialization),
         model_payload = Keyword.fetch!(provider_opts, :model_payload),
         {:ok, codex_opts} <-
           new_sdk_struct(
             @codex_options_module,
             codex_option_attrs(config, model_payload, execution_surface),
             "codex"
           ),
         {:ok, thread_opts} <-
           new_sdk_struct(
             @codex_thread_options_module,
             codex_thread_option_attrs(config, model_payload),
             "codex"
           ),
         {:ok, thread} <-
           build_codex_thread(codex_opts, thread_opts, Map.get(config, :continuation)),
         {:ok, exec_opts} <-
           new_sdk_struct(
             @codex_exec_options_module,
             codex_exec_option_attrs(codex_opts, thread, config, execution_surface),
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

  defp codex_app_server_requested?(%Provider{name: :codex}, config) do
    provider_opts = Map.get(config, :provider_opts, [])

    Keyword.get(provider_opts, :app_server, false) == true or
      non_empty_keyword_list?(provider_opts, :host_tools) or
      non_empty_keyword_list?(provider_opts, :dynamic_tools)
  end

  defp codex_app_server_requested?(_provider, _config), do: false

  defp codex_app_server_mode(provider, config) do
    if codex_app_server_requested?(provider, config), do: :app_server, else: :exec
  end

  defp start_codex_app_server_run(%Provider{name: :codex} = provider, config) do
    with {:ok, provider_opts} <-
           Options.finalize_provider_opts(
             :codex,
             effective_provider_opts(config, Map.get(config, :execution_config))
           ),
         config = Map.put(config, :provider_opts, provider_opts),
         {:ok, materialization} <- CodexMaterialization.authorize_config(config, provider_opts),
         config = put_codex_materialization(config, materialization),
         model_payload = Keyword.fetch!(provider_opts, :model_payload),
         {:ok, codex_opts} <-
           new_sdk_struct(
             @codex_options_module,
             codex_option_attrs(config, model_payload, Map.fetch!(config, :execution_surface)),
             "codex"
           ),
         {:ok, conn} <- connect_codex_app_server(codex_opts, config),
         {:ok, thread_opts} <-
           new_sdk_struct(
             @codex_thread_options_module,
             codex_app_server_thread_option_attrs(config, model_payload, conn),
             "codex"
           ),
         {:ok, thread} <-
           build_codex_thread(codex_opts, thread_opts, Map.get(config, :continuation)),
         {:ok, pid, info} <-
           CodexAppServer.start_link(
             app_server_api:
               backend_opt(config, :codex_app_server_module, @codex_app_server_module),
             conn: conn,
             thread: thread,
             thread_runner:
               backend_opt(config, :codex_thread_runner_module, @codex_thread_runner_module),
             prompt: Map.fetch!(config, :prompt),
             run_opts: backend_opt(config, :run_opts, []),
             tools: Map.get(config, :tools, %{}),
             metadata: Map.get(config, :metadata, %{}),
             capabilities: [:streaming, :app_server, :host_tools, :session_resume],
             initial_subscribers: initial_subscribers(config)
           ) do
      {:ok, pid, %{info | provider: provider.name, lane: :sdk, backend: __MODULE__}}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(
           :runtime,
           :runtime,
           "codex app-server backend start failed: #{inspect(reason)}",
           cause: reason
         )}
    end
  end

  defp connect_codex_app_server(codex_opts, config) do
    app_server_api = backend_opt(config, :codex_app_server_module, @codex_app_server_module)
    materialization = Map.get(config, :codex_materialization)

    connect_opts =
      [experimental_api: true, init_timeout_ms: 30_000]
      |> Keyword.merge(CodexMaterialization.connect_opts(materialization))
      |> Keyword.merge(backend_opt(config, :connect_opts, []))

    app_server_api.connect(codex_opts, connect_opts)
  end

  defp codex_app_server_thread_option_attrs(config, model_payload, conn) do
    config
    |> codex_thread_option_attrs(model_payload)
    |> Keyword.put(:transport, {:app_server, conn})
    |> Keyword.put(:dynamic_tools, codex_dynamic_tools(config))
  end

  defp codex_dynamic_tools(config) do
    provider_opts = Map.get(config, :provider_opts, [])

    host_dynamic_tools =
      provider_opts
      |> Keyword.get(:host_tools, [])
      |> HostTool.Spec.normalize_list()
      |> case do
        {:ok, specs} -> Enum.map(specs, &HostTool.Spec.to_dynamic_tool/1)
        {:error, _reason} -> []
      end

    host_dynamic_tools ++ Keyword.get(provider_opts, :dynamic_tools, [])
  end

  defp sdk_start_opts(_runtime, config, extra) do
    metadata =
      Map.merge(
        Map.get(config, :metadata, %{}),
        Keyword.get(extra, :metadata, %{})
      )

    extra
    |> Keyword.put(:metadata, metadata)
    |> Keyword.put(:execution_surface, Map.fetch!(config, :execution_surface))
  end

  defp put_codex_materialization(config, nil), do: config

  defp put_codex_materialization(config, %CodexMaterialization{} = materialization) do
    metadata =
      config
      |> Map.get(:metadata, %{})
      |> CodexMaterialization.put_redacted_metadata(materialization)

    config
    |> Map.put(:codex_materialization, materialization)
    |> Map.put(:metadata, metadata)
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

  defp gemini_approval_mode(nil), do: nil
  defp gemini_approval_mode(:default), do: nil
  defp gemini_approval_mode(mode), do: mode

  defp claude_option_attrs(config, model_payload, execution_surface) do
    [
      cwd: kw(config, :cwd),
      env: kw(config, :env, %{}),
      path_to_claude_code_executable: kw(config, :cli_path),
      execution_surface: execution_surface,
      permission_mode: kw(config, :provider_permission_mode),
      model_payload: model_payload,
      model: model_payload_value(model_payload, :resolved_model),
      max_turns: kw(config, :max_turns),
      system_prompt: kw(config, :system_prompt),
      append_system_prompt: kw(config, :append_system_prompt),
      continue_conversation:
        kw(config, :continue_conversation, continuation_continue_conversation(config)),
      resume: kw(config, :resume, continuation_resume_id(config)),
      include_partial_messages: true,
      output_format: :stream_json,
      timeout_ms: kw(config, :transport_timeout_ms)
    ]
    |> drop_nil_values()
  end

  defp gemini_option_attrs(config, model_payload, execution_surface) do
    [
      execution_surface: execution_surface,
      model_payload: model_payload,
      model: model_payload_value(model_payload, :resolved_model),
      system_prompt: kw(config, :system_prompt),
      approval_mode: gemini_approval_mode(kw(config, :provider_permission_mode)),
      sandbox: kw(config, :sandbox, false),
      resume: kw(config, :resume, gemini_resume_value(config)),
      extensions: kw(config, :extensions, []),
      cwd: kw(config, :cwd),
      env: kw(config, :env, %{}),
      timeout_ms: kw(config, :transport_timeout_ms),
      max_stderr_buffer_bytes: kw(config, :max_stderr_buffer_bytes)
    ]
    |> drop_nil_values()
  end

  defp amp_option_attrs(config, model_payload, execution_surface) do
    [
      execution_surface: execution_surface,
      model_payload: model_payload,
      cwd: kw(config, :cwd),
      mode: kw(config, :mode, "smart"),
      continue_thread: kw(config, :continue_thread, amp_continue_thread(config)),
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

  defp codex_option_attrs(config, model_payload, execution_surface) do
    materialization = Map.get(config, :codex_materialization)

    [
      execution_surface: execution_surface,
      model_payload: model_payload,
      model: model_payload_value(model_payload, :resolved_model),
      reasoning_effort: reasoning_atom(model_payload_value(model_payload, :reasoning)),
      codex_path_override: kw(config, :cli_path)
    ]
    |> Keyword.merge(CodexMaterialization.codex_option_attrs(materialization))
    |> drop_nil_values()
  end

  defp codex_thread_option_attrs(config, model_payload) do
    materialization = Map.get(config, :codex_materialization)

    [
      working_directory: kw(config, :cwd),
      additional_directories: kw(config, :additional_directories, []),
      base_instructions: kw(config, :system_prompt),
      oss: codex_payload_oss?(model_payload),
      local_provider: codex_payload_oss_provider(model_payload),
      model_provider: codex_payload_model_provider(model_payload),
      full_auto: kw(config, :provider_permission_mode) == :auto_edit,
      dangerously_bypass_approvals_and_sandbox: kw(config, :provider_permission_mode) == :yolo,
      skip_git_repo_check: kw(config, :skip_git_repo_check, false),
      output_schema: kw(config, :output_schema)
    ]
    |> Keyword.merge(CodexMaterialization.thread_attrs(materialization))
    |> drop_nil_values()
  end

  defp codex_exec_option_attrs(codex_opts, thread, config, execution_surface) do
    materialization = Map.get(config, :codex_materialization)

    [
      codex_opts: codex_opts,
      execution_surface: execution_surface,
      thread: thread,
      timeout_ms: kw(config, :transport_timeout_ms),
      max_stderr_buffer_bytes: kw(config, :max_stderr_buffer_bytes)
    ]
    |> Keyword.merge(CodexMaterialization.exec_attrs(materialization))
    |> drop_nil_values()
  end

  defp build_codex_thread(codex_opts, thread_opts, continuation) do
    with :ok <- ensure_sdk_module(@codex_module, "codex"),
         {:ok, build_fun} <- codex_thread_builder(continuation) do
      case build_fun.(codex_opts, thread_opts) do
        {:ok, thread} ->
          {:ok, thread}

        {:error, reason} ->
          {:error, invalid_sdk_options("codex", reason)}

        thread ->
          {:ok, thread}
      end
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  rescue
    error ->
      {:error, invalid_sdk_options("codex", error)}
  end

  defp codex_thread_builder(%{strategy: :latest}) do
    if function_exported?(@codex_module, :resume_thread, 3) do
      {:ok,
       fn codex_opts, thread_opts ->
         invoke_codex_resume_thread(:last, codex_opts, thread_opts)
       end}
    else
      {:error,
       invalid_sdk_options(
         "codex",
         ArgumentError.exception("Codex.resume_thread/3 is unavailable")
       )}
    end
  end

  defp codex_thread_builder(%{strategy: :exact, provider_session_id: provider_session_id})
       when is_binary(provider_session_id) and provider_session_id != "" do
    if function_exported?(@codex_module, :resume_thread, 3) do
      {:ok,
       fn codex_opts, thread_opts ->
         invoke_codex_resume_thread(provider_session_id, codex_opts, thread_opts)
       end}
    else
      {:error,
       invalid_sdk_options(
         "codex",
         ArgumentError.exception("Codex.resume_thread/3 is unavailable")
       )}
    end
  end

  defp codex_thread_builder(_continuation) do
    if function_exported?(@codex_module, :start_thread, 2) do
      {:ok, fn codex_opts, thread_opts -> invoke_codex_start_thread(codex_opts, thread_opts) end}
    else
      {:error,
       invalid_sdk_options(
         "codex",
         ArgumentError.exception("Codex.start_thread/2 is unavailable")
       )}
    end
  end

  defp invoke_codex_resume_thread(target, codex_opts, thread_opts) do
    :erlang.apply(@codex_module, :resume_thread, [target, codex_opts, thread_opts])
  end

  defp invoke_codex_start_thread(codex_opts, thread_opts) do
    :erlang.apply(@codex_module, :start_thread, [codex_opts, thread_opts])
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

  defp continuation_resume_id(%{
         continuation: %{strategy: :exact, provider_session_id: provider_session_id}
       })
       when is_binary(provider_session_id) and provider_session_id != "",
       do: provider_session_id

  defp continuation_resume_id(_config), do: nil

  defp continuation_continue_conversation(%{continuation: %{strategy: :latest}}), do: true
  defp continuation_continue_conversation(_config), do: nil

  defp gemini_resume_value(%{continuation: %{strategy: :latest}}), do: "latest"
  defp gemini_resume_value(config), do: continuation_resume_id(config)

  defp amp_continue_thread(%{continuation: %{strategy: :latest}}), do: true
  defp amp_continue_thread(config), do: continuation_resume_id(config)

  defp maybe_put(provider_opts, _key, nil), do: provider_opts
  defp maybe_put(provider_opts, key, value), do: Keyword.put(provider_opts, key, value)

  defp non_empty_keyword_list?(keyword, key) when is_list(keyword) do
    case Keyword.get(keyword, key, []) do
      values when is_list(values) -> values != []
      _value -> true
    end
  end

  defp backend_opt(config, key, default) do
    config
    |> Map.get(:backend_opts, [])
    |> Keyword.get(key, default)
  end

  defp execution_surface_from_config(%Execution.Config{} = execution_config) do
    {:ok, Execution.Config.to_execution_surface(execution_config)}
  end

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

  defp reasoning_atom(value) when is_binary(value) do
    case value do
      "none" -> :none
      "minimal" -> :minimal
      "low" -> :low
      "medium" -> :medium
      "high" -> :high
      "xhigh" -> :xhigh
      _other -> nil
    end
  end

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
