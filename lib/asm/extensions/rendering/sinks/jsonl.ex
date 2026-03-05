defmodule ASM.Extensions.Rendering.Sinks.JSONL do
  @moduledoc """
  Sink that writes events as newline-delimited JSON.

  Options:
  - `:path` (required unless `:io` is provided)
  - `:io` (optional pre-opened IO device; not closed by this sink)
  - `:append` (optional, default `false`)
  - `:mode` (`:full` or `:compact`, default `:full`)
  """

  @behaviour ASM.Extensions.Rendering.Sink

  alias ASM.{Error, Event}
  alias ASM.Extensions.Rendering.Serializer

  @type t :: %{
          path: String.t() | nil,
          io: term(),
          owns_io: boolean(),
          mode: :full | :compact
        }

  @compact_kind %{
    run_started: "rs",
    assistant_delta: "ad",
    assistant_message: "am",
    tool_use: "tu",
    tool_result: "tr",
    result: "re",
    error: "er",
    run_completed: "rc"
  }

  @impl true
  def init(opts) do
    with {:ok, mode} <- normalize_mode(Keyword.get(opts, :mode, :full)) do
      case Keyword.fetch(opts, :io) do
        {:ok, io_device} ->
          {:ok, %{path: nil, io: io_device, owns_io: false, mode: mode}}

        :error ->
          init_from_path(opts, mode)
      end
    end
  end

  @impl true
  def write(_iodata, state), do: {:ok, state}

  @impl true
  def write_event(%Event{} = event, _iodata, state) do
    entry =
      case state.mode do
        :compact -> compact_entry(event)
        :full -> Serializer.event_to_map(event)
      end

    line = Jason.encode!(entry) <> "\n"

    IO.binwrite(state.io, line)
    {:ok, state}
  rescue
    error -> {:error, io_error("jsonl sink write failed", error), state}
  catch
    kind, reason ->
      {:error, io_error("jsonl sink write failed", %{kind: kind, reason: reason}), state}
  end

  @impl true
  def flush(state) do
    case :file.sync(state.io) do
      :ok -> {:ok, state}
      {:error, :enotsup} -> {:ok, state}
      {:error, reason} -> {:error, io_error("jsonl sink flush failed", reason), state}
    end
  rescue
    error -> {:error, io_error("jsonl sink flush failed", error), state}
  catch
    kind, reason ->
      {:error, io_error("jsonl sink flush failed", %{kind: kind, reason: reason}), state}
  end

  @impl true
  def close(%{owns_io: true} = state) do
    case Elixir.File.close(state.io) do
      :ok -> :ok
      {:error, reason} -> {:error, io_error("jsonl sink close failed", reason)}
    end
  rescue
    error -> {:error, io_error("jsonl sink close failed", error)}
  catch
    kind, reason ->
      {:error, io_error("jsonl sink close failed", %{kind: kind, reason: reason})}
  end

  def close(_state), do: :ok

  defp init_from_path(opts, mode) do
    append? = Keyword.get(opts, :append, false)

    with :ok <- validate_append(append?),
         {:ok, path} <- fetch_path(opts),
         :ok <- Elixir.File.mkdir_p(Path.dirname(path)),
         {:ok, io_device} <- open_path(path, append?) do
      {:ok, %{path: path, io: io_device, owns_io: true, mode: mode}}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, io_error("jsonl sink init failed", reason)}
    end
  end

  defp open_path(path, true), do: Elixir.File.open(path, [:append, :utf8])
  defp open_path(path, false), do: Elixir.File.open(path, [:write, :utf8])

  defp fetch_path(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) and path != "" ->
        {:ok, path}

      {:ok, invalid} ->
        {:error, config_error("jsonl sink :path must be a non-empty string: #{inspect(invalid)}")}

      :error ->
        {:error, config_error("jsonl sink requires :path or :io option")}
    end
  end

  defp normalize_mode(mode) when mode in [:full, :compact], do: {:ok, mode}

  defp normalize_mode(other) do
    {:error, config_error("jsonl sink :mode must be :full or :compact, got: #{inspect(other)}")}
  end

  defp compact_entry(%Event{} = event) do
    %{
      "t" => datetime_to_epoch_ms(event.timestamp),
      "e" =>
        compact_event(event)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    }
  end

  defp compact_event(%Event{} = event) do
    %{
      "k" => Map.get(@compact_kind, event.kind, Atom.to_string(event.kind)),
      "id" => event.id,
      "s" => event.session_id,
      "r" => event.run_id,
      "p" => Serializer.to_json_term(event.payload)
    }
  end

  defp datetime_to_epoch_ms(%DateTime{} = timestamp) do
    DateTime.to_unix(timestamp, :millisecond)
  end

  defp datetime_to_epoch_ms(_other), do: System.system_time(:millisecond)

  defp validate_append(value) when is_boolean(value), do: :ok

  defp validate_append(other) do
    {:error, config_error("jsonl sink :append must be a boolean: #{inspect(other)}")}
  end

  defp config_error(message), do: Error.new(:config_invalid, :config, message)
  defp io_error(message, cause), do: Error.new(:unknown, :runtime, message, cause: cause)
end
