defmodule AgentSessionManager.Rendering.Sinks.FileSink do
  @moduledoc """
  A sink that writes rendered output to a log file with ANSI codes stripped.

  ## Options

    * `:path` — File path to write to. Required unless `:io` is given.
    * `:io` — Pre-opened IO device to write to. When provided, `:path` is
      ignored and the device will **not** be closed by `close/1`.
  """

  @behaviour AgentSessionManager.Rendering.Sink

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :io) do
      {:ok, io} ->
        {:ok, %{path: nil, io: io, owns_io: false}}

      :error ->
        init_from_path(opts)
    end
  end

  defp init_from_path(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} ->
        case File.open(path, [:write, :utf8]) do
          {:ok, io} -> {:ok, %{path: path, io: io, owns_io: true}}
          {:error, reason} -> {:error, "Failed to open #{path}: #{inspect(reason)}"}
        end

      :error ->
        {:error, "path or io option is required"}
    end
  end

  @impl true
  def write(iodata, state) do
    text = IO.iodata_to_binary(iodata)
    IO.binwrite(state.io, strip_ansi(text))
    {:ok, state}
  end

  @impl true
  def write_event(_event, iodata, state) do
    text = IO.iodata_to_binary(iodata)
    IO.binwrite(state.io, strip_ansi(text))
    {:ok, state}
  end

  @impl true
  def flush(state) do
    :file.sync(state.io)
    {:ok, state}
  end

  @impl true
  def close(%{owns_io: true} = state) do
    File.close(state.io)
    :ok
  end

  def close(_state), do: :ok

  defp strip_ansi(text) do
    String.replace(text, ~r/\x1b\[[0-9;]*[mABCDHJK]|\r(?!\n)/, "")
  end
end
