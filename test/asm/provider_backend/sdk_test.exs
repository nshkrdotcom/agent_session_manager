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

  defmodule CodexRuntimeStub do
    @moduledoc false

    def start_session(opts) when is_list(opts) do
      metadata = Keyword.get(opts, :metadata, %{})

      if is_pid(metadata[:test_pid]) do
        send(metadata[:test_pid], {:codex_runtime_start_opts, opts})
      end

      session =
        spawn_link(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, session, %{runtime: :codex_stub}}
    end

    def send_input(_session, _input, _opts), do: :ok
    def end_input(_session), do: :ok
    def interrupt(_session), do: :ok
    def subscribe(_session, _pid, _ref), do: :ok
    def info(_session), do: %{runtime: :codex_stub}
    def capabilities, do: [:streaming]

    def close(session) when is_pid(session) do
      send(session, :stop)
      :ok
    end
  end

  defmodule AmpRuntimeStub do
    @moduledoc false

    def start_session(opts) when is_list(opts) do
      metadata = Keyword.get(opts, :metadata, %{})

      if is_pid(metadata[:test_pid]) do
        send(metadata[:test_pid], {:amp_runtime_start_opts, opts})
      end

      session =
        spawn_link(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, session, %{runtime: :amp_stub}}
    end

    def send_input(_session, _input, _opts), do: :ok
    def end_input(_session), do: :ok
    def interrupt(_session), do: :ok
    def subscribe(_session, _pid, _ref), do: :ok
    def info(_session), do: %{runtime: :amp_stub}
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

  test "codex sdk backend propagates payload-derived oss settings into thread options" do
    provider = %{Provider.resolve!(:codex) | sdk_runtime: CodexRuntimeStub}

    config = %{
      provider: provider,
      prompt: "hello",
      execution_config: %Execution.Config{
        execution_mode: :local,
        transport_call_timeout_ms: 5_000
      },
      provider_opts: [
        model: "gpt-5.4",
        reasoning_effort: :high,
        provider_backend: :model_provider,
        model_provider: "gateway"
      ],
      metadata: %{test_pid: self()}
    }

    assert {:ok, proxy, info} = SDK.start_run(config)
    on_exit(fn -> SDK.close(proxy) end)

    assert info.lane == :sdk
    assert info.provider == :codex

    assert_receive {:codex_runtime_start_opts, start_opts}

    assert %Codex.Exec.Options{} = exec_opts = Keyword.fetch!(start_opts, :exec_opts)
    assert %Codex.Options{} = exec_opts.codex_opts
    assert %Codex.Thread.Options{} = exec_opts.thread
    assert exec_opts.thread.model_provider == "gateway"
    assert exec_opts.thread.oss == false
    assert exec_opts.thread.local_provider == nil

    metadata = Keyword.fetch!(start_opts, :metadata)
    assert metadata[:lane] == :sdk
    assert metadata[:asm_provider] == :codex
  end

  test "amp sdk backend maps ASM bypass mode to dangerously_allow_all and keeps safe defaults" do
    provider = %{Provider.resolve!(:amp) | sdk_runtime: AmpRuntimeStub}

    config = %{
      provider: provider,
      prompt: "hello",
      execution_config: %Execution.Config{
        execution_mode: :local,
        transport_call_timeout_ms: 5_000
      },
      provider_opts: [
        model: "amp-1",
        permission_mode: :bypass,
        provider_permission_mode: :dangerously_allow_all
      ],
      metadata: %{test_pid: self()}
    }

    assert {:ok, proxy, info} = SDK.start_run(config)
    on_exit(fn -> SDK.close(proxy) end)

    assert info.lane == :sdk
    assert info.provider == :amp

    assert_receive {:amp_runtime_start_opts, start_opts}

    assert %AmpSdk.Types.Options{} = options = Keyword.fetch!(start_opts, :options)
    assert options.dangerously_allow_all == true
    assert options.no_ide == true
    assert options.no_notifications == true

    metadata = Keyword.fetch!(start_opts, :metadata)
    assert metadata[:lane] == :sdk
    assert metadata[:asm_provider] == :amp
  end
end
