Application.ensure_all_started(:inets)
Application.ensure_all_started(:ssl)
Application.ensure_all_started(:agent_session_manager)

alias ASM.InferenceEndpoint
alias ASM.ProviderBackend.{Event, Info}
alias CliSubprocessCore.Event, as: CoreEvent
alias CliSubprocessCore.Payload

defmodule ExampleBackend do
  use GenServer

  @behaviour ASM.ProviderBackend

  defstruct [:config, :subscriber, :subscription_ref]

  def start_run(config) when is_map(config) do
    with {:ok, pid} <- GenServer.start_link(__MODULE__, config) do
      {:ok, pid,
       Info.new(
         provider: config.provider.name,
         lane: Map.get(config, :lane, :core),
         backend: __MODULE__,
         runtime: __MODULE__,
         capabilities: [],
         session_pid: pid,
         raw_info: %{backend: :example_inference_endpoint, provider: config.provider.name}
       )}
    end
  end

  def send_input(_server, _input, _opts), do: :ok
  def end_input(_server), do: :ok
  def interrupt(_server), do: :ok

  def close(server) do
    GenServer.stop(server, :normal)
  catch
    :exit, _ -> :ok
  end

  def subscribe(server, pid, ref) do
    GenServer.call(server, {:subscribe, pid, ref})
  end

  def info(server) do
    GenServer.call(server, :info)
  end

  def init(config) do
    {:ok, %__MODULE__{config: config, subscriber: nil, subscription_ref: nil}}
  end

  def handle_call({:subscribe, pid, ref}, _from, state) do
    state = %{state | subscriber: pid, subscription_ref: ref}
    emit_script(state)
    {:reply, :ok, state}
  end

  def handle_call(:info, _from, state) do
    {:reply,
     Info.new(
       provider: state.config.provider.name,
       lane: Map.get(state.config, :lane, :core),
       backend: __MODULE__,
       runtime: __MODULE__,
       capabilities: [],
       session_pid: self(),
       raw_info: %{backend: :example_inference_endpoint, provider: state.config.provider.name}
     ), state}
  end

  defp emit_script(%__MODULE__{} = state) do
    state.config.backend_opts
    |> Keyword.get(:script, [])
    |> Enum.each(fn {kind, payload} ->
      send(
        state.subscriber,
        Event.new(
          state.subscription_ref,
          CoreEvent.new(kind, provider: state.config.provider.name, payload: payload)
        )
      )
    end)
  end
end

defmodule ExampleHTTP do
  def post_json(url, headers, payload) do
    case post_raw(url, headers, payload) do
      {:ok, {status, body}} -> {:ok, {status, Jason.decode!(body)}}
      other -> other
    end
  end

  def post_raw(url, headers, payload) do
    request_headers = [{"content-type", "application/json"} | headers] |> to_httpc_headers()
    body = Jason.encode!(payload)

    case :httpc.request(
           :post,
           {String.to_charlist(url), request_headers, ~c"application/json", body},
           [],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _response_headers, response_body}} ->
        {:ok, {status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp to_httpc_headers(headers) do
    Enum.map(headers, fn {key, value} ->
      {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
    end)
  end
end

{opts, _argv, _invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      provider: :string,
      model: :string,
      message: :string,
      answer: :string,
      stream: :boolean
    ]
  )

provider =
  opts
  |> Keyword.get(:provider, "gemini")
  |> String.to_existing_atom()

model = Keyword.get(opts, :model, "gemini-3.1-flash-lite-preview")
message = Keyword.get(opts, :message, "Summarize the CLI inference endpoint seam.")
answer = Keyword.get(opts, :answer, "ASM inference endpoint example is alive.")
stream? = Keyword.get(opts, :stream, false)

Application.put_env(
  :agent_session_manager,
  ASM.InferenceEndpoint,
  backend_module: ExampleBackend,
  backend_opts: [
    script: [
      {:run_started, Payload.RunStarted.new(command: "example", args: ["prompt"], cwd: "/tmp")},
      {:assistant_delta, Payload.AssistantDelta.new(content: answer)},
      {:result, Payload.Result.new(status: :completed, stop_reason: :end_turn)}
    ]
  ]
)

request = %{
  request_id: "req-example-inference-endpoint-1",
  operation: if(stream?, do: :stream_text, else: :generate_text),
  messages: [%{role: "user", content: message}],
  prompt: nil,
  model_preference: %{provider: provider, id: model},
  target_preference: %{target_class: :cli_endpoint},
  stream?: stream?,
  tool_policy: %{},
  metadata: %{phase: "phase_5_example"}
}

context = %{
  run_id: "run-example-inference-endpoint-1",
  attempt_id: "run-example-inference-endpoint-1:1",
  boundary_ref: "boundary-example-inference-endpoint-1"
}

{:ok, endpoint, compatibility} =
  InferenceEndpoint.ensure_endpoint(
    request,
    InferenceEndpoint.consumer_manifest(),
    context
  )

IO.inspect(
  %{
    endpoint_id: endpoint.endpoint_id,
    provider: endpoint.provider_identity,
    model: endpoint.model_identity,
    publication: endpoint.metadata.publication,
    compatible?: compatibility.compatible?
  },
  label: "published_endpoint"
)

result =
  try do
    payload = %{
      model: endpoint.model_identity,
      stream: stream?,
      messages: [%{role: "user", content: message}]
    }

    if stream? do
      {:ok, {status, body}} =
        ExampleHTTP.post_raw("#{endpoint.base_url}/chat/completions", endpoint.headers, payload)

      %{status: status, body: body}
    else
      {:ok, {status, body}} =
        ExampleHTTP.post_json("#{endpoint.base_url}/chat/completions", endpoint.headers, payload)

      %{status: status, body: body}
    end
  after
    :ok = InferenceEndpoint.release_endpoint(endpoint)
  end

IO.inspect(result, label: "endpoint_response")
