defmodule ASM.Extensions.Persistence.FileStore do
  @moduledoc """
  Durable append-only event store backed by a local file.

  Events are persisted as Base64-encoded Erlang terms (one line per event) and
  reconstructed on startup for replay/rebuild operations.
  """

  use GenServer

  alias ASM.{Error, Event, Store}
  alias ASM.Extensions.Persistence.Adapter

  @behaviour Adapter

  @line_separator "\n"

  @type event_queue :: :queue.queue(Event.t())

  @type t :: %__MODULE__{
          path: String.t(),
          sync_writes: boolean(),
          events: event_queue(),
          by_session: %{optional(String.t()) => event_queue()},
          by_session_event_ids: %{optional(String.t()) => MapSet.t(String.t())},
          seen_event_ids: MapSet.t(String.t())
        }

  @enforce_keys [:path, :sync_writes]
  defstruct path: nil,
            sync_writes: true,
            events: :queue.new(),
            by_session: %{},
            by_session_event_ids: %{},
            seen_event_ids: MapSet.new()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def append_event(store, event), do: Store.append_event(store, event)

  @impl true
  def list_events(store, session_id), do: Store.list_events(store, session_id)

  @impl true
  def reset_session(store, session_id), do: Store.reset_session(store, session_id)

  @impl true
  def init(opts) do
    sync_writes = Keyword.get(opts, :sync_writes, true)

    with {:ok, path} <- validate_path(Keyword.get(opts, :path)),
         :ok <- validate_sync_writes(sync_writes),
         :ok <- ensure_file(path),
         {:ok, state} <- load_state(path, sync_writes) do
      {:ok, state}
    else
      {:error, %Error{} = error} ->
        {:stop, error}
    end
  end

  @impl true
  def handle_call({:append_event, %Event{} = event}, _from, %__MODULE__{} = state) do
    if MapSet.member?(state.seen_event_ids, event.id) do
      {:reply, :ok, state}
    else
      line = encode_event(event)

      case append_line(state.path, line, state.sync_writes) do
        :ok ->
          {:reply, :ok, put_event(state, event)}

        {:error, reason} ->
          {:reply, {:error, io_error("failed to append persistence event", reason)}, state}
      end
    end
  end

  def handle_call({:list_events, session_id}, _from, %__MODULE__{} = state) do
    events =
      state.by_session
      |> Map.get(session_id, :queue.new())
      |> :queue.to_list()

    {:reply, {:ok, events}, state}
  end

  def handle_call({:reset_session, session_id}, _from, %__MODULE__{} = state) do
    events =
      state.events
      |> :queue.to_list()
      |> Enum.reject(fn event -> event.session_id == session_id end)

    case rewrite_file(state.path, events, state.sync_writes) do
      :ok ->
        {:reply, :ok, rebuild_state(state.path, state.sync_writes, events)}

      {:error, reason} ->
        {:reply, {:error, io_error("failed to rewrite persistence file", reason)}, state}
    end
  end

  def handle_call(_other, _from, state) do
    {:reply, {:error, Error.new(:config_invalid, :config, "unsupported store operation")}, state}
  end

  defp validate_path(path) when is_binary(path) and path != "", do: {:ok, path}

  defp validate_path(_other) do
    {:error, Error.new(:config_invalid, :config, "file store requires non-empty :path")}
  end

  defp validate_sync_writes(sync_writes) when is_boolean(sync_writes), do: :ok

  defp validate_sync_writes(_other) do
    {:error, Error.new(:config_invalid, :config, ":sync_writes must be a boolean")}
  end

  defp ensure_file(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- touch_if_missing(path) do
      :ok
    else
      {:error, reason} ->
        {:error, io_error("failed to prepare persistence file", reason)}
    end
  end

  defp touch_if_missing(path) do
    case File.stat(path) do
      {:ok, _} -> :ok
      {:error, :enoent} -> File.write(path, "", [:binary])
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_state(path, sync_writes) do
    with {:ok, content} <- File.read(path),
         {:ok, events} <- decode_events(content) do
      {:ok, rebuild_state(path, sync_writes, events)}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, io_error("failed to load persistence file", reason)}
    end
  end

  defp decode_events(""), do: {:ok, []}

  defp decode_events(content) when is_binary(content) do
    content
    |> String.split(@line_separator, trim: true)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, line_no}, {:ok, acc} ->
      case decode_line(line) do
        {:ok, event} ->
          {:cont, {:ok, [event | acc]}}

        {:error, reason} ->
          {:halt,
           {:error,
            Error.new(
              :config_invalid,
              :config,
              "persistence file is corrupted at line #{line_no}",
              cause: reason
            )}}
      end
    end)
    |> case do
      {:ok, events_rev} -> {:ok, Enum.reverse(events_rev)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp decode_line(line) do
    with {:ok, term_binary} <- decode_base64(line) do
      decode_event(term_binary)
    end
  end

  defp decode_base64(line) do
    case Base.decode64(line, padding: false) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid_base64}
    end
  end

  defp decode_event(term_binary) when is_binary(term_binary) do
    case :erlang.binary_to_term(term_binary, [:safe]) do
      %Event{} = event -> {:ok, event}
      other -> {:error, {:invalid_event, other}}
    end
  rescue
    ArgumentError -> {:error, :invalid_binary_term}
  end

  defp encode_event(%Event{} = event) do
    event
    |> :erlang.term_to_binary([:compressed])
    |> Base.encode64(padding: false)
  end

  defp append_line(path, encoded_event, sync_writes) do
    path
    |> File.open([:append, :binary], fn io ->
      :ok = IO.binwrite(io, encoded_event <> @line_separator)
      maybe_sync(io, sync_writes)
    end)
    |> normalize_file_result()
  end

  defp rewrite_file(path, events, sync_writes) do
    temp_path = "#{path}.tmp.#{System.unique_integer([:positive])}"

    encoded_lines = Enum.map_join(events, @line_separator, &encode_event/1)

    contents =
      case encoded_lines do
        "" -> ""
        _ -> encoded_lines <> @line_separator
      end

    result =
      temp_path
      |> File.open([:write, :binary], fn io ->
        :ok = IO.binwrite(io, contents)
        maybe_sync(io, sync_writes)
      end)
      |> normalize_file_result()

    with :ok <- result,
         :ok <- File.rename(temp_path, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temp_path)
        {:error, reason}
    end
  end

  defp maybe_sync(_io, false), do: :ok

  defp maybe_sync(io, true) do
    :file.sync(io)
  end

  defp normalize_file_result({:ok, :ok}), do: :ok
  defp normalize_file_result({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_file_result({:error, reason}), do: {:error, reason}

  defp rebuild_state(path, sync_writes, events) do
    Enum.reduce(events, new_state(path, sync_writes), fn event, acc ->
      put_event(acc, event)
    end)
  end

  defp new_state(path, sync_writes) do
    %__MODULE__{
      path: path,
      sync_writes: sync_writes,
      events: :queue.new(),
      by_session: %{},
      by_session_event_ids: %{},
      seen_event_ids: MapSet.new()
    }
  end

  defp put_event(%__MODULE__{} = state, %Event{} = event) do
    if MapSet.member?(state.seen_event_ids, event.id) do
      state
    else
      session_queue = Map.get(state.by_session, event.session_id, :queue.new())
      session_event_ids = Map.get(state.by_session_event_ids, event.session_id, MapSet.new())

      %{
        state
        | events: :queue.in(event, state.events),
          by_session:
            Map.put(state.by_session, event.session_id, :queue.in(event, session_queue)),
          by_session_event_ids:
            Map.put(
              state.by_session_event_ids,
              event.session_id,
              MapSet.put(session_event_ids, event.id)
            ),
          seen_event_ids: MapSet.put(state.seen_event_ids, event.id)
      }
    end
  end

  defp io_error(message, reason) do
    Error.new(:unknown, :runtime, message, cause: reason)
  end
end
