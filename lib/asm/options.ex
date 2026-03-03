defmodule ASM.Options do
  @moduledoc """
  Shared runtime options validation and normalization.
  """

  alias ASM.{Error, Permission}

  @common_keys [
    :provider,
    :permission_mode,
    :provider_permission_mode,
    :cli_path,
    :cwd,
    :env,
    :args,
    :queue_limit,
    :overflow_policy,
    :subscriber_queue_warn,
    :subscriber_queue_limit,
    :approval_timeout_ms,
    :transport_timeout_ms,
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
      env: [type: :map, default: %{}],
      args: [type: {:list, :string}, default: []],
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
      max_concurrent_runs: [type: :pos_integer, default: 1],
      max_queued_runs: [type: :non_neg_integer, default: 10],
      debug: [type: :boolean, default: false]
    ]
  end

  @spec validate(keyword(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def validate(opts, provider_schema \\ [])
      when is_list(opts) and is_list(provider_schema) do
    with {:ok, merged_schema} <- merge_provider_schema(provider_schema),
         {:ok, validated} <- validate_schema(opts, merged_schema) do
      normalize_permission_modes(validated)
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

  defp config_error(message, details) do
    Error.new(:config_invalid, :config, message, cause: details)
  end
end
