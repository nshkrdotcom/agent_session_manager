if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule AgentSessionManager.Rendering.Sinks.PubSubSink do
    @moduledoc """
    A sink that broadcasts events via Phoenix PubSub.

    Ignores rendered text (`write/2`). Broadcasts structured events via
    `write_event/3` to one or more PubSub topics derived from the event.

    ## Options

      * `:pubsub` - The PubSub server (e.g. `MyApp.PubSub`). Required.
      * `:topic` - Static topic string. Mutually exclusive with `:topic_fn`.
      * `:topic_fn` - A function `(event -> String.t() | [String.t()])` that
        returns one or more topics. Mutually exclusive with `:topic`.
      * `:prefix` - Topic prefix. Default `"asm"`.
      * `:scope` - Topic scope when neither `:topic` nor `:topic_fn` is given.
        One of `:session`, `:run`, `:type`. Default `:session`.
      * `:message_wrapper` - Atom used as the first element of the broadcast
        tuple. Default `:asm_event`.
      * `:include_iodata` - Whether to include rendered iodata in the message.
        Default `false`.
      * `:dispatcher` - PubSub dispatcher module. Default `Phoenix.PubSub`.
        Override for testing.
    """

    @behaviour AgentSessionManager.Rendering.Sink

    alias AgentSessionManager.PubSub.Topic

    @default_prefix "asm"
    @default_scope :session
    @default_wrapper :asm_event

    @impl true
    def init(opts) do
      with {:ok, pubsub} <- fetch_required(opts, :pubsub),
           {:ok, topic_strategy} <- resolve_topic_strategy(opts),
           {:ok, dispatcher} <- resolve_dispatcher(opts) do
        {:ok,
         %{
           pubsub: pubsub,
           topic_strategy: topic_strategy,
           dispatcher: dispatcher,
           message_wrapper: Keyword.get(opts, :message_wrapper, @default_wrapper),
           include_iodata: Keyword.get(opts, :include_iodata, false),
           broadcast_count: 0,
           error_count: 0
         }}
      end
    end

    @impl true
    def write(_iodata, state), do: {:ok, state}

    @impl true
    def write_event(event, iodata, state) do
      topics = resolve_topics(event, state.topic_strategy)
      message = build_message(event, iodata, state)

      next_state =
        Enum.reduce(topics, state, fn topic, acc ->
          case state.dispatcher.broadcast(state.pubsub, topic, message) do
            :ok ->
              %{acc | broadcast_count: acc.broadcast_count + 1}

            {:error, _reason} ->
              %{acc | error_count: acc.error_count + 1}
          end
        end)

      {:ok, next_state}
    end

    @impl true
    def flush(state), do: {:ok, state}

    @impl true
    def close(_state), do: :ok

    defp resolve_topics(_event, {:static, topic}), do: [topic]

    defp resolve_topics(event, {:dynamic, fun}) do
      case fun.(event) do
        topics when is_list(topics) -> topics
        topic when is_binary(topic) -> [topic]
      end
    end

    defp resolve_topics(event, {:scoped, prefix, scope}) do
      [Topic.build(event, prefix: prefix, scope: scope)]
    end

    defp build_message(event, iodata, %{include_iodata: true, message_wrapper: wrapper}) do
      {wrapper, event[:session_id], event, iodata}
    end

    defp build_message(event, _iodata, %{include_iodata: false, message_wrapper: wrapper}) do
      {wrapper, event[:session_id], event}
    end

    defp fetch_required(opts, key) do
      case Keyword.fetch(opts, key) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, "#{key} option is required"}
      end
    end

    defp resolve_topic_strategy(opts) do
      topic = Keyword.get(opts, :topic)
      topic_fn = Keyword.get(opts, :topic_fn)
      prefix = Keyword.get(opts, :prefix, @default_prefix)
      scope = Keyword.get(opts, :scope, @default_scope)

      cond do
        topic && topic_fn ->
          {:error, ":topic and :topic_fn are mutually exclusive"}

        topic ->
          {:ok, {:static, topic}}

        topic_fn && not is_function(topic_fn, 1) ->
          {:error, ":topic_fn must be a 1-arity function"}

        is_function(topic_fn, 1) ->
          {:ok, {:dynamic, topic_fn}}

        scope not in [:session, :run, :type] ->
          {:error, ":scope must be :session, :run, or :type"}

        true ->
          {:ok, {:scoped, prefix, scope}}
      end
    end

    defp resolve_dispatcher(opts) do
      {:ok, Keyword.get(opts, :dispatcher, Phoenix.PubSub)}
    end
  end
else
  defmodule AgentSessionManager.Rendering.Sinks.PubSubSink do
    @moduledoc """
    PubSub broadcasting sink (stub).

    The `phoenix_pubsub` dependency is not available. Add it to your `mix.exs`:

        {:phoenix_pubsub, "~> 2.1"}
    """

    @behaviour AgentSessionManager.Rendering.Sink

    alias AgentSessionManager.OptionalDependency

    @impl true
    def init(_opts), do: {:error, missing_dependency_error(:init)}

    @impl true
    def write(_iodata, state), do: {:ok, state}

    @impl true
    def write_event(_event, _iodata, state), do: {:ok, state}

    @impl true
    def flush(state), do: {:ok, state}

    @impl true
    def close(_state), do: :ok

    defp missing_dependency_error(operation) do
      OptionalDependency.error(:phoenix_pubsub, __MODULE__, operation)
    end
  end
end
