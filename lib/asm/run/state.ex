defmodule ASM.Run.State do
  @moduledoc """
  Run process state with reducer-owned projection fields.
  """

  @enforce_keys [:run_id, :session_id, :provider]
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :run_id,
    :session_id,
    :provider,
    :prompt,
    :subscriber,
    :session_pid,
    :status,
    :sequence,
    :events,
    :events_rev,
    :text_acc,
    :text_chunks_rev,
    :messages_acc,
    :messages_rev,
    :result,
    :error,
    :cost,
    :tools,
    :backend,
    :backend_opts,
    :backend_pid,
    :backend_ref,
    :backend_subscription_ref,
    :backend_info,
    :lane,
    :execution_config,
    :provider_opts,
    :pipeline,
    :pipeline_ctx,
    :started_at,
    :finished_at,
    pending_approvals: %{},
    approval_timers: %{},
    approval_timeout_ms: 120_000,
    metadata: %{}
  ]

  @type status :: :initializing | :running | :completed | :failed | :interrupted

  @type cost_totals :: %{
          required(:input_tokens) => non_neg_integer(),
          required(:output_tokens) => non_neg_integer(),
          required(:cost_usd) => number()
        }

  @type t :: %__MODULE__{
          run_id: String.t(),
          session_id: String.t(),
          provider: atom(),
          prompt: String.t() | nil,
          subscriber: pid() | nil,
          session_pid: pid() | nil,
          status: status(),
          sequence: non_neg_integer(),
          events: [ASM.Event.t()],
          events_rev: [ASM.Event.t()],
          text_acc: String.t(),
          text_chunks_rev: [String.t()],
          messages_acc: [term()],
          messages_rev: [term()],
          result: ASM.Result.t() | nil,
          error: ASM.Error.t() | nil,
          cost: cost_totals(),
          tools: %{optional(String.t()) => term()},
          backend: module() | nil,
          backend_opts: keyword(),
          backend_pid: pid() | nil,
          backend_ref: reference() | nil,
          backend_subscription_ref: reference() | nil,
          backend_info: ASM.ProviderBackend.Info.t() | nil,
          lane: :core | :sdk | nil,
          execution_config: ASM.Execution.Config.t() | nil,
          provider_opts: keyword(),
          pipeline: [term()],
          pipeline_ctx: map(),
          pending_approvals: %{optional(String.t()) => term()},
          approval_timers: %{optional(String.t()) => reference()},
          approval_timeout_ms: pos_integer(),
          started_at: DateTime.t(),
          finished_at: DateTime.t() | nil,
          metadata: map()
        }

  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    %__MODULE__{
      run_id: Keyword.fetch!(opts, :run_id),
      session_id: Keyword.get(opts, :session_id, ""),
      provider: Keyword.get(opts, :provider, :unknown),
      prompt: Keyword.get(opts, :prompt),
      subscriber: Keyword.get(opts, :subscriber),
      session_pid: Keyword.get(opts, :session_pid),
      status: :initializing,
      sequence: 0,
      events: [],
      events_rev: [],
      text_acc: "",
      text_chunks_rev: [],
      messages_acc: [],
      messages_rev: [],
      result: nil,
      error: nil,
      cost: %{input_tokens: 0, output_tokens: 0, cost_usd: 0.0},
      tools: Keyword.get(opts, :tools, %{}),
      backend: Keyword.get(opts, :backend_module),
      backend_opts: Keyword.get(opts, :backend_opts, []),
      backend_pid: nil,
      backend_ref: nil,
      backend_subscription_ref: nil,
      backend_info: nil,
      lane: Keyword.get(opts, :lane),
      execution_config: Keyword.get(opts, :execution_config),
      provider_opts: Keyword.get(opts, :provider_opts, []),
      pipeline: Keyword.get(opts, :pipeline, []),
      pipeline_ctx: Keyword.get(opts, :pipeline_ctx, %{}),
      approval_timers: %{},
      approval_timeout_ms:
        Keyword.get(opts, :approval_timeout_ms, app_default(:approval_timeout_ms, 120_000)),
      started_at: DateTime.utc_now(),
      finished_at: nil
    }
  end

  @spec materialize(t()) :: t()
  def materialize(%__MODULE__{} = state) do
    %{
      state
      | events: Enum.reverse(state.events_rev),
        messages_acc: Enum.reverse(state.messages_rev),
        text_acc: state.text_chunks_rev |> Enum.reverse() |> IO.iodata_to_binary()
    }
  end

  defp app_default(key, default) do
    Application.get_env(:agent_session_manager, key, default)
  end
end
