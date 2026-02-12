defmodule AgentSessionManager.Core.ProviderError do
  @moduledoc """
  Shared normalization for provider-specific errors.

  Adapters pass provider-native error payloads and receive a stable
  `provider_error` map plus provider-specific `details`.
  """

  alias AgentSessionManager.Config

  @typedoc "Supported provider identifiers."
  @type provider :: :codex | :amp | :claude | :gemini | :unknown

  @typedoc "Normalized provider error payload."
  @type t :: %{
          provider: provider(),
          kind: atom(),
          message: String.t(),
          exit_code: integer() | nil,
          stderr: String.t() | nil,
          truncated?: boolean() | nil
        }

  @known_kind_map %{
    "transport_exit" => :transport_exit,
    "process_error" => :process_error,
    "parse_error" => :parse_error,
    "protocol_error" => :protocol_error,
    "cli_not_found" => :cli_not_found,
    "timeout" => :timeout,
    "unknown" => :unknown
  }

  @doc """
  Normalizes provider-specific attributes into a stable provider error map.

  Returns `{provider_error, details}` where:
  - `provider_error` follows the cross-provider contract
  - `details` contains provider-specific extras with duplicate error fields removed
  """
  @spec normalize(atom(), map(), keyword()) :: {t(), map()}
  def normalize(provider, attrs, opts \\ [])

  def normalize(provider, attrs, opts) when is_map(attrs) and is_list(opts) do
    details = extract_details(attrs)
    {stderr, truncated_by_limits?} = normalize_stderr(attrs, details, opts)
    truncated? = normalize_truncated?(attrs, details, truncated_by_limits?)
    exit_code = normalize_exit_code_from_attrs(attrs, details)
    message = normalize_message_from_attrs(attrs, details, stderr)
    kind = normalize_kind_from_attrs(attrs, details)

    provider_error = %{
      provider: normalize_provider(provider),
      kind: kind,
      message: message,
      exit_code: exit_code,
      stderr: stderr,
      truncated?: if(truncated?, do: true, else: nil)
    }

    normalized_details =
      details
      |> map_drop(:stderr)
      |> map_drop(:stderr_truncated?)
      |> map_drop(:exit_code)
      |> map_drop(:exit_status)

    {provider_error, normalized_details}
  end

  def normalize(provider, attrs, opts) do
    normalize(provider, %{message: inspect(attrs)}, opts)
  end

  defp extract_details(attrs), do: attrs |> map_fetch(:details) |> ensure_map()

  defp normalize_stderr(attrs, details, opts) do
    raw_stderr = map_fetch(attrs, :stderr) || map_fetch(details, :stderr)
    max_bytes = Keyword.get(opts, :max_bytes, Config.get(:error_text_max_bytes))
    max_lines = Keyword.get(opts, :max_lines, Config.get(:error_text_max_lines))
    truncate_text(raw_stderr, max_bytes, max_lines)
  end

  defp normalize_truncated?(attrs, details, truncated_by_limits?) do
    truthy?(map_fetch(attrs, :truncated?)) ||
      truthy?(map_fetch(attrs, :stderr_truncated?)) ||
      truthy?(map_fetch(details, :stderr_truncated?)) ||
      truncated_by_limits?
  end

  defp normalize_exit_code_from_attrs(attrs, details) do
    attrs
    |> map_fetch(:exit_code)
    |> Kernel.||(map_fetch(details, :exit_code))
    |> Kernel.||(map_fetch(details, :exit_status))
    |> normalize_exit_code()
  end

  defp normalize_message_from_attrs(attrs, details, stderr) do
    normalize_message(map_fetch(attrs, :message) || map_fetch(details, :message), stderr)
  end

  defp normalize_kind_from_attrs(attrs, details) do
    normalize_kind(map_fetch(attrs, :kind) || map_fetch(details, :kind))
  end

  @spec truncate_text(String.t() | nil, integer() | nil, integer() | nil) ::
          {String.t() | nil, boolean()}
  def truncate_text(nil, _max_bytes, _max_lines), do: {nil, false}

  def truncate_text(text, _max_bytes, _max_lines) when not is_binary(text),
    do: {inspect(text), true}

  def truncate_text(text, max_bytes, max_lines) do
    {line_truncated_text, lines_truncated?} = truncate_lines(text, max_lines)
    {byte_truncated_text, bytes_truncated?} = truncate_bytes(line_truncated_text, max_bytes)

    {byte_truncated_text, lines_truncated? || bytes_truncated?}
  end

  defp truncate_lines(text, max_lines) when is_integer(max_lines) and max_lines > 0 do
    lines = String.split(text, "\n", trim: false)

    if length(lines) <= max_lines do
      {text, false}
    else
      {Enum.take(lines, max_lines) |> Enum.join("\n"), true}
    end
  end

  defp truncate_lines(text, _), do: {text, false}

  defp truncate_bytes(text, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    if byte_size(text) <= max_bytes do
      {text, false}
    else
      prefix = binary_part(text, 0, max_bytes)
      {utf8_safe_prefix(prefix), true}
    end
  end

  defp truncate_bytes(text, _), do: {text, false}

  defp utf8_safe_prefix(binary) when binary == "", do: ""

  defp utf8_safe_prefix(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> binary_part(0, byte_size(binary) - 1)
      |> utf8_safe_prefix()
    end
  end

  defp normalize_provider(:codex), do: :codex
  defp normalize_provider(:amp), do: :amp
  defp normalize_provider(:claude), do: :claude
  defp normalize_provider(:gemini), do: :gemini
  defp normalize_provider(_), do: :unknown

  defp normalize_kind(kind) when is_atom(kind), do: kind

  defp normalize_kind(kind) when is_binary(kind) do
    normalized =
      kind
      |> String.trim()
      |> String.downcase()

    Map.get(@known_kind_map, normalized, :unknown)
  end

  defp normalize_kind(_), do: :unknown

  defp normalize_exit_code(nil), do: nil
  defp normalize_exit_code(value) when is_integer(value), do: value

  defp normalize_exit_code(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_exit_code(_), do: nil

  defp normalize_message(message, _stderr) when is_binary(message) and message != "",
    do: message

  defp normalize_message(_message, stderr) when is_binary(stderr) and stderr != "" do
    stderr
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.trim()
    |> case do
      "" -> "Provider execution failed"
      first_line -> first_line
    end
  end

  defp normalize_message(_message, _stderr), do: "Provider execution failed"

  defp map_fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_fetch(_, _), do: nil

  defp map_drop(map, key) when is_map(map) and is_atom(key) do
    map
    |> Map.delete(key)
    |> Map.delete(Atom.to_string(key))
  end

  defp map_drop(map, _), do: map

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_), do: %{}

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false
end
