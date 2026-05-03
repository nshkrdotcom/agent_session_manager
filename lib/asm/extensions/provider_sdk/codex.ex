defmodule ASM.Extensions.ProviderSDK.Codex do
  @moduledoc """
  Discovery metadata and bridge helpers for the optional Codex-native ASM
  extension namespace.

  This namespace lives above ASM's normalized kernel.

  It does not implement Codex's richer APIs itself. Instead it:

  - publishes discovery metadata for the optional Codex-native surface
  - derives `Codex.Options` from ASM-style configuration, including normalized
    execution-surface data for CLI-backed families
  - derives `Codex.Thread.Options` from ASM-style configuration or session
    defaults
  - starts `Codex.AppServer` connections when callers explicitly opt into the
    SDK-local app-server family

  The actual app-server, MCP, realtime, and voice families remain in
  `codex_sdk`.
  """

  alias ASM.{Error, Options, Provider, ProviderRegistry}
  alias ASM.Extensions.ProviderSDK.{Derivation, Dispatch, Extension, SessionOptions}

  @sdk_app :codex_sdk
  @sdk_module Module.concat(["Codex"])
  @sdk_options_module Module.concat(["Codex", "Options"])
  @thread_options_module Module.concat(["Codex", "Thread", "Options"])
  @app_server_module Module.concat(["Codex", "AppServer"])
  @native_capabilities [:app_server, :mcp, :realtime, :voice]
  @asm_derived_codex_option_keys [
    :model,
    :reasoning_effort,
    :reasoning,
    :codex_path_override,
    :codex_path
  ]
  @asm_derived_thread_option_keys [
    :working_directory,
    :cd,
    :additional_directories,
    :full_auto,
    :dangerously_bypass_approvals_and_sandbox,
    :skip_git_repo_check,
    :output_schema,
    :approval_timeout_ms
  ]
  @strict_derived_codex_option_keys [
    :execution_surface,
    :model,
    :codex_path_override
  ]

  @native_surface_modules [
    @app_server_module,
    Module.concat(["Codex", "MCP", "Client"]),
    Module.concat(["Codex", "Realtime"]),
    Module.concat(["Codex", "Voice"])
  ]

  @spec extension() :: Extension.t()
  def extension do
    Extension.new!(
      id: :codex,
      provider: :codex,
      namespace: __MODULE__,
      sdk_app: @sdk_app,
      sdk_module: @sdk_module,
      description: "Optional Codex-native extension namespace above the normalized ASM kernel.",
      sdk_available?: available?(),
      native_capabilities: @native_capabilities,
      native_surface_modules: @native_surface_modules
    )
  end

  @spec available?() :: boolean()
  def available?, do: ProviderRegistry.sdk_available?(:codex)

  @spec sdk_app() :: atom()
  def sdk_app, do: @sdk_app

  @spec sdk_module() :: module()
  def sdk_module, do: @sdk_module

  @doc """
  Derives `Codex.Options` from strict common ASM options.

  Provider-native Codex options must be supplied in `:native_overrides`; they
  are never read from the generic ASM option map.
  """
  @spec derive_options(keyword(), keyword()) :: {:ok, struct()} | {:error, term()}
  def derive_options(asm_common, opts \\ [])
      when is_list(asm_common) and is_list(opts) do
    native_overrides = Keyword.get(opts, :native_overrides, [])

    with {:ok, preflight} <- Derivation.strict_common(:codex, asm_common),
         :ok <-
           Derivation.ensure_native_override_boundary(
             native_overrides,
             @strict_derived_codex_option_keys,
             "Codex"
           ) do
      attrs =
        preflight.common
        |> strict_codex_option_attrs()
        |> Keyword.merge(native_overrides)

      new_sdk_struct(@sdk_options_module, attrs, "codex")
    end
  end

  @doc """
  Derives `Codex.Options` from ASM-style Codex configuration.

  `native_overrides` remains the explicit home for Codex-native global SDK
  settings such as config overrides, model personality, review model, or
  history settings. Execution-surface placement stays on `asm_opts`.
  """
  @spec codex_options(keyword(), keyword()) :: {:ok, struct()} | {:error, Error.t()}
  def codex_options(asm_opts, native_overrides \\ [])
      when is_list(asm_opts) and is_list(native_overrides) do
    with :ok <- ensure_sdk_module(@sdk_options_module, "Codex SDK options"),
         {:ok, %{validated: validated, execution_surface: execution_surface}} <-
           validate_asm_options(asm_opts),
         :ok <-
           ensure_native_override_boundary(
             native_overrides,
             @asm_derived_codex_option_keys,
             "Codex native_overrides"
           ),
         attrs <-
           Keyword.merge(codex_option_attrs(validated, execution_surface), native_overrides) do
      new_sdk_struct(@sdk_options_module, attrs, "codex")
    end
  end

  @doc """
  Derives `Codex.Options` from an ASM session plus optional ASM/native
  overrides.
  """
  @spec codex_options_for_session(term(), keyword(), keyword()) ::
          {:ok, struct()} | {:error, Error.t()}
  def codex_options_for_session(session, asm_overrides \\ [], native_overrides \\ [])
      when is_list(asm_overrides) and is_list(native_overrides) do
    with {:ok, asm_opts} <- asm_options_from_session(session, asm_overrides) do
      codex_options(asm_opts, native_overrides)
    end
  end

  @doc """
  Derives `Codex.Thread.Options` from ASM-style Codex configuration.

  ASM-derived thread defaults such as working directory, approval timeout, exec
  permission mode, and output schema stay on the ASM argument. Richer
  Codex-native fields such as personality, collaboration mode, attachments, or
  app-server family selection belong in `native_overrides`.
  """
  @spec thread_options(keyword(), keyword()) :: {:ok, struct()} | {:error, Error.t()}
  def thread_options(asm_opts, native_overrides \\ [])
      when is_list(asm_opts) and is_list(native_overrides) do
    with :ok <- ensure_sdk_module(@thread_options_module, "Codex thread options"),
         {:ok, %{validated: validated}} <- validate_asm_options(asm_opts),
         :ok <-
           ensure_native_override_boundary(
             native_overrides,
             @asm_derived_thread_option_keys,
             "Codex native_overrides"
           ),
         {:ok, finalized} <-
           Options.finalize_provider_opts(:codex, Keyword.delete(validated, :provider)),
         model_payload = Keyword.fetch!(finalized, :model_payload),
         attrs <- Keyword.merge(thread_option_attrs(finalized, model_payload), native_overrides) do
      new_sdk_struct(@thread_options_module, attrs, "codex")
    end
  end

  @doc """
  Derives `Codex.Thread.Options` from an ASM session plus optional ASM/native
  overrides.
  """
  @spec thread_options_for_session(term(), keyword(), keyword()) ::
          {:ok, struct()} | {:error, Error.t()}
  def thread_options_for_session(session, asm_overrides \\ [], native_overrides \\ [])
      when is_list(asm_overrides) and is_list(native_overrides) do
    with {:ok, asm_opts} <- asm_options_from_session(session, asm_overrides) do
      thread_options(asm_opts, native_overrides)
    end
  end

  @doc """
  Starts `Codex.AppServer` from ASM-style Codex configuration.

  ASM configuration stays on the first argument. Codex-native global overrides
  stay in `native_overrides`. App-server child launch overrides such as
  `:experimental_api`, `:cwd`, `:process_env`, or an explicit
  `:execution_surface` override stay in `connect_opts`.
  """
  @spec connect_app_server(keyword(), keyword(), keyword()) ::
          {:ok, pid()} | {:error, Error.t() | term()}
  def connect_app_server(asm_opts, native_overrides \\ [], connect_opts \\ [])
      when is_list(asm_opts) and is_list(native_overrides) and is_list(connect_opts) do
    with :ok <- ensure_sdk_module(@app_server_module, "Codex app-server"),
         {:ok, options} <- codex_options(asm_opts, native_overrides) do
      connect_sdk_app_server(options, connect_opts)
    end
  end

  @doc """
  Starts `Codex.AppServer` from an ASM session plus optional ASM/native
  overrides.
  """
  @spec connect_app_server_for_session(term(), keyword(), keyword(), keyword()) ::
          {:ok, pid()} | {:error, Error.t() | term()}
  def connect_app_server_for_session(
        session,
        asm_overrides \\ [],
        native_overrides \\ [],
        connect_opts \\ []
      )
      when is_list(asm_overrides) and is_list(native_overrides) and is_list(connect_opts) do
    with {:ok, asm_opts} <- asm_options_from_session(session, asm_overrides) do
      connect_app_server(asm_opts, native_overrides, connect_opts)
    end
  end

  @spec native_capabilities() :: [atom()]
  def native_capabilities, do: @native_capabilities

  @spec native_surface_modules() :: [module()]
  def native_surface_modules, do: @native_surface_modules

  defp asm_options_from_session(session, asm_overrides) do
    case ASM.session_info(session) do
      {:ok, %{provider: provider, options: options}} when is_list(options) ->
        case resolve_codex_provider(provider) do
          {:ok, :codex} ->
            {:ok,
             options
             |> SessionOptions.provider_opts()
             |> Keyword.put(:provider, :codex)
             |> Keyword.merge(asm_overrides)}

          {:error, %Error{} = error} ->
            {:error, error}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp validate_asm_options(asm_opts) do
    provider_schema = Provider.resolve!(:codex).options_schema
    asm_opts = SessionOptions.provider_opts(asm_opts)

    with {:ok, execution_surface, stripped_opts} <-
           SessionOptions.extract_execution_surface(asm_opts),
         {:ok, :codex} <- resolve_codex_provider(Keyword.get(stripped_opts, :provider, :codex)),
         {:ok, validated} <-
           Options.validate(Keyword.put(stripped_opts, :provider, :codex), provider_schema) do
      {:ok, %{validated: validated, execution_surface: execution_surface}}
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp resolve_codex_provider(provider) do
    case Provider.resolve(provider) do
      {:ok, %Provider{name: :codex}} ->
        {:ok, :codex}

      {:ok, %Provider{name: other}} ->
        {:error, invalid_provider_error(other)}

      {:error, %Error{}} ->
        {:error, invalid_provider_error(provider)}
    end
  end

  defp invalid_provider_error(provider) do
    Error.new(
      :config_invalid,
      :provider,
      "Codex extension requires provider :codex, got #{inspect(provider)}"
    )
  end

  defp ensure_native_override_boundary(native_overrides, asm_derived_keys, label)
       when is_list(native_overrides) and is_list(asm_derived_keys) do
    conflicts =
      native_overrides
      |> Keyword.keys()
      |> Enum.uniq()
      |> Enum.filter(&(&1 in asm_derived_keys))

    if conflicts == [] do
      :ok
    else
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "#{label} must not redefine ASM-derived options: " <>
           Enum.map_join(conflicts, ", ", &inspect/1) <> ". Set those fields in asm_opts instead.",
         cause: conflicts
       )}
    end
  end

  defp codex_option_attrs(validated, execution_surface) do
    {:ok, finalized} =
      Options.finalize_provider_opts(:codex, Keyword.delete(validated, :provider))

    model_payload = Keyword.fetch!(finalized, :model_payload)

    [
      execution_surface: execution_surface,
      model_payload: model_payload,
      model: model_payload_value(model_payload, :resolved_model),
      reasoning_effort: reasoning_atom(model_payload_value(model_payload, :reasoning)),
      codex_path_override: Keyword.get(finalized, :cli_path)
    ]
    |> drop_nil_values()
  end

  defp strict_codex_option_attrs(common) when is_map(common) do
    []
    |> Derivation.maybe_put(:execution_surface, Map.get(common, :execution_surface))
    |> Derivation.maybe_put(:model, Map.get(common, :model))
    |> Derivation.maybe_put(:codex_path_override, Map.get(common, :cli_path))
  end

  defp thread_option_attrs(validated, model_payload) do
    [
      working_directory: Keyword.get(validated, :cwd),
      additional_directories: Keyword.get(validated, :additional_directories, []),
      approval_timeout_ms: Keyword.get(validated, :approval_timeout_ms),
      oss: codex_payload_oss?(model_payload),
      local_provider: codex_payload_oss_provider(model_payload),
      model_provider: codex_payload_model_provider(model_payload),
      full_auto: Keyword.get(validated, :provider_permission_mode) == :auto_edit,
      dangerously_bypass_approvals_and_sandbox:
        Keyword.get(validated, :provider_permission_mode) == :yolo,
      skip_git_repo_check: Keyword.get(validated, :skip_git_repo_check, false),
      output_schema: Keyword.get(validated, :output_schema)
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
    case value |> String.trim() |> String.downcase() do
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
      "invalid #{provider_name} SDK options: #{Exception.message(reason)}",
      cause: reason
    )
  rescue
    error in [Protocol.UndefinedError, FunctionClauseError] ->
      Error.new(
        :config_invalid,
        :config,
        "invalid #{provider_name} SDK options: #{inspect(reason)}",
        cause: error
      )
  end

  defp connect_sdk_app_server(options, connect_opts) when is_list(connect_opts) do
    with :ok <- ensure_sdk_module(@app_server_module, "Codex app-server"),
         true <- function_exported?(@app_server_module, :connect, 2) do
      module = @app_server_module
      Dispatch.invoke_2(module, :connect, options, connect_opts)
    else
      false ->
        {:error,
         Error.new(
           :config_invalid,
           :provider,
           "Codex app-server is missing connect/2",
           cause: @app_server_module
         )}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end
end
