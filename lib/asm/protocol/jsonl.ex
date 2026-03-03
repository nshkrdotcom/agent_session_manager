defmodule ASM.Protocol.JSONL do
  @moduledoc """
  NDJSON/JSONL framing helpers for CLI transports.
  """

  @spec extract_lines(binary()) :: {[binary()], binary()}
  def extract_lines(buffer) when is_binary(buffer) do
    parts = String.split(buffer, ~r/\r?\n/, trim: false)

    case parts do
      [] ->
        {[], ""}

      [single] ->
        {[], single}

      _ ->
        {complete, [remainder]} = Enum.split(parts, length(parts) - 1)
        {Enum.reject(complete, &(&1 == "")), remainder}
    end
  end

  @spec decode_line(binary()) :: {:ok, map()} | {:error, term()}
  def decode_line(line) when is_binary(line) do
    with {:ok, decoded} <- Jason.decode(line),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      false -> {:error, :not_json_object}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec encode(map()) :: binary()
  def encode(map) when is_map(map) do
    Jason.encode!(map) <> "\n"
  end
end
