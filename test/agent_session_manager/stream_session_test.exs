defmodule AgentSessionManager.StreamSessionTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.StreamSession
  alias AgentSessionManager.Test.MockProviderAdapter

  describe "start/1" do
    test "streams events from a mock adapter with {Module, opts} tuple" do
      result =
        StreamSession.start(
          adapter: {MockProviderAdapter, execution_mode: :instant},
          input: %{messages: [%{role: "user", content: "hello"}]}
        )

      assert {:ok, stream, close_fun, meta} = result
      assert is_function(close_fun, 0)
      assert is_map(meta)

      events = Enum.to_list(stream)
      assert events != []

      types = Enum.map(events, & &1.type)
      assert :run_started in types
      assert :message_received in types
      assert :run_completed in types

      assert close_fun.() == :ok
    end

    test "accepts an existing adapter pid (not terminated on close)" do
      {:ok, adapter} =
        MockProviderAdapter.start_link(execution_mode: :instant)

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      {:ok, stream, close_fun, _meta} =
        StreamSession.start(
          adapter: adapter,
          input: %{messages: [%{role: "user", content: "hello"}]}
        )

      Enum.to_list(stream)
      close_fun.()

      # Adapter should still be alive — StreamSession doesn't own it
      assert Process.alive?(adapter)
    end

    test "accepts an existing store pid (not terminated on close)" do
      {:ok, store} = InMemorySessionStore.start_link([])
      cleanup_on_exit(fn -> safe_stop(store) end)

      {:ok, stream, close_fun, _meta} =
        StreamSession.start(
          adapter: {MockProviderAdapter, execution_mode: :instant},
          store: store,
          input: %{messages: [%{role: "user", content: "hello"}]}
        )

      Enum.to_list(stream)
      close_fun.()

      # Store should still be alive — StreamSession doesn't own it
      assert Process.alive?(store)
    end

    test "close_fun is idempotent" do
      {:ok, _stream, close_fun, _meta} =
        StreamSession.start(
          adapter: {MockProviderAdapter, execution_mode: :instant},
          input: %{messages: [%{role: "user", content: "hello"}]}
        )

      assert close_fun.() == :ok
      assert close_fun.() == :ok
      assert close_fun.() == :ok
    end

    test "close_fun works before stream is consumed" do
      {:ok, _stream, close_fun, _meta} =
        StreamSession.start(
          adapter: {MockProviderAdapter, execution_mode: :instant},
          input: %{messages: [%{role: "user", content: "hello"}]}
        )

      # Close immediately without consuming the stream
      assert close_fun.() == :ok
    end

    test "stream emits error event when adapter fails" do
      {:ok, adapter} =
        MockProviderAdapter.start_link(execution_mode: :failing)

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      {:ok, stream, close_fun, _meta} =
        StreamSession.start(
          adapter: adapter,
          input: %{messages: [%{role: "user", content: "hello"}]}
        )

      events = Enum.to_list(stream)
      close_fun.()

      error_events = Enum.filter(events, &(&1.type == :error_occurred))
      assert error_events != []
    end

    test "stream halts after idle timeout" do
      {:ok, adapter} =
        MockProviderAdapter.start_link(execution_mode: :timeout)

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      {:ok, stream, close_fun, _meta} =
        StreamSession.start(
          adapter: adapter,
          input: %{messages: [%{role: "user", content: "hello"}]},
          idle_timeout: 100
        )

      events = Enum.to_list(stream)
      close_fun.()

      # Should get a timeout error event
      error_events = Enum.filter(events, &(&1.type == :error_occurred))
      assert error_events != []

      error_data = hd(error_events).data
      assert error_data.error_message =~ "timeout"
    end

    test "emits provider_timeout when run_once execute call times out" do
      {:ok, adapter} =
        MockProviderAdapter.start_link(execution_mode: :timeout)

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      {:ok, stream, close_fun, _meta} =
        StreamSession.start(
          adapter: adapter,
          input: %{messages: [%{role: "user", content: "hello"}]},
          idle_timeout: 10_000,
          run_opts: [adapter_opts: [timeout: 1]]
        )

      events = Enum.to_list(stream)
      close_fun.()

      assert Enum.any?(events, fn event ->
               event.type == :error_occurred and
                 get_in(event, [:data, :error_code]) == :provider_timeout
             end)
    end

    test "forwards agent_id to run_once" do
      {:ok, stream, close_fun, _meta} =
        StreamSession.start(
          adapter: {MockProviderAdapter, execution_mode: :instant},
          input: %{messages: [%{role: "user", content: "hello"}]},
          agent_id: "test-agent"
        )

      Enum.to_list(stream)
      close_fun.()
    end

    test "invokes user-provided run_opts event_callback while still streaming events" do
      parent = self()

      user_callback = fn event ->
        send(parent, {:user_callback_event, event.type})
      end

      {:ok, stream, close_fun, _meta} =
        StreamSession.start(
          adapter: {MockProviderAdapter, execution_mode: :instant},
          input: %{messages: [%{role: "user", content: "hello"}]},
          run_opts: [event_callback: user_callback]
        )

      events = Enum.to_list(stream)
      close_fun.()

      assert events != []
      assert_receive {:user_callback_event, :run_started}
      assert_receive {:user_callback_event, :run_completed}
    end

    test "returns error for missing adapter option" do
      assert {:error, _reason} =
               StreamSession.start(input: %{messages: [%{role: "user", content: "hello"}]})
    end

    test "returns error for missing input option" do
      assert {:error, _reason} =
               StreamSession.start(adapter: {MockProviderAdapter, execution_mode: :instant})
    end

    test "meta includes adapter info" do
      {:ok, _stream, close_fun, meta} =
        StreamSession.start(
          adapter: {MockProviderAdapter, execution_mode: :instant},
          input: %{messages: [%{role: "user", content: "hello"}]}
        )

      assert is_map(meta)
      assert meta.adapter == MockProviderAdapter

      close_fun.()
    end

    test "streaming adapter delivers events in order" do
      {:ok, stream, close_fun, _meta} =
        StreamSession.start(
          adapter: {MockProviderAdapter, execution_mode: :streaming, chunk_delay_ms: 1},
          input: %{messages: [%{role: "user", content: "hello"}]}
        )

      events = Enum.to_list(stream)
      close_fun.()

      types = Enum.map(events, & &1.type)

      # run_started must come first
      assert hd(types) == :run_started

      # run_completed must come last (among non-error types)
      completed_idx = Enum.find_index(types, &(&1 == :run_completed))
      assert completed_idx == length(types) - 1
    end
  end
end
