defmodule AgentSessionManager.StreamSession do
  @moduledoc """
  One-shot streaming session lifecycle.

  Starts a store and adapter under supervision, runs `SessionManager.run_once`
  in a monitored task, and exposes the event stream as a lazy `Stream.resource`.

  ## Usage

      {:ok, stream, close_fun, meta} =
        StreamSession.start(
          adapter: {ClaudeAdapter, model: Models.default_model(:claude)},
          input: %{messages: [%{role: "user", content: "Hello"}]}
        )

      stream
      |> Stream.each(&IO.inspect/1)
      |> Stream.run()

      close_fun.()

  ## With existing store and adapter

      {:ok, stream, close_fun, meta} =
        StreamSession.start(
          store: existing_store_pid,
          adapter: existing_adapter_pid,
          input: %{messages: [%{role: "user", content: "Hello"}]}
        )

  ## Options

  - `:adapter` — Required. `{AdapterModule, opts}` tuple or a pid of a running adapter.
  - `:input` — Required. Input map for `SessionManager.run_once/4`.
  - `:store` — Optional. Pid of an existing SessionStore. Defaults to starting an InMemorySessionStore.
  - `:agent_id` — Optional. Agent identifier for the session.
  - `:run_opts` — Optional. Additional keyword opts forwarded to `SessionManager.run_once/4`.
  - `:idle_timeout` — Optional. Stream idle timeout in ms. Default: 120_000.
  - `:shutdown_timeout` — Optional. Task shutdown grace period in ms. Default: 5_000.
  """

  alias AgentSessionManager.Config
  alias AgentSessionManager.StreamSession.{EventStream, Lifecycle}

  @type stream_event :: map()
  @type close_fun :: (-> :ok)
  @type meta :: map()

  @spec start(keyword()) :: {:ok, Enumerable.t(), close_fun(), meta()} | {:error, term()}
  def start(opts) when is_list(opts) do
    with {:ok, config} <- validate_opts(opts),
         {:ok, resources} <- Lifecycle.acquire(config) do
      {stream, close_fun} = EventStream.build(resources, config)
      meta = build_meta(config)
      {:ok, stream, close_fun, meta}
    end
  end

  defp validate_opts(opts) do
    adapter = Keyword.get(opts, :adapter)
    input = Keyword.get(opts, :input)

    cond do
      is_nil(adapter) ->
        {:error, {:missing_option, :adapter}}

      is_nil(input) ->
        {:error, {:missing_option, :input}}

      true ->
        {:ok,
         %{
           adapter: adapter,
           input: input,
           store: Keyword.get(opts, :store),
           agent_id: Keyword.get(opts, :agent_id),
           run_opts: Keyword.get(opts, :run_opts, []),
           idle_timeout: Keyword.get(opts, :idle_timeout, Config.get(:stream_idle_timeout_ms)),
           shutdown_timeout:
             Keyword.get(opts, :shutdown_timeout, Config.get(:task_shutdown_timeout_ms))
         }}
    end
  end

  defp build_meta(%{adapter: {module, _opts}}), do: %{adapter: module}
  defp build_meta(%{adapter: pid}) when is_pid(pid), do: %{adapter: pid}
  defp build_meta(%{adapter: name}) when is_atom(name), do: %{adapter: name}
end
