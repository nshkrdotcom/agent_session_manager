defmodule AgentSessionManager.Test.CodexMockSDK do
  @moduledoc """
  Mock Codex SDK for testing CodexAdapter without network dependencies.

  This module simulates Codex SDK behavior by generating typed event structs
  that match the real `Codex.Events` module structure.

  ## Usage

      {:ok, mock} = CodexMockSDK.start_link(events: [:thread_started, :turn_completed])

      # Configure specific responses
      CodexMockSDK.set_events(mock, [
        %Codex.Events.ThreadStarted{thread_id: "test-123"},
        %Codex.Events.TurnCompleted{thread_id: "test-123", turn_id: "turn-1"}
      ])

      # Get streaming result that mimics Thread.run_streamed/3
      result = CodexMockSDK.run_streamed(mock, thread, input, opts)

  ## Event Scenarios

  Use `build_event_stream/1` to generate realistic event sequences:
  - `:simple_response` - ThreadStarted, ItemAgentMessageDelta, TurnCompleted
  - `:with_tool_call` - Includes ToolCallRequested and ToolCallCompleted
  - `:with_command_item` - Includes ItemStarted/ItemCompleted command execution events
  - `:streaming` - Multiple ItemAgentMessageDelta events
  - `:error` - Includes Error or TurnFailed event
  """

  use GenServer
  use Supertester.TestableGenServer

  alias Codex.Events
  alias Codex.Items

  @type event_scenario ::
          :simple_response
          | :with_tool_call
          | :with_command_item
          | :streaming
          | :error
          | :cancelled

  @type state :: %{
          events: [Events.t()],
          subscribers: [pid()],
          cancelled: boolean(),
          delay_ms: non_neg_integer()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the mock Codex SDK.

  ## Options

  - `:events` - List of events to emit (default: simple_response scenario)
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
  Sets the events to emit.
  """
  @spec set_events(GenServer.server(), [Events.t()]) :: :ok
  def set_events(server, events) do
    GenServer.call(server, {:set_events, events})
  end

  @doc """
  Sets events using a scenario name.
  """
  @spec set_scenario(GenServer.server(), event_scenario(), keyword()) :: :ok
  def set_scenario(server, scenario, opts \\ []) do
    events = build_event_stream(scenario, opts)
    set_events(server, events)
  end

  @doc """
  Simulates Thread.run_streamed/3 returning a mock RunResultStreaming.
  """
  @spec run_streamed(GenServer.server(), term(), term(), keyword()) ::
          {:ok, mock_result()} | {:error, term()}
  def run_streamed(server, _thread, _input, _opts \\ []) do
    GenServer.call(server, :run_streamed)
  end

  @type mock_result :: %{
          mock_pid: pid(),
          events_fn: (-> Enumerable.t()),
          raw_events_fn: (-> Enumerable.t())
        }

  @doc """
  Gets raw events stream from mock result (mimics RunResultStreaming.raw_events/1).
  """
  @spec raw_events(mock_result()) :: Enumerable.t()
  def raw_events(%{raw_events_fn: fun}), do: fun.()

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

  - `:thread_id` - Thread ID (default: "test-thread-id")
  - `:turn_id` - Turn ID (default: "test-turn-id")
  - `:content` - Response content (default: "Test response")
  - `:tool_name` - Tool name for tool_call scenarios (default: "test_tool")
  - `:error_message` - Error message for error scenarios
  """
  @spec build_event_stream(event_scenario(), keyword()) :: [Events.t()]
  def build_event_stream(scenario, opts \\ [])

  def build_event_stream(:simple_response, opts) do
    thread_id = Keyword.get(opts, :thread_id, "test-thread-id")
    turn_id = Keyword.get(opts, :turn_id, "test-turn-id")
    content = Keyword.get(opts, :content, "Test response")

    [
      %Events.ThreadStarted{thread_id: thread_id, metadata: %{}},
      %Events.TurnStarted{thread_id: thread_id, turn_id: turn_id},
      %Events.ItemAgentMessageDelta{
        thread_id: thread_id,
        turn_id: turn_id,
        item: %{
          "id" => "item-1",
          "type" => "agentMessage",
          "content" => [%{"type" => "text", "text" => content}]
        }
      },
      %Events.ThreadTokenUsageUpdated{
        thread_id: thread_id,
        turn_id: turn_id,
        usage: %{"input_tokens" => 10, "output_tokens" => 20}
      },
      %Events.TurnCompleted{
        thread_id: thread_id,
        turn_id: turn_id,
        status: "completed",
        usage: %{"input_tokens" => 10, "output_tokens" => 20}
      }
    ]
  end

  def build_event_stream(:streaming, opts) do
    thread_id = Keyword.get(opts, :thread_id, "test-thread-id")
    turn_id = Keyword.get(opts, :turn_id, "test-turn-id")
    chunks = Keyword.get(opts, :chunks, ["Hello", " ", "world", "!"])

    [%Events.ThreadStarted{thread_id: thread_id, metadata: %{}}] ++
      [%Events.TurnStarted{thread_id: thread_id, turn_id: turn_id}] ++
      Enum.with_index(chunks, fn chunk, idx ->
        %Events.ItemAgentMessageDelta{
          thread_id: thread_id,
          turn_id: turn_id,
          item: %{
            "id" => "item-#{idx}",
            "type" => "agentMessage",
            "content" => [%{"type" => "text", "text" => chunk}]
          }
        }
      end) ++
      [
        %Events.ThreadTokenUsageUpdated{
          thread_id: thread_id,
          turn_id: turn_id,
          usage: %{"input_tokens" => 15, "output_tokens" => 25}
        },
        %Events.TurnCompleted{
          thread_id: thread_id,
          turn_id: turn_id,
          status: "completed"
        }
      ]
  end

  def build_event_stream(:with_tool_call, opts) do
    thread_id = Keyword.get(opts, :thread_id, "test-thread-id")
    turn_id = Keyword.get(opts, :turn_id, "test-turn-id")
    tool_name = Keyword.get(opts, :tool_name, "test_tool")
    call_id = Keyword.get(opts, :call_id, "call-1")
    tool_args = Keyword.get(opts, :tool_args, %{"arg1" => "value1"})
    tool_output = Keyword.get(opts, :tool_output, %{"result" => "success"})
    content = Keyword.get(opts, :content, "Used the tool successfully")

    [
      %Events.ThreadStarted{thread_id: thread_id, metadata: %{}},
      %Events.TurnStarted{thread_id: thread_id, turn_id: turn_id},
      %Events.ToolCallRequested{
        thread_id: thread_id,
        turn_id: turn_id,
        call_id: call_id,
        tool_name: tool_name,
        arguments: tool_args,
        requires_approval: false
      },
      %Events.ToolCallCompleted{
        thread_id: thread_id,
        turn_id: turn_id,
        call_id: call_id,
        tool_name: tool_name,
        output: tool_output
      },
      %Events.ItemAgentMessageDelta{
        thread_id: thread_id,
        turn_id: turn_id,
        item: %{
          "id" => "item-1",
          "type" => "agentMessage",
          "content" => [%{"type" => "text", "text" => content}]
        }
      },
      %Events.ThreadTokenUsageUpdated{
        thread_id: thread_id,
        turn_id: turn_id,
        usage: %{"input_tokens" => 30, "output_tokens" => 50}
      },
      %Events.TurnCompleted{
        thread_id: thread_id,
        turn_id: turn_id,
        status: "completed"
      }
    ]
  end

  def build_event_stream(:with_command_item, opts) do
    thread_id = Keyword.get(opts, :thread_id, "test-thread-id")
    turn_id = Keyword.get(opts, :turn_id, "test-turn-id")
    command = Keyword.get(opts, :command, "pwd")
    command_output = Keyword.get(opts, :command_output, "/tmp/test\n")
    cwd = Keyword.get(opts, :cwd, "/tmp/test")
    first_message = Keyword.get(opts, :first_message, "I will inspect the workspace first.")
    final_message = Keyword.get(opts, :final_message, "Done. Current directory is /tmp/test.")

    [
      %Events.ThreadStarted{thread_id: thread_id, metadata: %{}},
      %Events.TurnStarted{thread_id: thread_id, turn_id: turn_id},
      %Events.ItemCompleted{
        thread_id: thread_id,
        turn_id: turn_id,
        item: %Items.AgentMessage{id: "msg-1", text: first_message}
      },
      %Events.ItemStarted{
        thread_id: thread_id,
        turn_id: turn_id,
        item: %Items.CommandExecution{
          id: "cmd-1",
          command: command,
          cwd: cwd,
          status: :in_progress
        }
      },
      %Events.ItemCompleted{
        thread_id: thread_id,
        turn_id: turn_id,
        item: %Items.CommandExecution{
          id: "cmd-1",
          command: command,
          cwd: cwd,
          aggregated_output: command_output,
          exit_code: 0,
          status: :completed,
          duration_ms: 5
        }
      },
      %Events.ItemCompleted{
        thread_id: thread_id,
        turn_id: turn_id,
        item: %Items.AgentMessage{id: "msg-2", text: final_message}
      },
      %Events.TurnCompleted{
        thread_id: thread_id,
        turn_id: turn_id,
        status: "completed",
        usage: %{"input_tokens" => 21, "output_tokens" => 34}
      }
    ]
  end

  def build_event_stream(:error, opts) do
    thread_id = Keyword.get(opts, :thread_id, "test-thread-id")
    turn_id = Keyword.get(opts, :turn_id, "test-turn-id")
    error_message = Keyword.get(opts, :error_message, "Test error occurred")

    [
      %Events.ThreadStarted{thread_id: thread_id, metadata: %{}},
      %Events.TurnStarted{thread_id: thread_id, turn_id: turn_id},
      %Events.Error{
        thread_id: thread_id,
        turn_id: turn_id,
        message: error_message
      },
      %Events.TurnFailed{
        thread_id: thread_id,
        turn_id: turn_id,
        error: %{"message" => error_message, "code" => "test_error"}
      }
    ]
  end

  def build_event_stream(:cancelled, opts) do
    thread_id = Keyword.get(opts, :thread_id, "test-thread-id")
    turn_id = Keyword.get(opts, :turn_id, "test-turn-id")

    [
      %Events.ThreadStarted{thread_id: thread_id, metadata: %{}},
      %Events.TurnStarted{thread_id: thread_id, turn_id: turn_id},
      %Events.TurnAborted{
        turn_id: turn_id,
        reason: "cancelled"
      }
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
      subscribers: [],
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
  def handle_call(:run_streamed, _from, state) do
    mock_pid = self()

    events_fn = fn ->
      GenServer.call(mock_pid, :get_events_stream)
    end

    raw_events_fn = fn ->
      GenServer.call(mock_pid, :get_raw_events_stream)
    end

    result = %{
      mock_pid: mock_pid,
      events_fn: events_fn,
      raw_events_fn: raw_events_fn
    }

    {:reply, {:ok, result}, state}
  end

  @impl GenServer
  def handle_call(:get_events_stream, _from, state) do
    stream = build_event_stream_resource(state)
    {:reply, stream, state}
  end

  @impl GenServer
  def handle_call(:get_raw_events_stream, _from, state) do
    stream = build_event_stream_resource(state)
    {:reply, stream, state}
  end

  @impl GenServer
  def handle_call(:cancel, _from, state) do
    {:reply, :ok, %{state | cancelled: true}}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  # ============================================================================
  # Private Stream Helpers
  # ============================================================================

  defp build_event_stream_resource(state) do
    Stream.resource(
      fn -> {state.events, state.cancelled, state.delay_ms} end,
      &stream_next_element/1,
      fn _ -> :ok end
    )
  end

  defp stream_next_element({[], _cancelled, _delay}), do: {:halt, nil}
  defp stream_next_element({_events, true, _delay}), do: {:halt, nil}

  defp stream_next_element({[event | rest], _cancelled, delay}) do
    if delay > 0, do: Process.sleep(delay)
    {[event], {rest, false, delay}}
  end
end
