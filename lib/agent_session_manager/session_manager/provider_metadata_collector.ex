defmodule AgentSessionManager.SessionManager.ProviderMetadataCollector do
  @moduledoc false

  alias AgentSessionManager.Core.Event

  @spec collect(String.t(), map()) :: map()
  def collect(run_id, acc \\ %{}) do
    receive do
      {:provider_metadata, ^run_id, metadata} when is_map(metadata) ->
        collect(run_id, Map.merge(acc, metadata))
    after
      0 ->
        acc
    end
  end

  @spec extract_from_result(map()) :: map()
  def extract_from_result(result) when is_map(result) do
    events =
      case Map.get(result, :events) do
        event_list when is_list(event_list) -> event_list
        _ -> []
      end

    case Enum.find(events, fn event -> event_type(event) == :run_started end) do
      nil -> %{}
      event -> extract_from_event_data(event)
    end
  end

  @spec extract_from_event_data(term()) :: map()
  def extract_from_event_data(event_data) do
    case event_type(event_data) do
      :run_started ->
        event_data
        |> event_data_map()
        |> normalize_provider_metadata()

      _ ->
        %{}
    end
  end

  defp event_type(%Event{type: type}) when is_atom(type), do: type
  defp event_type(%{type: type}) when is_atom(type), do: type
  defp event_type(%{type: "run_started"}), do: :run_started
  defp event_type(%{"type" => "run_started"}), do: :run_started
  defp event_type(_), do: nil

  defp event_data_map(%Event{data: data}) when is_map(data), do: data
  defp event_data_map(%{data: data}) when is_map(data), do: data
  defp event_data_map(%{"data" => data}) when is_map(data), do: data
  defp event_data_map(_), do: %{}

  defp normalize_provider_metadata(data) do
    %{
      provider_session_id:
        map_get(data, :provider_session_id) || map_get(data, :session_id) ||
          map_get(data, :thread_id),
      model: map_get(data, :model),
      tools: map_get(data, :tools)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
