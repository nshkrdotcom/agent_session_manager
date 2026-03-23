alias ASM.Extensions.ProviderSDK.Claude, as: ClaudeExtension
alias ClaudeAgentSDK.{Client, Hooks}
alias ClaudeAgentSDK.Hooks.Matcher

defmodule ASM.Examples.ClaudeControlExtensionDemo.Transport do
  @moduledoc false

  use GenServer

  import Kernel, except: [send: 2]

  @behaviour ClaudeAgentSDK.Transport

  @impl true
  def start(opts), do: GenServer.start(__MODULE__, opts)

  @impl true
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def send(transport, payload), do: GenServer.call(transport, {:send, payload})

  @impl true
  def subscribe(transport, pid), do: GenServer.call(transport, {:subscribe, pid})

  @impl true
  def close(transport), do: GenServer.stop(transport, :normal)

  @impl true
  def status(_transport), do: :connected

  @impl GenServer
  def init(_opts) do
    {:ok, %{subscribers: MapSet.new()}}
  end

  @impl GenServer
  def handle_call({:send, payload}, _from, state) do
    maybe_acknowledge_control_request(payload, state.subscribers)
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  defp maybe_acknowledge_control_request(payload, subscribers) do
    with {:ok, decoded} <- Jason.decode(payload),
         "control_request" <- decoded["type"],
         request_id when is_binary(request_id) <- decoded["request_id"] do
      response = %{
        "type" => "control_response",
        "response" => %{
          "subtype" => "success",
          "request_id" => request_id,
          "response" => %{}
        }
      }

      Enum.each(subscribers, fn pid ->
        Kernel.send(pid, {:transport_message, Jason.encode!(response)})
      end)
    else
      _ -> :ok
    end
  end
end

hook = fn _input, _tool_use_id, _context -> Hooks.Output.allow() end

asm_opts = [
  provider: :claude,
  cwd: File.cwd!(),
  permission_mode: :plan,
  model: System.get_env("ASM_CLAUDE_MODEL") || "sonnet",
  max_turns: 2
]

native_overrides = [
  hooks: %{pre_tool_use: [Matcher.new("Bash", [hook])]},
  enable_file_checkpointing: true
]

{:ok, options} = ClaudeExtension.sdk_options(asm_opts, native_overrides)

IO.puts("Claude Control Extension Demo")

IO.inspect(
  %{
    cwd: options.cwd,
    model: options.model,
    permission_mode: options.permission_mode,
    hooks?: not is_nil(options.hooks),
    file_checkpointing?: options.enable_file_checkpointing == true
  },
  label: "Derived ClaudeAgentSDK options"
)

{:ok, client} =
  ClaudeExtension.start_client(
    asm_opts,
    native_overrides,
    transport: ASM.Examples.ClaudeControlExtensionDemo.Transport
  )

try do
  :ok = Client.await_initialized(client, 1_000)
  :ok = Client.set_permission_mode(client, :plan)

  IO.puts("Started ClaudeAgentSDK.Client through ASM.Extensions.ProviderSDK.Claude.")
  IO.puts("Native control calls still go through ClaudeAgentSDK.Client.* APIs.")
after
  Client.stop(client)
end
