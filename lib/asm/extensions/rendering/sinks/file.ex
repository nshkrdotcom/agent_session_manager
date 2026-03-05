defmodule ASM.Extensions.Rendering.Sinks.File do
  @moduledoc """
  Sink that writes rendered output to a file with ANSI escape codes stripped.

  Options:
  - `:path` (required unless `:io` is provided)
  - `:io` (optional pre-opened IO device; not closed by this sink)
  - `:append` (optional, default `false`)
  - `:strip_ansi` (optional, default `true`)
  """

  @behaviour ASM.Extensions.Rendering.Sink

  alias ASM.Error

  @type t :: %{
          path: String.t() | nil,
          io: term(),
          owns_io: boolean(),
          strip_ansi: boolean()
        }

  @impl true
  def init(opts) do
    strip_ansi = Keyword.get(opts, :strip_ansi, true)

    with :ok <- validate_strip_ansi(strip_ansi) do
      case Keyword.fetch(opts, :io) do
        {:ok, io_device} ->
          {:ok, %{path: nil, io: io_device, owns_io: false, strip_ansi: strip_ansi}}

        :error ->
          init_from_path(opts, strip_ansi)
      end
    end
  end

  @impl true
  def write(iodata, state), do: write_binary(iodata, state)

  @impl true
  def write_event(_event, iodata, state), do: write_binary(iodata, state)

  @impl true
  def flush(state) do
    case :file.sync(state.io) do
      :ok -> {:ok, state}
      {:error, :enotsup} -> {:ok, state}
      {:error, reason} -> {:error, io_error("file sink flush failed", reason), state}
    end
  rescue
    error -> {:error, io_error("file sink flush failed", error), state}
  catch
    kind, reason ->
      {:error, io_error("file sink flush failed", %{kind: kind, reason: reason}), state}
  end

  @impl true
  def close(%{owns_io: true} = state) do
    case Elixir.File.close(state.io) do
      :ok -> :ok
      {:error, reason} -> {:error, io_error("file sink close failed", reason)}
    end
  rescue
    error -> {:error, io_error("file sink close failed", error)}
  catch
    kind, reason ->
      {:error, io_error("file sink close failed", %{kind: kind, reason: reason})}
  end

  def close(_state), do: :ok

  defp init_from_path(opts, strip_ansi) do
    append? = Keyword.get(opts, :append, false)

    with :ok <- validate_append(append?),
         {:ok, path} <- fetch_path(opts),
         :ok <- Elixir.File.mkdir_p(Path.dirname(path)),
         {:ok, io_device} <- open_path(path, append?) do
      {:ok, %{path: path, io: io_device, owns_io: true, strip_ansi: strip_ansi}}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, io_error("file sink init failed", reason)}
    end
  end

  defp open_path(path, true), do: Elixir.File.open(path, [:append, :utf8])
  defp open_path(path, false), do: Elixir.File.open(path, [:write, :utf8])

  defp fetch_path(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) and path != "" ->
        {:ok, path}

      {:ok, invalid} ->
        {:error, config_error("file sink :path must be a non-empty string: #{inspect(invalid)}")}

      :error ->
        {:error, config_error("file sink requires :path or :io option")}
    end
  end

  defp write_binary(iodata, state) do
    text = IO.iodata_to_binary(iodata)
    output = if state.strip_ansi, do: strip_ansi(text), else: text

    IO.binwrite(state.io, output)
    {:ok, state}
  rescue
    error -> {:error, io_error("file sink write failed", error), state}
  catch
    kind, reason ->
      {:error, io_error("file sink write failed", %{kind: kind, reason: reason}), state}
  end

  defp strip_ansi(text) when is_binary(text) do
    String.replace(text, ~r/\x1b\[[0-9;]*[A-Za-z]|\r(?!\n)/, "")
  end

  defp validate_append(value) when is_boolean(value), do: :ok

  defp validate_append(other) do
    {:error, config_error("file sink :append must be a boolean: #{inspect(other)}")}
  end

  defp validate_strip_ansi(value) when is_boolean(value), do: :ok

  defp validate_strip_ansi(other) do
    {:error, config_error("file sink :strip_ansi must be a boolean: #{inspect(other)}")}
  end

  defp config_error(message), do: Error.new(:config_invalid, :config, message)
  defp io_error(message, cause), do: Error.new(:unknown, :runtime, message, cause: cause)
end
