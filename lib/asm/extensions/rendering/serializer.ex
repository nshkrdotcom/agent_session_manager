defmodule ASM.Extensions.Rendering.Serializer do
  @moduledoc false

  alias ASM.Event

  @spec event_to_map(Event.t()) :: map()
  def event_to_map(%Event{} = event) do
    event
    |> Event.to_map()
    |> Enum.map(fn {key, value} ->
      serialized =
        case key do
          :kind -> atom_to_string(value)
          :provider -> atom_to_string(value)
          :timestamp -> datetime_to_iso8601(value)
          _other -> to_json_term(value)
        end

      {map_key_to_string(key), serialized}
    end)
    |> Map.new()
    |> drop_nil_values()
  end

  @spec to_json_term(term()) :: term()
  def to_json_term(nil), do: nil
  def to_json_term(value) when is_binary(value), do: value
  def to_json_term(value) when is_boolean(value), do: value
  def to_json_term(value) when is_number(value), do: value
  def to_json_term(value) when is_atom(value), do: atom_to_string(value)
  def to_json_term(%DateTime{} = value), do: DateTime.to_iso8601(value)

  def to_json_term(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> to_json_term()
    |> Map.put("__struct__", Atom.to_string(struct.__struct__))
  end

  def to_json_term(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {map_key_to_string(key), to_json_term(item)} end)
    |> Map.new()
  end

  def to_json_term(value) when is_list(value), do: Enum.map(value, &to_json_term/1)

  def to_json_term(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&to_json_term/1)

  def to_json_term(value) when is_pid(value), do: inspect(value)
  def to_json_term(value) when is_reference(value), do: inspect(value)
  def to_json_term(value) when is_function(value), do: inspect(value)
  def to_json_term(value), do: inspect(value)

  defp map_key_to_string(key) when is_binary(key), do: key
  defp map_key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp map_key_to_string(key), do: inspect(key)

  defp atom_to_string(nil), do: nil
  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string(value), do: to_string(value)

  defp datetime_to_iso8601(nil), do: nil
  defp datetime_to_iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime_to_iso8601(other), do: inspect(other)

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
