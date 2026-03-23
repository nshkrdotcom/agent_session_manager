defmodule ASM.ProviderBackend.SDKTest do
  use ASM.TestCase

  alias ASM.{Execution, Provider}
  alias ASM.ProviderBackend.SDK

  defmodule ClaudeRuntimeStub do
    @moduledoc false

    def start_session(opts) when is_list(opts) do
      metadata = Keyword.get(opts, :metadata, %{})

      if is_pid(metadata[:test_pid]) do
        send(metadata[:test_pid], {:claude_runtime_start_opts, opts})
      end

      session =
        spawn_link(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, session, %{runtime: :claude_stub}}
    end

    def send_input(_session, _input, _opts), do: :ok
    def end_input(_session), do: :ok
    def interrupt(_session), do: :ok
    def subscribe(_session, _pid, _ref), do: :ok
    def info(_session), do: %{runtime: :claude_stub}
    def capabilities, do: [:streaming]

    def close(session) when is_pid(session) do
      send(session, :stop)
      :ok
    end
  end

  test "claude sdk backend forwards stderr buffer size as a runtime option" do
    provider = %{Provider.resolve!(:claude) | sdk_runtime: ClaudeRuntimeStub}

    config = %{
      provider: provider,
      prompt: "hello",
      execution_config: %Execution.Config{
        execution_mode: :local,
        transport_call_timeout_ms: 5_000
      },
      provider_opts: [max_stderr_buffer_bytes: 2048],
      metadata: %{test_pid: self()}
    }

    assert {:ok, proxy, info} = SDK.start_run(config)
    on_exit(fn -> SDK.close(proxy) end)

    assert info.lane == :sdk
    assert info.provider == :claude

    assert_receive {:claude_runtime_start_opts, start_opts}

    assert Keyword.get(start_opts, :max_stderr_buffer_size) == 2048
    assert %ClaudeAgentSDK.Options{} = Keyword.fetch!(start_opts, :options)

    metadata = Keyword.fetch!(start_opts, :metadata)
    assert metadata[:lane] == :sdk
    assert metadata[:asm_provider] == :claude
  end
end
