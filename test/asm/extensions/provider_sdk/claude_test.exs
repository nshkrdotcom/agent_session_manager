defmodule ASM.Extensions.ProviderSDK.ClaudeTest do
  use ASM.TestCase

  alias ASM.Extensions.ProviderSDK.Claude
  alias ClaudeAgentSDK.{Client, Hooks, Options}
  alias ClaudeAgentSDK.Hooks.Matcher

  defmodule MockTransport do
    @moduledoc false

    use GenServer

    import Kernel, except: [send: 2]

    @behaviour ClaudeAgentSDK.Transport

    def start(opts), do: GenServer.start(__MODULE__, opts)
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def send(transport, message), do: GenServer.call(transport, {:send, message})
    def subscribe(transport, pid), do: GenServer.call(transport, {:subscribe, pid})
    def close(transport), do: GenServer.stop(transport, :normal)
    def status(transport), do: GenServer.call(transport, :status)

    def push_message(transport, payload) do
      GenServer.cast(transport, {:push_message, payload})
    end

    @impl GenServer
    def init(opts) do
      test_pid = Keyword.get(opts, :test_pid)

      if is_pid(test_pid) do
        Kernel.send(test_pid, {:mock_transport_started, self(), opts})
      end

      {:ok, %{messages: [], status: :connected, subscribers: MapSet.new(), test_pid: test_pid}}
    end

    @impl GenServer
    def handle_call({:send, message}, _from, state) do
      if is_pid(state.test_pid) do
        Kernel.send(state.test_pid, {:mock_transport_send, message})
      end

      {:reply, :ok, %{state | messages: [message | state.messages]}}
    end

    def handle_call({:subscribe, pid}, _from, state) do
      Process.monitor(pid)
      {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
    end

    def handle_call(:status, _from, state) do
      {:reply, state.status, state}
    end

    @impl GenServer
    def handle_cast({:push_message, payload}, state) do
      Enum.each(state.subscribers, fn pid ->
        Kernel.send(pid, {:transport_message, payload})
      end)

      {:noreply, state}
    end

    @impl GenServer
    def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
      {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
    end
  end

  test "sdk_options/2 maps ASM config and keeps Claude-native overrides explicit" do
    hook = fn _input, _tool_use_id, _context -> %{} end

    asm_opts = [
      provider: :claude,
      cwd: "/tmp/asm-claude-extension",
      env: %{"FOO" => "bar"},
      cli_path: "/usr/local/bin/claude",
      permission_mode: :auto,
      model: "sonnet",
      max_turns: 3,
      include_thinking: true,
      transport_timeout_ms: 12_000
    ]

    native_overrides = [
      hooks: %{pre_tool_use: [Matcher.new("Bash", [hook])]},
      enable_file_checkpointing: true
    ]

    assert {:ok, %Options{} = options} = Claude.sdk_options(asm_opts, native_overrides)

    assert options.cwd == "/tmp/asm-claude-extension"
    assert options.env == %{"FOO" => "bar"}
    assert options.path_to_claude_code_executable == "/usr/local/bin/claude"
    assert options.permission_mode == :auto
    assert options.model == "sonnet"
    assert options.max_turns == 3
    assert options.timeout_ms == 12_000
    assert options.thinking == %{type: :adaptive}
    assert options.enable_file_checkpointing == true
    assert options.hooks == %{pre_tool_use: [Matcher.new("Bash", [hook])]}
  end

  test "sdk_options_for_session/3 merges session defaults with ASM overrides" do
    {:ok, session} =
      ASM.start_session(
        provider: :claude,
        cwd: "/tmp/asm-session-defaults",
        permission_mode: :plan,
        model: "haiku",
        max_turns: 2
      )

    on_exit(fn -> safe_stop_session(session) end)

    assert {:ok, %Options{} = options} =
             Claude.sdk_options_for_session(
               session,
               [model: "sonnet"],
               enable_file_checkpointing: true
             )

    assert options.cwd == "/tmp/asm-session-defaults"
    assert options.permission_mode == :plan
    assert options.model == "sonnet"
    assert options.max_turns == 2
    assert options.enable_file_checkpointing == true
  end

  test "start_client/3 starts the SDK-local Claude client without widening ASM APIs" do
    hook = fn _input, _tool_use_id, _context -> Hooks.Output.allow() end

    asm_opts = [
      provider: :claude,
      cwd: "/tmp/asm-client-start",
      permission_mode: :plan,
      model: "sonnet",
      max_turns: 4
    ]

    native_overrides = [
      hooks: %{pre_tool_use: [Matcher.new("Bash", [hook])]},
      enable_file_checkpointing: true
    ]

    assert {:ok, client} =
             Claude.start_client(
               asm_opts,
               native_overrides,
               transport: MockTransport,
               transport_opts: [test_pid: self()]
             )

    on_exit(fn -> safe_stop_client(client) end)

    assert_receive {:mock_transport_started, transport_pid, transport_opts}

    assert %Options{} = Keyword.fetch!(transport_opts, :options)

    assert Keyword.fetch!(transport_opts, :options).cwd == "/tmp/asm-client-start"
    assert Keyword.fetch!(transport_opts, :options).model == "sonnet"
    assert Keyword.fetch!(transport_opts, :options).permission_mode == :plan
    assert Keyword.fetch!(transport_opts, :options).enable_file_checkpointing == true

    assert_receive {:mock_transport_send, init_json}, 1_000
    assert {:ok, request_id} = Client.await_init_sent(client, 1_000)

    decoded = Jason.decode!(init_json)
    assert decoded["type"] == "control_request"
    assert decoded["request_id"] == request_id
    assert decoded["request"]["subtype"] == "initialize"
    assert is_map(decoded["request"]["hooks"])

    MockTransport.push_message(
      transport_pid,
      Jason.encode!(%{
        "type" => "control_response",
        "response" => %{
          "subtype" => "success",
          "request_id" => request_id,
          "response" => %{}
        }
      })
    )

    assert :ok = Client.await_initialized(client, 1_000)
  end

  test "sdk_options/2 rejects non-Claude providers" do
    assert {:error, error} = Claude.sdk_options(provider: :codex)

    assert error.kind == :config_invalid
    assert error.domain == :provider
  end

  defp safe_stop_client(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Client.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp safe_stop_session(session) do
    _ = ASM.stop_session(session)
    :ok
  catch
    :exit, _ -> :ok
  end
end
