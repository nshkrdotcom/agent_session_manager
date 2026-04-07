defmodule ASM.Session.State do
  @moduledoc """
  Aggregate state owned by `ASM.Session.Server`.
  """

  alias ASM.Provider

  @enforce_keys [:session_id, :provider, :provider_profile, :options]
  defstruct [
    :session_id,
    :provider,
    :provider_profile,
    :options,
    status: :ready,
    active_runs: %{},
    run_monitors: %{},
    run_queue: :queue.new(),
    pending_approval_index: %{},
    checkpoint: nil,
    cost: %{input_tokens: 0, output_tokens: 0, cost_usd: 0.0}
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          provider: Provider.t(),
          provider_profile: Provider.Profile.t(),
          options: keyword(),
          status: :ready | :stopped,
          active_runs: %{optional(String.t()) => pid()},
          run_monitors: %{optional(pid()) => reference()},
          # :queue is opaque to Dialyzer; keep this field generic at the type level.
          run_queue: term(),
          pending_approval_index: %{optional(String.t()) => pid()},
          checkpoint: map() | nil,
          cost: %{
            required(:input_tokens) => non_neg_integer(),
            required(:output_tokens) => non_neg_integer(),
            required(:cost_usd) => float()
          }
        }

  @type queued_run :: %{
          required(:run_id) => String.t(),
          required(:prompt) => String.t(),
          required(:opts) => keyword()
        }

  @spec new(String.t(), Provider.t(), keyword()) :: t()
  def new(session_id, %Provider{} = provider, options \\ []) when is_binary(session_id) do
    %__MODULE__{
      session_id: session_id,
      provider: provider,
      provider_profile: profile_from_options(provider.profile, options),
      options: options
    }
  end

  defp profile_from_options(%Provider.Profile{} = profile, options) when is_list(options) do
    %Provider.Profile{
      profile
      | max_concurrent_runs:
          positive_integer_option(options, :max_concurrent_runs, profile.max_concurrent_runs),
        max_queued_runs:
          non_neg_integer_option(options, :max_queued_runs, profile.max_queued_runs)
    }
  end

  defp positive_integer_option(options, key, default) do
    case Keyword.get(options, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp non_neg_integer_option(options, key, default) do
    case Keyword.get(options, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _other -> default
    end
  end
end
