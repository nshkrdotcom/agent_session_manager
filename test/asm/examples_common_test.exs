defmodule ASM.Examples.CommonTest do
  use ASM.SerialTestCase

  alias ASM.Examples.Common

  @script_name "live_query.exs"
  @description "Run a one-off ASM.query/3 call against the selected provider."
  @default_prompt "Reply with exactly: LIVE_QUERY_OK"
  @cli_path "/bin/echo"

  setup do
    env_vars = [
      "AMP_SDK_ROOT",
      "AMP_CLI_PATH",
      "ASM_PERMISSION_MODE",
      "ASM_AMP_MODEL",
      "ASM_CLAUDE_MODEL",
      "ASM_CODEX_MODEL",
      "ASM_GEMINI_MODEL",
      "CLAUDE_AGENT_SDK_ROOT",
      "CLAUDE_CLI_PATH",
      "CODEX_SDK_ROOT",
      "CODEX_PATH",
      "GEMINI_CLI_PATH",
      "GEMINI_CLI_SDK_ROOT"
    ]

    original =
      Map.new(env_vars, fn key ->
        {key, System.get_env(key)}
      end)

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "core-lane common examples do not resolve SDK roots" do
    sdk_root = Path.expand("../../../codex_sdk", __DIR__)
    System.put_env("CODEX_SDK_ROOT", sdk_root)

    assert {:ok, config} =
             Common.build_example_config(
               ["--provider", "codex", "--cli-path", @cli_path],
               @script_name,
               @description,
               @default_prompt
             )

    assert config.provider == :codex
    assert config.lane == :core
    assert config.sdk_root == nil
    assert config.session_opts[:cli_path] == @cli_path
  end

  test "provider CLI env remains resolver-owned for common examples" do
    System.put_env("GEMINI_CLI_PATH", "gemini")

    assert {:ok, config} =
             Common.build_example_config(
               ["--provider", "gemini"],
               @script_name,
               @description,
               @default_prompt
             )

    refute Keyword.has_key?(config.session_opts, :cli_path)
  end

  test "gemini examples default to flash when no explicit model is provided" do
    assert {:ok, config} =
             Common.build_example_config(
               ["--provider", "gemini"],
               @script_name,
               @description,
               @default_prompt
             )

    assert config.session_opts[:model] == "gemini-2.5-flash"
  end

  test "sdk lane resolves SDK root from provider env" do
    sdk_root = Path.expand("../../../codex_sdk", __DIR__)
    System.put_env("CODEX_SDK_ROOT", sdk_root)

    assert {:ok, config} =
             Common.build_example_config(
               ["--provider", "codex", "--lane", "sdk", "--cli-path", @cli_path],
               @script_name,
               @description,
               @default_prompt
             )

    assert config.lane == :sdk
    assert config.sdk_root == sdk_root
  end

  test "provider-native examples resolve SDK roots even on core lane" do
    sdk_root = Path.expand("../../../gemini_cli_sdk", __DIR__)
    System.put_env("GEMINI_CLI_SDK_ROOT", sdk_root)

    assert {:ok, config} =
             Common.build_example_config(
               ["--provider", "gemini", "--cli-path", @cli_path],
               "provider_gemini_session_resume.exs",
               "Provider-native Gemini example.",
               "Reply with exactly: GEMINI_OK",
               provider_sdk?: true
             )

    assert config.provider == :gemini
    assert config.lane == :core
    assert config.sdk_root == sdk_root
  end

  test "missing provider returns informational usage without building config" do
    assert {:usage, 0, output} =
             Common.build_example_config([], @script_name, @description, @default_prompt)

    assert output =~ "did not run because no provider was selected"
    assert output =~ "--provider claude|gemini|codex|amp"
  end

  test "unsupported provider returns usage error" do
    assert {:usage, 1, output} =
             Common.build_example_config(
               ["--provider", "unknown"],
               @script_name,
               @description,
               @default_prompt
             )

    assert output =~ "unsupported provider"
    assert output =~ "Usage:"
  end

  test "invalid lane returns usage error instead of halting the caller" do
    assert {:usage, 1, output} =
             Common.build_example_config(
               ["--provider", "codex", "--lane", "wrong", "--cli-path", @cli_path],
               @script_name,
               @description,
               @default_prompt
             )

    assert output =~ "unsupported lane"
    assert output =~ "Usage:"
  end

  test "sdk_bridge_opts drops orchestration-only lane metadata" do
    config = %Common{
      provider: :codex,
      prompt: @default_prompt,
      lane: :core,
      sdk_root: nil,
      session_opts: [provider: :codex, lane: :core, cli_path: @cli_path, model: "gpt-5-codex"]
    }

    assert Common.sdk_bridge_opts(config) == [
             provider: :codex,
             cli_path: @cli_path,
             model: "gpt-5-codex"
           ]
  end
end
