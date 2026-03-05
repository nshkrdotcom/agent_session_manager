defmodule ASM.Extensions.Persistence do
  @moduledoc """
  Public persistence extension API.

  This domain adds optional persistence paths and async integration hooks without
  coupling core runtime modules to extension internals.
  """

  use Boundary,
    deps: [ASM],
    exports: [
      ASM.Extensions.Persistence,
      ASM.Extensions.Persistence.Adapter,
      ASM.Extensions.Persistence.FileStore,
      ASM.Extensions.Persistence.PipelinePlug,
      ASM.Extensions.Persistence.Writer
    ]

  alias ASM.{Error, Event, History, Store}
  alias ASM.Extensions.Persistence.{FileStore, PipelinePlug, Writer}
  alias ASM.Store.Memory

  @typedoc "Known persistence store implementations shipped by this extension."
  @type store_kind :: :memory | :file

  @typedoc "Store process reference implementing the `ASM.Store` callbacks."
  @type store_ref :: pid()

  @spec start_store(store_kind(), keyword()) :: GenServer.on_start() | {:error, Error.t()}
  def start_store(:memory, opts) when is_list(opts), do: Memory.start_link(opts)
  def start_store(:file, opts) when is_list(opts), do: FileStore.start_link(opts)

  def start_store(other, _opts) do
    {:error,
     Error.new(
       :config_invalid,
       :config,
       "unsupported persistence store: #{inspect(other)}"
     )}
  end

  @spec start_writer(keyword()) :: GenServer.on_start()
  def start_writer(opts) when is_list(opts), do: Writer.start_link(opts)

  @spec flush_writer(pid(), timeout()) :: :ok | {:error, Error.t()}
  def flush_writer(writer, timeout \\ 5_000) when is_pid(writer),
    do: Writer.flush(writer, timeout)

  @spec writer_plug(pid(), keyword()) :: {module(), keyword()}
  def writer_plug(writer, opts \\ []) when is_pid(writer) and is_list(opts) do
    {PipelinePlug, Keyword.put(opts, :writer, writer)}
  end

  @spec append_event(store_ref(), Event.t()) :: :ok | {:error, Error.t()}
  def append_event(store, %Event{} = event) when is_pid(store) do
    store
    |> Store.append_event(event)
    |> as_term()
    |> normalize_result("append_event/2 failed")
  catch
    :exit, reason ->
      {:error, runtime_error("append_event/2 failed", reason)}
  end

  @spec list_events(store_ref(), String.t()) :: {:ok, [Event.t()]} | {:error, Error.t()}
  def list_events(store, session_id) when is_pid(store) and is_binary(session_id) do
    store
    |> Store.list_events(session_id)
    |> as_term()
    |> normalize_result("list_events/2 failed")
  catch
    :exit, reason ->
      {:error, runtime_error("list_events/2 failed", reason)}
  end

  @spec reset_session(store_ref(), String.t()) :: :ok | {:error, Error.t()}
  def reset_session(store, session_id) when is_pid(store) and is_binary(session_id) do
    store
    |> Store.reset_session(session_id)
    |> as_term()
    |> normalize_result("reset_session/2 failed")
  catch
    :exit, reason ->
      {:error, runtime_error("reset_session/2 failed", reason)}
  end

  @spec replay_session(store_ref(), String.t(), term(), (term(), Event.t() -> term())) ::
          {:ok, term()} | {:error, Error.t()}
  def replay_session(store, session_id, initial_state, reducer)
      when is_pid(store) and is_binary(session_id) and is_function(reducer, 2) do
    store
    |> History.replay_session(session_id, initial_state, reducer)
    |> as_term()
    |> normalize_result("replay_session/4 failed")
  rescue
    error ->
      {:error, runtime_error("replay_session/4 failed", error)}
  catch
    :exit, reason ->
      {:error, runtime_error("replay_session/4 failed", reason)}
  end

  @spec rebuild_run(store_ref(), String.t(), String.t()) ::
          {:ok, %{state: ASM.Run.State.t(), result: ASM.Result.t(), events: [ASM.Event.t()]}}
          | {:error, Error.t()}
  def rebuild_run(store, session_id, run_id)
      when is_pid(store) and is_binary(session_id) and is_binary(run_id) do
    store
    |> History.rebuild_run(session_id, run_id)
    |> as_term()
    |> normalize_result("rebuild_run/3 failed")
  rescue
    error ->
      {:error, runtime_error("rebuild_run/3 failed", error)}
  catch
    :exit, reason ->
      {:error, runtime_error("rebuild_run/3 failed", reason)}
  end

  @dialyzer {:nowarn_function, normalize_result: 2}
  defp normalize_result(:ok, _message), do: :ok
  defp normalize_result({:ok, value}, _message), do: {:ok, value}
  defp normalize_result({:error, %Error{} = error}, _message), do: {:error, error}
  defp normalize_result(other, message), do: {:error, runtime_error(message, other)}

  @spec as_term(term()) :: term()
  defp as_term(value), do: value

  defp runtime_error(message, cause) do
    Error.new(:unknown, :runtime, message, cause: cause)
  end
end
