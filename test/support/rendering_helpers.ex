defmodule ASM.Test.RenderingHelpers do
  @moduledoc false

  alias ASM.{Content, Control, Event, Message}

  @default_session_id "session-rendering-test"
  @default_run_id "run-rendering-test"
  @default_provider :claude

  @spec event(Event.kind(), Message.t() | Control.t(), keyword()) :: Event.t()
  def event(kind, payload, opts \\ []) when is_atom(kind) and is_list(opts) do
    %Event{
      id: Event.generate_id(),
      kind: kind,
      run_id: Keyword.get(opts, :run_id, @default_run_id),
      session_id: Keyword.get(opts, :session_id, @default_session_id),
      provider: Keyword.get(opts, :provider, @default_provider),
      payload: payload,
      sequence: Keyword.get(opts, :sequence),
      timestamp: Keyword.get(opts, :timestamp, ~U[2026-03-04 00:00:00Z])
    }
  end

  @spec run_started(keyword()) :: Event.t()
  def run_started(opts \\ []) do
    event(:run_started, %Control.RunLifecycle{status: :started, summary: %{}}, opts)
  end

  @spec run_completed(keyword()) :: Event.t()
  def run_completed(opts \\ []) do
    event(:run_completed, %Control.RunLifecycle{status: :completed, summary: %{}}, opts)
  end

  @spec assistant_delta(String.t(), keyword()) :: Event.t()
  def assistant_delta(text, opts \\ []) when is_binary(text) do
    event(:assistant_delta, %Message.Partial{content_type: :text, delta: text}, opts)
  end

  @spec assistant_message(String.t(), keyword()) :: Event.t()
  def assistant_message(text, opts \\ []) when is_binary(text) do
    payload = %Message.Assistant{content: [%Content.Text{text: text}]}
    event(:assistant_message, payload, opts)
  end

  @spec tool_use(String.t(), map(), keyword()) :: Event.t()
  def tool_use(tool_name, input \\ %{}, opts \\ []) when is_binary(tool_name) and is_map(input) do
    payload =
      %Message.ToolUse{
        tool_name: tool_name,
        tool_id: Keyword.get(opts, :tool_id, "tool-rendering-1"),
        input: input
      }

    event(:tool_use, payload, opts)
  end

  @spec tool_result(String.t(), term(), keyword()) :: Event.t()
  def tool_result(tool_id, content, opts \\ []) when is_binary(tool_id) do
    payload =
      %Message.ToolResult{
        tool_id: tool_id,
        content: content,
        is_error: Keyword.get(opts, :is_error, false)
      }

    event(:tool_result, payload, opts)
  end

  @spec result_event(keyword()) :: Event.t()
  def result_event(opts \\ []) do
    payload =
      %Message.Result{
        stop_reason: Keyword.get(opts, :stop_reason, :end_turn),
        usage: Keyword.get(opts, :usage, %{input_tokens: 5, output_tokens: 8}),
        duration_ms: Keyword.get(opts, :duration_ms, 42),
        metadata: Keyword.get(opts, :metadata, %{})
      }

    event(:result, payload, opts)
  end

  @spec error_event(keyword()) :: Event.t()
  def error_event(opts \\ []) do
    payload =
      %Message.Error{
        severity: Keyword.get(opts, :severity, :error),
        message: Keyword.get(opts, :message, "rendering test error"),
        kind: Keyword.get(opts, :kind, :runtime)
      }

    event(:error, payload, opts)
  end

  @spec sample_events() :: [Event.t()]
  def sample_events do
    [
      run_started(),
      assistant_delta("Hello"),
      assistant_delta(" world"),
      tool_use("bash", %{"cmd" => "pwd"}),
      tool_result("tool-rendering-1", %{"stdout" => "/tmp"}),
      result_event(),
      run_completed()
    ]
  end
end
