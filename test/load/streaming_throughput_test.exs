defmodule AgentSessionManager.Load.StreamingThroughputTest do
  @moduledoc """
  Load test scaffolding for streaming throughput testing.

  This module provides scaffolding for performance testing, but does not
  execute actual load tests during normal test runs. Load tests should be
  run separately with appropriate resources.

  ## Running Load Tests

  To run load tests:

      mix test test/load --include load_test

  Or run specific scenarios:

      mix test test/load --include load_test:streaming_throughput

  ## Metrics Collected

  - Events per second
  - Latency percentiles (p50, p95, p99)
  - Memory usage
  - Session/Run creation rate
  - Event processing rate

  ## Usage

      # Run a load scenario
      results = LoadTest.run_scenario(:concurrent_streams, duration_ms: 10_000)

      # Analyze results
      IO.puts("Events/sec: \#{results.events_per_second}")
      IO.puts("P99 latency: \#{results.p99_latency_ms}ms")

  """

  use ExUnit.Case, async: false

  alias AgentSessionManager.Adapters.InMemorySessionStore
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager
  alias AgentSessionManager.Test.{Fixtures, MockProviderAdapter}

  @moduletag :load_test

  # Skip load tests by default - they need to be explicitly enabled
  @moduletag :skip

  # ============================================================================
  # Load Test Configuration
  # ============================================================================

  @default_config %{
    # Number of concurrent sessions
    concurrent_sessions: 10,
    # Number of runs per session
    runs_per_session: 5,
    # Duration of streaming simulation in ms
    stream_duration_ms: 1000,
    # Events per stream
    events_per_stream: 100,
    # Delay between events in ms
    event_delay_ms: 10,
    # Warmup duration before measurements
    warmup_ms: 1000,
    # Measurement duration
    measurement_duration_ms: 5000
  }

  # ============================================================================
  # Load Test Scenarios
  # ============================================================================

  describe "streaming throughput scaffolding" do
    @tag :load_test
    test "scaffolding: measure single stream throughput" do
      config = Map.merge(@default_config, %{concurrent_sessions: 1, runs_per_session: 1})

      {:ok, results} = run_throughput_scenario(config)

      # Scaffolding assertions - actual thresholds would be set based on requirements
      assert results.total_events > 0
      assert results.duration_ms > 0
      assert results.events_per_second > 0

      IO.puts("\n=== Single Stream Throughput Results ===")
      print_results(results)
    end

    @tag :load_test
    test "scaffolding: measure concurrent streams throughput" do
      config = Map.merge(@default_config, %{concurrent_sessions: 5, runs_per_session: 2})

      {:ok, results} = run_throughput_scenario(config)

      assert results.total_events > 0
      assert results.concurrent_sessions == 5

      IO.puts("\n=== Concurrent Streams Throughput Results ===")
      print_results(results)
    end

    @tag :load_test
    test "scaffolding: measure event processing latency" do
      config = Map.merge(@default_config, %{concurrent_sessions: 3})

      {:ok, results} = run_latency_scenario(config)

      assert results.p50_latency_ms != nil
      assert results.p95_latency_ms != nil
      assert results.p99_latency_ms != nil

      IO.puts("\n=== Event Processing Latency Results ===")
      print_latency_results(results)
    end
  end

  # ============================================================================
  # Stress Test Scaffolding
  # ============================================================================

  describe "stress test scaffolding" do
    @tag :load_test
    test "scaffolding: session creation rate" do
      config = %{
        target_sessions: 100,
        batch_size: 10,
        measurement_duration_ms: 5000
      }

      {:ok, results} = run_session_creation_scenario(config)

      assert results.sessions_created > 0
      assert results.sessions_per_second > 0

      IO.puts("\n=== Session Creation Rate Results ===")
      IO.puts("Sessions created: #{results.sessions_created}")
      IO.puts("Sessions/second: #{Float.round(results.sessions_per_second, 2)}")
      IO.puts("Average creation time: #{Float.round(results.avg_creation_time_ms, 2)}ms")
    end

    @tag :load_test
    test "scaffolding: memory usage under load" do
      config = Map.merge(@default_config, %{concurrent_sessions: 20})

      initial_memory = :erlang.memory(:total)

      {:ok, results} = run_throughput_scenario(config)

      final_memory = :erlang.memory(:total)
      memory_delta = final_memory - initial_memory

      results_with_memory =
        Map.merge(results, %{
          initial_memory_mb: initial_memory / 1_000_000,
          final_memory_mb: final_memory / 1_000_000,
          memory_delta_mb: memory_delta / 1_000_000
        })

      IO.puts("\n=== Memory Usage Results ===")
      print_memory_results(results_with_memory)
    end
  end

  # ============================================================================
  # Benchmark Scaffolding
  # ============================================================================

  describe "benchmark scaffolding" do
    @tag :load_test
    test "scaffolding: event store append performance" do
      {:ok, store} = InMemorySessionStore.start_link()
      session = Fixtures.build_session()
      :ok = SessionStore.save_session(store, session)

      event_count = 1000

      {time_us, :ok} =
        :timer.tc(fn ->
          for i <- 1..event_count do
            event = Fixtures.build_event(index: i, session_id: session.id)
            :ok = SessionStore.append_event(store, event)
          end
        end)

      events_per_second = event_count / (time_us / 1_000_000)

      IO.puts("\n=== Event Store Append Performance ===")
      IO.puts("Events appended: #{event_count}")
      IO.puts("Total time: #{Float.round(time_us / 1000, 2)}ms")
      IO.puts("Events/second: #{Float.round(events_per_second, 0)}")
      IO.puts("Average append time: #{Float.round(time_us / event_count, 2)}us")

      InMemorySessionStore.stop(store)
    end

    @tag :load_test
    test "scaffolding: event retrieval performance" do
      {:ok, store} = InMemorySessionStore.start_link()
      session = Fixtures.build_session()
      :ok = SessionStore.save_session(store, session)

      # Insert events
      event_count = 1000

      for i <- 1..event_count do
        event = Fixtures.build_event(index: i, session_id: session.id)
        :ok = SessionStore.append_event(store, event)
      end

      # Measure retrieval
      {time_us, {:ok, events}} =
        :timer.tc(fn ->
          SessionStore.get_events(store, session.id)
        end)

      IO.puts("\n=== Event Store Retrieval Performance ===")
      IO.puts("Events retrieved: #{length(events)}")
      IO.puts("Retrieval time: #{Float.round(time_us / 1000, 2)}ms")
      IO.puts("Events/ms: #{Float.round(length(events) / (time_us / 1000), 2)}")

      InMemorySessionStore.stop(store)
    end
  end

  # ============================================================================
  # Load Test Helpers
  # ============================================================================

  defp run_throughput_scenario(config) do
    {:ok, store} = InMemorySessionStore.start_link()

    {:ok, adapter} =
      MockProviderAdapter.start_link(
        capabilities: Fixtures.provider_capabilities(:full_claude),
        execution_mode: :streaming,
        chunk_delay_ms: config.event_delay_ms
      )

    start_time = System.monotonic_time(:millisecond)
    event_counter = :counters.new(1, [])

    # Create sessions and runs concurrently
    tasks =
      for session_idx <- 1..config.concurrent_sessions do
        Task.async(fn ->
          run_session_with_tracking(store, adapter, session_idx, config, event_counter)
        end)
      end

    # Wait for all to complete
    Task.await_many(tasks, 60_000)

    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time
    total_events = :counters.get(event_counter, 1)

    events_per_second = if duration_ms > 0, do: total_events / (duration_ms / 1000), else: 0

    results = %{
      concurrent_sessions: config.concurrent_sessions,
      runs_per_session: config.runs_per_session,
      total_events: total_events,
      duration_ms: duration_ms,
      events_per_second: events_per_second,
      config: config
    }

    cleanup([store, adapter])

    {:ok, results}
  end

  defp run_latency_scenario(config) do
    {:ok, store} = InMemorySessionStore.start_link()

    {:ok, adapter} =
      MockProviderAdapter.start_link(
        capabilities: Fixtures.provider_capabilities(:full_claude),
        execution_mode: :streaming,
        chunk_delay_ms: config.event_delay_ms
      )

    latencies = :ets.new(:latencies, [:bag, :public])

    # Run sessions and collect latencies
    tasks =
      for session_idx <- 1..config.concurrent_sessions do
        Task.async(fn ->
          run_session_with_latency_tracking(store, adapter, session_idx, config, latencies)
        end)
      end

    Task.await_many(tasks, 60_000)

    # Calculate percentiles
    all_latencies = :ets.tab2list(latencies) |> Enum.map(fn {_, lat} -> lat end) |> Enum.sort()

    results =
      if length(all_latencies) > 0 do
        %{
          sample_count: length(all_latencies),
          min_latency_ms: Enum.min(all_latencies),
          max_latency_ms: Enum.max(all_latencies),
          avg_latency_ms: Enum.sum(all_latencies) / length(all_latencies),
          p50_latency_ms: percentile(all_latencies, 50),
          p95_latency_ms: percentile(all_latencies, 95),
          p99_latency_ms: percentile(all_latencies, 99)
        }
      else
        %{
          sample_count: 0,
          min_latency_ms: 0,
          max_latency_ms: 0,
          avg_latency_ms: 0,
          p50_latency_ms: 0,
          p95_latency_ms: 0,
          p99_latency_ms: 0
        }
      end

    :ets.delete(latencies)
    cleanup([store, adapter])

    {:ok, results}
  end

  defp run_session_creation_scenario(config) do
    {:ok, adapter} =
      MockProviderAdapter.start_link(capabilities: Fixtures.provider_capabilities(:full_claude))

    stores = []
    creation_times = []

    start_time = System.monotonic_time(:millisecond)

    {stores, creation_times} =
      Enum.reduce(1..config.target_sessions, {stores, creation_times}, fn i,
                                                                          {acc_stores, acc_times} ->
        {:ok, store} = InMemorySessionStore.start_link()

        {time_us, _} =
          :timer.tc(fn ->
            SessionManager.start_session(store, adapter, %{agent_id: "load-test-#{i}"})
          end)

        {[store | acc_stores], [time_us / 1000 | acc_times]}
      end)

    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    results = %{
      sessions_created: config.target_sessions,
      duration_ms: duration_ms,
      sessions_per_second:
        if(duration_ms > 0, do: config.target_sessions / (duration_ms / 1000), else: 0),
      avg_creation_time_ms: Enum.sum(creation_times) / length(creation_times),
      min_creation_time_ms: Enum.min(creation_times),
      max_creation_time_ms: Enum.max(creation_times)
    }

    cleanup(stores ++ [adapter])

    {:ok, results}
  end

  defp run_session_with_tracking(store, adapter, session_idx, config, event_counter) do
    {:ok, session} =
      SessionManager.start_session(store, adapter, %{agent_id: "load-test-#{session_idx}"})

    {:ok, _} = SessionManager.activate_session(store, session.id)

    for run_idx <- 1..config.runs_per_session do
      {:ok, run} =
        SessionManager.start_run(store, adapter, session.id, %{prompt: "Load test #{run_idx}"})

      callback = fn _event ->
        :counters.add(event_counter, 1, 1)
      end

      # Execute directly on adapter to get event callbacks
      MockProviderAdapter.execute(adapter, run, session, event_callback: callback)
    end
  end

  defp run_session_with_latency_tracking(store, adapter, session_idx, config, latencies) do
    {:ok, session} =
      SessionManager.start_session(store, adapter, %{agent_id: "latency-test-#{session_idx}"})

    {:ok, _} = SessionManager.activate_session(store, session.id)

    for run_idx <- 1..config.runs_per_session do
      {:ok, run} =
        SessionManager.start_run(store, adapter, session.id, %{prompt: "Latency test #{run_idx}"})

      callback = fn _event ->
        latency = System.monotonic_time(:microsecond)
        :ets.insert(latencies, {:latency, latency / 1000})
      end

      MockProviderAdapter.execute(adapter, run, session, event_callback: callback)
    end
  end

  defp percentile(sorted_list, p) when length(sorted_list) > 0 do
    k = (length(sorted_list) - 1) * p / 100
    f = floor(k)
    c = ceil(k)

    if f == c do
      Enum.at(sorted_list, trunc(f))
    else
      lower = Enum.at(sorted_list, trunc(f))
      upper = Enum.at(sorted_list, trunc(c))
      lower + (upper - lower) * (k - f)
    end
  end

  defp percentile(_, _), do: 0

  defp cleanup(pids) do
    for pid <- pids do
      if is_pid(pid) and Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  defp print_results(results) do
    IO.puts("Concurrent sessions: #{results.concurrent_sessions}")
    IO.puts("Runs per session: #{results.runs_per_session}")
    IO.puts("Total events: #{results.total_events}")
    IO.puts("Duration: #{results.duration_ms}ms")
    IO.puts("Events/second: #{Float.round(results.events_per_second, 2)}")
  end

  defp print_latency_results(results) do
    IO.puts("Sample count: #{results.sample_count}")
    IO.puts("Min latency: #{Float.round(results.min_latency_ms, 2)}ms")
    IO.puts("Max latency: #{Float.round(results.max_latency_ms, 2)}ms")
    IO.puts("Avg latency: #{Float.round(results.avg_latency_ms, 2)}ms")
    IO.puts("P50 latency: #{Float.round(results.p50_latency_ms, 2)}ms")
    IO.puts("P95 latency: #{Float.round(results.p95_latency_ms, 2)}ms")
    IO.puts("P99 latency: #{Float.round(results.p99_latency_ms, 2)}ms")
  end

  defp print_memory_results(results) do
    IO.puts("Initial memory: #{Float.round(results.initial_memory_mb, 2)}MB")
    IO.puts("Final memory: #{Float.round(results.final_memory_mb, 2)}MB")
    IO.puts("Memory delta: #{Float.round(results.memory_delta_mb, 2)}MB")
    IO.puts("Events processed: #{results.total_events}")
    IO.puts("Events/second: #{Float.round(results.events_per_second, 2)}")
  end
end
