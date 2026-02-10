defmodule AgentSessionManager.Test.RenderingHelpers do
  @moduledoc """
  Helpers for building canonical adapter events in rendering tests.
  """

  @default_session_id "ses_test_123"
  @default_run_id "run_test_456"

  def event(type, data \\ %{}, opts \\ []) do
    %{
      type: type,
      timestamp: DateTime.utc_now(),
      session_id: opts[:session_id] || @default_session_id,
      run_id: opts[:run_id] || @default_run_id,
      data: data,
      provider: opts[:provider] || :claude
    }
  end

  def run_started(opts \\ []) do
    event(:run_started, %{
      model: opts[:model] || "claude-sonnet-4-5-20250929",
      session_id: opts[:session_id] || @default_session_id
    })
  end

  def message_streamed(text) do
    event(:message_streamed, %{content: text, delta: text})
  end

  def tool_call_started(name, opts \\ []) do
    event(:tool_call_started, %{
      tool_name: name,
      tool_call_id: opts[:id] || "tool_#{name}_001",
      tool_use_id: opts[:id] || "tool_#{name}_001",
      tool_input: opts[:input] || %{}
    })
  end

  def tool_call_completed(name, opts \\ []) do
    event(:tool_call_completed, %{
      tool_name: name,
      tool_call_id: opts[:id] || "tool_#{name}_001",
      tool_use_id: opts[:id] || "tool_#{name}_001",
      tool_input: opts[:input] || %{},
      tool_output: opts[:output] || "done"
    })
  end

  def token_usage_updated(input_tokens, output_tokens) do
    event(:token_usage_updated, %{
      input_tokens: input_tokens,
      output_tokens: output_tokens
    })
  end

  def message_received(content \\ "Hello!") do
    event(:message_received, %{content: content, role: "assistant"})
  end

  def run_completed(opts \\ []) do
    event(:run_completed, %{
      stop_reason: opts[:stop_reason] || "end_turn",
      token_usage: opts[:token_usage] || %{input_tokens: 100, output_tokens: 50}
    })
  end

  def run_failed(error_message \\ "something went wrong") do
    event(:run_failed, %{
      error_code: :execution_error,
      error_message: error_message
    })
  end

  def run_cancelled do
    event(:run_cancelled, %{})
  end

  def error_occurred(message \\ "unexpected error") do
    event(:error_occurred, %{
      error_code: :internal_error,
      error_message: message
    })
  end

  @doc """
  Build a typical multi-turn event sequence for testing.
  """
  def simple_session_events do
    [
      run_started(),
      message_streamed("Hello"),
      message_streamed(" world"),
      message_received("Hello world"),
      token_usage_updated(100, 20),
      run_completed()
    ]
  end

  @doc """
  Build a session with tool use for testing.
  """
  def tool_use_session_events do
    [
      run_started(),
      message_streamed("Let me read that file."),
      tool_call_started("Read", id: "tu_001", input: %{"path" => "/foo/bar.ex"}),
      tool_call_completed("Read", id: "tu_001", output: "defmodule Foo do\nend"),
      message_streamed("The file contains module Foo."),
      message_received("Let me read that file. The file contains module Foo."),
      token_usage_updated(200, 80),
      run_completed()
    ]
  end
end
