defmodule ASM.Options do
  @moduledoc """
  Shared runtime options validation and normalization.
  """

  alias ASM.{Error, Permission, Provider, ProviderFeatures}

  alias ASM.Options.{
    PartialFeatureUnsupportedError,
    ProviderMismatchError,
    ProviderNativeOptionError,
    UnsupportedExecutionSurfaceError,
    UnsupportedOptionError,
    Warning
  }

  alias ASM.Schema.ProviderOptions, as: ProviderOptionsSchema
  alias CliSubprocessCore.ExecutionSurface
  alias CliSubprocessCore.ModelInput
  alias CliSubprocessCore.ModelRegistry.Selection

  @common_keys [
    :provider,
    :permission_mode,
    :provider_permission_mode,
    :cli_path,
    :cwd,
    :env,
    :args,
    :ollama,
    :ollama_model,
    :ollama_base_url,
    :ollama_http,
    :ollama_timeout_ms,
    :model_payload,
    :queue_limit,
    :overflow_policy,
    :subscriber_queue_warn,
    :subscriber_queue_limit,
    :approval_timeout_ms,
    :transport_timeout_ms,
    :transport_headless_timeout_ms,
    :max_stdout_buffer_bytes,
    :max_stderr_buffer_bytes,
    :max_concurrent_runs,
    :max_queued_runs,
    :debug
  ]

  @preflight_modes [:strict_common, :compat]
  @preflight_lanes [:core, :sdk, :auto]
  @preflight_common_keys [
    :model,
    :cli_path,
    :cwd,
    :execution_surface,
    :transport_timeout_ms,
    :transport_headless_timeout_ms,
    :approval_timeout_ms,
    :max_stdout_buffer_bytes,
    :max_stderr_buffer_bytes,
    :debug
  ]
  @preflight_session_keys [
    :lane,
    :session_id,
    :name,
    :queue_limit,
    :overflow_policy,
    :subscriber_queue_warn,
    :subscriber_queue_limit,
    :max_concurrent_runs,
    :max_queued_runs
  ]
  @preflight_partial_keys [
    :ollama,
    :ollama_model,
    :ollama_base_url,
    :ollama_http,
    :ollama_timeout_ms
  ]
  @preflight_escape_hatch_keys [:env, :args]
  @preflight_legacy_provider_native_keys [
    :permission_mode,
    :provider_permission_mode,
    :model_payload,
    :system_prompt,
    :append_system_prompt,
    :provider_backend,
    :external_model_overrides,
    :anthropic_base_url,
    :anthropic_auth_token,
    :include_thinking,
    :max_turns,
    :reasoning_effort,
    :model_provider,
    :oss_provider,
    :skip_git_repo_check,
    :app_server,
    :host_tools,
    :dynamic_tools,
    :output_schema,
    :additional_directories,
    :sandbox,
    :extensions,
    :mode,
    :permissions,
    :mcp_config,
    :tools
  ]
  @high_risk_env_fragments [
    "API_KEY",
    "AUTH_TOKEN",
    "BASE_URL",
    "MODEL",
    "PERMISSION",
    "SANDBOX",
    "TOOLS",
    "MCP"
  ]
  @high_risk_env_prefixes [
    "ANTHROPIC_",
    "CLAUDE_",
    "CODEX_",
    "OPENAI_",
    "GEMINI_",
    "GOOGLE_",
    "AMP_"
  ]

  @type t :: keyword()
  @type preflight_mode :: :strict_common | :compat
  @type preflight_result :: %{
          required(:provider) => atom(),
          required(:mode) => preflight_mode(),
          required(:common) => map(),
          required(:session) => map(),
          required(:partial) => map(),
          required(:provider_native_legacy) => map(),
          required(:rejected) => list(),
          required(:warnings) => [Warning.t()]
        }

  @type preflight_error ::
          UnsupportedOptionError.t()
          | ProviderMismatchError.t()
          | ProviderNativeOptionError.t()
          | PartialFeatureUnsupportedError.t()
          | UnsupportedExecutionSurfaceError.t()

  @spec schema() :: keyword()
  def schema do
    [
      provider: [type: :atom, required: true],
      permission_mode: [type: {:or, [:atom, :string]}, default: :default],
      provider_permission_mode: [type: {:or, [:atom, nil]}, default: nil],
      cli_path: [type: {:or, [:string, nil]}, default: nil],
      cwd: [type: {:or, [:string, nil]}, default: nil],
      env: [type: {:custom, __MODULE__, :validate_passthrough_map, [:env]}, default: %{}],
      args: [type: {:list, :string}, default: []],
      ollama: [type: :boolean, default: false],
      ollama_model: [type: {:or, [:string, nil]}, default: nil],
      ollama_base_url: [type: {:or, [:string, nil]}, default: nil],
      ollama_http: [type: {:or, [:boolean, nil]}, default: nil],
      ollama_timeout_ms: [type: {:or, [:pos_integer, nil]}, default: nil],
      model_payload: [
        type: {:custom, __MODULE__, :validate_model_payload, [:model_payload]},
        default: nil
      ],
      queue_limit: [type: :pos_integer, default: app_default(:queue_limit, 1_000)],
      overflow_policy: [
        type: {:in, [:fail_run, :drop_oldest, :block]},
        default: app_default(:overflow_policy, :fail_run)
      ],
      subscriber_queue_warn: [
        type: :non_neg_integer,
        default: app_default(:subscriber_queue_warn, 100)
      ],
      subscriber_queue_limit: [
        type: :pos_integer,
        default: app_default(:subscriber_queue_limit, 500)
      ],
      approval_timeout_ms: [
        type: :pos_integer,
        default: app_default(:approval_timeout_ms, 120_000)
      ],
      transport_timeout_ms: [type: :pos_integer, default: 60_000],
      transport_headless_timeout_ms: [
        type: {:or, [:pos_integer, {:in, [:infinity]}]},
        default: app_default(:transport_headless_timeout_ms, 5_000)
      ],
      max_stdout_buffer_bytes: [
        type: :pos_integer,
        default: app_default(:max_stdout_buffer_bytes, 1_048_576)
      ],
      max_stderr_buffer_bytes: [
        type: :pos_integer,
        default: app_default(:max_stderr_buffer_bytes, 65_536)
      ],
      max_concurrent_runs: [type: :pos_integer, default: 1],
      max_queued_runs: [type: :non_neg_integer, default: 10],
      debug: [type: :boolean, default: false]
    ]
  end

  @spec preflight(Provider.provider_name(), keyword()) ::
          {:ok, preflight_result()} | {:error, preflight_error() | Error.t()}
  def preflight(provider, opts), do: preflight(provider, opts, mode: :strict_common)

  @spec preflight(Provider.provider_name(), keyword(), keyword()) ::
          {:ok, preflight_result()} | {:error, preflight_error() | Error.t()}
  def preflight(provider, opts, preflight_opts)
      when is_list(opts) and is_list(preflight_opts) do
    if Keyword.keyword?(opts) and Keyword.keyword?(preflight_opts) do
      with {:ok, %Provider{name: canonical_provider}} <- Provider.resolve(provider),
           {:ok, mode} <-
             normalize_preflight_mode(Keyword.get(preflight_opts, :mode, :strict_common)),
           {:ok, result} <- base_preflight_result(canonical_provider, mode),
           {:ok, result} <- preflight_provider_option(canonical_provider, opts, mode, result) do
        classify_preflight_opts(canonical_provider, opts, mode, result)
      end
    else
      preflight_keyword_error(provider)
    end
  end

  def preflight(provider, opts, preflight_opts) do
    _ = opts
    _ = preflight_opts
    preflight_keyword_error(provider)
  end

  defp preflight_keyword_error(provider) do
    {:error,
     UnsupportedOptionError.exception(
       key: :opts,
       provider: provider,
       mode: :strict_common,
       reason: :invalid_opts,
       message: "ASM.Options.preflight/3 expects opts and preflight options to be keyword lists"
     )}
  end

  @spec ensure_positional_provider(Provider.provider_name(), keyword()) ::
          :ok | {:error, ProviderMismatchError.t()}
  def ensure_positional_provider(provider, opts) when is_atom(provider) and is_list(opts) do
    case Keyword.fetch(opts, :provider) do
      :error ->
        :ok

      {:ok, option_provider} ->
        compare_positional_provider(provider, option_provider)
    end
  end

  defp compare_positional_provider(provider, option_provider) do
    case {canonical_provider_name(provider), canonical_provider_name(option_provider)} do
      {{:ok, positional}, {:ok, positional}} ->
        :ok

      {{:ok, positional}, {:ok, _option_name}} ->
        {:error,
         ProviderMismatchError.exception(
           expected_provider: positional,
           actual_provider: option_provider,
           mode: :compat,
           reason: :mismatch
         )}

      {{:error, %Error{} = error}, _other} ->
        invalid_provider_mismatch(provider, option_provider, :compat, error)

      {_positional, {:error, %Error{} = error}} ->
        invalid_provider_mismatch(provider, option_provider, :compat, error)
    end
  end

  defp normalize_preflight_mode(mode) when mode in @preflight_modes, do: {:ok, mode}

  defp normalize_preflight_mode(mode) do
    {:error,
     UnsupportedOptionError.exception(
       key: :mode,
       mode: mode,
       reason: :invalid_mode,
       message:
         "invalid ASM preflight mode #{inspect(mode)}; expected one of #{inspect(@preflight_modes)}"
     )}
  end

  defp base_preflight_result(provider, mode) do
    {:ok,
     %{
       provider: provider,
       mode: mode,
       common: %{},
       session: %{},
       partial: %{},
       provider_native_legacy: %{},
       rejected: [],
       warnings: []
     }}
  end

  defp preflight_provider_option(provider, opts, mode, result) do
    case Keyword.fetch(opts, :provider) do
      :error ->
        {:ok, result}

      {:ok, option_provider} ->
        classify_preflight_provider_value(provider, option_provider, mode, result)
    end
  end

  defp classify_preflight_provider_value(provider, option_provider, mode, result) do
    case canonical_provider_name(option_provider) do
      {:ok, ^provider} ->
        classify_matching_preflight_provider(provider, option_provider, mode, result)

      {:ok, _other_provider} ->
        {:error,
         ProviderMismatchError.exception(
           expected_provider: provider,
           actual_provider: option_provider,
           mode: mode,
           reason: :mismatch
         )}

      {:error, %Error{} = error} ->
        invalid_provider_mismatch(provider, option_provider, mode, error)
    end
  end

  defp classify_matching_preflight_provider(provider, option_provider, :strict_common, _result) do
    {:error,
     ProviderMismatchError.exception(
       expected_provider: provider,
       actual_provider: option_provider,
       mode: :strict_common,
       reason: :redundant_provider
     )}
  end

  defp classify_matching_preflight_provider(_provider, option_provider, :compat, result) do
    {:ok,
     result
     |> put_preflight_value(:provider_native_legacy, :provider, option_provider)
     |> add_warning(
       :provider,
       :redundant_provider,
       "provider is positional for ASM.query/3-style APIs; keep provider in opts only for compatibility paths",
       "Remove :provider from ASM.query/3 opts and pass it positionally."
     )}
  end

  defp canonical_provider_name(provider_or_name) do
    case Provider.resolve(provider_or_name) do
      {:ok, %Provider{name: name}} -> {:ok, name}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp invalid_provider_mismatch(expected_provider, actual_provider, mode, error) do
    {:error,
     ProviderMismatchError.exception(
       expected_provider: expected_provider,
       actual_provider: actual_provider,
       mode: mode,
       reason: :invalid_provider,
       message: Exception.message(error)
     )}
  end

  defp classify_preflight_opts(provider, opts, mode, result) do
    opts
    |> Enum.reject(fn {key, _value} -> key == :provider end)
    |> Enum.reduce_while({:ok, result}, fn {key, value}, {:ok, acc} ->
      case classify_preflight_option(provider, key, value, mode, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp classify_preflight_option(provider, key, value, mode, result)
       when key in @preflight_common_keys do
    normalize_common_preflight_value(provider, key, value, mode, result)
  end

  defp classify_preflight_option(provider, :lane = key, value, mode, result) do
    if value in @preflight_lanes do
      {:ok, put_preflight_value(result, :session, key, value)}
    else
      {:error,
       UnsupportedOptionError.exception(
         key: key,
         provider: provider,
         mode: mode,
         reason: :invalid_lane,
         message: "invalid lane #{inspect(value)}; expected one of #{inspect(@preflight_lanes)}"
       )}
    end
  end

  defp classify_preflight_option(_provider, key, value, _mode, result)
       when key in @preflight_session_keys do
    {:ok, put_preflight_value(result, :session, key, value)}
  end

  defp classify_preflight_option(provider, key, value, mode, result)
       when key in @preflight_partial_keys do
    case mode do
      :strict_common ->
        {:error,
         PartialFeatureUnsupportedError.exception(
           key: key,
           provider: provider,
           mode: mode,
           feature: :ollama
         )}

      :compat ->
        {:ok,
         result
         |> put_preflight_value(:partial, key, value)
         |> add_warning(
           key,
           :partial_feature,
           "option #{inspect(key)} belongs to a partial feature and is not all-provider common ASM behavior",
           "Use a provider SDK or keep this behind an explicit compatibility path."
         )}
    end
  end

  defp classify_preflight_option(provider, key, value, mode, result)
       when key in @preflight_escape_hatch_keys do
    classify_provider_native_preflight_option(provider, key, value, mode, result, :escape_hatch)
  end

  defp classify_preflight_option(provider, key, value, mode, result)
       when key in @preflight_legacy_provider_native_keys do
    classify_provider_native_preflight_option(
      provider,
      key,
      value,
      mode,
      result,
      :provider_native
    )
  end

  defp classify_preflight_option(provider, key, _value, mode, _result) do
    {:error,
     UnsupportedOptionError.exception(
       key: key,
       provider: provider,
       mode: mode,
       reason: :unknown_option
     )}
  end

  defp normalize_common_preflight_value(_provider, :execution_surface = key, value, _mode, result) do
    case ExecutionSurface.new(value) do
      {:ok, %ExecutionSurface{} = execution_surface} ->
        {:ok, put_preflight_value(result, :common, key, execution_surface)}

      {:error, reason} ->
        {:error, UnsupportedExecutionSurfaceError.exception(value: value, reason: reason)}
    end
  end

  defp normalize_common_preflight_value(_provider, key, value, _mode, result) do
    {:ok, put_preflight_value(result, :common, key, value)}
  end

  defp classify_provider_native_preflight_option(provider, key, value, mode, result, reason) do
    case mode do
      :strict_common ->
        {:error,
         ProviderNativeOptionError.exception(
           key: key,
           provider: provider,
           mode: mode,
           reason: reason,
           migration: provider_native_migration(key)
         )}

      :compat ->
        warning_reason = compat_warning_reason(key, value, reason)

        {:ok,
         result
         |> put_preflight_value(:provider_native_legacy, key, value)
         |> add_warning(
           key,
           warning_reason,
           compat_warning_message(key, value, warning_reason),
           provider_native_migration(key)
         )}
    end
  end

  defp put_preflight_value(result, bucket, key, value) do
    Map.update!(result, bucket, &Map.put(&1, key, value))
  end

  defp add_warning(result, key, reason, message, migration) do
    warning = %Warning{
      key: key,
      reason: reason,
      message: message,
      migration: migration,
      mode: result.mode
    }

    Map.update!(result, :warnings, &(&1 ++ [warning]))
  end

  defp compat_warning_reason(:env, value, _reason) do
    if high_risk_env?(value), do: :provider_native_env, else: :escape_hatch
  end

  defp compat_warning_reason(_key, _value, reason), do: reason

  defp compat_warning_message(:env, value, :provider_native_env) do
    "env contains provider-native-looking keys #{inspect(high_risk_env_keys(value))}; env is compatibility-only subprocess configuration"
  end

  defp compat_warning_message(key, _value, :escape_hatch) do
    "option #{inspect(key)} is an escape hatch and is not part of ASM's strict common contract"
  end

  defp compat_warning_message(key, _value, :provider_native) do
    "option #{inspect(key)} is provider-native legacy compatibility, not common ASM behavior"
  end

  defp high_risk_env?(value), do: high_risk_env_keys(value) != []

  defp high_risk_env_keys(value) when is_map(value) do
    value
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&high_risk_env_key?/1)
  end

  defp high_risk_env_keys(_value), do: []

  defp high_risk_env_key?(key) do
    Enum.any?(@high_risk_env_prefixes, &String.starts_with?(key, &1)) or
      Enum.any?(@high_risk_env_fragments, &String.contains?(key, &1))
  end

  defp provider_native_migration(:env),
    do:
      "Pass provider configuration through provider SDK options; use ASM env only in legacy compatibility paths."

  defp provider_native_migration(:args),
    do:
      "Use a provider SDK for native CLI flags; generic ASM does not admit raw args as common behavior."

  defp provider_native_migration(:permission_mode),
    do: "Use provider SDK permission controls until all-provider permission semantics are proven."

  defp provider_native_migration(:model_payload),
    do:
      "Use public :model in strict ASM paths; model_payload remains internal/compatibility-only."

  defp provider_native_migration(key),
    do:
      "Move #{inspect(key)} to the owning provider SDK or an explicit provider-native extension."

  @spec validate(keyword(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def validate(opts, provider_schema \\ [])
      when is_list(opts) and is_list(provider_schema) do
    with {:ok, merged_schema} <- merge_provider_schema(provider_schema),
         {:ok, validated} <- validate_schema(opts, merged_schema),
         {:ok, validated} <- normalize_permission_modes(validated) do
      with {:ok, normalized} <- normalize_common_features(validated),
           {:ok, _validated} <- ProviderOptionsSchema.validate(normalized) do
        {:ok, normalized}
      else
        {:error, {:invalid_provider_options, details}} ->
          {:error, config_error(details.message, validation: details)}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  end

  @spec validate!(keyword(), keyword()) :: t()
  def validate!(opts, provider_schema \\ []) do
    case validate(opts, provider_schema) do
      {:ok, validated} ->
        validated

      {:error, %Error{} = error} ->
        raise ArgumentError, Exception.message(error)
    end
  end

  @spec merge_provider_schema(keyword()) :: {:ok, keyword()} | {:error, Error.t()}
  def merge_provider_schema(provider_schema) when is_list(provider_schema) do
    collisions =
      provider_schema
      |> Keyword.keys()
      |> Enum.filter(&(&1 in @common_keys))

    if collisions == [] do
      {:ok, schema() ++ provider_schema}
    else
      {:error,
       config_error(
         "Provider schema collides with reserved keys: #{Enum.map_join(collisions, ", ", &inspect/1)}",
         collisions: collisions
       )}
    end
  end

  defp validate_schema(opts, merged_schema) do
    case NimbleOptions.validate(opts, merged_schema) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, %NimbleOptions.ValidationError{} = error} ->
        {:error, config_error(Exception.message(error), validation: error)}
    end
  end

  defp normalize_permission_modes(validated) do
    provider =
      validated
      |> Keyword.fetch!(:provider)
      |> Permission.canonical_provider()

    permission_mode = Keyword.get(validated, :permission_mode, :default)

    case Permission.normalize(provider, permission_mode) do
      {:ok, %{normalized: normalized, native: native}} ->
        validated
        |> Keyword.put(:provider, provider)
        |> Keyword.put(:permission_mode, normalized)
        |> Keyword.put(:provider_permission_mode, native)
        |> then(&{:ok, &1})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp app_default(key, default) do
    Application.get_env(:agent_session_manager, key, default)
  end

  defp normalize_common_features(validated) do
    validated
    |> normalize_ollama_surface()
    |> then(&{:ok, &1})
  rescue
    error in [ArgumentError] ->
      {:error, config_error(Exception.message(error), normalized: validated, exception: error)}
  end

  @doc false
  def validate_passthrough_map(value, key) when is_map(value) do
    if Enum.all?(Map.keys(value), &(is_atom(&1) or is_binary(&1))) do
      {:ok, value}
    else
      {:error, "expected #{inspect(key)} map keys to be atoms or strings"}
    end
  end

  def validate_passthrough_map(nil, _key), do: {:ok, nil}

  def validate_passthrough_map(value, key) do
    {:error, "expected #{inspect(key)} to be a map, got: #{inspect(value)}"}
  end

  @doc false
  def validate_passthrough_list(value, _key) when is_list(value), do: {:ok, value}
  def validate_passthrough_list(nil, _key), do: {:ok, []}

  def validate_passthrough_list(value, key) do
    {:error, "expected #{inspect(key)} to be a list, got: #{inspect(value)}"}
  end

  def validate_model_payload(nil, _key), do: {:ok, nil}
  def validate_model_payload(value, _key) when is_map(value), do: {:ok, value}

  def validate_model_payload(value, key) do
    {:error, "expected #{inspect(key)} to be a map/struct, got: #{inspect(value)}"}
  end

  @spec finalize_provider_opts(atom(), keyword(), keyword()) ::
          {:ok, keyword()} | {:error, Error.t()}
  def finalize_provider_opts(provider, provider_opts, opts \\ [])
      when is_atom(provider) and is_list(provider_opts) and is_list(opts) do
    with :ok <- reject_legacy_transport_surface(provider, provider_opts),
         {:ok, normalized} <- normalize_model_input(provider, provider_opts, opts) do
      {:ok, normalized.attrs}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         config_error(
           "model resolution failed for #{inspect(provider)}: #{inspect(reason)}",
           provider: provider,
           reason: reason
         )}
    end
  end

  @spec resolve_model_payload(atom(), keyword()) ::
          {:ok, CliSubprocessCore.ModelRegistry.selection()} | {:error, Error.t()}
  def resolve_model_payload(provider, provider_opts)
      when is_atom(provider) and is_list(provider_opts) do
    case finalize_provider_opts(provider, provider_opts) do
      {:ok, finalized} ->
        {:ok, normalize_model_payload(Keyword.fetch!(finalized, :model_payload))}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @spec attach_model_payload(keyword(), map()) :: keyword()
  def attach_model_payload(provider_opts, model_payload)
      when is_list(provider_opts) and is_map(model_payload) do
    provider_opts
    |> Keyword.put(:model_payload, model_payload)
    |> Keyword.delete(:model)
    |> Keyword.delete(:reasoning)
    |> Keyword.delete(:reasoning_effort)
    |> Keyword.delete(:provider_backend)
    |> Keyword.delete(:model_provider)
    |> Keyword.delete(:oss_provider)
    |> Keyword.delete(:ollama_base_url)
    |> Keyword.delete(:ollama_http)
    |> Keyword.delete(:ollama_timeout_ms)
    |> Keyword.delete(:ollama)
    |> Keyword.delete(:ollama_model)
  end

  defp normalize_model_payload(%Selection{} = payload), do: payload
  defp normalize_model_payload(payload) when is_map(payload), do: Selection.new(payload)

  defp normalize_model_input(provider, provider_opts, opts)
       when is_atom(provider) and is_list(provider_opts) and is_list(opts) do
    strip_keys =
      [:ollama, :ollama_model]
      |> Kernel.++(Keyword.get(opts, :strip_keys, []))
      |> Enum.uniq()

    ModelInput.normalize(provider, provider_opts, strip_keys: strip_keys)
  end

  defp reject_legacy_transport_surface(provider, provider_opts) do
    if Keyword.has_key?(provider_opts, :transport_module) do
      {:error,
       config_error(
         "#{inspect(provider)} no longer accepts legacy transport-selector overrides; transport selection is internal to cli_subprocess_core",
         provider: provider,
         option: :transport_selector
       )}
    else
      :ok
    end
  end

  defp normalize_ollama_surface(validated) when is_list(validated) do
    provider = Keyword.fetch!(validated, :provider)
    feature_provider = canonical_feature_provider(provider)

    if ollama_requested?(validated) do
      ensure_ollama_supported!(feature_provider)

      case feature_provider do
        :claude ->
          normalize_claude_ollama_surface(validated)

        :codex ->
          normalize_codex_ollama_surface(validated)

        _other ->
          raise ArgumentError,
                "provider #{inspect(provider)} does not support the common Ollama surface"
      end
    else
      validated
    end
  end

  defp ollama_requested?(validated) when is_list(validated) do
    Keyword.get(validated, :ollama, false) or
      Keyword.get(validated, :ollama_model) not in [nil, ""] or
      Keyword.get(validated, :ollama_base_url) not in [nil, ""] or
      not is_nil(Keyword.get(validated, :ollama_http)) or
      not is_nil(Keyword.get(validated, :ollama_timeout_ms))
  end

  defp ensure_ollama_supported!(provider) when is_atom(provider) do
    if ProviderFeatures.supports_common_feature?(provider, :ollama) do
      :ok
    else
      raise ArgumentError,
            "provider #{inspect(provider)} does not support the common Ollama surface"
    end
  end

  defp normalize_claude_ollama_surface(validated) do
    backend = Keyword.get(validated, :provider_backend)
    ollama_model = present_binary(Keyword.get(validated, :ollama_model))
    requested_model = present_binary(Keyword.get(validated, :model))
    external_model_overrides = Keyword.get(validated, :external_model_overrides, %{}) || %{}

    if backend not in [nil, :ollama, "ollama"] do
      raise ArgumentError,
            "common Ollama surface conflicts with :provider_backend=#{inspect(backend)} for :claude"
    end

    overrides =
      if is_binary(requested_model) and is_binary(ollama_model) and
           requested_model != ollama_model do
        merge_claude_ollama_override!(external_model_overrides, requested_model, ollama_model)
      else
        external_model_overrides
      end

    validated
    |> Keyword.put(:ollama, true)
    |> Keyword.put(:provider_backend, :ollama)
    |> maybe_put(:anthropic_base_url, Keyword.get(validated, :ollama_base_url))
    |> maybe_put(:anthropic_auth_token, Keyword.get(validated, :anthropic_auth_token) || "ollama")
    |> maybe_put(:model, requested_model || ollama_model)
    |> Keyword.put(:external_model_overrides, overrides)
  end

  defp merge_claude_ollama_override!(overrides, requested_model, ollama_model)
       when is_map(overrides) and is_binary(requested_model) and is_binary(ollama_model) do
    normalized_overrides =
      Map.new(overrides, fn {key, value} -> {to_string(key), to_string(value)} end)

    case Map.get(normalized_overrides, requested_model) do
      nil ->
        Map.put(normalized_overrides, requested_model, ollama_model)

      ^ollama_model ->
        normalized_overrides

      other ->
        raise ArgumentError,
              "common Ollama surface conflicts with external_model_overrides[#{inspect(requested_model)}]=#{inspect(other)}"
    end
  end

  defp normalize_codex_ollama_surface(validated) do
    backend = Keyword.get(validated, :provider_backend)
    oss_provider = present_binary(Keyword.get(validated, :oss_provider))
    ollama_model = present_binary(Keyword.get(validated, :ollama_model))
    requested_model = present_binary(Keyword.get(validated, :model))

    if backend not in [nil, :oss, "oss"] do
      raise ArgumentError,
            "common Ollama surface conflicts with :provider_backend=#{inspect(backend)} for :codex"
    end

    if oss_provider not in [nil, "ollama"] do
      raise ArgumentError,
            "common Ollama surface conflicts with :oss_provider=#{inspect(oss_provider)} for :codex"
    end

    if is_binary(requested_model) and is_binary(ollama_model) and requested_model != ollama_model do
      raise ArgumentError,
            "common Ollama surface :model=#{inspect(requested_model)} conflicts with :ollama_model=#{inspect(ollama_model)} for :codex"
    end

    validated
    |> Keyword.put(:ollama, true)
    |> Keyword.put(:provider_backend, :oss)
    |> Keyword.put(:oss_provider, "ollama")
    |> maybe_put(:model, requested_model || ollama_model)
  end

  defp present_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_binary(_value), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp canonical_feature_provider(:codex_exec), do: :codex
  defp canonical_feature_provider(provider), do: provider

  defp config_error(message, details) do
    Error.new(:config_invalid, :config, message, cause: details)
  end
end
