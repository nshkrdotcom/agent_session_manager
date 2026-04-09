defmodule ASM.ProviderBackend.SDKTest do
  use ASM.TestCase

  alias ASM.{Execution, Provider}
  alias ASM.Execution.Environment
  alias ASM.ProviderBackend.SDK
  alias CliSubprocessCore.ExecutionSurface

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

  defmodule GeminiRuntimeStub do
    @moduledoc false

    def start_session(opts) when is_list(opts) do
      metadata = Keyword.get(opts, :metadata, %{})

      if is_pid(metadata[:test_pid]) do
        send(metadata[:test_pid], {:gemini_runtime_start_opts, opts})
      end

      session =
        spawn_link(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, session, %{runtime: :gemini_stub}}
    end

    def send_input(_session, _input, _opts), do: :ok
    def end_input(_session), do: :ok
    def interrupt(_session), do: :ok
    def subscribe(_session, _pid, _ref), do: :ok
    def info(_session), do: %{runtime: :gemini_stub}
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
      execution_config:
        execution_config(
          surface_kind: :ssh_exec,
          transport_options: [destination: "claude.sdk.example", port: 2222],
          target_id: "claude-target-1",
          observability: %{suite: :sdk}
        ),
      continuation: %{strategy: :latest},
      provider_opts: [
        max_stderr_buffer_bytes: 2048,
        system_prompt: %{type: :preset, preset: :claude_code, append: "Stay concise."},
        append_system_prompt: "Include exact file paths."
      ],
      metadata: %{test_pid: self()}
    }

    assert {:ok, proxy, info} = SDK.start_run(config)
    on_exit(fn -> SDK.close(proxy) end)

    assert info.lane == :sdk
    assert info.provider == :claude

    assert_receive {:claude_runtime_start_opts, start_opts}

    assert Keyword.get(start_opts, :max_stderr_buffer_size) == 2048
    assert %ClaudeAgentSDK.Options{} = Keyword.fetch!(start_opts, :options)

    assert %CliSubprocessCore.ExecutionSurface{} =
             execution_surface = Keyword.fetch!(start_opts, :execution_surface)

    assert execution_surface.surface_kind == :ssh_exec
    assert execution_surface.transport_options[:destination] == "claude.sdk.example"
    assert execution_surface.target_id == "claude-target-1"
    assert execution_surface.observability == %{suite: :sdk}
    assert Keyword.fetch!(start_opts, :options).execution_surface == execution_surface
    assert Keyword.fetch!(start_opts, :options).continue_conversation == true
    assert Keyword.fetch!(start_opts, :options).resume == nil

    assert Keyword.fetch!(start_opts, :options).system_prompt == %{
             type: :preset,
             preset: :claude_code,
             append: "Stay concise."
           }

    assert Keyword.fetch!(start_opts, :options).append_system_prompt ==
             "Include exact file paths."

    metadata = Keyword.fetch!(start_opts, :metadata)
    assert metadata[:lane] == :sdk
    assert metadata[:asm_provider] == :claude
  end

  test "codex sdk backend propagates payload-derived oss settings into thread options" do
    provider = %{Provider.resolve!(:codex) | sdk_runtime: CodexRuntimeStub}

    config = %{
      provider: provider,
      prompt: "hello",
      execution_config:
        execution_config(
          surface_kind: :ssh_exec,
          transport_options: [destination: "codex.sdk.example"],
          lease_ref: "lease-123"
        ),
      continuation: %{strategy: :exact, provider_session_id: "codex-thread-123"},
      provider_opts: [
        model: "gpt-5.4",
        system_prompt: "Stay inside the repo instructions.",
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
    assert %Codex.Thread{} = exec_opts.thread
    assert %Codex.Thread.Options{} = exec_opts.thread.thread_opts

    assert %CliSubprocessCore.ExecutionSurface{} =
             execution_surface = Keyword.fetch!(start_opts, :execution_surface)

    assert execution_surface.surface_kind == :ssh_exec
    assert execution_surface.transport_options[:destination] == "codex.sdk.example"
    assert execution_surface.lease_ref == "lease-123"
    assert exec_opts.execution_surface == execution_surface
    assert exec_opts.codex_opts.execution_surface == execution_surface
    assert exec_opts.thread.thread_id == "codex-thread-123"
    assert exec_opts.thread.resume == nil
    assert exec_opts.thread.thread_opts.model_provider == "gateway"
    assert exec_opts.thread.thread_opts.oss == false
    assert exec_opts.thread.thread_opts.local_provider == nil
    assert exec_opts.thread.thread_opts.base_instructions == "Stay inside the repo instructions."

    metadata = Keyword.fetch!(start_opts, :metadata)
    assert metadata[:lane] == :sdk
    assert metadata[:asm_provider] == :codex
  end

  test "amp sdk backend maps ASM bypass mode to dangerously_allow_all and keeps safe defaults" do
    provider = %{Provider.resolve!(:amp) | sdk_runtime: AmpRuntimeStub}

    config = %{
      provider: provider,
      prompt: "hello",
      execution_config:
        execution_config(
          surface_kind: :ssh_exec,
          transport_options: [destination: "amp.sdk.example"],
          boundary_class: :workspace
        ),
      continuation: %{strategy: :latest},
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

    assert %CliSubprocessCore.ExecutionSurface{} =
             execution_surface = Keyword.fetch!(start_opts, :execution_surface)

    assert execution_surface.surface_kind == :ssh_exec
    assert execution_surface.transport_options[:destination] == "amp.sdk.example"
    assert execution_surface.boundary_class == :workspace
    assert options.execution_surface == execution_surface
    assert options.continue_thread == true
    assert options.dangerously_allow_all == true
    assert options.no_ide == true
    assert options.no_notifications == true

    metadata = Keyword.fetch!(start_opts, :metadata)
    assert metadata[:lane] == :sdk
    assert metadata[:asm_provider] == :amp
  end

  test "gemini sdk backend propagates execution surface into the runtime options" do
    provider = %{Provider.resolve!(:gemini) | sdk_runtime: GeminiRuntimeStub}

    config = %{
      provider: provider,
      prompt: "hello",
      execution_config:
        execution_config(
          surface_kind: :ssh_exec,
          transport_options: [destination: "gemini.sdk.example"],
          surface_ref: "surface-9"
        ),
      continuation: %{strategy: :exact, provider_session_id: "gemini-session-123"},
      provider_opts: [model: "gemini-2.5-pro", system_prompt: "Be brief."],
      metadata: %{test_pid: self()}
    }

    assert {:ok, proxy, info} = SDK.start_run(config)
    on_exit(fn -> SDK.close(proxy) end)

    assert info.lane == :sdk
    assert info.provider == :gemini

    assert_receive {:gemini_runtime_start_opts, start_opts}

    assert %GeminiCliSdk.Options{} = options = Keyword.fetch!(start_opts, :options)

    assert %CliSubprocessCore.ExecutionSurface{} =
             execution_surface = Keyword.fetch!(start_opts, :execution_surface)

    assert execution_surface.surface_kind == :ssh_exec
    assert execution_surface.transport_options[:destination] == "gemini.sdk.example"
    assert execution_surface.surface_ref == "surface-9"
    assert options.system_prompt == "Be brief."
    assert options.execution_surface == execution_surface
    assert options.resume == "gemini-session-123"
    assert Keyword.fetch!(start_opts, :prompt) == "hello"

    metadata = Keyword.fetch!(start_opts, :metadata)
    assert metadata[:lane] == :sdk
    assert metadata[:asm_provider] == :gemini
  end

  test "gemini sdk backend maps ASM bypass mode onto approval_mode without legacy yolo duplication" do
    provider = %{Provider.resolve!(:gemini) | sdk_runtime: GeminiRuntimeStub}

    config = %{
      provider: provider,
      prompt: "hello",
      execution_config: execution_config([]),
      provider_opts: [
        model: "gemini-2.5-pro",
        permission_mode: :bypass,
        provider_permission_mode: :yolo
      ],
      metadata: %{test_pid: self()}
    }

    assert {:ok, proxy, info} = SDK.start_run(config)
    on_exit(fn -> SDK.close(proxy) end)

    assert info.lane == :sdk
    assert info.provider == :gemini

    assert_receive {:gemini_runtime_start_opts, start_opts}

    assert %GeminiCliSdk.Options{} = options = Keyword.fetch!(start_opts, :options)
    assert options.approval_mode == :yolo
    assert options.yolo == false
  end

  test "sdk backends reject explicit approval_posture :none before runtime start" do
    provider = %{Provider.resolve!(:claude) | sdk_runtime: ClaudeRuntimeStub}

    config = %{
      provider: provider,
      prompt: "hello",
      provider_opts: [model: "sonnet"],
      execution_config: execution_config([], approval_posture: :none)
    }

    assert {:error, error} = SDK.start_run(config)
    assert error.kind == :config_invalid
    assert error.domain == :config
    assert error.message =~ "approval_posture"
    assert error.message =~ ":none"
  end

  defp execution_config(surface_attrs) when is_list(surface_attrs) do
    execution_config(surface_attrs, [], [])
  end

  defp execution_config(surface_attrs, environment_attrs)
       when is_list(surface_attrs) and is_list(environment_attrs) do
    execution_config(surface_attrs, environment_attrs, [])
  end

  defp execution_config(surface_attrs, environment_attrs, attrs)
       when is_list(surface_attrs) and is_list(environment_attrs) and is_list(attrs) do
    {:ok, execution_surface} = ExecutionSurface.new(surface_attrs)
    {:ok, execution_environment} = Environment.new(environment_attrs)

    struct!(Execution.Config,
      execution_mode: Keyword.get(attrs, :execution_mode, :local),
      transport_call_timeout_ms: Keyword.get(attrs, :transport_call_timeout_ms, 5_000),
      execution_surface: execution_surface,
      execution_environment: execution_environment,
      provider_permission_mode: Keyword.get(attrs, :provider_permission_mode),
      remote: Keyword.get(attrs, :remote)
    )
  end
end
