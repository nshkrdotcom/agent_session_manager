defmodule ASM.Extensions.ProviderSDK.Claude do
  @moduledoc """
  Discovery metadata and bridge helpers for the optional Claude-native ASM
  extension namespace.

  This namespace lives above ASM's normalized kernel.

  It does not implement Claude's richer control semantics itself. Instead it:

  - publishes discovery metadata for the optional Claude-native surface
  - derives `ClaudeAgentSDK.Options` from ASM-style configuration
  - starts `ClaudeAgentSDK.Client` when callers explicitly opt into the
    SDK-local control family

  The actual control family remains in `claude_agent_sdk`.
  """

  alias ASM.{Error, Options, Provider, ProviderRegistry}
  alias ASM.Extensions.ProviderSDK.{Dispatch, Extension}

  @sdk_app :claude_agent_sdk
  @sdk_module Module.concat(["ClaudeAgentSDK"])
  @sdk_client_module Module.concat(["ClaudeAgentSDK", "Client"])
  @sdk_options_module Module.concat(["ClaudeAgentSDK", "Options"])
  @hooks_module Module.concat(["ClaudeAgentSDK", "Hooks"])
  @permission_module Module.concat(["ClaudeAgentSDK", "Permission"])
  @control_protocol_module Module.concat(["ClaudeAgentSDK", "ControlProtocol", "Protocol"])
  @asm_derived_sdk_option_keys [
    :cwd,
    :env,
    :path_to_claude_code_executable,
    :permission_mode,
    :model,
    :max_turns,
    :timeout_ms
  ]
  @native_capabilities [:control_client, :control_protocol, :hooks, :permission_callbacks]

  @native_surface_modules [
    @sdk_client_module,
    @control_protocol_module,
    @hooks_module,
    @permission_module
  ]

  @spec extension() :: Extension.t()
  def extension do
    Extension.new!(
      id: :claude,
      provider: :claude,
      namespace: __MODULE__,
      sdk_app: @sdk_app,
      sdk_module: @sdk_module,
      description: "Optional Claude-native extension namespace above the normalized ASM kernel.",
      sdk_available?: available?(),
      native_capabilities: @native_capabilities,
      native_surface_modules: @native_surface_modules
    )
  end

  @spec available?() :: boolean()
  def available?, do: ProviderRegistry.sdk_available?(:claude)

  @doc """
  Returns the SDK-local Claude client module.
  """
  @spec client_module() :: module()
  def client_module, do: @sdk_client_module

  @spec sdk_app() :: atom()
  def sdk_app, do: @sdk_app

  @spec sdk_module() :: module()
  def sdk_module, do: @sdk_module

  @doc """
  Returns the Claude SDK control protocol module.
  """
  @spec control_protocol_module() :: module()
  def control_protocol_module, do: @control_protocol_module

  @doc """
  Returns the Claude SDK hooks module.
  """
  @spec hooks_module() :: module()
  def hooks_module, do: @hooks_module

  @doc """
  Returns the Claude SDK permission module.
  """
  @spec permission_module() :: module()
  def permission_module, do: @permission_module

  @spec native_capabilities() :: [atom()]
  def native_capabilities, do: @native_capabilities

  @spec native_surface_modules() :: [module()]
  def native_surface_modules, do: @native_surface_modules

  @doc """
  Derives `ClaudeAgentSDK.Options` from ASM-style Claude configuration.

  `native_overrides` remains the explicit home for Claude-native options such as
  hooks, permission callbacks, SDK MCP servers, file checkpointing, or thinking
  configuration. Those fields are not normalized into ASM's kernel API.
  """
  @spec sdk_options(keyword(), keyword()) :: {:ok, struct()} | {:error, Error.t()}
  def sdk_options(asm_opts, native_overrides \\ [])
      when is_list(asm_opts) and is_list(native_overrides) do
    with :ok <- ensure_sdk_module(@sdk_options_module, "Claude SDK options"),
         {:ok, validated} <- validate_asm_options(asm_opts),
         :ok <- ensure_native_override_boundary(native_overrides),
         attrs <- sdk_option_attrs(validated, native_overrides) do
      build_sdk_options(attrs)
    end
  end

  @doc """
  Derives `ClaudeAgentSDK.Options` from an ASM session plus optional ASM/native
  overrides.
  """
  @spec sdk_options_for_session(term(), keyword(), keyword()) ::
          {:ok, struct()} | {:error, Error.t()}
  def sdk_options_for_session(session, asm_overrides \\ [], native_overrides \\ [])
      when is_list(asm_overrides) and is_list(native_overrides) do
    with {:ok, asm_opts} <- asm_options_from_session(session, asm_overrides) do
      sdk_options(asm_opts, native_overrides)
    end
  end

  @doc """
  Starts `ClaudeAgentSDK.Client` from ASM-style Claude configuration.

  ASM configuration stays on the first argument. Claude-native options live in
  `native_overrides`. Direct client startup knobs such as `:transport` live in
  `client_opts`.
  """
  @spec start_client(keyword(), keyword(), keyword()) ::
          GenServer.on_start() | {:error, Error.t() | term()}
  def start_client(asm_opts, native_overrides \\ [], client_opts \\ [])
      when is_list(asm_opts) and is_list(native_overrides) and is_list(client_opts) do
    with :ok <- ensure_sdk_module(@sdk_client_module, "Claude SDK client"),
         {:ok, options} <- sdk_options(asm_opts, native_overrides) do
      start_sdk_client(options, client_opts)
    end
  end

  @doc """
  Starts `ClaudeAgentSDK.Client` from an ASM session plus optional ASM/native
  overrides.
  """
  @spec start_client_for_session(term(), keyword(), keyword(), keyword()) ::
          GenServer.on_start() | {:error, Error.t() | term()}
  def start_client_for_session(
        session,
        asm_overrides \\ [],
        native_overrides \\ [],
        client_opts \\ []
      )
      when is_list(asm_overrides) and is_list(native_overrides) and is_list(client_opts) do
    with {:ok, asm_opts} <- asm_options_from_session(session, asm_overrides) do
      start_client(asm_opts, native_overrides, client_opts)
    end
  end

  defp asm_options_from_session(session, asm_overrides) do
    case ASM.session_info(session) do
      {:ok, %{provider: :claude, options: options}} when is_list(options) ->
        {:ok, Keyword.merge(Keyword.put(options, :provider, :claude), asm_overrides)}

      {:ok, %{provider: provider}} ->
        {:error,
         Error.new(
           :config_invalid,
           :provider,
           "Claude extension requires an ASM Claude session, got #{inspect(provider)}"
         )}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp validate_asm_options(asm_opts) do
    provider_schema = Provider.resolve!(:claude).options_schema

    case Keyword.get(asm_opts, :provider, :claude) do
      :claude ->
        Options.validate(Keyword.put(asm_opts, :provider, :claude), provider_schema)

      other ->
        {:error,
         Error.new(
           :config_invalid,
           :provider,
           "Claude extension requires provider :claude, got #{inspect(other)}"
         )}
    end
  end

  defp sdk_option_attrs(validated, native_overrides) do
    validated
    |> base_sdk_option_attrs()
    |> maybe_add_thinking(validated, native_overrides)
    |> Keyword.merge(native_overrides)
  end

  defp ensure_native_override_boundary(native_overrides) when is_list(native_overrides) do
    conflicts =
      native_overrides
      |> Keyword.keys()
      |> Enum.uniq()
      |> Enum.filter(&(&1 in @asm_derived_sdk_option_keys))

    if conflicts == [] do
      :ok
    else
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "Claude native_overrides must not redefine ASM-derived options: " <>
           Enum.map_join(conflicts, ", ", &inspect/1) <> ". Set those fields in asm_opts instead.",
         cause: conflicts
       )}
    end
  end

  defp base_sdk_option_attrs(validated) do
    {:ok, model_payload} = Options.resolve_model_payload(:claude, validated)

    [
      cwd: Keyword.get(validated, :cwd),
      env: Keyword.get(validated, :env, %{}),
      path_to_claude_code_executable: Keyword.get(validated, :cli_path),
      permission_mode: Keyword.get(validated, :provider_permission_mode),
      model_payload: model_payload,
      model: model_payload_value(model_payload, :resolved_model),
      max_turns: Keyword.get(validated, :max_turns),
      timeout_ms: Keyword.get(validated, :transport_timeout_ms)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp maybe_add_thinking(attrs, validated, native_overrides) do
    include_thinking? = Keyword.get(validated, :include_thinking, false)

    explicit_thinking? =
      Keyword.has_key?(native_overrides, :thinking) or
        Keyword.has_key?(native_overrides, :max_thinking_tokens)

    if include_thinking? and not explicit_thinking? do
      Keyword.put_new(attrs, :thinking, %{type: :adaptive})
    else
      attrs
    end
  end

  defp build_sdk_options(attrs) do
    new_sdk_struct(@sdk_options_module, attrs)
  rescue
    error ->
      {:error, invalid_sdk_options(error)}
  end

  defp new_sdk_struct(module, attrs) when is_atom(module) do
    with :ok <- ensure_sdk_module(module, "Claude SDK options") do
      if function_exported?(module, :new, 1) do
        {:ok, module.new(attrs)}
      else
        build_sdk_struct(module, attrs)
      end
    end
  rescue
    error in [ArgumentError, KeyError] ->
      {:error, invalid_sdk_options(error)}
  end

  defp build_sdk_struct(module, attrs) when is_atom(module) do
    with :ok <- ensure_sdk_module(module, "Claude SDK options") do
      {:ok, struct(module, attrs)}
    end
  rescue
    error in [ArgumentError, KeyError] ->
      {:error, invalid_sdk_options(error)}
  end

  defp start_sdk_client(options, client_opts) when is_list(client_opts) do
    with :ok <- ensure_sdk_module(@sdk_client_module, "Claude SDK client"),
         true <- function_exported?(@sdk_client_module, :start_link, 2) do
      module = @sdk_client_module
      Dispatch.invoke_2(module, :start_link, options, client_opts)
    else
      false ->
        {:error,
         Error.new(
           :config_invalid,
           :provider,
           "Claude SDK client is missing start_link/2",
           cause: @sdk_client_module
         )}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp invalid_sdk_options(reason) do
    Error.new(
      :config_invalid,
      :config,
      "invalid Claude SDK options for ASM extension: #{describe_invalid_sdk_options(reason)}",
      cause: reason
    )
  end

  defp describe_invalid_sdk_options(reason) do
    Exception.message(reason)
  rescue
    _error in [Protocol.UndefinedError, FunctionClauseError] ->
      inspect(reason)
  end

  defp ensure_sdk_module(module, label) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      :ok
    else
      {:error,
       Error.new(
         :config_invalid,
         :provider,
         "#{label} is unavailable because claude_agent_sdk is not loaded",
         cause: module
       )}
    end
  end

  defp model_payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
  end

  defp model_payload_value(_payload, _key), do: nil
end
