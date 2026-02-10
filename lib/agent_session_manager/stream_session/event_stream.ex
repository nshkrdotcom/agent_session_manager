defmodule AgentSessionManager.StreamSession.EventStream do
  @moduledoc false

  alias AgentSessionManager.Core.Error, as: ASMError
  alias AgentSessionManager.StreamSession.Lifecycle

  @doc "Build a lazy event stream and close function from acquired resources."
  def build(%Lifecycle{} = resources, config) do
    released = :atomics.new(1, signed: false)

    close_fun = fn ->
      case :atomics.compare_exchange(released, 1, 0, 1) do
        :ok -> Lifecycle.release(resources)
        _ -> :ok
      end
    end

    idle_timeout = config.idle_timeout

    stream =
      Stream.resource(
        fn -> :running end,
        fn
          :done ->
            {:halt, :done}

          :running ->
            next_events(resources, idle_timeout)
        end,
        fn _state -> close_fun.() end
      )

    {stream, close_fun}
  end

  defp next_events(resources, idle_timeout) do
    ref = resources.stream_ref
    task_pid = resources.task_pid
    task_monitor = resources.task_monitor

    receive do
      {^ref, :event, event} ->
        {[event], :running}

      {^ref, :done, {:ok, _result}} ->
        {:halt, :done}

      {^ref, :done, {:error, reason}} ->
        {error_events(reason), :done}

      {:DOWN, ^task_monitor, :process, ^task_pid, :normal} ->
        {:halt, :done}

      {:DOWN, ^task_monitor, :process, ^task_pid, reason} ->
        {error_events({:task_down, reason}), :done}
    after
      idle_timeout ->
        {[
           %{
             type: :error_occurred,
             data: %{error_message: "stream idle timeout after #{idle_timeout}ms"}
           }
         ], :done}
    end
  end

  defp error_events(%ASMError{} = error) do
    [%{type: :error_occurred, data: %{error_code: error.code, error_message: error.message}}]
  end

  defp error_events({:task_down, :shutdown}) do
    [%{type: :error_occurred, data: %{error_message: "session task shutdown"}}]
  end

  defp error_events({:task_down, :killed}) do
    [%{type: :error_occurred, data: %{error_message: "session task killed"}}]
  end

  defp error_events({:task_down, reason}) do
    [%{type: :error_occurred, data: %{error_message: "session task crashed: #{inspect(reason)}"}}]
  end

  defp error_events({:exception, exception, stacktrace}) do
    [
      %{
        type: :error_occurred,
        data: %{error_message: Exception.format(:error, exception, stacktrace)}
      }
    ]
  end

  defp error_events({kind, reason}) when kind in [:throw, :exit] do
    [
      %{
        type: :error_occurred,
        data: %{error_message: "session terminated (#{kind}): #{inspect(reason)}"}
      }
    ]
  end

  defp error_events(reason) do
    [%{type: :error_occurred, data: %{error_message: inspect(reason)}}]
  end
end
