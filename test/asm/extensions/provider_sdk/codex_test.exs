defmodule ASM.Extensions.ProviderSDK.CodexTest do
  use ASM.TestCase

  alias ASM.Extensions.ProviderSDK.Codex, as: CodexExtension
  alias Codex.{Options, Thread}
  alias Codex.Thread.Options, as: ThreadOptions

  test "codex_options/2 maps ASM config and keeps Codex-native overrides explicit" do
    asm_opts = [
      provider: :codex,
      cli_path: "/usr/local/bin/codex",
      model: "gpt-5-codex",
      reasoning_effort: :high
    ]

    native_overrides = [
      model_personality: :pragmatic,
      hide_agent_reasoning: true
    ]

    assert {:ok, %Options{} = options} =
             CodexExtension.codex_options(asm_opts, native_overrides)

    assert options.codex_path_override == "/usr/local/bin/codex"
    assert options.model == "gpt-5-codex"
    assert options.reasoning_effort == :high
    assert options.model_personality == :pragmatic
    assert options.hide_agent_reasoning == true
  end

  test "thread_options/2 maps ASM config and keeps Codex-native thread overrides explicit" do
    asm_opts = [
      provider: :codex,
      cwd: "/tmp/asm-codex-thread",
      permission_mode: :auto,
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
    assert options.approval_timeout_ms == 45_000
    assert options.full_auto == true
    assert options.dangerously_bypass_approvals_and_sandbox == false
    assert options.output_schema == %{"type" => "object"}
    assert options.personality == :pragmatic

    assert options.collaboration_mode == %Codex.Protocol.CollaborationMode{
             mode: :plan,
             model: "",
             reasoning_effort: nil,
             developer_instructions: nil
           }
  end

  test "session-based helpers merge ASM session defaults with explicit overrides" do
    {:ok, session} =
      ASM.start_session(
        provider: :codex,
        cwd: "/tmp/asm-codex-session",
        permission_mode: :bypass,
        approval_timeout_ms: 10_000,
        model: "gpt-5-codex",
        reasoning_effort: :medium
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
    assert codex_options.model_personality == :friendly

    assert thread_options.working_directory == "/tmp/asm-codex-session-override"
    assert thread_options.approval_timeout_ms == 10_000
    assert thread_options.full_auto == false
    assert thread_options.dangerously_bypass_approvals_and_sandbox == true
    assert thread_options.personality == :none
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
               model: "gpt-5-codex"
             )

    assert error.kind == :config_invalid
    assert error.domain == :config
    assert error.message =~ "native_overrides"
    assert error.message =~ ":model"
  end

  test "native overrides may not redefine ASM-derived Codex thread fields" do
    assert {:error, error} =
             CodexExtension.thread_options(
               [provider: :codex, cwd: "/tmp/asm-codex"],
               working_directory: "/tmp/native-codex"
             )

    assert error.kind == :config_invalid
    assert error.domain == :config
    assert error.message =~ "native_overrides"
    assert error.message =~ ":working_directory"
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
