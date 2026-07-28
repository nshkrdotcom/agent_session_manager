defmodule ASM.Extensions.ProviderSDK.CodexTest do
  use ASM.TestCase

  alias ASM.Extensions.ProviderSDK.Codex, as: CodexExtension
  alias ASM.Options.ProviderNativeOptionError
  alias CliSubprocessCore.ModelRegistry.Selection
  alias Codex.AppServer
  alias Codex.{Options, Thread}
  alias Codex.Thread.Options, as: ThreadOptions

  test "derive_options/2 maps strict common ASM config and keeps Codex-native overrides explicit" do
    assert {:ok, %Options{} = options} =
             CodexExtension.derive_options(
               [
                 cli_path: "/usr/local/bin/codex",
                 model: "gpt-5.4",
                 execution_surface: [
                   surface_kind: :ssh_exec,
                   transport_options: [destination: "codex.strict-extension.example"]
                 ]
               ],
               native_overrides: [model_personality: :pragmatic, reasoning_effort: :high]
             )

    assert options.codex_path_override == "/usr/local/bin/codex"
    assert options.model == "gpt-5.4"
    assert options.execution_surface.surface_kind == :ssh_exec

    assert options.execution_surface.transport_options[:destination] ==
             "codex.strict-extension.example"

    assert options.model_personality == :pragmatic
    assert options.reasoning_effort == :high
  end

  test "derive_options/2 rejects Codex-native settings in generic ASM input" do
    assert {:error, %ProviderNativeOptionError{} = error} =
             CodexExtension.derive_options(model: "gpt-5.4", output_schema: %{"type" => "object"})

    assert error.key == :output_schema
    assert error.provider == :codex
  end

  test "codex_options/2 maps ASM config and keeps Codex-native overrides explicit" do
    asm_opts = [
      provider: :codex,
      cli_path: "/usr/local/bin/codex",
      model: "gpt-5.4",
      reasoning_effort: :high,
      execution_surface: [
        surface_kind: :ssh_exec,
        transport_options: [destination: "codex.options.example", port: 2222]
      ]
    ]

    native_overrides = [
      model_personality: :pragmatic,
      hide_agent_reasoning: true
    ]

    assert {:ok, %Options{} = options} =
             CodexExtension.codex_options(asm_opts, native_overrides)

    assert options.codex_path_override == "/usr/local/bin/codex"
    assert options.model == "gpt-5.4"
    assert options.reasoning_effort == :high
    assert options.execution_surface.surface_kind == :ssh_exec
    assert options.execution_surface.transport_options[:destination] == "codex.options.example"
    assert options.model_personality == :pragmatic
    assert options.hide_agent_reasoning == true
  end

  test "codex bridge accepts ASM's canonicalized :codex_exec provider alias" do
    assert {:ok, %Options{} = options} =
             CodexExtension.codex_options(provider: :codex_exec, model: "gpt-5.4")

    assert options.model == "gpt-5.4"
  end

  test "thread_options/2 maps ASM config and keeps Codex-native thread overrides explicit" do
    asm_opts = [
      provider: :codex,
      cwd: "/tmp/asm-codex-thread",
      additional_directories: ["/tmp/asm-codex-thread/docs", "/tmp/asm-codex-thread/test"],
      permission_mode: :bypass,
      skip_git_repo_check: true,
      approval_timeout_ms: 45_000,
      output_schema: %{"type" => "object"}
    ]

    native_overrides = [
      personality: :pragmatic,
      collaboration_mode: %{mode: :plan}
    ]

    assert {:ok, %ThreadOptions{} = options} =
             CodexExtension.thread_options(asm_opts, native_overrides)

    assert options.working_directory == "/tmp/asm-codex-thread"

    assert options.additional_directories == [
             "/tmp/asm-codex-thread/docs",
             "/tmp/asm-codex-thread/test"
           ]

    assert options.approval_timeout_ms == 45_000
    assert options.full_auto == false
    assert options.dangerously_bypass_approvals_and_sandbox == true
    assert options.skip_git_repo_check == true
    assert options.output_schema == %{"type" => "object"}
    assert options.personality == :pragmatic

    assert options.collaboration_mode == %Codex.Protocol.CollaborationMode{
             mode: :plan,
             model: nil,
             reasoning_effort: nil,
             developer_instructions: nil
           }
  end

  test "thread_options/2 maps ASM normalized auto mode to sandboxed Codex automation" do
    assert {:ok, %ThreadOptions{} = options} =
             CodexExtension.thread_options(
               provider: :codex,
               cwd: "/tmp/asm-codex-thread",
               permission_mode: :auto
             )

    assert options.full_auto == true
    assert options.ask_for_approval == :never
    assert options.sandbox == :workspace_write
    assert options.dangerously_bypass_approvals_and_sandbox == false
  end

  test "Codex bridges accept the ASM common Ollama surface" do
    model_payload =
      Selection.new(%{
        provider: :codex,
        requested_model: "llama3.2",
        resolved_model: "llama3.2",
        resolution_source: :explicit,
        reasoning: "high",
        reasoning_effort: nil,
        normalized_reasoning_effort: nil,
        model_family: "llama",
        catalog_version: nil,
        visibility: :public,
        provider_backend: :oss,
        model_source: :external,
        env_overrides: %{"CODEX_OSS_BASE_URL" => "http://127.0.0.1:11434/v1"},
        settings_patch: %{},
        backend_metadata: %{
          "provider_backend" => "oss",
          "oss_provider" => "ollama",
          "external_model" => "llama3.2",
          "support_tier" => "runtime_validated_only"
        },
        errors: []
      })

    asm_opts = [
      provider: :codex,
      ollama: true,
      ollama_model: "llama3.2",
      ollama_base_url: "http://127.0.0.1:11434",
      model_payload: model_payload,
      permission_mode: :bypass
    ]

    assert {:ok, %Options{} = codex_options} = CodexExtension.codex_options(asm_opts)
    assert {:ok, %ThreadOptions{} = thread_options} = CodexExtension.thread_options(asm_opts)

    assert codex_options.model == "llama3.2"
    assert codex_options.model_payload.provider_backend == :oss
    assert codex_options.reasoning_effort == :high
    assert codex_options.model_payload.backend_metadata["oss_provider"] == "ollama"

    assert codex_options.model_payload.backend_metadata["support_tier"] ==
             "runtime_validated_only"

    assert thread_options.oss == true
    assert thread_options.local_provider == "ollama"
    assert thread_options.model_provider == nil
    assert thread_options.dangerously_bypass_approvals_and_sandbox == true
  end

  test "thread_options/2 propagates payload-derived model providers" do
    asm_opts = [
      provider: :codex,
      provider_backend: :model_provider,
      model_provider: "gateway",
      model: "gpt-5.4"
    ]

    assert {:ok, %ThreadOptions{} = options} = CodexExtension.thread_options(asm_opts)

    assert options.model_provider == "gateway"
    assert options.oss == false
    assert options.local_provider == nil
  end

  test "session-based helpers merge ASM session defaults with explicit overrides" do
    {:ok, session} =
      ASM.start_session(
        provider: :codex,
        workspace_root: "/tmp/asm-codex-session",
        permission_mode: :bypass,
        approval_timeout_ms: 10_000,
        model: "gpt-5.4",
        reasoning_effort: :medium,
        execution_surface: [
          surface_kind: :ssh_exec,
          transport_options: [destination: "codex.session.example"],
          observability: %{suite: :provider_sdk}
        ],
        allowed_tools: ["search"],
        session_id: "asm-codex-session-defaults"
      )

    on_exit(fn -> safe_stop_session(session) end)

    assert {:ok, %Options{} = codex_options} =
             CodexExtension.codex_options_for_session(
               session,
               [model: "gpt-5.4"],
               model_personality: :friendly
             )

    assert {:ok, %ThreadOptions{} = thread_options} =
             CodexExtension.thread_options_for_session(
               session,
               [cwd: "/tmp/asm-codex-session-override"],
               personality: :none
             )

    assert codex_options.model == "gpt-5.4"
    assert codex_options.reasoning_effort == :medium
    assert codex_options.execution_surface.surface_kind == :ssh_exec

    assert codex_options.execution_surface.transport_options[:destination] ==
             "codex.session.example"

    assert codex_options.execution_surface.observability == %{suite: :provider_sdk}
    assert codex_options.model_personality == :friendly

    assert thread_options.working_directory == "/tmp/asm-codex-session-override"
    assert thread_options.approval_timeout_ms == 10_000
    assert thread_options.full_auto == false
    assert thread_options.dangerously_bypass_approvals_and_sandbox == true
    assert thread_options.personality == :none
  end

  test "connect_app_server/3 preserves execution-surface config through the SDK boundary" do
    assert {:ok, conn} =
             CodexExtension.connect_app_server(
               [
                 provider: :codex,
                 cli_path: "/usr/local/bin/codex",
                 model: "gpt-5.4",
                 execution_surface: [
                   surface_kind: :ssh_exec,
                   transport_options: [
                     destination: "codex.extension.example",
                     port: 2222
                   ]
                 ]
               ],
               [],
               test_owner: self()
             )

    on_exit(fn -> AppServer.disconnect(conn) end)

    assert_receive {:codex_app_server_options, %Options{} = options}, 1_000
    assert options.execution_surface.surface_kind == :ssh_exec
    assert options.execution_surface.transport_options[:destination] == "codex.extension.example"
    assert options.execution_surface.transport_options[:port] == 2222
    assert options.codex_path_override == "/usr/local/bin/codex"
  end

  test "thread_options/2 accepts app-server transport as a Codex-native override" do
    asm_opts = [provider: :codex]
    conn = self()

    assert {:ok, %ThreadOptions{} = options} =
             CodexExtension.thread_options(
               asm_opts,
               transport: {:app_server, conn},
               personality: :pragmatic
             )

    assert options.transport == {:app_server, conn}
    assert options.personality == :pragmatic
  end

  test "codex_options/2 rejects non-Codex providers" do
    assert {:error, error} = CodexExtension.codex_options(provider: :claude)

    assert error.kind == :config_invalid
    assert error.domain == :provider
  end

  test "native overrides may not redefine ASM-derived Codex option fields" do
    assert {:error, error} =
             CodexExtension.codex_options(
               [provider: :codex, model: "gpt-5.4"],
               model: "gpt-5.4"
             )

    assert error.kind == :config_invalid
    assert error.domain == :config
    assert String.contains?(error.message, "native_overrides")
    assert String.contains?(error.message, ":model")
  end

  test "native overrides may not redefine ASM-derived Codex thread fields" do
    assert {:error, error} =
             CodexExtension.thread_options(
               [provider: :codex, cwd: "/tmp/asm-codex"],
               working_directory: "/tmp/native-codex"
             )

    assert error.kind == :config_invalid
    assert error.domain == :config
    assert String.contains?(error.message, "native_overrides")
    assert String.contains?(error.message, ":working_directory")
  end

  test "thread_options/2 returns a struct that can seed Codex.start_thread/2" do
    assert {:ok, %Options{} = codex_opts} = CodexExtension.codex_options(provider: :codex)
    assert {:ok, %ThreadOptions{} = thread_opts} = CodexExtension.thread_options(provider: :codex)

    assert {:ok, %Thread{} = thread} = Elixir.Codex.start_thread(codex_opts, thread_opts)
    assert thread.codex_opts == codex_opts
    assert thread.thread_opts == thread_opts
  end

  defp safe_stop_session(session) do
    _ = ASM.stop_session(session)
    :ok
  catch
    :exit, _ -> :ok
  end
end
