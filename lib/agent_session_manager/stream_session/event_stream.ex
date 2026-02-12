defmodule AgentSessionManager.StreamSession.EventStream do
  @moduledoc false

  alias AgentSessionManager.Core.Error, as: ASMError
  alias AgentSessionManager.Core.ProviderError
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
    {provider_error, details} = normalize_provider_error_payload(error)

    data =
      %{
        error_code: error.code,
        error_message: error.message
      }
      |> maybe_put(:provider_error, provider_error)
      |> maybe_put(:details, non_empty_map(details))

    [%{type: :error_occurred, data: data}]
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

  defp normalize_provider_error_payload(%ASMError{} = error) do
    has_provider_error? = is_map(error.provider_error)
    provider_code? = ASMError.category(error.code) == :provider

    if has_provider_error? or provider_code? do
      attrs =
        ensure_map(error.provider_error)
        |> Map.put_new(:message, error.message)
        |> Map.put_new(:details, ensure_map(error.details))

      {provider_error, provider_details} =
        ProviderError.normalize(
          normalize_provider_hint(map_get(error.provider_error, :provider)),
          attrs
        )

      {provider_error, Map.merge(ensure_map(error.details), provider_details)}
    else
      {nil, ensure_map(error.details)}
    end
  end

  defp normalize_provider_hint(provider) when is_atom(provider), do: provider

  defp normalize_provider_hint(provider) when is_binary(provider) do
    case String.downcase(provider) do
      "codex" -> :codex
      "amp" -> :amp
      "claude" -> :claude
      "gemini" -> :gemini
      _ -> :unknown
    end
  end

  defp normalize_provider_hint(_provider), do: :unknown

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_map, _key), do: nil

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_), do: %{}

  defp non_empty_map(value) when is_map(value) and map_size(value) > 0, do: value
  defp non_empty_map(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
