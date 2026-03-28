defmodule ASM.Extensions.ProviderSDK.ClaudeTest do
  use ASM.TestCase

  alias ASM.Extensions.ProviderSDK.Claude
  alias ClaudeAgentSDK.{Client, Hooks, Options}
  alias ClaudeAgentSDK.Hooks.Matcher
  alias ClaudeAgentSDK.TestSupport.FakeCLI
  alias CliSubprocessCore.ModelRegistry.Selection
  alias CliSubprocessCore.TestSupport.FakeSSH

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
      transport_timeout_ms: 12_000,
      surface_kind: :static_ssh,
      transport_options: [destination: "claude.options.example", port: 2222]
    ]

    native_overrides = [
      hooks: %{pre_tool_use: [Matcher.new("Bash", [hook])]},
      enable_file_checkpointing: true
    ]

    assert {:ok, %Options{} = options} = Claude.sdk_options(asm_opts, native_overrides)

    assert options.cwd == "/tmp/asm-claude-extension"
    assert options.env == %{"FOO" => "bar"}
    assert options.path_to_claude_code_executable == "/usr/local/bin/claude"
    assert options.permission_mode == :accept_edits
    assert options.model == "sonnet"
    assert options.max_turns == 3
    assert options.timeout_ms == 12_000
    assert options.execution_surface.surface_kind == :static_ssh
    assert options.execution_surface.transport_options[:destination] == "claude.options.example"
    assert options.thinking == %{type: :adaptive}
    assert options.enable_file_checkpointing == true
    assert options.hooks == %{pre_tool_use: [Matcher.new("Bash", [hook])]}
  end

  test "sdk_options/2 accepts the ASM common Ollama surface for Claude" do
    asm_opts = [
      provider: :claude,
      model: "haiku",
      ollama: true,
      ollama_model: "llama3.2",
      ollama_base_url: "http://127.0.0.1:11434",
      model_payload: claude_ollama_payload(),
      permission_mode: :bypass
    ]

    assert {:ok, %Options{} = options} = Claude.sdk_options(asm_opts)

    assert options.permission_mode == :bypass_permissions
    assert options.model == "llama3.2"
    assert options.model_payload.requested_model == "haiku"
    assert options.model_payload.provider_backend == :ollama
    assert options.model_payload.env_overrides["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:11434"
    assert options.model_payload.env_overrides["ANTHROPIC_AUTH_TOKEN"] == "ollama"
    assert options.model_payload.backend_metadata["external_model"] == "llama3.2"
  end

  test "sdk_options_for_session/3 merges session defaults with ASM overrides" do
    {:ok, session} =
      ASM.start_session(
        provider: :claude,
        workspace_root: "/tmp/asm-session-defaults",
        permission_mode: :plan,
        model: "haiku",
        max_turns: 2,
        surface_kind: :leased_ssh,
        transport_options: [destination: "claude.session.example"],
        allowed_tools: ["search"],
        observability: %{suite: :provider_sdk}
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
    assert options.execution_surface.surface_kind == :leased_ssh
    assert options.execution_surface.transport_options[:destination] == "claude.session.example"
    assert options.execution_surface.observability == %{suite: :provider_sdk}
    assert options.enable_file_checkpointing == true
  end

  test "start_client/3 preserves ASM execution-surface config over fake SSH" do
    fake_cli = FakeCLI.new!()
    fake_ssh = FakeSSH.new!()
    hook = fn _input, _tool_use_id, _context -> Hooks.Output.allow() end
    cwd = fake_cli.root_dir

    on_exit(fn ->
      FakeCLI.cleanup(fake_cli)
      FakeSSH.cleanup(fake_ssh)
    end)

    asm_opts =
      [
        provider: :claude,
        cwd: cwd,
        cli_path: fake_cli.script_path,
        permission_mode: :plan,
        model: "sonnet",
        max_turns: 4
      ] ++ FakeCLI.static_ssh_surface(fake_cli, fake_ssh, destination: "claude.extension.example")

    native_overrides = [
      hooks: %{pre_tool_use: [Matcher.new("Bash", [hook])]},
      enable_file_checkpointing: true
    ]

    assert {:ok, client} =
             Claude.start_client(asm_opts, native_overrides, control_request_timeout_ms: 1_000)

    on_exit(fn -> safe_stop_client(client) end)

    assert FakeCLI.wait_until_started(fake_cli, 1_000) == :ok
    assert {:ok, request} = FakeCLI.initialize_request(fake_cli, 1_000)
    assert request["type"] == "control_request"
    assert request["request"]["subtype"] == "initialize"
    assert is_map(request["request"]["hooks"])

    request_id = FakeCLI.respond_initialize_success!(fake_cli, %{}, 1_000)
    assert is_binary(request_id)
    assert :ok = Client.await_initialized(client, 1_000)
    assert FakeSSH.wait_until_written(fake_ssh, 1_000) == :ok
    assert FakeSSH.read_manifest!(fake_ssh) =~ "destination=claude.extension.example"
  end

  test "sdk_options/2 rejects non-Claude providers" do
    assert {:error, error} = Claude.sdk_options(provider: :codex)

    assert error.kind == :config_invalid
    assert error.domain == :provider
  end

  test "sdk_options/2 rejects native overrides that redefine ASM-derived fields" do
    assert {:error, error} =
             Claude.sdk_options(
               [provider: :claude, permission_mode: :plan],
               permission_mode: :auto
             )

    assert error.kind == :config_invalid
    assert error.domain == :config
    assert error.message =~ "native_overrides"
    assert error.message =~ ":permission_mode"
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

  defp claude_ollama_payload do
    Selection.new(%{
      provider: :claude,
      requested_model: "haiku",
      resolved_model: "llama3.2",
      resolution_source: :explicit,
      reasoning: nil,
      reasoning_effort: nil,
      normalized_reasoning_effort: nil,
      model_family: "llama",
      catalog_version: nil,
      visibility: :public,
      provider_backend: :ollama,
      model_source: :external,
      env_overrides: %{
        "ANTHROPIC_AUTH_TOKEN" => "ollama",
        "ANTHROPIC_API_KEY" => "",
        "ANTHROPIC_BASE_URL" => "http://127.0.0.1:11434"
      },
      settings_patch: %{},
      backend_metadata: %{"external_model" => "llama3.2"},
      errors: []
    })
  end
end
