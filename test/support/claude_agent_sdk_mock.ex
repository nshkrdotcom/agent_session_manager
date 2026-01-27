defmodule AgentSessionManager.Test.ClaudeAgentSDKMock do
  @moduledoc """
  Mock for ClaudeAgentSDK that simulates the streaming Message interface.

  This mock generates `ClaudeAgentSDK.Message` structs that match the real SDK's
  streaming behavior, allowing tests without network or CLI dependencies.

  ## Event Flow

  The real ClaudeAgentSDK.Query.run/3 returns a stream of Message structs:
  1. `:system` (init) - Session initialization
  2. `:assistant` - Claude's responses (possibly multiple for streaming)
  3. `:result` (success/error) - Final result

  ## Usage

      {:ok, mock} = ClaudeAgentSDKMock.start_link(scenario: :simple_response)

      # Get stream that mimics ClaudeAgentSDK.Query.run/3
      stream = ClaudeAgentSDKMock.query(mock, "Hello", %Options{})

      # Process messages
      Enum.each(stream, fn msg -> IO.inspect(msg) end)

  ## Scenarios

  - `:simple_response` - System init, assistant message, success result
  - `:streaming` - Multiple assistant messages (partial content)
  - `:with_tool_use` - Includes tool use content blocks
  - `:error` - Ends with error result
  """

  use GenServer

  alias ClaudeAgentSDK.Message

  @type scenario :: :simple_response | :streaming | :with_tool_use | :error

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the mock SDK.

  ## Options

  - `:scenario` - The scenario to simulate (default: :simple_response)
  - `:content` - Custom content for assistant response
  - `:session_id` - Custom session ID
  - `:delay_ms` - Delay between messages (default: 0)
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

  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  @doc """
  Simulates ClaudeAgentSDK.Query.run/3 - returns a stream of Message structs.
  """
  @spec query(GenServer.server(), String.t(), term()) :: Enumerable.t(Message.t())
  def query(server, _prompt, _options) do
    GenServer.call(server, :get_message_stream)
  end

  @doc """
  Sets a custom list of messages to emit.
  """
  @spec set_messages(GenServer.server(), [Message.t()]) :: :ok
  def set_messages(server, messages) do
    GenServer.call(server, {:set_messages, messages})
  end

  @doc """
  Builds a realistic message stream for the given scenario.
  """
  @spec build_message_stream(scenario(), keyword()) :: [Message.t()]
  def build_message_stream(scenario, opts \\ [])

  def build_message_stream(:simple_response, opts) do
    session_id = Keyword.get(opts, :session_id, "test-session-id")
    content = Keyword.get(opts, :content, "Hello! How can I help you?")

    [
      # System init message
      %Message{
        type: :system,
        subtype: :init,
        data: %{
          session_id: session_id,
          cwd: "/tmp/test",
          tools: [],
          mcp_servers: [],
          model: "claude-sonnet-4-20250514",
          permission_mode: "default",
          api_key_source: "test"
        },
        raw: %{}
      },
      # Assistant message with full response
      %Message{
        type: :assistant,
        subtype: nil,
        data: %{
          message: %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => content}]
          },
          session_id: session_id
        },
        raw: %{}
      },
      # Success result
      %Message{
        type: :result,
        subtype: :success,
        data: %{
          session_id: session_id,
          result: content,
          total_cost_usd: 0.001,
          duration_ms: 1500,
          duration_api_ms: 1200,
          num_turns: 1,
          is_error: false,
          usage: %{"input_tokens" => 10, "output_tokens" => 20}
        },
        raw: %{}
      }
    ]
  end

  def build_message_stream(:streaming, opts) do
    session_id = Keyword.get(opts, :session_id, "test-session-id")
    chunks = Keyword.get(opts, :chunks, ["Hello", " ", "world", "!"])

    # Multiple assistant messages for streaming effect
    [
      # System init
      %Message{
        type: :system,
        subtype: :init,
        data: %{
          session_id: session_id,
          cwd: "/tmp/test",
          tools: [],
          mcp_servers: [],
          model: "claude-sonnet-4-20250514",
          permission_mode: "default",
          api_key_source: "test"
        },
        raw: %{}
      }
    ] ++
      Enum.map(chunks, fn chunk ->
        %Message{
          type: :assistant,
          subtype: nil,
          data: %{
            message: %{
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => chunk}]
            },
            session_id: session_id
          },
          raw: %{}
        }
      end) ++
      [
        # Success result
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: session_id,
            result: Enum.join(chunks, ""),
            total_cost_usd: 0.002,
            duration_ms: 2000,
            duration_api_ms: 1800,
            num_turns: 1,
            is_error: false,
            usage: %{"input_tokens" => 15, "output_tokens" => 25}
          },
          raw: %{}
        }
      ]
  end

  def build_message_stream(:with_tool_use, opts) do
    session_id = Keyword.get(opts, :session_id, "test-session-id")
    tool_name = Keyword.get(opts, :tool_name, "read_file")
    tool_id = Keyword.get(opts, :tool_id, "toolu_test123")
    tool_input = Keyword.get(opts, :tool_input, %{"path" => "/test.txt"})

    [
      # System init
      %Message{
        type: :system,
        subtype: :init,
        data: %{
          session_id: session_id,
          cwd: "/tmp/test",
          tools: [tool_name],
          mcp_servers: [],
          model: "claude-sonnet-4-20250514",
          permission_mode: "default",
          api_key_source: "test"
        },
        raw: %{}
      },
      # Assistant message with tool use
      %Message{
        type: :assistant,
        subtype: nil,
        data: %{
          message: %{
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "Let me read that file for you."},
              %{
                "type" => "tool_use",
                "id" => tool_id,
                "name" => tool_name,
                "input" => tool_input
              }
            ]
          },
          session_id: session_id
        },
        raw: %{}
      },
      # Final assistant message after tool use
      %Message{
        type: :assistant,
        subtype: nil,
        data: %{
          message: %{
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "I've read the file successfully."}
            ]
          },
          session_id: session_id
        },
        raw: %{}
      },
      # Success result
      %Message{
        type: :result,
        subtype: :success,
        data: %{
          session_id: session_id,
          result: "I've read the file successfully.",
          total_cost_usd: 0.003,
          duration_ms: 3000,
          duration_api_ms: 2500,
          num_turns: 2,
          is_error: false,
          usage: %{"input_tokens" => 30, "output_tokens" => 50}
        },
        raw: %{}
      }
    ]
  end

  def build_message_stream(:error, opts) do
    session_id = Keyword.get(opts, :session_id, "test-session-id")
    error_message = Keyword.get(opts, :error_message, "An error occurred")

    [
      # System init
      %Message{
        type: :system,
        subtype: :init,
        data: %{
          session_id: session_id,
          cwd: "/tmp/test",
          tools: [],
          mcp_servers: [],
          model: "claude-sonnet-4-20250514",
          permission_mode: "default",
          api_key_source: "test"
        },
        raw: %{}
      },
      # Error result
      %Message{
        type: :result,
        subtype: :error_during_execution,
        data: %{
          session_id: session_id,
          error: error_message,
          total_cost_usd: 0.0,
          duration_ms: 500,
          duration_api_ms: 0,
          num_turns: 0,
          is_error: true
        },
        raw: %{}
      }
    ]
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl GenServer
  def init(opts) do
    scenario = Keyword.get(opts, :scenario, :simple_response)
    delay_ms = Keyword.get(opts, :delay_ms, 0)
    messages = Keyword.get(opts, :messages) || build_message_stream(scenario, opts)

    state = %{
      messages: messages,
      delay_ms: delay_ms
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:set_messages, messages}, _from, state) do
    {:reply, :ok, %{state | messages: messages}}
  end

  @impl GenServer
  def handle_call(:get_message_stream, _from, state) do
    stream =
      Stream.resource(
        fn -> {state.messages, state.delay_ms} end,
        fn
          {[], _delay} ->
            {:halt, nil}

          {[msg | rest], delay} ->
            if delay > 0, do: Process.sleep(delay)
            {[msg], {rest, delay}}
        end,
        fn _ -> :ok end
      )

    {:reply, stream, state}
  end
end
