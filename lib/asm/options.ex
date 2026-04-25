defmodule ASM.Options do
  @moduledoc """
  Shared runtime options validation and normalization.
  """

  alias ASM.{Error, Permission, ProviderFeatures}
  alias ASM.Schema.ProviderOptions, as: ProviderOptionsSchema
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

  @type t :: keyword()

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
