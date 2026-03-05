defmodule ASM.Extensions.PubSub do
  @moduledoc """
  Public PubSub extension API.

  This domain provides non-blocking event fanout to local or optional external
  PubSub backends.

  Topic strategy:
  - `:all` -> `asm:events`
  - `:session` -> `asm:session:<session_id>`
  - `:run` -> `asm:session:<session_id>:run:<run_id>`

  Payload contract:
  - `%{schema: "asm.pubsub.event.v1", event: %ASM.Event{}, meta: %{...}}`
  - broadcast messages are delivered as `{:asm_pubsub, topic, payload}`
  """

  use Boundary,
    deps: [ASM],
    exports: [
      ASM.Extensions.PubSub,
      ASM.Extensions.PubSub.Adapter,
      ASM.Extensions.PubSub.Adapters.Local,
      ASM.Extensions.PubSub.Adapters.Phoenix,
      ASM.Extensions.PubSub.Broadcaster,
      ASM.Extensions.PubSub.Payload,
      ASM.Extensions.PubSub.PipelinePlug,
      ASM.Extensions.PubSub.Topic
    ]

  alias ASM.{Error, Event}
  alias ASM.Extensions.PubSub.{Adapters, Broadcaster, Payload, PipelinePlug, Topic}

  @type adapter_spec :: {module(), keyword()}

  @spec local_adapter(keyword()) :: adapter_spec()
  def local_adapter(opts \\ []) when is_list(opts), do: {Adapters.Local, opts}

  @spec phoenix_adapter(keyword()) :: adapter_spec()
  def phoenix_adapter(opts \\ []) when is_list(opts), do: {Adapters.Phoenix, opts}

  @spec start_local_bus(keyword()) :: GenServer.on_start() | {:error, Error.t()}
  def start_local_bus(opts \\ []) when is_list(opts), do: Adapters.Local.start_link(opts)

  @spec start_broadcaster(keyword()) :: GenServer.on_start() | {:error, Error.t()}
  def start_broadcaster(opts \\ []) when is_list(opts), do: Broadcaster.start_link(opts)

  @spec flush_broadcaster(pid(), timeout()) :: :ok | {:error, Error.t()}
  def flush_broadcaster(broadcaster, timeout \\ 5_000) when is_pid(broadcaster),
    do: Broadcaster.flush(broadcaster, timeout)

  @spec publish(pid(), Event.t(), keyword()) :: :ok
  def publish(broadcaster, %Event{} = event, publish_opts \\ [])
      when is_pid(broadcaster) and is_list(publish_opts) do
    Broadcaster.enqueue(broadcaster, event, publish_opts)
  end

  @spec broadcaster_plug(pid(), keyword()) :: {module(), keyword()}
  def broadcaster_plug(broadcaster, opts \\ []) when is_pid(broadcaster) and is_list(opts) do
    {PipelinePlug, Keyword.put(opts, :broadcaster, broadcaster)}
  end

  @spec event_callback(pid(), keyword()) :: (Event.t(), iodata() -> :ok)
  def event_callback(broadcaster, opts \\ []) when is_pid(broadcaster) and is_list(opts) do
    publish_opts = Keyword.get(opts, :publish_opts, [])

    fn %Event{} = event, _iodata ->
      publish(broadcaster, event, publish_opts)
    end
  end

  @spec subscribe(adapter_spec(), String.t()) :: :ok | {:error, Error.t()}
  def subscribe({adapter_mod, adapter_opts}, topic)
      when is_atom(adapter_mod) and is_list(adapter_opts) and is_binary(topic) do
    with :ok <- ensure_loaded(adapter_mod),
         :ok <- ensure_export(adapter_mod, :init, 1),
         :ok <- ensure_export(adapter_mod, :subscribe, 2),
         {:ok, adapter_state} <- normalize_adapter_init(adapter_mod.init(adapter_opts)),
         :ok <- normalize_adapter_call(adapter_mod.subscribe(adapter_state, topic), "subscribe/2") do
      :ok
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  rescue
    error ->
      {:error, runtime_error("pubsub subscribe failed", error)}
  catch
    :exit, reason ->
      {:error, runtime_error("pubsub subscribe failed", reason)}
  end

  def subscribe(invalid_adapter, topic) when is_binary(topic) do
    {:error,
     config_error(
       "adapter must be {module, keyword} for pubsub subscribe, got: #{inspect(invalid_adapter)}"
     )}
  end

  @spec all_topic(keyword()) :: String.t()
  def all_topic(opts \\ []) when is_list(opts) do
    Topic.all(Keyword.get(opts, :prefix, Topic.default_prefix()))
  end

  @spec session_topic(String.t(), keyword()) :: String.t()
  def session_topic(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    Topic.session(session_id, Keyword.get(opts, :prefix, Topic.default_prefix()))
  end

  @spec run_topic(String.t(), String.t(), keyword()) :: String.t()
  def run_topic(session_id, run_id, opts \\ [])
      when is_binary(session_id) and is_binary(run_id) and is_list(opts) do
    Topic.run(session_id, run_id, Keyword.get(opts, :prefix, Topic.default_prefix()))
  end

  @spec topics_for_event(Event.t(), keyword()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def topics_for_event(%Event{} = event, opts \\ []) when is_list(opts),
    do: Topic.for_event(event, opts)

  @spec payload_for_event(Event.t(), keyword()) :: Payload.t()
  def payload_for_event(%Event{} = event, opts \\ []) when is_list(opts),
    do: Payload.build(event, opts)

  defp ensure_loaded(module) do
    if Code.ensure_loaded?(module) do
      :ok
    else
      {:error, config_error("pubsub adapter module is not available: #{inspect(module)}")}
    end
  end

  defp ensure_export(module, function, arity) do
    if function_exported?(module, function, arity) do
      :ok
    else
      {:error,
       config_error("pubsub adapter module #{inspect(module)} must export #{function}/#{arity}")}
    end
  end

  defp normalize_adapter_init({:ok, state}), do: {:ok, state}
  defp normalize_adapter_init({:error, %Error{} = error}), do: {:error, error}

  defp normalize_adapter_init({:error, reason}) do
    {:error, runtime_error("pubsub adapter init failed", reason)}
  end

  defp normalize_adapter_init(other) do
    {:error, runtime_error("pubsub adapter init returned invalid response", other)}
  end

  defp normalize_adapter_call(:ok, _op), do: :ok
  defp normalize_adapter_call({:error, %Error{} = error}, _op), do: {:error, error}

  defp normalize_adapter_call({:error, reason}, operation) do
    {:error, runtime_error("pubsub adapter #{operation} failed", reason)}
  end

  defp normalize_adapter_call(other, operation) do
    {:error, runtime_error("pubsub adapter #{operation} returned invalid response", other)}
  end

  defp config_error(message) do
    Error.new(:config_invalid, :config, message)
  end

  defp runtime_error(message, cause) do
    Error.new(:unknown, :runtime, message, cause: cause)
  end
end
