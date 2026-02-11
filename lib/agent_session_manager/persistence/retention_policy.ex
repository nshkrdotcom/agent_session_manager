defmodule AgentSessionManager.Persistence.RetentionPolicy do
  @moduledoc """
  Configurable rules for session and event lifecycle management.

  ## Usage

      policy = RetentionPolicy.new(
        max_completed_session_age_days: 90,
        hard_delete_after_days: 30,
        max_events_per_session: 10_000
      )

      :ok = RetentionPolicy.validate(policy)

  """

  @type t :: %__MODULE__{
          max_session_age_days: pos_integer() | :infinity,
          max_completed_session_age_days: pos_integer() | :infinity,
          max_events_per_session: pos_integer() | :infinity,
          max_total_events: pos_integer() | :infinity,
          hard_delete_after_days: pos_integer() | :infinity,
          archive_before_prune: boolean(),
          archive_store: GenServer.server() | nil,
          exempt_statuses: [atom()],
          exempt_tags: [String.t()],
          prune_event_types_first: [atom()],
          batch_size: pos_integer()
        }

  defstruct max_session_age_days: :infinity,
            max_completed_session_age_days: 90,
            max_events_per_session: :infinity,
            max_total_events: :infinity,
            hard_delete_after_days: 30,
            archive_before_prune: false,
            archive_store: nil,
            exempt_statuses: [:active, :paused],
            exempt_tags: ["pinned"],
            prune_event_types_first: [:message_streamed, :token_usage_updated],
            batch_size: 100

  @doc """
  Builds a policy from keyword options.

  Any options not provided use defaults from `AgentSessionManager.Config`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    alias AgentSessionManager.Config

    defaults = [
      max_completed_session_age_days: Config.get(:retention_max_completed_age_days),
      hard_delete_after_days: Config.get(:retention_hard_delete_after_days),
      batch_size: Config.get(:retention_batch_size),
      exempt_statuses: Config.get(:retention_exempt_statuses),
      exempt_tags: Config.get(:retention_exempt_tags),
      prune_event_types_first: Config.get(:retention_prune_event_types_first)
    ]

    merged = Keyword.merge(defaults, opts)
    struct(__MODULE__, merged)
  end

  @doc """
  Validates a policy for internal consistency.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{} = policy) do
    with :ok <- validate_age(:max_session_age_days, policy.max_session_age_days),
         :ok <-
           validate_age(:max_completed_session_age_days, policy.max_completed_session_age_days),
         :ok <- validate_age(:hard_delete_after_days, policy.hard_delete_after_days),
         :ok <- validate_count(:max_events_per_session, policy.max_events_per_session),
         :ok <- validate_count(:max_total_events, policy.max_total_events),
         :ok <- validate_batch_size(policy.batch_size) do
      validate_archive(policy.archive_before_prune, policy.archive_store)
    end
  end

  defp validate_age(field, value) do
    if valid_age?(value),
      do: :ok,
      else: {:error, "#{field} must be a positive integer or :infinity"}
  end

  defp validate_count(field, value) do
    if valid_count?(value),
      do: :ok,
      else: {:error, "#{field} must be a positive integer or :infinity"}
  end

  defp validate_batch_size(size) when is_integer(size) and size > 0, do: :ok
  defp validate_batch_size(_), do: {:error, "batch_size must be a positive integer"}

  defp validate_archive(true, nil),
    do: {:error, "archive_store is required when archive_before_prune is true"}

  defp validate_archive(_, _), do: :ok

  defp valid_age?(:infinity), do: true
  defp valid_age?(n) when is_integer(n) and n > 0, do: true
  defp valid_age?(_), do: false

  defp valid_count?(:infinity), do: true
  defp valid_count?(n) when is_integer(n) and n > 0, do: true
  defp valid_count?(_), do: false
end
