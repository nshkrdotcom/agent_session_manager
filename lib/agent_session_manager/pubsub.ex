if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule AgentSessionManager.PubSub do
    @moduledoc """
    Convenience functions for PubSub integration with AgentSessionManager.

    Provides helpers for creating PubSub-aware event callbacks and for
    subscribing to session/run topics.

    ## Event Callback Usage

        callback = AgentSessionManager.PubSub.event_callback(
          MyApp.PubSub,
          scope: :session
        )

        SessionManager.run_once(store, adapter, input,
          event_callback: callback
        )

    ## Subscription Usage

        AgentSessionManager.PubSub.subscribe(MyApp.PubSub, session_id: "ses_123")

        # In a LiveView handle_info:
        def handle_info({:asm_event, session_id, event}, socket) do
          # ...
        end
    """

    alias AgentSessionManager.PubSub.Topic

    @default_prefix "asm"
    @default_scope :session
    @default_wrapper :asm_event

    @doc """
    Returns a 1-arity event callback that broadcasts each event to PubSub.

    This function returns a closure suitable for the `:event_callback` option
    of `SessionManager.execute_run/4` or `SessionManager.run_once/4`.

    ## Options

      * `:prefix` - Topic prefix. Default `"asm"`.
      * `:scope` - `:session` or `:run`. Default `:session`.
      * `:message_wrapper` - Broadcast tuple tag. Default `:asm_event`.
      * `:topic` - Override with a static topic string.
    """
    @spec event_callback(module(), keyword()) :: (map() -> :ok | {:error, term()})
    def event_callback(pubsub, opts \\ []) do
      wrapper = Keyword.get(opts, :message_wrapper, @default_wrapper)

      case Keyword.get(opts, :topic) do
        nil ->
          prefix = Keyword.get(opts, :prefix, @default_prefix)
          scope = Keyword.get(opts, :scope, @default_scope)

          fn event_data ->
            topic = Topic.build(event_data, prefix: prefix, scope: scope)

            Phoenix.PubSub.broadcast(
              pubsub,
              topic,
              {wrapper, event_data[:session_id], event_data}
            )
          end

        static_topic ->
          fn event_data ->
            Phoenix.PubSub.broadcast(pubsub, static_topic, {
              wrapper,
              event_data[:session_id],
              event_data
            })
          end
      end
    end

    @doc """
    Subscribes the calling process to ASM events on the given topic.

    ## Options

      * `:session_id` - Subscribe to all events for this session.
      * `:session_id` + `:run_id` - Subscribe to events for a specific run.
      * `:topic` - Subscribe to an explicit topic string.
      * `:prefix` - Topic prefix. Default `"asm"`.
    """
    @spec subscribe(module(), keyword()) :: :ok | {:error, term()}
    def subscribe(pubsub, opts) do
      topic =
        case Keyword.get(opts, :topic) do
          nil ->
            prefix = Keyword.get(opts, :prefix, @default_prefix)
            session_id = Keyword.fetch!(opts, :session_id)
            run_id = Keyword.get(opts, :run_id)

            if run_id do
              Topic.build_run_topic(prefix, session_id, run_id)
            else
              Topic.build_session_topic(prefix, session_id)
            end

          explicit_topic ->
            explicit_topic
        end

      Phoenix.PubSub.subscribe(pubsub, topic)
    end
  end
else
  defmodule AgentSessionManager.PubSub do
    @moduledoc """
    PubSub integration helpers (stub).

    The `phoenix_pubsub` dependency is not available. Add it to your `mix.exs`:

        {:phoenix_pubsub, "~> 2.1"}
    """

    alias AgentSessionManager.OptionalDependency

    @spec event_callback(term(), keyword()) :: (map() -> no_return())
    def event_callback(_pubsub, _opts \\ []) do
      raise OptionalDependency.error(:phoenix_pubsub, __MODULE__, :event_callback).message
    end

    @spec subscribe(term(), keyword()) :: {:error, AgentSessionManager.Core.Error.t()}
    def subscribe(_pubsub, _opts) do
      {:error, OptionalDependency.error(:phoenix_pubsub, __MODULE__, :subscribe)}
    end
  end
end
