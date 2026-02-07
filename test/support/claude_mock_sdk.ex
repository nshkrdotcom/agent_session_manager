defmodule AgentSessionManager.Adapters.Claude.MockSDK do
  @moduledoc """
  Mock SDK that simulates Claude API streaming responses for testing.

  This mock uses process mailbox to deliver events, allowing test control over timing.
  It simulates the actual Claude API event shapes as documented in the SDK integration notes.

  ## Claude API Event Shapes (Simulated)

  The Claude Messages API streams events in Server-Sent Events (SSE) format:

  ### message_start
  ```json
  {
    "type": "message_start",
    "message": {
      "id": "msg_01...",
      "type": "message",
      "role": "assistant",
      "content": [],
      "model": "claude-haiku-4-5-20251001",
      "stop_reason": null,
      "stop_sequence": null,
      "usage": {"input_tokens": 25, "output_tokens": 1}
    }
  }
  ```

  ### content_block_start
  ```json
  {
    "type": "content_block_start",
    "index": 0,
    "content_block": {"type": "text", "text": ""}
  }
  ```

  ### content_block_delta
  ```json
  {
    "type": "content_block_delta",
    "index": 0,
    "delta": {"type": "text_delta", "text": "Hello"}
  }
  ```

  ### content_block_stop
  ```json
  {
    "type": "content_block_stop",
    "index": 0
  }
  ```

  ### message_delta
  ```json
  {
    "type": "message_delta",
    "delta": {"stop_reason": "end_turn", "stop_sequence": null},
    "usage": {"output_tokens": 15}
  }
  ```

  ### message_stop
  ```json
  {
    "type": "message_stop"
  }
  ```

  ### Tool Use Content Block
  ```json
  {
    "type": "content_block_start",
    "index": 1,
    "content_block": {
      "type": "tool_use",
      "id": "toolu_01...",
      "name": "get_weather",
      "input": {}
    }
  }
  ```

  ```json
  {
    "type": "content_block_delta",
    "index": 1,
    "delta": {"type": "input_json_delta", "partial_json": "{\"location\":"}
  }
  ```

  ## Scenarios

  - `:successful_stream` - Normal streaming response with multiple content blocks
  - `:tool_use_response` - Response containing tool use requiring tool result
  - `:rate_limit_error` - Simulates 429 rate limit error
  - `:network_timeout` - Simulates network timeout
  - `:partial_disconnect` - Partial response followed by disconnect

  ## Usage

  ```elixir
  {:ok, mock} = MockSDK.start_link(scenario: :successful_stream)
  config = %{sdk_module: MockSDK, sdk_pid: mock}
  {:ok, handle} = ClaudeAdapter.init_session(config, %{})

  MockSDK.emit_next(mock)  # Emit message_start
  MockSDK.emit_next(mock)  # Emit content_block_start
  MockSDK.emit_next(mock)  # Emit content_block_delta
  MockSDK.complete(mock)   # Emit remaining events and close
  ```
  """

  use GenServer

  alias AgentSessionManager.Core.Error

  @type scenario ::
          :successful_stream
          | :tool_use_response
          | :rate_limit_error
          | :network_timeout
          | :partial_disconnect

  @type event :: map()

  @type state :: %{
          scenario: scenario(),
          events: [event()],
          emitted: [event()],
          subscriber: pid() | nil,
          completed: boolean(),
          error: Error.t() | nil,
          message_id: String.t(),
          model: String.t()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the mock SDK with a specific scenario.

  ## Options

  - `:scenario` - The scenario to simulate (default: `:successful_stream`)
  - `:model` - The model name to use (default: "claude-haiku-4-5-20251001")
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
  Subscribes a process to receive events.

  Events will be sent to the subscriber as `{:claude_event, event}` messages.
  """
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server, pid) do
    GenServer.call(server, {:subscribe, pid})
  end

  @doc """
  Emits the next event in the sequence.

  Returns `{:ok, event}` if an event was emitted, or `{:error, :no_more_events}` if complete.
  """
  @spec emit_next(GenServer.server()) ::
          {:ok, event()} | {:error, :no_more_events | :already_completed}
  def emit_next(server) do
    GenServer.call(server, :emit_next)
  end

  @doc """
  Emits all remaining events and completes the stream.
  """
  @spec complete(GenServer.server()) :: {:ok, [event()]} | {:error, :already_completed}
  def complete(server) do
    GenServer.call(server, :complete)
  end

  @doc """
  Forces an error condition during streaming.
  """
  @spec force_error(GenServer.server(), Error.t()) :: :ok
  def force_error(server, error) do
    GenServer.call(server, {:force_error, error})
  end

  @doc """
  Gets the current state of the mock (for testing).
  """
  @spec get_state(GenServer.server()) :: state()
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @doc """
  Simulates creating a new message stream.

  This is the mock equivalent of calling the Claude API to create a message.
  Returns a handle that can be used to receive events.
  """
  @spec create_message(GenServer.server(), map()) ::
          {:ok, reference()} | {:error, Error.t()}
  def create_message(server, _params) do
    GenServer.call(server, :create_message)
  end

  @doc """
  Simulates cancelling/aborting an in-progress stream.
  """
  @spec cancel_stream(GenServer.server(), reference()) :: :ok | {:error, Error.t()}
  def cancel_stream(server, stream_ref) do
    GenServer.call(server, {:cancel_stream, stream_ref})
  end

  @doc """
  Returns the capabilities that Claude supports.
  """
  @spec get_capabilities() :: [map()]
  def get_capabilities do
    [
      %{name: "streaming", type: :sampling, enabled: true},
      %{name: "tool_use", type: :tool, enabled: true},
      %{name: "vision", type: :resource, enabled: true},
      %{name: "system_prompts", type: :prompt, enabled: true}
    ]
  end

  @doc """
  Returns whether the mock supports interruption (it does).
  """
  @spec supports_interrupt?() :: boolean()
  def supports_interrupt?, do: true

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl GenServer
  def init(opts) do
    scenario = Keyword.get(opts, :scenario, :successful_stream)
    model = Keyword.get(opts, :model, "claude-haiku-4-5-20251001")
    message_id = generate_message_id()

    state = %{
      scenario: scenario,
      events: build_events_for_scenario(scenario, message_id, model),
      emitted: [],
      subscriber: nil,
      completed: false,
      error: nil,
      message_id: message_id,
      model: model,
      stream_ref: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscriber: pid}}
  end

  @impl GenServer
  def handle_call(:emit_next, _from, %{completed: true} = state) do
    {:reply, {:error, :already_completed}, state}
  end

  @impl GenServer
  def handle_call(:emit_next, _from, %{events: []} = state) do
    {:reply, {:error, :no_more_events}, state}
  end

  @impl GenServer
  def handle_call(:emit_next, _from, %{error: error} = state) when not is_nil(error) do
    if state.subscriber do
      send(state.subscriber, {:claude_error, error})
    end

    {:reply, {:error, error}, %{state | completed: true}}
  end

  @impl GenServer
  def handle_call(:emit_next, _from, state) do
    [event | remaining] = state.events

    if state.subscriber do
      send(state.subscriber, {:claude_event, event})
    end

    new_state = %{
      state
      | events: remaining,
        emitted: state.emitted ++ [event],
        completed: remaining == []
    }

    {:reply, {:ok, event}, new_state}
  end

  @impl GenServer
  def handle_call(:complete, _from, %{completed: true} = state) do
    {:reply, {:error, :already_completed}, state}
  end

  @impl GenServer
  def handle_call(:complete, _from, state) do
    # Emit all remaining events
    Enum.each(state.events, fn event ->
      if state.subscriber do
        send(state.subscriber, {:claude_event, event})
      end
    end)

    new_state = %{
      state
      | events: [],
        emitted: state.emitted ++ state.events,
        completed: true
    }

    {:reply, {:ok, state.events}, new_state}
  end

  @impl GenServer
  def handle_call({:force_error, error}, _from, state) do
    if state.subscriber do
      send(state.subscriber, {:claude_error, error})
    end

    {:reply, :ok, %{state | error: error, completed: true}}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_call(:create_message, _from, %{scenario: :rate_limit_error} = state) do
    error =
      Error.new(:provider_rate_limited, "Rate limit exceeded",
        provider_error: %{
          status_code: 429,
          headers: %{"retry-after" => "30"},
          body: %{"error" => %{"type" => "rate_limit_error", "message" => "Rate limit exceeded"}}
        }
      )

    {:reply, {:error, error}, state}
  end

  @impl GenServer
  def handle_call(:create_message, _from, %{scenario: :network_timeout} = state) do
    error =
      Error.new(:provider_timeout, "Request timed out",
        provider_error: %{
          reason: :timeout,
          timeout_ms: 30_000
        }
      )

    {:reply, {:error, error}, state}
  end

  @impl GenServer
  def handle_call(:create_message, _from, state) do
    stream_ref = make_ref()
    {:reply, {:ok, stream_ref}, %{state | stream_ref: stream_ref}}
  end

  @impl GenServer
  def handle_call({:cancel_stream, stream_ref}, _from, state) do
    if state.stream_ref == stream_ref do
      if state.subscriber do
        send(state.subscriber, {:claude_cancelled, stream_ref})
      end

      {:reply, :ok, %{state | completed: true}}
    else
      {:reply, {:error, Error.new(:not_found, "Stream not found")}, state}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp generate_message_id do
    random_suffix =
      :crypto.strong_rand_bytes(12)
      |> Base.encode32(case: :lower, padding: false)

    "msg_01#{random_suffix}"
  end

  defp generate_tool_use_id do
    random_suffix =
      :crypto.strong_rand_bytes(12)
      |> Base.encode32(case: :lower, padding: false)

    "toolu_01#{random_suffix}"
  end

  defp build_events_for_scenario(:successful_stream, message_id, model) do
    [
      # message_start
      %{
        type: "message_start",
        message: %{
          id: message_id,
          type: "message",
          role: "assistant",
          content: [],
          model: model,
          stop_reason: nil,
          stop_sequence: nil,
          usage: %{input_tokens: 25, output_tokens: 1}
        }
      },
      # content_block_start for text
      %{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "text", text: ""}
      },
      # content_block_delta with first chunk
      %{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "text_delta", text: "Hello! "}
      },
      # content_block_delta with second chunk
      %{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "text_delta", text: "How can I "}
      },
      # content_block_delta with third chunk
      %{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "text_delta", text: "help you today?"}
      },
      # content_block_stop
      %{
        type: "content_block_stop",
        index: 0
      },
      # message_delta with final usage
      %{
        type: "message_delta",
        delta: %{stop_reason: "end_turn", stop_sequence: nil},
        usage: %{output_tokens: 15}
      },
      # message_stop
      %{
        type: "message_stop"
      }
    ]
  end

  defp build_events_for_scenario(:tool_use_response, message_id, model) do
    tool_use_id = generate_tool_use_id()

    [
      # message_start
      %{
        type: "message_start",
        message: %{
          id: message_id,
          type: "message",
          role: "assistant",
          content: [],
          model: model,
          stop_reason: nil,
          stop_sequence: nil,
          usage: %{input_tokens: 50, output_tokens: 1}
        }
      },
      # content_block_start for text (thinking/explanation)
      %{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "text", text: ""}
      },
      # content_block_delta with explanation
      %{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "text_delta", text: "Let me check the weather for you."}
      },
      # content_block_stop for text
      %{
        type: "content_block_stop",
        index: 0
      },
      # content_block_start for tool_use
      %{
        type: "content_block_start",
        index: 1,
        content_block: %{
          type: "tool_use",
          id: tool_use_id,
          name: "get_weather",
          input: %{}
        }
      },
      # content_block_delta with partial JSON input
      %{
        type: "content_block_delta",
        index: 1,
        delta: %{type: "input_json_delta", partial_json: "{\"location\":"}
      },
      # content_block_delta with more JSON
      %{
        type: "content_block_delta",
        index: 1,
        delta: %{type: "input_json_delta", partial_json: "\"San Francisco\"}"}
      },
      # content_block_stop for tool_use
      %{
        type: "content_block_stop",
        index: 1
      },
      # message_delta with tool_use stop reason
      %{
        type: "message_delta",
        delta: %{stop_reason: "tool_use", stop_sequence: nil},
        usage: %{output_tokens: 45}
      },
      # message_stop
      %{
        type: "message_stop"
      }
    ]
  end

  defp build_events_for_scenario(:partial_disconnect, message_id, model) do
    # Only partial events before "disconnect"
    [
      # message_start
      %{
        type: "message_start",
        message: %{
          id: message_id,
          type: "message",
          role: "assistant",
          content: [],
          model: model,
          stop_reason: nil,
          stop_sequence: nil,
          usage: %{input_tokens: 25, output_tokens: 1}
        }
      },
      # content_block_start for text
      %{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "text", text: ""}
      },
      # content_block_delta with first chunk
      %{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "text_delta", text: "Hello! "}
      },
      # DISCONNECT happens here - no more events
      # This will be followed by an error being forced
      %{
        type: "__disconnect__",
        error:
          Error.new(:provider_error, "Connection lost",
            provider_error: %{
              reason: :closed,
              partial_content: "Hello! "
            }
          )
      }
    ]
  end

  # Error scenarios return empty events as the error happens immediately
  defp build_events_for_scenario(:rate_limit_error, _message_id, _model), do: []
  defp build_events_for_scenario(:network_timeout, _message_id, _model), do: []
end
