defmodule ASM.Extensions.PubSub.Broadcaster do
  @moduledoc """
  Async broadcaster process that publishes `%ASM.Event{}` outside run-critical paths.

  Design notes:
  - enqueue path uses `GenServer.cast/2` and never blocks callers
  - dispatch runs in monitored async tasks
  - bounded queue with drop policy protects against unbounded mailbox growth
  """

  use GenServer

  alias ASM.{Error, Event, Telemetry}
  alias ASM.Extensions.PubSub.{Adapter, Payload, Topic}
  alias ASM.Extensions.PubSub.Adapters.Local

  @type adapter_spec :: {module(), keyword()}
  @type overflow_policy :: :drop_oldest | :drop_newest

  @type state :: %__MODULE__{
          adapter_mod: module(),
          adapter_state: Adapter.state(),
          topic_prefix: String.t(),
          topic_scopes: [Topic.scope()],
          payload_builder: (Event.t(), keyword() -> Payload.t()),
          max_queue_size: pos_integer(),
          overflow: overflow_policy(),
          notify: pid() | nil,
          task_supervisor: pid(),
          queue: :queue.queue(),
          queue_len: non_neg_integer(),
          inflight_ref: reference() | nil,
          inflight_pid: pid() | nil,
          waiters: [GenServer.from()]
        }

  @enforce_keys [
    :adapter_mod,
    :adapter_state,
    :topic_prefix,
    :topic_scopes,
    :payload_builder,
    :max_queue_size,
    :overflow,
    :task_supervisor
  ]
  defstruct [
    :adapter_mod,
    :adapter_state,
    :topic_prefix,
    :topic_scopes,
    :payload_builder,
    :max_queue_size,
    :overflow,
    :notify,
    :task_supervisor,
    queue: :queue.new(),
    queue_len: 0,
    inflight_ref: nil,
    inflight_pid: nil,
    waiters: []
  ]

  @default_adapter {Local, []}
  @default_max_queue_size 2_048
  @default_overflow :drop_oldest

  @spec start_link(keyword()) :: GenServer.on_start() | {:error, Error.t()}
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name)

    GenServer.start_link(__MODULE__, opts, name: name)
  catch
    :exit, %Error{} = error ->
      {:error, error}

    :exit, {:shutdown, %Error{} = error} ->
      {:error, error}

    :exit, reason ->
      {:error, runtime_error("pubsub broadcaster start failed", reason)}
  end

  @spec enqueue(pid(), Event.t(), keyword()) :: :ok
  def enqueue(broadcaster, %Event{} = event, publish_opts \\ [])
      when is_pid(broadcaster) and is_list(publish_opts) do
    GenServer.cast(broadcaster, {:publish, event, publish_opts})
  end

  @spec flush(pid(), timeout()) :: :ok | {:error, Error.t()}
  def flush(broadcaster, timeout \\ 5_000) when is_pid(broadcaster) do
    GenServer.call(broadcaster, :flush, timeout)
  catch
    :exit, reason ->
      {:error, Error.new(:unknown, :runtime, "pubsub broadcaster flush failed", cause: reason)}
  end

  @impl true
  def init(opts) do
    with {:ok, {adapter_mod, adapter_opts}} <-
           normalize_adapter_spec(Keyword.get(opts, :adapter, @default_adapter)),
         :ok <- ensure_adapter_module(adapter_mod),
         {:ok, adapter_state} <- normalize_adapter_init(adapter_mod.init(adapter_opts)),
         {:ok, topic_prefix} <-
           normalize_topic_prefix(Keyword.get(opts, :topic_prefix, Topic.default_prefix())),
         {:ok, topic_scopes} <-
           normalize_topic_scopes(Keyword.get(opts, :topic_scopes, Topic.default_scopes())),
         {:ok, payload_builder} <-
           normalize_payload_builder(Keyword.get(opts, :payload_builder, &Payload.build/2)),
         {:ok, max_queue_size} <-
           normalize_max_queue_size(Keyword.get(opts, :max_queue_size, @default_max_queue_size)),
         {:ok, overflow} <- normalize_overflow(Keyword.get(opts, :overflow, @default_overflow)),
         {:ok, task_supervisor} <- Task.Supervisor.start_link() do
      {:ok,
       %__MODULE__{
         adapter_mod: adapter_mod,
         adapter_state: adapter_state,
         topic_prefix: topic_prefix,
         topic_scopes: topic_scopes,
         payload_builder: payload_builder,
         max_queue_size: max_queue_size,
         overflow: overflow,
         notify: Keyword.get(opts, :notify),
         task_supervisor: task_supervisor
       }}
    else
      {:error, %Error{} = error} ->
        {:stop, error}

      {:error, reason} ->
        {:stop, runtime_error("pubsub broadcaster init failed", reason)}
    end
  end

  @impl true
  def handle_cast({:publish, %Event{} = event, publish_opts}, %__MODULE__{} = state)
      when is_list(publish_opts) do
    state =
      state
      |> enqueue_item(event, publish_opts)
      |> maybe_start_dispatch()
      |> maybe_reply_waiters()

    {:noreply, state}
  end

  def handle_cast(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:flush, from, state) do
    if idle?(state) do
      {:reply, :ok, state}
    else
      {:noreply, %{state | waiters: [from | state.waiters]}}
    end
  end

  def handle_call(_other, _from, state) do
    {:reply, {:error, config_error("unsupported pubsub broadcaster operation")}, state}
  end

  @impl true
  def handle_info({ref, result}, %__MODULE__{inflight_ref: ref} = state) do
    Process.demonitor(ref, [:flush])

    state =
      state
      |> clear_inflight()
      |> handle_dispatch_result(result)
      |> maybe_start_dispatch()
      |> maybe_reply_waiters()

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{inflight_ref: ref} = state) do
    error = runtime_error("pubsub broadcast task crashed", reason)

    state =
      state
      |> clear_inflight()
      |> emit_dispatch_error(error, nil, nil)
      |> maybe_start_dispatch()
      |> maybe_reply_waiters()

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %__MODULE__{task_supervisor: task_supervisor})
      when is_pid(task_supervisor) do
    Process.exit(task_supervisor, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp enqueue_item(%__MODULE__{} = state, %Event{} = event, publish_opts) do
    pending = pending_count(state)

    if pending < state.max_queue_size do
      %{
        state
        | queue: :queue.in({event, publish_opts}, state.queue),
          queue_len: state.queue_len + 1
      }
    else
      handle_overflow(state, event, publish_opts)
    end
  end

  defp handle_overflow(
         %__MODULE__{overflow: :drop_oldest, queue_len: queue_len} = state,
         event,
         publish_opts
       )
       when queue_len > 0 do
    {{:value, {dropped_event, _dropped_opts}}, queue} = :queue.out(state.queue)
    queue = :queue.in({event, publish_opts}, queue)

    state
    |> emit_drop(dropped_event, :drop_oldest)
    |> Map.put(:queue, queue)
  end

  defp handle_overflow(%__MODULE__{} = state, event, _publish_opts) do
    emit_drop(state, event, :drop_newest)
  end

  defp maybe_start_dispatch(%__MODULE__{inflight_ref: ref} = state) when not is_nil(ref),
    do: state

  defp maybe_start_dispatch(%__MODULE__{} = state) do
    case :queue.out(state.queue) do
      {{:value, {event, publish_opts}}, queue} ->
        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            dispatch_event(state, event, publish_opts)
          end)

        %{
          state
          | inflight_ref: task.ref,
            inflight_pid: task.pid,
            queue: queue,
            queue_len: state.queue_len - 1
        }

      {:empty, _queue} ->
        state
    end
  end

  defp handle_dispatch_result(%__MODULE__{} = state, :ok), do: state

  defp handle_dispatch_result(%__MODULE__{} = state, {:error, %Error{} = error, event, topic}) do
    emit_dispatch_error(state, error, event, topic)
  end

  defp handle_dispatch_result(%__MODULE__{} = state, {:error, reason, event, topic}) do
    emit_dispatch_error(state, runtime_error("pubsub broadcast failed", reason), event, topic)
  end

  defp handle_dispatch_result(%__MODULE__{} = state, other) do
    emit_dispatch_error(
      state,
      runtime_error("pubsub broadcast returned invalid response", other),
      nil,
      nil
    )
  end

  defp dispatch_event(%__MODULE__{} = state, %Event{} = event, publish_opts)
       when is_list(publish_opts) do
    with {:ok, topics} <- Topic.for_event(event, build_topic_opts(state, publish_opts)),
         {:ok, payload} <- build_payload(state, event, topics, publish_opts),
         :ok <- broadcast_topics(state, topics, payload) do
      :ok
    else
      {:error, %Error{} = error, _event, topic} ->
        {:error, error, event, topic}

      {:error, reason, _event, topic} ->
        {:error, reason, event, topic}

      {:error, %Error{} = error} ->
        {:error, error, event, nil}

      {:error, reason} ->
        {:error, reason, event, nil}
    end
  end

  defp build_topic_opts(%__MODULE__{} = state, publish_opts) do
    []
    |> Keyword.put(:prefix, Keyword.get(publish_opts, :prefix, state.topic_prefix))
    |> Keyword.put(:scopes, Keyword.get(publish_opts, :scopes, state.topic_scopes))
  end

  defp build_payload(%__MODULE__{} = state, %Event{} = event, topics, publish_opts) do
    payload_opts =
      publish_opts
      |> Keyword.get(:payload_opts, [])
      |> Keyword.put(:topics, topics)
      |> Keyword.put_new(:source, :pipeline)

    {:ok, state.payload_builder.(event, payload_opts)}
  rescue
    error ->
      {:error, runtime_error("pubsub payload build failed", error)}
  catch
    :exit, reason ->
      {:error, runtime_error("pubsub payload build failed", reason)}
  end

  defp broadcast_topics(_state, [], _payload), do: :ok

  defp broadcast_topics(%__MODULE__{} = state, topics, payload) do
    Enum.reduce_while(topics, :ok, fn topic, :ok ->
      case state.adapter_mod.broadcast(state.adapter_state, topic, {:asm_pubsub, topic, payload}) do
        :ok ->
          {:cont, :ok}

        {:error, %Error{} = error} ->
          {:halt, {:error, error, nil, topic}}

        {:error, reason} ->
          {:halt, {:error, runtime_error("pubsub adapter broadcast failed", reason), nil, topic}}

        other ->
          {:halt,
           {:error, runtime_error("pubsub adapter broadcast returned invalid response", other),
            nil, topic}}
      end
    end)
  rescue
    error ->
      {:error, runtime_error("pubsub adapter broadcast failed", error), nil, nil}
  catch
    :exit, reason ->
      {:error, runtime_error("pubsub adapter broadcast failed", reason), nil, nil}
  end

  defp emit_dispatch_error(%__MODULE__{} = state, %Error{} = error, event, topic) do
    Telemetry.execute([:asm, :ext, :pub_sub, :broadcast, :error], %{}, %{
      session_id: event && event.session_id,
      run_id: event && event.run_id,
      event_id: event && event.id,
      event_kind: event && event.kind,
      topic: topic,
      error_kind: error.kind,
      error_domain: error.domain
    })

    maybe_notify(state.notify, {:asm_pubsub_error, error, event, topic})
    state
  end

  defp emit_drop(%__MODULE__{} = state, %Event{} = event, policy) do
    metadata = %{
      reason: :queue_full,
      policy: policy,
      dropped_event_id: event.id,
      dropped_event_kind: event.kind,
      dropped_run_id: event.run_id,
      dropped_session_id: event.session_id
    }

    Telemetry.execute([:asm, :ext, :pub_sub, :queue, :drop], %{}, metadata)
    maybe_notify(state.notify, {:asm_pubsub_drop, metadata})
    state
  end

  defp maybe_notify(pid, message) when is_pid(pid) do
    send(pid, message)
    :ok
  end

  defp maybe_notify(_other, _message), do: :ok

  defp maybe_reply_waiters(%__MODULE__{} = state) do
    if idle?(state) and state.waiters != [] do
      Enum.each(state.waiters, &GenServer.reply(&1, :ok))
      %{state | waiters: []}
    else
      state
    end
  end

  defp clear_inflight(%__MODULE__{} = state) do
    %{state | inflight_ref: nil, inflight_pid: nil}
  end

  defp idle?(%__MODULE__{inflight_ref: nil, queue_len: 0}), do: true
  defp idle?(%__MODULE__{}), do: false

  defp pending_count(%__MODULE__{} = state) do
    inflight = if state.inflight_ref, do: 1, else: 0
    state.queue_len + inflight
  end

  defp normalize_adapter_spec({module, opts}) when is_atom(module) and is_list(opts) do
    {:ok, {module, opts}}
  end

  defp normalize_adapter_spec(other) do
    {:error, config_error("pubsub adapter must be {module, keyword}, got: #{inspect(other)}")}
  end

  defp ensure_adapter_module(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, config_error("pubsub adapter module is not available: #{inspect(module)}")}

      not function_exported?(module, :init, 1) ->
        {:error, config_error("pubsub adapter #{inspect(module)} must export init/1")}

      not function_exported?(module, :broadcast, 3) ->
        {:error, config_error("pubsub adapter #{inspect(module)} must export broadcast/3")}

      not function_exported?(module, :subscribe, 2) ->
        {:error, config_error("pubsub adapter #{inspect(module)} must export subscribe/2")}

      true ->
        :ok
    end
  end

  defp normalize_adapter_init({:ok, adapter_state}), do: {:ok, adapter_state}
  defp normalize_adapter_init({:error, %Error{} = error}), do: {:error, error}

  defp normalize_adapter_init({:error, reason}) do
    {:error, runtime_error("pubsub adapter init failed", reason)}
  end

  defp normalize_adapter_init(other) do
    {:error, runtime_error("pubsub adapter init returned invalid response", other)}
  end

  defp normalize_topic_prefix(prefix) when is_binary(prefix) do
    if String.trim(prefix) == "" do
      {:error, config_error(":topic_prefix must be a non-empty string")}
    else
      {:ok, prefix}
    end
  end

  defp normalize_topic_prefix(other) do
    {:error, config_error(":topic_prefix must be a non-empty string, got: #{inspect(other)}")}
  end

  defp normalize_topic_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.reduce_while({:ok, []}, fn
      scope, {:ok, acc} when scope in [:all, :session, :run] ->
        {:cont, {:ok, [scope | acc]}}

      invalid, _acc ->
        {:halt,
         {:error,
          config_error(
            ":topic_scopes entries must be :all, :session, or :run, got: #{inspect(invalid)}"
          )}}
    end)
    |> case do
      {:ok, reversed_scopes} -> {:ok, Enum.reverse(reversed_scopes)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp normalize_topic_scopes(other) do
    {:error, config_error(":topic_scopes must be a list, got: #{inspect(other)}")}
  end

  defp normalize_payload_builder(fun) when is_function(fun, 2), do: {:ok, fun}

  defp normalize_payload_builder(other) do
    {:error,
     config_error(":payload_builder must be a function with arity 2, got: #{inspect(other)}")}
  end

  defp normalize_max_queue_size(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_max_queue_size(other) do
    {:error, config_error(":max_queue_size must be a positive integer, got: #{inspect(other)}")}
  end

  defp normalize_overflow(policy) when policy in [:drop_oldest, :drop_newest], do: {:ok, policy}

  defp normalize_overflow(other) do
    {:error,
     config_error(":overflow must be :drop_oldest or :drop_newest, got: #{inspect(other)}")}
  end

  defp config_error(message) do
    Error.new(:config_invalid, :config, message)
  end

  defp runtime_error(message, cause) do
    Error.new(:unknown, :runtime, message, cause: cause)
  end
end
