defmodule AgentSessionManager.Test.AmpMockSDK do
  @moduledoc """
  Mock Amp SDK for testing AmpAdapter without network dependencies.

  This module simulates `AmpSdk.execute/2` by returning lazy streams of
  amp_sdk-compatible message structs.

  ## Usage

      {:ok, mock} = AmpMockSDK.start_link(scenario: :simple_response)

      # Get streaming result that mimics AmpSdk.execute/2
      stream = AmpMockSDK.execute(mock, "Hello", %AmpSdk.Types.Options{})
      Enum.to_list(stream)

  ## Event Scenarios

  Use `build_event_stream/2` to generate realistic message sequences:
  - `:simple_response` - SystemMessage, AssistantMessage, ResultMessage
  - `:streaming` - Multiple AssistantMessages with text content
  - `:with_tool_call` - Includes ToolUseContent and ToolResultContent
  - `:multi_turn` - Multiple assistant/user turns
  - `:error` - ErrorResultMessage
  - `:cancelled` - Partial stream (simulates cancel)
  """

  use GenServer
  use Supertester.TestableGenServer

  alias AgentSessionManager.Test.Models, as: TestModels

  alias AmpSdk.Types.{
    AssistantMessage,
    AssistantPayload,
    ErrorResultMessage,
    ResultMessage,
    SystemMessage,
    TextContent,
    ToolResultContent,
    ToolUseContent,
    Usage,
    UserMessage,
    UserPayload
  }

  @type event_scenario ::
          :simple_response
          | :streaming
          | :with_tool_call
          | :multi_turn
          | :error
          | :cancelled

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the mock Amp SDK.

  ## Options

  - `:scenario` - Event scenario to use (default: :simple_response)
  - `:delay_ms` - Delay between events in milliseconds (default: 0)
  - `:name` - Optional GenServer name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Stops the mock SDK.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  @doc """
  Sets events using a scenario name.
  """
  @spec set_scenario(GenServer.server(), event_scenario(), keyword()) :: :ok
  def set_scenario(server, scenario, opts \\ []) do
    events = build_event_stream(scenario, opts)
    GenServer.call(server, {:set_events, events})
  end

  @doc """
  Simulates AmpSdk.execute/2 returning a lazy stream of messages.
  """
  @spec execute(GenServer.server(), term(), term()) :: Enumerable.t()
  def execute(server, _prompt, _options) do
    GenServer.call(server, :execute)
  end

  @doc """
  Cancels the mock streaming.
  """
  @spec cancel(GenServer.server()) :: :ok
  def cancel(server) do
    GenServer.call(server, :cancel)
  end

  @doc """
  Builds a realistic event stream for the given scenario.

  ## Options

  - `:session_id` - Session ID (default: "amp-test-session-id")
  - `:content` - Response content (default: "Test response")
  - `:tool_name` - Tool name for tool_call scenarios (default: "test_tool")
  - `:tool_id` - Tool use ID (default: "tool-use-1")
  - `:tool_input` - Tool input map (default: %{"arg1" => "value1"})
  - `:tool_output` - Tool result content (default: "Tool executed successfully")
  - `:error_message` - Error message for error scenarios
  - `:chunks` - List of text chunks for streaming scenario
  """
  @spec build_event_stream(event_scenario(), keyword()) :: [AmpSdk.Types.stream_message()]
  def build_event_stream(scenario, opts \\ [])

  def build_event_stream(:simple_response, opts) do
    session_id = Keyword.get(opts, :session_id, "amp-test-session-id")
    content = Keyword.get(opts, :content, "Test response")

    [
      %SystemMessage{
        type: "system",
        subtype: "init",
        session_id: session_id,
        cwd: "/tmp/test",
        tools: ["Read", "Write", "Bash"],
        mcp_servers: []
      },
      %AssistantMessage{
        type: "assistant",
        session_id: session_id,
        message: %AssistantPayload{
          id: "msg-1",
          role: "assistant",
          model: TestModels.claude_sonnet_model(),
          content: [%TextContent{type: "text", text: content}],
          stop_reason: "end_turn",
          usage: %Usage{input_tokens: 10, output_tokens: 20}
        }
      },
      %ResultMessage{
        type: "result",
        subtype: "success",
        session_id: session_id,
        is_error: false,
        result: content,
        duration_ms: 1500,
        num_turns: 1,
        usage: %Usage{input_tokens: 10, output_tokens: 20}
      }
    ]
  end

  def build_event_stream(:streaming, opts) do
    session_id = Keyword.get(opts, :session_id, "amp-test-session-id")
    chunks = Keyword.get(opts, :chunks, ["Hello", " ", "world", "!"])
    full_content = Enum.join(chunks)

    [
      %SystemMessage{
        type: "system",
        subtype: "init",
        session_id: session_id,
        cwd: "/tmp/test",
        tools: ["Read", "Write", "Bash"],
        mcp_servers: []
      }
    ] ++
      Enum.with_index(chunks, fn chunk, idx ->
        %AssistantMessage{
          type: "assistant",
          session_id: session_id,
          message: %AssistantPayload{
            id: "msg-#{idx}",
            role: "assistant",
            model: TestModels.claude_sonnet_model(),
            content: [%TextContent{type: "text", text: chunk}],
            stop_reason: if(idx == length(chunks) - 1, do: "end_turn", else: nil),
            usage: %Usage{
              input_tokens: 10 + idx * 2,
              output_tokens: 5 + idx * 5
            }
          }
        }
      end) ++
      [
        %ResultMessage{
          type: "result",
          subtype: "success",
          session_id: session_id,
          is_error: false,
          result: full_content,
          duration_ms: 2000,
          num_turns: 1,
          usage: %Usage{input_tokens: 15, output_tokens: 25}
        }
      ]
  end

  def build_event_stream(:with_tool_call, opts) do
    session_id = Keyword.get(opts, :session_id, "amp-test-session-id")
    tool_name = Keyword.get(opts, :tool_name, "test_tool")
    tool_id = Keyword.get(opts, :tool_id, "tool-use-1")
    tool_input = Keyword.get(opts, :tool_input, %{"arg1" => "value1"})
    tool_output = Keyword.get(opts, :tool_output, "Tool executed successfully")
    tool_is_error = Keyword.get(opts, :tool_is_error, false)
    content = Keyword.get(opts, :content, "Used the tool successfully")

    [
      %SystemMessage{
        type: "system",
        subtype: "init",
        session_id: session_id,
        cwd: "/tmp/test",
        tools: ["Read", "Write", "Bash", tool_name],
        mcp_servers: []
      },
      # Assistant requests tool use
      %AssistantMessage{
        type: "assistant",
        session_id: session_id,
        message: %AssistantPayload{
          id: "msg-1",
          role: "assistant",
          model: TestModels.claude_sonnet_model(),
          content: [
            %ToolUseContent{
              type: "tool_use",
              id: tool_id,
              name: tool_name,
              input: tool_input
            }
          ],
          stop_reason: "tool_use",
          usage: %Usage{input_tokens: 15, output_tokens: 30}
        }
      },
      # User message with tool result
      %UserMessage{
        type: "user",
        session_id: session_id,
        message: %UserPayload{
          role: "user",
          content: [
            %ToolResultContent{
              type: "tool_result",
              tool_use_id: tool_id,
              content: tool_output,
              is_error: tool_is_error
            }
          ]
        }
      },
      # Assistant responds after tool use
      %AssistantMessage{
        type: "assistant",
        session_id: session_id,
        message: %AssistantPayload{
          id: "msg-2",
          role: "assistant",
          model: TestModels.claude_sonnet_model(),
          content: [%TextContent{type: "text", text: content}],
          stop_reason: "end_turn",
          usage: %Usage{input_tokens: 30, output_tokens: 50}
        }
      },
      %ResultMessage{
        type: "result",
        subtype: "success",
        session_id: session_id,
        is_error: false,
        result: content,
        duration_ms: 3000,
        num_turns: 2,
        usage: %Usage{input_tokens: 30, output_tokens: 50}
      }
    ]
  end

  def build_event_stream(:multi_turn, opts) do
    session_id = Keyword.get(opts, :session_id, "amp-test-session-id")

    [
      %SystemMessage{
        type: "system",
        subtype: "init",
        session_id: session_id,
        cwd: "/tmp/test",
        tools: ["Read", "Write", "Bash"],
        mcp_servers: []
      },
      %AssistantMessage{
        type: "assistant",
        session_id: session_id,
        message: %AssistantPayload{
          id: "msg-1",
          role: "assistant",
          content: [%TextContent{type: "text", text: "First turn"}],
          stop_reason: nil,
          usage: %Usage{input_tokens: 10, output_tokens: 15}
        }
      },
      %AssistantMessage{
        type: "assistant",
        session_id: session_id,
        message: %AssistantPayload{
          id: "msg-2",
          role: "assistant",
          content: [%TextContent{type: "text", text: "Second turn"}],
          stop_reason: "end_turn",
          usage: %Usage{input_tokens: 20, output_tokens: 30}
        }
      },
      %ResultMessage{
        type: "result",
        subtype: "success",
        session_id: session_id,
        is_error: false,
        result: "First turnSecond turn",
        duration_ms: 2500,
        num_turns: 2,
        usage: %Usage{input_tokens: 20, output_tokens: 30}
      }
    ]
  end

  def build_event_stream(:error, opts) do
    session_id = Keyword.get(opts, :session_id, "amp-test-session-id")
    error_message = Keyword.get(opts, :error_message, "Test error occurred")

    [
      %SystemMessage{
        type: "system",
        subtype: "init",
        session_id: session_id,
        cwd: "/tmp/test",
        tools: ["Read", "Write", "Bash"],
        mcp_servers: []
      },
      %ErrorResultMessage{
        type: "result",
        subtype: "error_during_execution",
        session_id: session_id,
        is_error: true,
        error: error_message,
        duration_ms: 500,
        num_turns: 0,
        usage: %Usage{input_tokens: 5, output_tokens: 0},
        permission_denials: Keyword.get(opts, :permission_denials)
      }
    ]
  end

  def build_event_stream(:cancelled, opts) do
    session_id = Keyword.get(opts, :session_id, "amp-test-session-id")

    [
      %SystemMessage{
        type: "system",
        subtype: "init",
        session_id: session_id,
        cwd: "/tmp/test",
        tools: ["Read", "Write", "Bash"],
        mcp_servers: []
      },
      %AssistantMessage{
        type: "assistant",
        session_id: session_id,
        message: %AssistantPayload{
          id: "msg-1",
          role: "assistant",
          content: [%TextContent{type: "text", text: "Partial"}],
          stop_reason: nil,
          usage: %Usage{input_tokens: 5, output_tokens: 5}
        }
      }
      # Stream ends abruptly (no ResultMessage) to simulate cancellation
    ]
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl GenServer
  def init(opts) do
    scenario = Keyword.get(opts, :scenario, :simple_response)
    events = Keyword.get(opts, :events) || build_event_stream(scenario, opts)
    delay_ms = Keyword.get(opts, :delay_ms, 0)

    state = %{
      events: events,
      cancelled: false,
      delay_ms: delay_ms
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:set_events, events}, _from, state) do
    {:reply, :ok, %{state | events: events, cancelled: false}}
  end

  @impl GenServer
  def handle_call(:execute, _from, state) do
    mock_pid = self()

    stream =
      Stream.resource(
        fn -> {state.events, state.delay_ms, mock_pid} end,
        fn
          {[], _delay, _pid} ->
            {:halt, nil}

          {[event | rest], delay, pid} ->
            # Check if cancelled
            cancelled =
              try do
                GenServer.call(pid, :is_cancelled?, 100)
              catch
                :exit, _ -> true
              end

            if cancelled do
              {:halt, nil}
            else
              maybe_sleep(delay)
              {[event], {rest, delay, pid}}
            end
        end,
        fn _ -> :ok end
      )

    {:reply, stream, state}
  end

  @impl GenServer
  def handle_call(:cancel, _from, state) do
    {:reply, :ok, %{state | cancelled: true}}
  end

  @impl GenServer
  def handle_call(:is_cancelled?, _from, state) do
    {:reply, state.cancelled, state}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  defp maybe_sleep(delay) when delay > 0, do: Process.sleep(delay)
  defp maybe_sleep(_delay), do: :ok
end
