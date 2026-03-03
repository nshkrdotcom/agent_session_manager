defmodule ASM.Run.State do
  @moduledoc """
  Run process state with deterministic reducer-owned fields.
  """

  @enforce_keys [:run_id, :session_id, :provider]
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
    :text_acc,
    :messages_acc,
    :result,
    :error,
    :tools,
    :tool_executor,
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
          text_acc: String.t(),
          messages_acc: [term()],
          result: ASM.Result.t() | nil,
          error: ASM.Error.t() | nil,
          tools: %{optional(String.t()) => term()},
          tool_executor: module(),
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
      text_acc: "",
      messages_acc: [],
      result: nil,
      error: nil,
      tools: Keyword.get(opts, :tools, %{}),
      tool_executor: Keyword.get(opts, :tool_executor, ASM.Tool.Executor),
      pipeline: Keyword.get(opts, :pipeline, []),
      pipeline_ctx: Keyword.get(opts, :pipeline_ctx, %{}),
      approval_timers: %{},
      approval_timeout_ms:
        Keyword.get(opts, :approval_timeout_ms, app_default(:approval_timeout_ms, 120_000)),
      started_at: DateTime.utc_now(),
      finished_at: nil
    }
  end

  defp app_default(key, default) do
    Application.get_env(:agent_session_manager, key, default)
  end
end
