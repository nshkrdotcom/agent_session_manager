defmodule ASM.ProviderBackend.SDK.CodexAppServer do
  @moduledoc false

  use GenServer

  alias ASM.HostTool
  alias ASM.ProviderBackend.{Event, Info}
  alias CliSubprocessCore.Event, as: CoreEvent

  @provider :codex
  @turn_started :"Elixir.Codex.Events.TurnStarted"
  @dynamic_tool_call_requested :"Elixir.Codex.Events.DynamicToolCallRequested"
  @item_agent_message_delta :"Elixir.Codex.Events.ItemAgentMessageDelta"
  @item_completed :"Elixir.Codex.Events.ItemCompleted"
  @turn_completed :"Elixir.Codex.Events.TurnCompleted"
  @turn_failed :"Elixir.Codex.Events.TurnFailed"
  @agent_message :"Elixir.Codex.Items.AgentMessage"

  defstruct [
    :app_server_api,
    :conn,
    :thread,
    :thread_runner,
    :prompt,
    :run_task,
    :run_ref,
    :metadata,
    :run_opts,
    :tools,
    :info,
    :delta_turns,
    capabilities: [],
    subscribers: %{}
  ]

  @spec start_link(keyword()) :: {:ok, pid(), Info.t()} | {:error, term()}
  def start_link(opts) when is_list(opts) do
    case GenServer.start_link(__MODULE__, opts) do
      {:ok, pid} ->
        {:ok, pid, info(pid)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def send_input(session, input, opts \\ []) when is_pid(session) do
    GenServer.call(session, {:send_input, input, opts})
  end

  def end_input(session) when is_pid(session), do: GenServer.call(session, :end_input)
  def interrupt(session) when is_pid(session), do: GenServer.call(session, :interrupt)

  def close(session) when is_pid(session) do
    GenServer.stop(session, :normal)
  catch
    :exit, _reason -> :ok
  end

  def subscribe(session, pid, ref) when is_pid(session) and is_pid(pid) and is_reference(ref) do
    GenServer.call(session, {:subscribe, pid, ref})
  end

  def info(session) when is_pid(session), do: GenServer.call(session, :info)

  def capabilities, do: [:streaming, :app_server, :host_tools, :session_resume]

  @impl true
  def init(opts) when is_list(opts) do
    conn = Keyword.fetch!(opts, :conn)
    app_server_api = Keyword.fetch!(opts, :app_server_api)
    thread = Keyword.fetch!(opts, :thread)
    thread_runner = Keyword.fetch!(opts, :thread_runner)
    metadata = Keyword.get(opts, :metadata, %{})
    capabilities = Keyword.get(opts, :capabilities, capabilities())

    info =
      Info.new(
        provider: @provider,
        lane: :sdk,
        backend: ASM.ProviderBackend.SDK,
        runtime: __MODULE__,
        capabilities: capabilities,
        session_pid: self(),
        raw_info: %{app_server?: true}
      )

    state = %__MODULE__{
      app_server_api: app_server_api,
      conn: conn,
      thread: thread,
      thread_runner: thread_runner,
      prompt: Keyword.fetch!(opts, :prompt),
      metadata: metadata,
      run_opts: Keyword.get(opts, :run_opts, []),
      tools: Keyword.get(opts, :tools, %{}),
      info: info,
      delta_turns: MapSet.new(),
      capabilities: capabilities,
      subscribers: normalize_subscribers(Keyword.get(opts, :initial_subscribers, %{}))
    }

    {:ok, state, {:continue, :run_prompt}}
  end

  @impl true
  def handle_continue(:run_prompt, %__MODULE__{} = state) do
    {:noreply, start_run_task(state, state.prompt, state.run_opts)}
  end

  @impl true
  def handle_call({:send_input, input, opts}, _from, %__MODULE__{} = state) do
    {:reply, :ok, start_run_task(state, IO.iodata_to_binary(input), opts)}
  end

  def handle_call(:end_input, _from, %__MODULE__{} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:interrupt, _from, %__MODULE__{} = state) do
    {:reply, :ok, cancel_run_task(state)}
  end

  def handle_call({:subscribe, pid, ref}, _from, %__MODULE__{} = state) do
    {:reply, :ok, put_in(state.subscribers[ref], pid)}
  end

  def handle_call(:info, _from, %__MODULE__{} = state) do
    {:reply, state.info, state}
  end

  @impl true
  def handle_info({:codex_app_server_event, event}, %__MODULE__{} = state) do
    {:noreply, handle_codex_event(state, event)}
  end

  def handle_info({:codex_app_server_error, reason}, %__MODULE__{} = state) do
    core_event =
      CoreEvent.new(:error,
        provider: @provider,
        payload: %{message: inspect(reason), code: "codex_app_server_error"},
        metadata: state.metadata
      )

    publish_core(state, core_event)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{run_ref: ref} = state) do
    {:noreply, %{state | run_task: nil, run_ref: nil}}
  end

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    _ = cancel_run_task(state)
    _ = state.app_server_api.disconnect(state.conn)
    :ok
  end

  defp start_run_task(%__MODULE__{} = state, prompt, opts) do
    state = cancel_run_task(state)
    owner = self()
    runner = state.thread_runner
    thread = state.thread
    run_opts = Keyword.merge(state.run_opts, opts)

    {:ok, pid} =
      Task.start(fn ->
        case runner.run_streamed(thread, prompt, run_opts) do
          {:ok, stream} ->
            stream
            |> raw_events()
            |> Enum.each(&send(owner, {:codex_app_server_event, &1}))

          {:error, reason} ->
            send(owner, {:codex_app_server_error, reason})
        end
      end)

    %{state | run_task: pid, run_ref: Process.monitor(pid)}
  end

  defp cancel_run_task(%__MODULE__{run_task: pid, run_ref: ref} = state) do
    if is_reference(ref), do: Process.demonitor(ref, [:flush])

    if is_pid(pid) and Process.alive?(pid) do
      Process.exit(pid, :kill)
    end

    %{state | run_task: nil, run_ref: nil}
  end

  defp raw_events(stream) do
    streaming_module = :"Elixir.Codex.RunResultStreaming"

    if Code.ensure_loaded?(streaming_module) and
         function_exported?(streaming_module, :raw_events, 1) and
         match?(%{__struct__: ^streaming_module}, stream) do
      :erlang.apply(streaming_module, :raw_events, [stream])
    else
      stream
    end
  end

  defp handle_codex_event(%__MODULE__{} = state, %{__struct__: @turn_started} = event) do
    core_event =
      CoreEvent.new(:run_started,
        provider: @provider,
        provider_session_id: event.thread_id,
        payload: %{
          provider_session_id: event.thread_id,
          cwd: thread_working_directory(state.thread),
          metadata: %{provider_turn_id: event.turn_id}
        },
        metadata: Map.merge(state.metadata, %{provider_turn_id: event.turn_id})
      )

    publish_core(state, core_event)
    state
  end

  defp handle_codex_event(
         %__MODULE__{} = state,
         %{__struct__: @dynamic_tool_call_requested} = event
       ) do
    request = host_tool_request(state, event)
    requested = asm_event(state, :host_tool_requested, request, event)
    publish_asm(state, requested)

    response = execute_host_tool(state, request)

    response_event_kind =
      cond do
        response.success? -> :host_tool_completed
        is_nil(Map.get(state.tools, request.tool_name)) -> :host_tool_denied
        true -> :host_tool_failed
      end

    _ =
      state.app_server_api.respond(
        state.conn,
        event.id,
        HostTool.Response.to_dynamic_tool_response(response)
      )

    publish_asm(state, asm_event(state, response_event_kind, response, event))
    state
  end

  defp handle_codex_event(
         %__MODULE__{} = state,
         %{__struct__: @item_agent_message_delta} = event
       ) do
    text = get_in(event.item, ["text"]) || ""

    publish_core(
      state,
      CoreEvent.new(:assistant_delta,
        provider: @provider,
        provider_session_id: event.thread_id,
        payload: %{content: text, metadata: %{provider_turn_id: event.turn_id}},
        metadata: Map.merge(state.metadata, %{provider_turn_id: event.turn_id})
      )
    )

    mark_delta_seen(state, event)
  end

  defp handle_codex_event(
         %__MODULE__{} = state,
         %{__struct__: @item_completed, item: %{__struct__: @agent_message, text: text}} = event
       ) do
    if delta_seen?(state, event) do
      state
    else
      publish_core(
        state,
        CoreEvent.new(:assistant_message,
          provider: @provider,
          provider_session_id: event.thread_id,
          payload: %{
            content: [%{"type" => "text", "text" => text}],
            metadata: %{provider_turn_id: event.turn_id}
          },
          metadata: Map.merge(state.metadata, %{provider_turn_id: event.turn_id})
        )
      )

      state
    end
  end

  defp handle_codex_event(%__MODULE__{} = state, %{__struct__: @turn_completed} = event) do
    publish_core(
      state,
      CoreEvent.new(:result,
        provider: @provider,
        provider_session_id: event.thread_id,
        payload: %{
          status: event.status || :completed,
          stop_reason: event.status || "completed",
          output: %{text: final_response_text(event.final_response), usage: event.usage},
          metadata: %{provider_turn_id: event.turn_id}
        },
        metadata: Map.merge(state.metadata, %{provider_turn_id: event.turn_id})
      )
    )

    state
  end

  defp handle_codex_event(%__MODULE__{} = state, %{__struct__: @turn_failed} = event) do
    publish_core(
      state,
      CoreEvent.new(:error,
        provider: @provider,
        provider_session_id: event.thread_id,
        payload: %{
          message: inspect(event.error),
          code: "turn_failed",
          metadata: %{provider_turn_id: event.turn_id}
        },
        metadata: Map.merge(state.metadata, %{provider_turn_id: event.turn_id})
      )
    )

    state
  end

  defp handle_codex_event(%__MODULE__{} = state, _event), do: state

  defp host_tool_request(
         %__MODULE__{} = state,
         %{__struct__: @dynamic_tool_call_requested} = event
       ) do
    HostTool.Request.new!(
      id: event.id,
      session_id: metadata_string(state.metadata, :session_id, "sdk-session"),
      run_id: metadata_string(state.metadata, :run_id, "sdk-run"),
      provider: @provider,
      provider_session_id: event.thread_id,
      provider_turn_id: event.turn_id,
      tool_name: event.tool_name,
      arguments: event.arguments,
      raw: event,
      metadata: %{call_id: event.call_id}
    )
  end

  defp execute_host_tool(%__MODULE__{} = state, %HostTool.Request{} = request) do
    case Map.get(state.tools, request.tool_name) do
      nil ->
        HostTool.Response.new!(
          request_id: request.id,
          success?: false,
          output: "host tool #{request.tool_name} is not registered",
          error: %{reason: :unknown_tool}
        )

      tool ->
        invoke_host_tool(tool, request)
    end
  end

  defp invoke_host_tool(fun, %HostTool.Request{} = request) when is_function(fun, 1) do
    fun.(request.arguments)
    |> normalize_tool_result(request)
  rescue
    error -> failed_response(request, error)
  end

  defp invoke_host_tool(fun, %HostTool.Request{} = request) when is_function(fun, 2) do
    fun.(request.arguments, request)
    |> normalize_tool_result(request)
  rescue
    error -> failed_response(request, error)
  end

  defp invoke_host_tool(tool, %HostTool.Request{} = request) do
    case tool do
      %{execute: fun} when is_function(fun, 1) -> invoke_host_tool(fun, request)
      %{execute: fun} when is_function(fun, 2) -> invoke_host_tool(fun, request)
      _other -> failed_response(request, {:invalid_tool, tool})
    end
  end

  defp normalize_tool_result(%HostTool.Response{} = response, _request), do: response

  defp normalize_tool_result({:ok, output}, %HostTool.Request{} = request) do
    successful_response(request, output)
  end

  defp normalize_tool_result({:error, reason}, %HostTool.Request{} = request) do
    failed_response(request, reason)
  end

  defp normalize_tool_result(output, %HostTool.Request{} = request) do
    successful_response(request, output)
  end

  defp successful_response(%HostTool.Request{} = request, output) do
    encoded = encode_output(output)

    HostTool.Response.new!(
      request_id: request.id,
      success?: true,
      output: output,
      content_items: [%{"type" => "inputText", "text" => encoded}],
      metadata: request.metadata
    )
  end

  defp failed_response(%HostTool.Request{} = request, reason) do
    HostTool.Response.new!(
      request_id: request.id,
      success?: false,
      output: inspect(reason),
      error: %{reason: inspect(reason)},
      metadata: request.metadata
    )
  end

  defp asm_event(
         %__MODULE__{} = state,
         kind,
         payload,
         %{__struct__: @dynamic_tool_call_requested} = event
       ) do
    ASM.Event.new(kind, payload,
      run_id: metadata_string(state.metadata, :run_id, "sdk-run"),
      session_id: metadata_string(state.metadata, :session_id, "sdk-session"),
      provider: @provider,
      provider_session_id: event.thread_id,
      metadata:
        Map.merge(state.metadata, %{
          provider_turn_id: event.turn_id,
          tool_name: event.tool_name,
          call_id: event.call_id,
          codex_request_id: event.id
        })
    )
  end

  defp publish_core(%__MODULE__{} = state, %CoreEvent{} = event) do
    Enum.each(state.subscribers, fn
      {ref, pid} when is_reference(ref) and is_pid(pid) -> send(pid, Event.new(ref, event))
      _other -> :ok
    end)
  end

  defp publish_asm(%__MODULE__{} = state, %ASM.Event{} = event) do
    Enum.each(state.subscribers, fn
      {ref, pid} when is_reference(ref) and is_pid(pid) -> send(pid, Event.new_asm(ref, event))
      _other -> :ok
    end)
  end

  defp normalize_subscribers(%{} = subscribers) do
    Enum.reduce(subscribers, %{}, fn
      {ref, pid}, acc when is_reference(ref) and is_pid(pid) -> Map.put(acc, ref, pid)
      {_key, _value}, acc -> acc
    end)
  end

  defp normalize_subscribers(_subscribers), do: %{}

  defp mark_delta_seen(%__MODULE__{} = state, event) do
    %{state | delta_turns: MapSet.put(state.delta_turns, turn_key(event))}
  end

  defp delta_seen?(%__MODULE__{} = state, event) do
    MapSet.member?(state.delta_turns, turn_key(event))
  end

  defp turn_key(event), do: {Map.get(event, :thread_id), Map.get(event, :turn_id)}

  defp thread_working_directory(%{thread_opts: %{working_directory: cwd}}), do: cwd
  defp thread_working_directory(_thread), do: nil

  defp metadata_string(metadata, key, default) do
    case Map.get(metadata, key, Map.get(metadata, Atom.to_string(key))) do
      value when is_binary(value) and value != "" -> value
      _other -> default
    end
  end

  defp final_response_text(%{__struct__: @agent_message, text: text}), do: text
  defp final_response_text(%{"text" => text}) when is_binary(text), do: text
  defp final_response_text(text) when is_binary(text), do: text
  defp final_response_text(nil), do: nil
  defp final_response_text(other), do: inspect(other)

  defp encode_output(output) when is_binary(output), do: output

  defp encode_output(output) do
    Jason.encode!(output)
  rescue
    _error -> inspect(output)
  end
end
