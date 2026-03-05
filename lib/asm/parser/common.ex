defmodule ASM.Parser.Common do
  @moduledoc false

  alias ASM.Error

  @spec parser_failure(String.t(), Exception.t()) :: Error.t()
  def parser_failure(provider_label, error) when is_binary(provider_label) do
    Error.new(
      :parse_error,
      :parser,
      "#{provider_label} parser failure: #{Exception.message(error)}",
      cause: error
    )
  end

  @spec expected_map_error(String.t(), term()) :: Error.t()
  def expected_map_error(provider_label, other) when is_binary(provider_label) do
    Error.new(
      :parse_error,
      :parser,
      "#{provider_label} parser expected map, got: #{inspect(other)}"
    )
  end

  @spec event_type(map()) :: String.t()
  def event_type(raw) when is_map(raw) do
    raw
    |> fetch_any([:type, "type", :event, "event"])
    |> case do
      nil -> "unknown"
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      value -> to_string(value)
    end
  end

  @spec fetch_any(map(), [atom() | String.t()]) :: term()
  def fetch_any(raw, keys) when is_map(raw) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(raw, key) end)
  end

  @spec normalize_map(map()) :: map()
  def normalize_map(raw) when is_map(raw) do
    Map.new(raw, fn {k, v} -> {normalize_key(k), v} end)
  end

  @spec normalize_severity(term()) :: :fatal | :error | :warning
  def normalize_severity(value) when value in [:fatal, "fatal"], do: :fatal
  def normalize_severity(value) when value in [:warning, "warning", "warn"], do: :warning
  def normalize_severity(_), do: :error

  @spec normalize_kind(term()) :: atom()
  def normalize_kind(nil), do: :unknown
  def normalize_kind(kind) when is_atom(kind), do: kind

  @normalized_kinds %{
    "user_cancelled" => :user_cancelled,
    "cancelled" => :user_cancelled,
    "parse_error" => :parse_error,
    "timeout" => :timeout,
    "tool_failed" => :tool_failed,
    "approval_denied" => :approval_denied,
    "rate_limit" => :rate_limit,
    "transport_error" => :transport_error,
    "auth_error" => :auth_error
  }

  def normalize_kind(kind) when is_binary(kind) do
    kind
    |> String.downcase()
    |> then(&Map.get(@normalized_kinds, &1, :unknown))
  end

  def normalize_kind(_), do: :unknown

  @spec truthy?(term()) :: boolean()
  def truthy?(value) when value in [true, "true", 1, "1", "yes", "on"], do: true
  def truthy?(_), do: false

  @spec int_value(map(), [atom() | String.t()], non_neg_integer()) :: non_neg_integer()
  def int_value(raw, keys, default \\ 0) when is_map(raw) and is_list(keys) do
    raw
    |> fetch_any(keys)
    |> case do
      value when is_integer(value) and value >= 0 -> value
      value when is_float(value) and value >= 0 -> trunc(value)
      value when is_binary(value) -> parse_int(value, default)
      _ -> default
    end
  end

  @spec float_value(map(), [atom() | String.t()], float()) :: float()
  def float_value(raw, keys, default \\ 0.0) when is_map(raw) and is_list(keys) do
    raw
    |> fetch_any(keys)
    |> case do
      value when is_float(value) -> value
      value when is_integer(value) -> value * 1.0
      value when is_binary(value) -> parse_float(value, default)
      _ -> default
    end
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(other), do: other

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end
end
