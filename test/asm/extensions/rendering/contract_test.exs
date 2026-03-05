defmodule ASM.Extensions.Rendering.ContractTest do
  use ASM.TestCase

  alias ASM.Error
  alias ASM.Extensions.Rendering
  alias ASM.Test.RenderingHelpers

  defmodule TrackingSink do
    @moduledoc false

    @behaviour ASM.Extensions.Rendering.Sink

    @impl true
    def init(opts) do
      {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}
    end

    @impl true
    def write(iodata, state) do
      send(state.test_pid, {:tracking_sink_write, IO.iodata_to_binary(iodata)})
      {:ok, state}
    end

    @impl true
    def write_event(event, iodata, state) do
      send(state.test_pid, {:tracking_sink_event, event.kind, IO.iodata_to_binary(iodata)})
      {:ok, state}
    end

    @impl true
    def flush(state) do
      send(state.test_pid, :tracking_sink_flushed)
      {:ok, state}
    end

    @impl true
    def close(state) do
      send(state.test_pid, :tracking_sink_closed)
      :ok
    end
  end

  defmodule FailingSink do
    @moduledoc false

    @behaviour ASM.Extensions.Rendering.Sink

    @impl true
    def init(opts) do
      {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}
    end

    @impl true
    def write(_iodata, state), do: {:ok, state}

    @impl true
    def write_event(_event, _iodata, state) do
      {:error, :sink_write_failed, state}
    end

    @impl true
    def flush(state), do: {:ok, state}

    @impl true
    def close(state) do
      send(state.test_pid, :failing_sink_closed)
      :ok
    end
  end

  test "stream/2 renders events, flushes, and closes sinks" do
    callback_pid = self()

    callback = fn event, iodata ->
      send(callback_pid, {:callback_event, event.kind, IO.iodata_to_binary(iodata)})
      :ok
    end

    assert :ok =
             Rendering.stream(RenderingHelpers.sample_events(),
               renderer: Rendering.compact_renderer(color: false),
               sinks: [
                 Rendering.callback_sink(callback: callback),
                 {TrackingSink, test_pid: self()}
               ]
             )

    assert_receive {:callback_event, :run_started, output}
    assert output =~ "r+"

    assert_receive {:tracking_sink_event, :assistant_delta, output}
    assert output =~ "Hello"

    assert_receive :tracking_sink_flushed
    assert_receive :tracking_sink_closed
  end

  test "stream/2 closes sinks when a sink write fails" do
    assert {:error, %Error{} = error} =
             Rendering.stream(RenderingHelpers.sample_events(),
               renderer: Rendering.compact_renderer(color: false),
               sinks: [{FailingSink, test_pid: self()}]
             )

    assert error.kind == :unknown
    assert error.domain == :runtime
    assert_receive :failing_sink_closed
  end

  test "stream/2 returns config errors for invalid renderer and sink specs" do
    assert {:error, %Error{} = renderer_error} =
             Rendering.stream(RenderingHelpers.sample_events(), renderer: :invalid, sinks: [])

    assert renderer_error.kind == :config_invalid
    assert renderer_error.domain == :config

    assert {:error, %Error{} = sink_error} =
             Rendering.stream(RenderingHelpers.sample_events(),
               renderer: Rendering.compact_renderer(color: false),
               sinks: [Rendering.callback_sink()]
             )

    assert sink_error.kind == :config_invalid
    assert sink_error.domain == :config
  end
end
