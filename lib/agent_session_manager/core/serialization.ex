defmodule AgentSessionManager.Core.Serialization do
  @moduledoc false

  @spec stringify_keys(term()) :: term()
  def stringify_keys(nil), do: nil

  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
  end

  def stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_keys/1)
  end

  def stringify_keys(other), do: other

  @spec atomize_keys(term()) :: term()
  def atomize_keys(nil), do: nil

  def atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {maybe_to_existing_atom(k), atomize_value(v)}
      {k, v} -> {k, atomize_value(v)}
    end)
  end

  def atomize_keys(list) when is_list(list) do
    Enum.map(list, &atomize_keys/1)
  end

  def atomize_keys(other), do: other

  @spec maybe_to_existing_atom(String.t()) :: atom() | String.t()
  def maybe_to_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  @spec has_key?(map(), String.t()) :: boolean()
  def has_key?(map, key) when is_map(map) and is_binary(key) do
    Map.has_key?(map, key) or
      case maybe_to_existing_atom(key) do
        atom when is_atom(atom) -> Map.has_key?(map, atom)
        _ -> false
      end
  end

  defp stringify_value(v) when is_map(v) or is_list(v), do: stringify_keys(v)

  defp stringify_value(v) when is_atom(v) and not is_nil(v) and not is_boolean(v),
    do: Atom.to_string(v)

  defp stringify_value(v), do: v

  defp atomize_value(v) when is_map(v) or is_list(v), do: atomize_keys(v)
  defp atomize_value(v), do: v
end
