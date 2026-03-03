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
    transport_pid: nil,
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
          transport_pid: pid() | nil,
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
      provider_profile: provider.profile,
      options: options
    }
  end
end
