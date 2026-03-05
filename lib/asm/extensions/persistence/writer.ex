defmodule ASM.Extensions.Persistence.Writer do
  @moduledoc """
  Async writer process that persists events outside the run process path.
  """

  use GenServer

  alias ASM.{Error, Event, Telemetry}
  alias ASM.Extensions.Persistence

  @type t :: %__MODULE__{
          store: pid(),
          notify: pid() | nil
        }

  @enforce_keys [:store]
  defstruct [:store, :notify]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec enqueue(pid(), Event.t()) :: :ok
  def enqueue(writer, %Event{} = event) when is_pid(writer) do
    GenServer.cast(writer, {:append_event, event})
  end

  @spec flush(pid(), timeout()) :: :ok | {:error, Error.t()}
  def flush(writer, timeout \\ 5_000) when is_pid(writer) do
    GenServer.call(writer, :flush, timeout)
  catch
    :exit, reason ->
      {:error, Error.new(:unknown, :runtime, "persistence writer flush failed", cause: reason)}
  end

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} when is_pid(store) ->
        {:ok, %__MODULE__{store: store, notify: Keyword.get(opts, :notify)}}

      _ ->
        {:stop,
         Error.new(:config_invalid, :config, "persistence writer requires :store pid option")}
    end
  end

  @impl true
  def handle_cast({:append_event, %Event{} = event}, %__MODULE__{} = state) do
    case Persistence.append_event(state.store, event) do
      :ok ->
        :ok

      {:error, %Error{} = error} ->
        emit_error_telemetry(event, error)
        maybe_notify(state.notify, event, error)
    end

    {:noreply, state}
  end

  def handle_cast(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:flush, _from, state) do
    # `flush/2` is a synchronization barrier. Any prior cast writes have
    # already been handled when this call is processed.
    {:reply, :ok, state}
  end

  def handle_call(_other, _from, state) do
    {:reply,
     {:error, Error.new(:config_invalid, :config, "unsupported persistence writer operation")},
     state}
  end

  defp emit_error_telemetry(%Event{} = event, %Error{} = error) do
    Telemetry.execute([:asm, :ext, :persistence, :append, :error], %{}, %{
      session_id: event.session_id,
      run_id: event.run_id,
      event_id: event.id,
      event_kind: event.kind,
      error_kind: error.kind,
      error_domain: error.domain
    })
  end

  defp maybe_notify(pid, event, error) when is_pid(pid) do
    send(pid, {:asm_persistence_error, error, event})
    :ok
  end

  defp maybe_notify(_other, _event, _error), do: :ok
end
