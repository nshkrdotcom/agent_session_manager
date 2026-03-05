defmodule ASM.Parser.Shell do
  @moduledoc """
  Shell parser that maps transport line events into ASM payload structs.
  """

  alias ASM.{Error, Message, Parser}
  alias ASM.Parser.Common

  @behaviour Parser

  @impl true
  @spec parse(map()) ::
          {:ok, {ASM.Event.kind(), ASM.Message.t() | ASM.Control.t()}} | {:error, Error.t()}
  def parse(raw) when is_map(raw) do
    type = Common.event_type(raw)
    {:ok, parse_typed(type, raw)}
  rescue
    error ->
      {:error, Common.parser_failure("Shell", error)}
  end

  def parse(other) do
    {:error, Common.expected_map_error("Shell", other)}
  end

  defp parse_typed("shell.output", raw) do
    stream = Common.fetch_any(raw, [:stream, "stream"])
    line = Common.fetch_any(raw, [:line, "line"]) |> normalize_line()

    case stream do
      "stdout" ->
        {:assistant_delta, %Message.Partial{content_type: :text, delta: line}}

      _other ->
        raw_message("shell.output", raw)
    end
  end

  defp parse_typed(type, raw), do: raw_message(type, raw)

  defp raw_message(type, raw) do
    {:raw, %Message.Raw{provider: :shell, type: type, data: Common.normalize_map(raw)}}
  end

  defp normalize_line(value) when is_binary(value) do
    if String.ends_with?(value, "\n"), do: value, else: value <> "\n"
  end

  defp normalize_line(nil), do: "\n"
  defp normalize_line(value), do: normalize_line(to_string(value))
end
