defmodule ASM.RuntimeAuth.CodexMaterialization do
  @moduledoc """
  Codex-specific governed materialization guard owned by ASM.

  Codex-native auth, OAuth, and app-server mechanics remain in `codex_sdk`.
  This module only decides whether a governed ASM run may hand a materialized
  Codex command/env/cwd/config-root envelope to that SDK boundary.
  """

  alias ASM.{Error, RuntimeAuth}
  alias CliSubprocessCore.ExecutionSurface

  @default_openai_base_url "https://api.openai.com/v1"
  @metadata_key :codex_materialization
  @materialized_keys [:codex_materialized_runtime, :materialized_runtime]
  @sources [:verified_materializer, :provider_auth_backend]
  @target_auth_postures [
    :auth_state_preinstalled,
    :materialize_on_attach,
    :proxy_only,
    :no_credentials
  ]
  @provider_override_keys [
    :command,
    :cmd,
    :cli_path,
    :codex_path,
    :codex_path_override,
    :cwd,
    :working_directory,
    :env,
    :process_env,
    :config_root,
    :auth_root,
    :codex_home,
    :codex_home_override,
    :config_values,
    :config_overrides,
    :api_key,
    :base_url,
    :openai_base_url,
    :openai_api_key,
    :codex_api_key,
    :provider_backend,
    :model_provider,
    :oss_provider,
    :ollama,
    :ollama_model,
    :ollama_base_url
  ]
  @transport_override_keys [
    :command,
    :cmd,
    :cwd,
    :env,
    :process_env,
    :config_root,
    :auth_root,
    :codex_home,
    :config_values,
    :config_overrides,
    :api_key,
    :base_url,
    :openai_base_url,
    :auth_token,
    :auth_token_env
  ]
  @ambient_env_keys [
    "CODEX_API_KEY",
    "OPENAI_API_KEY",
    "CODEX_HOME",
    "OPENAI_BASE_URL"
  ]
  @provider_env_keys [
    "CODEX_API_KEY",
    "OPENAI_API_KEY",
    "CODEX_HOME",
    "OPENAI_BASE_URL",
    "CODEX_PROVIDER_BACKEND",
    "CODEX_OSS_PROVIDER",
    "CODEX_OLLAMA_BASE_URL"
  ]

  @enforce_keys [
    :command,
    :cwd,
    :env,
    :config_root,
    :credential_lease_ref,
    :native_auth_assertion_ref,
    :connector_binding_ref,
    :provider_account_ref,
    :native_auth_assertion
  ]
  defstruct [
    :command,
    :cwd,
    :env,
    :config_root,
    :credential_lease_ref,
    :native_auth_assertion_ref,
    :connector_binding_ref,
    :provider_account_ref,
    :native_auth_assertion,
    api_key: nil,
    base_url: nil,
    clear_env?: true,
    source: :verified_materializer,
    target_auth_posture: :materialize_on_attach
  ]

  @type t :: %__MODULE__{
          command: String.t(),
          cwd: String.t(),
          env: %{optional(String.t()) => String.t()},
          config_root: String.t(),
          credential_lease_ref: String.t(),
          native_auth_assertion_ref: String.t(),
          connector_binding_ref: String.t(),
          provider_account_ref: String.t(),
          native_auth_assertion: map(),
          api_key: String.t() | nil,
          base_url: String.t() | nil,
          clear_env?: true,
          source: atom(),
          target_auth_posture: atom()
        }

  @spec authorize_config(map(), keyword()) :: {:ok, t() | nil} | {:error, Error.t()}
  def authorize_config(config, provider_opts)
      when is_map(config) and is_list(provider_opts) do
    metadata = Map.get(config, :metadata, %{})
    runtime_auth = Map.get(config, :runtime_auth, metadata)

    if RuntimeAuth.governed_context?(runtime_auth) or RuntimeAuth.governed_context?(metadata) do
      with :ok <- require_governed_authority(runtime_auth, metadata),
           {:ok, materialized_attrs} <- fetch_materialized_runtime(config),
           {:ok, materialization} <- new(materialized_attrs, runtime_auth),
           :ok <- reject_unmanaged_process_env(materialization),
           :ok <- reject_provider_smuggling(provider_opts),
           :ok <- reject_execution_surface_smuggling(Map.get(config, :execution_surface)),
           :ok <- reject_backend_smuggling(Map.get(config, :backend_opts, [])) do
        {:ok, materialization}
      end
    else
      {:ok, nil}
    end
  end

  @spec new(term(), RuntimeAuth.t() | map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = materialization, runtime_auth) do
    validate_materialization(materialization, runtime_auth)
  end

  def new(attrs, runtime_auth) when is_map(attrs) or is_list(attrs) do
    with {:ok, source} <- normalize_source(attr(attrs, :source, :verified_materializer)),
         {:ok, posture} <-
           normalize_target_auth_posture(
             attr(attrs, :target_auth_posture, :materialize_on_attach)
           ),
         {:ok, env} <- normalize_env(attr(attrs, :env, %{})),
         {:ok, config_root} <- required_string(attrs, :config_root),
         {:ok, env} <- put_config_root_env(env, config_root),
         {:ok, assertion_ref} <-
           materialized_ref(attrs, runtime_auth, :native_auth_assertion_ref),
         {:ok, lease_ref} <- materialized_ref(attrs, runtime_auth, :credential_lease_ref),
         {:ok, binding_ref} <- materialized_ref(attrs, runtime_auth, :connector_binding_ref),
         {:ok, account_ref} <- materialized_ref(attrs, runtime_auth, :provider_account_ref),
         {:ok, assertion} <- native_auth_assertion(attrs, assertion_ref) do
      %__MODULE__{
        command: string_attr(attrs, :command) || string_attr(attrs, :codex_path),
        cwd: string_attr(attrs, :cwd),
        env: env,
        config_root: config_root,
        credential_lease_ref: lease_ref,
        native_auth_assertion_ref: assertion_ref,
        connector_binding_ref: binding_ref,
        provider_account_ref: account_ref,
        native_auth_assertion: assertion,
        api_key: string_attr(attrs, :api_key),
        base_url: string_attr(attrs, :base_url),
        clear_env?: attr(attrs, :clear_env?, true),
        source: source,
        target_auth_posture: posture
      }
      |> validate_materialization(runtime_auth)
    end
  end

  def new(attrs, _runtime_auth) do
    {:error,
     config_error(
       "codex materialized runtime must be a map, keyword list, or %#{inspect(__MODULE__)}{}",
       cause: attrs
     )}
  end

  @spec redacted_evidence(t() | nil) :: map() | nil
  def redacted_evidence(nil), do: nil

  def redacted_evidence(%__MODULE__{} = materialization) do
    %{
      source: materialization.source,
      target_auth_posture: materialization.target_auth_posture,
      clear_env?: materialization.clear_env?,
      command: :redacted_materialized_command,
      cwd: :redacted_materialized_cwd,
      config_root: :redacted_materialized_config_root,
      env_keys: materialization.env |> Map.keys() |> Enum.sort(),
      credential_lease_ref: materialization.credential_lease_ref,
      native_auth_assertion_ref: materialization.native_auth_assertion_ref,
      native_auth_introspection_level:
        Map.get(materialization.native_auth_assertion, :introspection_level),
      native_auth_limits: Map.get(materialization.native_auth_assertion, :limits),
      connector_binding_ref: materialization.connector_binding_ref,
      provider_account_ref: materialization.provider_account_ref
    }
  end

  @spec put_redacted_metadata(map(), t() | nil) :: map()
  def put_redacted_metadata(metadata, nil) when is_map(metadata), do: metadata

  def put_redacted_metadata(metadata, %__MODULE__{} = materialization) when is_map(metadata) do
    Map.put(metadata, @metadata_key, redacted_evidence(materialization))
  end

  @spec codex_option_attrs(t() | nil) :: keyword()
  def codex_option_attrs(nil), do: []

  def codex_option_attrs(%__MODULE__{} = materialization) do
    [
      api_key: materialization.api_key || "",
      base_url: materialization.base_url || default_codex_base_url(),
      codex_path_override: materialization.command
    ]
  end

  @spec thread_attrs(t() | nil) :: keyword()
  def thread_attrs(nil), do: []
  def thread_attrs(%__MODULE__{} = materialization), do: [working_directory: materialization.cwd]

  @spec exec_attrs(t() | nil) :: keyword()
  def exec_attrs(nil), do: []

  def exec_attrs(%__MODULE__{} = materialization) do
    [env: materialization.env, clear_env?: materialization.clear_env?]
  end

  @spec connect_opts(t() | nil) :: keyword()
  def connect_opts(nil), do: []

  def connect_opts(%__MODULE__{} = materialization) do
    [
      cwd: materialization.cwd,
      process_env: materialization.env,
      clear_env?: materialization.clear_env?,
      codex_home: materialization.config_root
    ]
  end

  @spec metadata_key() :: atom()
  def metadata_key, do: @metadata_key

  defp require_governed_authority(runtime_auth, metadata) do
    if RuntimeAuth.governed_authority?(runtime_auth) or RuntimeAuth.governed_authority?(metadata) do
      :ok
    else
      {:error,
       config_error(
         "governed Codex strict mode requires credential lease, native auth assertion, authority, connector, and provider-account evidence before materialization",
         cause: %{runtime_auth: runtime_auth, metadata: metadata}
       )}
    end
  end

  defp fetch_materialized_runtime(config) do
    Enum.find_value(@materialized_keys, fn key ->
      case Map.fetch(config, key) do
        {:ok, value} -> {:ok, value}
        :error -> nil
      end
    end) ||
      {:error,
       config_error(
         "governed Codex strict mode requires a materialized runtime from the verified provider-auth materializer"
       )}
  end

  defp validate_materialization(%__MODULE__{} = materialization, runtime_auth) do
    cond do
      not present?(materialization.command) ->
        {:error, config_error("codex materialized runtime is missing command")}

      not present?(materialization.cwd) ->
        {:error, config_error("codex materialized runtime is missing cwd")}

      materialization.clear_env? != true ->
        {:error, config_error("codex materialized runtime must set clear_env? true")}

      not materialized_refs_match?(materialization, runtime_auth) ->
        {:error,
         config_error(
           "codex materialized runtime refs do not match governed runtime_auth binding",
           cause: ref_match_cause(materialization, runtime_auth)
         )}

      true ->
        {:ok, materialization}
    end
  end

  defp reject_unmanaged_process_env(%__MODULE__{} = materialization) do
    unmanaged =
      Enum.filter(@ambient_env_keys, fn key ->
        case System.get_env(key) do
          nil -> false
          "" -> false
          value -> Map.get(materialization.env, key) != value
        end
      end)

    if unmanaged == [] do
      :ok
    else
      {:error,
       config_error(
         "governed Codex strict mode rejects unmanaged ambient provider auth environment",
         cause: %{env_keys: unmanaged}
       )}
    end
  end

  defp reject_provider_smuggling(provider_opts) when is_list(provider_opts) do
    provider_opts
    |> reject_key_smuggling(@provider_override_keys, "provider options")
    |> continue_if_ok(fn ->
      reject_env_smuggling(Keyword.get(provider_opts, :env), "provider env")
    end)
    |> continue_if_ok(fn ->
      reject_model_payload_smuggling(Keyword.get(provider_opts, :model_payload))
    end)
  end

  defp reject_execution_surface_smuggling(nil), do: :ok

  defp reject_execution_surface_smuggling(%ExecutionSurface{} = execution_surface) do
    reject_transport_smuggling(execution_surface.transport_options, "execution_surface")
  end

  defp reject_execution_surface_smuggling(execution_surface) when is_map(execution_surface) do
    execution_surface
    |> attr(:transport_options, [])
    |> reject_transport_smuggling("execution_surface")
  end

  defp reject_execution_surface_smuggling(execution_surface) when is_list(execution_surface) do
    execution_surface
    |> Keyword.get(:transport_options, [])
    |> reject_transport_smuggling("execution_surface")
  end

  defp reject_execution_surface_smuggling(_other), do: :ok

  defp reject_backend_smuggling(backend_opts) when is_list(backend_opts) do
    backend_opts
    |> Keyword.get(:connect_opts, [])
    |> reject_transport_smuggling("connect_opts")
    |> continue_if_ok(fn ->
      backend_opts
      |> Keyword.get(:run_opts, [])
      |> reject_transport_smuggling("run_opts")
    end)
  end

  defp reject_backend_smuggling(_backend_opts), do: :ok

  defp reject_transport_smuggling(options, label) do
    options
    |> reject_key_smuggling(@transport_override_keys, label)
    |> continue_if_ok(fn -> reject_env_smuggling(attr(options, :env), label) end)
    |> continue_if_ok(fn -> reject_env_smuggling(attr(options, :process_env), label) end)
  end

  defp reject_key_smuggling(options, keys, label) when is_list(options) or is_map(options) do
    present_keys =
      keys
      |> Enum.filter(&has_attr?(options, &1))
      |> Enum.uniq()

    if present_keys == [] do
      :ok
    else
      {:error,
       config_error(
         "governed Codex strict mode rejects materialized runtime override keys in #{label}",
         cause: %{keys: present_keys, surface: label}
       )}
    end
  end

  defp reject_key_smuggling(_options, _keys, _label), do: :ok

  defp reject_env_smuggling(nil, _label), do: :ok
  defp reject_env_smuggling([], _label), do: :ok
  defp reject_env_smuggling(%{} = env, label), do: reject_provider_env_keys(Map.keys(env), label)

  defp reject_env_smuggling(env, label) when is_list(env) do
    if Keyword.keyword?(env) do
      env |> Keyword.keys() |> reject_provider_env_keys(label)
    else
      {:error,
       config_error("governed Codex strict mode rejects invalid env override shape",
         cause: %{surface: label}
       )}
    end
  end

  defp reject_env_smuggling(_env, label) do
    {:error,
     config_error("governed Codex strict mode rejects invalid env override shape",
       cause: %{surface: label}
     )}
  end

  defp reject_provider_env_keys(keys, label) do
    rejected =
      keys
      |> Enum.map(&to_string/1)
      |> Enum.filter(&(&1 in @provider_env_keys))
      |> Enum.uniq()

    if rejected == [] do
      :ok
    else
      {:error,
       config_error(
         "governed Codex strict mode rejects provider auth env outside the materializer",
         cause: %{env_keys: rejected, surface: label}
       )}
    end
  end

  defp reject_model_payload_smuggling(nil), do: :ok

  defp reject_model_payload_smuggling(model_payload) when is_map(model_payload) do
    env_overrides = attr(model_payload, :env_overrides, %{})
    backend_metadata = attr(model_payload, :backend_metadata, %{})
    config_values = attr(backend_metadata, :config_values, [])

    cond do
      env_overrides != %{} ->
        {:error,
         config_error(
           "governed Codex strict mode rejects model-payload env overrides outside the materializer",
           cause: %{payload_field: :env_overrides}
         )}

      List.wrap(config_values) != [] ->
        {:error,
         config_error(
           "governed Codex strict mode rejects model-payload config overrides outside the materializer",
           cause: %{payload_field: :config_values}
         )}

      true ->
        :ok
    end
  end

  defp reject_model_payload_smuggling(_model_payload), do: :ok

  defp continue_if_ok(:ok, fun) when is_function(fun, 0), do: fun.()
  defp continue_if_ok(error, _fun), do: error

  defp normalize_source(source) when source in @sources, do: {:ok, source}

  defp normalize_source(source) when is_binary(source) do
    case source do
      "verified_materializer" -> {:ok, :verified_materializer}
      "provider_auth_backend" -> {:ok, :provider_auth_backend}
      _ -> invalid_source(source)
    end
  end

  defp normalize_source(source), do: invalid_source(source)

  defp invalid_source(source) do
    {:error,
     config_error("codex materialized runtime source must be verified_materializer",
       cause: %{source: source}
     )}
  end

  defp normalize_target_auth_posture(posture) when posture in @target_auth_postures,
    do: {:ok, posture}

  defp normalize_target_auth_posture(posture) when is_binary(posture) do
    case posture do
      "auth_state_preinstalled" -> {:ok, :auth_state_preinstalled}
      "materialize_on_attach" -> {:ok, :materialize_on_attach}
      "proxy_only" -> {:ok, :proxy_only}
      "no_credentials" -> {:ok, :no_credentials}
      _ -> invalid_target_auth_posture(posture)
    end
  end

  defp normalize_target_auth_posture(posture), do: invalid_target_auth_posture(posture)

  defp invalid_target_auth_posture(posture) do
    {:error,
     config_error("invalid Codex target auth posture for materialized runtime",
       cause: %{target_auth_posture: posture}
     )}
  end

  defp normalize_env(env) when env in [nil, %{}, []], do: {:ok, %{}}

  defp normalize_env(env) when is_map(env) do
    {:ok, Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)}
  end

  defp normalize_env(env) when is_list(env) do
    if Keyword.keyword?(env) do
      {:ok,
       env |> Map.new() |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)}
    else
      {:error, config_error("codex materialized runtime env must be a map or keyword list")}
    end
  end

  defp normalize_env(_env),
    do: {:error, config_error("codex materialized runtime env must be a map or keyword list")}

  defp put_config_root_env(env, config_root) do
    case Map.get(env, "CODEX_HOME") do
      nil ->
        {:ok, Map.put(env, "CODEX_HOME", config_root)}

      ^config_root ->
        {:ok, env}

      other ->
        {:error,
         config_error("codex materialized runtime env CODEX_HOME must match config_root",
           cause: %{config_root: :redacted, env_codex_home: other}
         )}
    end
  end

  defp native_auth_assertion(attrs, assertion_ref) do
    assertion = attr(attrs, :native_auth_assertion, %{})
    level = attr(assertion, :introspection_level) || attr(attrs, :native_auth_introspection_level)
    limits = attr(assertion, :limits) || attr(attrs, :native_auth_limits)

    cond do
      not present?(assertion_ref) ->
        {:error, config_error("codex materialized runtime is missing native auth assertion ref")}

      not present?(level) ->
        {:error,
         config_error(
           "codex materialized runtime native auth assertion is missing introspection level"
         )}

      not is_map(limits) ->
        {:error,
         config_error("codex materialized runtime native auth assertion is missing limits")}

      true ->
        {:ok,
         %{
           ref: assertion_ref,
           introspection_level: level,
           limits: limits,
           redacted?: attr(assertion, :redacted?, true) != false
         }}
    end
  end

  defp materialized_ref(attrs, runtime_auth, key) do
    value = string_attr(attrs, key) || binding_value(runtime_auth, key)

    if present?(value) do
      {:ok, value}
    else
      {:error, config_error("codex materialized runtime is missing #{key}", cause: %{key: key})}
    end
  end

  defp required_string(attrs, key) do
    case string_attr(attrs, key) do
      value when is_binary(value) ->
        {:ok, value}

      _ ->
        {:error, config_error("codex materialized runtime is missing #{key}", cause: %{key: key})}
    end
  end

  defp materialized_refs_match?(%__MODULE__{} = materialization, runtime_auth) do
    [
      {:credential_lease_ref, materialization.credential_lease_ref},
      {:native_auth_assertion_ref, materialization.native_auth_assertion_ref},
      {:connector_binding_ref, materialization.connector_binding_ref},
      {:provider_account_ref, materialization.provider_account_ref}
    ]
    |> Enum.all?(fn {key, value} ->
      binding = binding_value(runtime_auth, key)
      binding in [nil, value]
    end)
  end

  defp ref_match_cause(%__MODULE__{} = materialization, runtime_auth) do
    %{
      materialized: %{
        credential_lease_ref: materialization.credential_lease_ref,
        native_auth_assertion_ref: materialization.native_auth_assertion_ref,
        connector_binding_ref: materialization.connector_binding_ref,
        provider_account_ref: materialization.provider_account_ref
      },
      runtime_auth: %{
        credential_lease_ref: binding_value(runtime_auth, :credential_lease_ref),
        native_auth_assertion_ref: binding_value(runtime_auth, :native_auth_assertion_ref),
        connector_binding_ref: binding_value(runtime_auth, :connector_binding_ref),
        provider_account_ref: binding_value(runtime_auth, :provider_account_ref)
      }
    }
  end

  defp binding_value(%RuntimeAuth{} = runtime_auth, :connector_binding_ref),
    do: runtime_auth.connector_binding.ref

  defp binding_value(%RuntimeAuth{} = runtime_auth, :provider_account_ref),
    do: runtime_auth.provider_account_identity.ref

  defp binding_value(%RuntimeAuth{} = runtime_auth, key),
    do: Map.get(runtime_auth.connector_binding, key)

  defp binding_value(metadata, key) when is_map(metadata) do
    runtime_auth = attr(metadata, :runtime_auth, %{})
    binding = attr(metadata, :connector_binding) || attr(runtime_auth, :connector_binding, %{})

    case key do
      :connector_binding_ref -> attr(metadata, key) || attr(binding, :ref)
      :provider_account_ref -> attr(metadata, key) || attr(binding, key)
      _ -> attr(metadata, key) || attr(binding, key)
    end
  end

  defp binding_value(_runtime_auth, _key), do: nil

  defp has_attr?(attrs, key) when is_atom(key) do
    attrs
    |> attr(key)
    |> present_override?()
  end

  defp present_override?(nil), do: false
  defp present_override?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_override?(value) when is_list(value), do: value != []
  defp present_override?(value) when is_map(value), do: map_size(value) > 0
  defp present_override?(value), do: not is_nil(value)

  defp attr(attrs, key, default \\ nil)

  defp attr(nil, _key, default), do: default

  defp attr(%{} = attrs, key, default) when is_atom(key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp attr(attrs, key, default) when is_list(attrs) and is_atom(key) do
    case Keyword.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> list_value(attrs, Atom.to_string(key), default)
    end
  end

  defp list_value(list, key, default) do
    Enum.find_value(list, default, fn
      {^key, value} -> value
      _other -> nil
    end)
  end

  defp string_attr(attrs, key) do
    case attr(attrs, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _other ->
        nil
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp default_codex_base_url do
    module = :"Elixir.Codex.Config.BaseURL"

    if Code.ensure_loaded?(module) and function_exported?(module, :default, 0) do
      :erlang.apply(module, :default, [])
    else
      @default_openai_base_url
    end
  end

  defp config_error(message, opts \\ []) do
    Error.new(:config_invalid, :config, message, opts)
  end
end
