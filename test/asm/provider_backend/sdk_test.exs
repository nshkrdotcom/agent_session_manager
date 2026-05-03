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

  defmodule CodexAppServerStub do
    @moduledoc false

    def connect(options, connect_opts) when is_list(connect_opts) do
      if pid = Keyword.get(connect_opts, :test_pid) do
        send(pid, {:codex_app_server_options, options})
        send(pid, {:codex_app_server_connect_opts, connect_opts})
      end

      conn =
        spawn_link(fn ->
          receive do
            :disconnect -> :ok
          end
        end)

      {:ok, conn}
    end

    def respond(conn, request_id, response) when is_pid(conn) do
      send(conn, {:dynamic_tool_response, request_id, response})
      :ok
    end

    def disconnect(conn) when is_pid(conn) do
      send(conn, :disconnect)
      :ok
    end
  end

  defmodule CodexThreadRunnerStub do
    @moduledoc false

    def run_streamed(thread, prompt, opts) do
      send(opts[:test_pid], {:codex_app_server_run_streamed, thread, prompt, opts})

      {:ok,
       [
         %Codex.Events.TurnStarted{thread_id: "thread-app-1", turn_id: "turn-1"},
         %Codex.Events.DynamicToolCallRequested{
           id: "jsonrpc-1",
           thread_id: "thread-app-1",
           turn_id: "turn-1",
           call_id: "call-1",
           tool_name: "echo_json",
           arguments: %{"message" => "hello"}
         },
         %Codex.Events.ItemAgentMessageDelta{
           thread_id: "thread-app-1",
           turn_id: "turn-1",
           item: %{"text" => "done"}
         },
         %Codex.Events.TurnCompleted{
           thread_id: "thread-app-1",
           turn_id: "turn-1",
           status: "completed",
           final_response: %Codex.Items.AgentMessage{text: "done"}
         }
       ]}
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

  test "codex sdk backend applies governed materialized runtime without ambient auth" do
    saved_env = capture_codex_env()
    clear_codex_env()
    on_exit(fn -> restore_env(saved_env) end)

    provider = %{Provider.resolve!(:codex) | sdk_runtime: CodexRuntimeStub}

    config = %{
      provider: provider,
      prompt: "hello",
      execution_config: execution_config([]),
      provider_opts: [model: "gpt-5.4"],
      codex_materialized_runtime: materialized_codex_runtime(),
      metadata: Map.put(governed_runtime_metadata(), :test_pid, self())
    }

    assert {:ok, proxy, info} = SDK.start_run(config)
    on_exit(fn -> SDK.close(proxy) end)

    assert info.lane == :sdk
    assert info.provider == :codex

    assert_receive {:codex_runtime_start_opts, start_opts}

    assert %Codex.Exec.Options{} = exec_opts = Keyword.fetch!(start_opts, :exec_opts)
    assert exec_opts.codex_opts.codex_path_override == "/materialized/bin/codex"
    assert exec_opts.codex_opts.api_key == nil
    assert exec_opts.thread.thread_opts.working_directory == "/workspace/project"
    assert exec_opts.env == %{"CODEX_HOME" => "/materialized/codex-home"}
    assert exec_opts.clear_env? == true

    metadata = Keyword.fetch!(start_opts, :metadata)
    assert metadata[:codex_materialization].env_keys == ["CODEX_HOME"]
    assert metadata[:codex_materialization].command == :redacted_materialized_command
    refute inspect(metadata[:codex_materialization]) =~ "/materialized/bin/codex"
  end

  test "codex sdk backend rejects governed provider auth option smuggling" do
    saved_env = capture_codex_env()
    clear_codex_env()
    on_exit(fn -> restore_env(saved_env) end)

    provider = %{Provider.resolve!(:codex) | sdk_runtime: CodexRuntimeStub}

    config = %{
      provider: provider,
      prompt: "hello",
      execution_config: execution_config([]),
      provider_opts: [model: "gpt-5.4", env: %{"CODEX_API_KEY" => "secret"}],
      codex_materialized_runtime: materialized_codex_runtime(),
      metadata: governed_runtime_metadata()
    }

    assert {:error, error} = SDK.start_run(config)
    assert error.kind == :config_invalid
    assert error.message =~ "governed Codex strict mode rejects"
  end

  test "codex app-server backend applies governed materialized launch context" do
    saved_env = capture_codex_env()
    clear_codex_env()
    on_exit(fn -> restore_env(saved_env) end)

    provider = %{Provider.resolve!(:codex) | sdk_runtime: CodexRuntimeStub}

    config = %{
      provider: provider,
      prompt: "use app-server",
      execution_config: execution_config([]),
      provider_opts: [app_server: true, model: "gpt-5.4"],
      backend_opts: [
        codex_app_server_module: CodexAppServerStub,
        codex_thread_runner_module: CodexThreadRunnerStub,
        connect_opts: [test_pid: self()],
        run_opts: [test_pid: self()]
      ],
      codex_materialized_runtime: materialized_codex_runtime(),
      metadata: Map.put(governed_runtime_metadata(), :test_pid, self())
    }

    assert {:ok, session, info} = SDK.start_run(config)
    on_exit(fn -> SDK.close(session) end)

    assert info.lane == :sdk
    assert info.provider == :codex
    assert info.runtime == ASM.ProviderBackend.SDK.CodexAppServer

    assert_receive {:codex_app_server_options, codex_opts}
    assert codex_opts.codex_path_override == "/materialized/bin/codex"
    assert codex_opts.api_key == nil

    assert_receive {:codex_app_server_connect_opts, connect_opts}
    assert connect_opts[:cwd] == "/workspace/project"
    assert connect_opts[:process_env] == %{"CODEX_HOME" => "/materialized/codex-home"}
    assert connect_opts[:clear_env?] == true
    assert connect_opts[:codex_home] == "/materialized/codex-home"
    assert connect_opts[:experimental_api] == true

    assert_receive {:codex_app_server_run_streamed, thread, "use app-server", run_opts}
    assert run_opts[:test_pid] == self()
    assert thread.thread_opts.working_directory == "/workspace/project"
  end

  test "codex sdk backend selects app-server runtime when host dynamic tools are requested" do
    provider = %{Provider.resolve!(:codex) | sdk_runtime: CodexRuntimeStub}
    subscription_ref = make_ref()

    host_tools = [
      %{
        name: "echo_json",
        description: "Echo JSON arguments",
        input_schema: %{
          "type" => "object",
          "properties" => %{"message" => %{"type" => "string"}},
          "required" => ["message"]
        }
      }
    ]

    config = %{
      provider: provider,
      prompt: "use echo_json",
      execution_config: execution_config([]),
      provider_opts: [
        app_server: true,
        host_tools: host_tools,
        system_prompt: "Use dynamic tools when requested."
      ],
      backend_opts: [
        codex_app_server_module: CodexAppServerStub,
        codex_thread_runner_module: CodexThreadRunnerStub,
        connect_opts: [test_pid: self()],
        run_opts: [test_pid: self()]
      ],
      tools: %{
        "echo_json" => fn args -> {:ok, %{"echo" => args}} end
      },
      subscriber_pid: self(),
      subscription_ref: subscription_ref,
      metadata: %{test_pid: self()}
    }

    assert {:ok, session, info} = SDK.start_run(config)
    on_exit(fn -> SDK.close(session) end)

    assert info.lane == :sdk
    assert info.provider == :codex
    assert info.runtime == ASM.ProviderBackend.SDK.CodexAppServer
    assert :app_server in info.capabilities
    assert :host_tools in info.capabilities

    assert_receive {:codex_app_server_connect_opts, connect_opts}
    assert connect_opts[:experimental_api] == true

    assert_receive {:codex_app_server_run_streamed, thread, "use echo_json", run_opts}
    assert run_opts[:test_pid] == self()
    assert %Codex.Thread.Options{} = thread.thread_opts
    assert {:app_server, conn} = thread.thread_opts.transport
    assert is_pid(conn)
    assert [%{"name" => "echo_json"}] = thread.thread_opts.dynamic_tools

    assert_receive %ASM.ProviderBackend.Event{
      subscription_ref: ^subscription_ref,
      asm_event: %ASM.Event{
        kind: :host_tool_requested,
        payload: %ASM.HostTool.Request{
          id: "jsonrpc-1",
          provider_session_id: "thread-app-1",
          provider_turn_id: "turn-1",
          tool_name: "echo_json",
          arguments: %{"message" => "hello"}
        }
      }
    }

    assert_receive %ASM.ProviderBackend.Event{
      subscription_ref: ^subscription_ref,
      asm_event: %ASM.Event{
        kind: :host_tool_completed,
        payload: %ASM.HostTool.Response{request_id: "jsonrpc-1", success?: true}
      }
    }

    assert_receive %ASM.ProviderBackend.Event{
      subscription_ref: ^subscription_ref,
      core_event: %CliSubprocessCore.Event{kind: :assistant_delta}
    }

    assert_receive %ASM.ProviderBackend.Event{
      subscription_ref: ^subscription_ref,
      core_event: %CliSubprocessCore.Event{kind: :result, provider_session_id: "thread-app-1"}
    }

    refute_receive %ASM.ProviderBackend.Event{
                     subscription_ref: ^subscription_ref,
                     core_event: %CliSubprocessCore.Event{kind: :assistant_message}
                   },
                   50
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
      provider_opts: [model: "gemini-3.1-flash-lite-preview", system_prompt: "Be brief."],
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
        model: "gemini-3.1-flash-lite-preview",
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

  test "non-codex governed sdk backends reject unmanaged ambient provider auth env" do
    for {provider_name, runtime, env_key, model} <- [
          {:claude, ClaudeRuntimeStub, "ANTHROPIC_API_KEY", "sonnet"},
          {:gemini, GeminiRuntimeStub, "GEMINI_API_KEY", "gemini-3.1-flash-lite-preview"},
          {:amp, AmpRuntimeStub, "AMP_API_KEY", "amp-1"}
        ] do
      with_env(provider_env(env_key, "ambient-secret"), fn ->
        provider = %{Provider.resolve!(provider_name) | sdk_runtime: runtime}

        config = %{
          provider: provider,
          prompt: "hello",
          provider_opts: [model: model],
          execution_config: execution_config([]),
          metadata: governed_runtime_metadata(provider_name)
        }

        assert {:error, error} = SDK.start_run(config)
        assert error.kind == :config_invalid
        assert error.message =~ "rejects unmanaged ambient provider auth environment"
        assert error.cause.env_keys == [env_key]
      end)
    end
  end

  test "non-codex governed sdk backends reject env and command override smuggling" do
    provider = %{Provider.resolve!(:claude) | sdk_runtime: ClaudeRuntimeStub}

    config = %{
      provider: provider,
      prompt: "hello",
      provider_opts: [
        model: "sonnet",
        env: %{"ANTHROPIC_API_KEY" => "secret"},
        cli_path: "/tmp/claude"
      ],
      execution_config: execution_config([]),
      metadata: governed_runtime_metadata(:claude)
    }

    assert {:error, error} = SDK.start_run(config)
    assert error.kind == :config_invalid
    assert error.message =~ "rejects provider auth"
    assert :env in error.cause.keys
    assert :cli_path in error.cause.keys
  end

  test "non-codex governed sdk backends fail closed without provider materialization" do
    provider = %{Provider.resolve!(:gemini) | sdk_runtime: GeminiRuntimeStub}

    with_env(provider_env(), fn ->
      config = %{
        provider: provider,
        prompt: "hello",
        provider_opts: [model: "gemini-3.1-flash-lite-preview"],
        execution_config: execution_config([]),
        metadata: governed_runtime_metadata(:gemini)
      }

      assert {:error, error} = SDK.start_run(config)
      assert error.kind == :config_invalid
      assert error.message =~ "requires verified provider-auth materialization"
      assert error.message =~ "standalone env"
    end)
  end

  defp governed_runtime_metadata do
    "sdk-governed-runtime"
    |> ASM.RuntimeAuth.new!(:codex,
      runtime_auth_mode: :governed,
      runtime_auth_scope: :governed,
      execution_context_ref: "asm-execution-context://governed/sdk",
      connector_instance_ref: "jido-connector-instance://codex/sdk-instance",
      connector_binding_ref: "jido-connector-binding://codex/sdk-binding",
      provider_account_ref: "provider-account://codex/sdk-account",
      authority_ref: "citadel-authority://decision/sdk",
      credential_lease_ref: "jido-credential-lease://lease/sdk",
      native_auth_assertion_ref: "codex-native-auth://assertion/sdk"
    )
    |> ASM.RuntimeAuth.to_metadata()
  end

  defp governed_runtime_metadata(provider) when is_atom(provider) do
    "sdk-governed-runtime-#{provider}"
    |> ASM.RuntimeAuth.new!(provider,
      runtime_auth_mode: :governed,
      runtime_auth_scope: :governed,
      execution_context_ref: "asm-execution-context://governed/sdk-#{provider}",
      connector_instance_ref: "jido-connector-instance://#{provider}/sdk-instance",
      connector_binding_ref: "jido-connector-binding://#{provider}/sdk-binding",
      provider_account_ref: "provider-account://#{provider}/sdk-account",
      authority_ref: "citadel-authority://decision/sdk-#{provider}",
      credential_lease_ref: "jido-credential-lease://lease/sdk-#{provider}",
      native_auth_assertion_ref: "native-auth://assertion/sdk-#{provider}"
    )
    |> ASM.RuntimeAuth.to_metadata()
  end

  defp materialized_codex_runtime do
    %{
      source: :verified_materializer,
      command: "/materialized/bin/codex",
      cwd: "/workspace/project",
      config_root: "/materialized/codex-home",
      env: %{"CODEX_HOME" => "/materialized/codex-home"},
      clear_env?: true,
      target_auth_posture: :materialize_on_attach,
      native_auth_assertion: %{
        introspection_level: :auth_file_metadata,
        limits: %{secrets: :redacted, token_values: :not_read},
        redacted?: true
      }
    }
  end

  defp capture_codex_env do
    Map.new(codex_env_keys(), &{&1, System.get_env(&1)})
  end

  defp clear_codex_env do
    Enum.each(codex_env_keys(), &System.delete_env/1)
  end

  defp restore_env(saved) do
    Enum.each(saved, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp with_env(env, fun) when is_map(env) and is_function(fun, 0) do
    saved = Map.new(env, fn {key, _value} -> {key, System.get_env(key)} end)

    try do
      Enum.each(env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      fun.()
    after
      restore_env(saved)
    end
  end

  defp provider_env(key \\ nil, value \\ nil) do
    [
      "ANTHROPIC_API_KEY",
      "ANTHROPIC_AUTH_TOKEN",
      "ANTHROPIC_BASE_URL",
      "ASM_AMP_MODEL",
      "ASM_CLAUDE_MODEL",
      "ASM_GEMINI_MODEL",
      "CLAUDE_CLI_PATH",
      "CLAUDE_CODE_OAUTH_TOKEN",
      "CLAUDE_CONFIG_DIR",
      "CLAUDE_HOME",
      "CLAUDE_MODEL",
      "GEMINI_API_KEY",
      "GEMINI_CLI_CONFIG_HOME",
      "GEMINI_CLI_PATH",
      "GEMINI_MODEL",
      "GOOGLE_API_KEY",
      "GOOGLE_APPLICATION_CREDENTIALS",
      "AMP_API_KEY",
      "AMP_AUTH_TOKEN",
      "AMP_BASE_URL",
      "AMP_CLI_PATH",
      "AMP_HOME",
      "AMP_MODEL"
    ]
    |> Map.new(&{&1, nil})
    |> maybe_put_env(key, value)
  end

  defp maybe_put_env(env, nil, _value), do: env
  defp maybe_put_env(env, key, value), do: Map.put(env, key, value)

  defp codex_env_keys do
    ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_HOME", "OPENAI_BASE_URL"]
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
