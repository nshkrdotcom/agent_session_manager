defmodule ASM.TestSupport.ClaudeTransport do
  @moduledoc false

  import Kernel, except: [send: 2]

  use GenServer

  @behaviour ClaudeAgentSDK.Transport

  @impl true
  def start(opts), do: GenServer.start(__MODULE__, opts)

  @impl true
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def send(transport, payload), do: GenServer.call(transport, {:send, payload})

  @impl true
  def subscribe(transport, subscriber), do: GenServer.call(transport, {:subscribe, subscriber})

  @impl true
  def close(transport), do: GenServer.stop(transport, :normal)

  @impl true
  def status(transport), do: GenServer.call(transport, :status)

  @impl true
  def init(opts) do
    options = Keyword.fetch!(opts, :options)
    owner = Keyword.fetch!(opts, :owner)
    Kernel.send(owner, {:claude_transport_options, options})
    {:ok, %{subscriber: nil}}
  end

  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) do
    {:reply, :ok, %{state | subscriber: subscriber}}
  end

  def handle_call({:send, payload}, _from, %{subscriber: subscriber} = state)
      when is_pid(subscriber) do
    request = Jason.decode!(payload)

    response =
      Jason.encode!(%{
        "type" => "control_response",
        "response" => %{
          "subtype" => "success",
          "request_id" => request["request_id"],
          "response" => %{}
        }
      })

    Kernel.send(subscriber, {:transport_message, response})
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state), do: {:reply, :ready, state}
end
