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

  test "examples default to bypass mode with provider-native permission metadata" do
    assert {:ok, config} =
             Common.build_example_config(
               ["--provider", "codex"],
               @script_name,
               @description,
               @default_prompt
             )

    assert config.provider_opts[:permission_mode] == :bypass
    assert config.provider_opts[:provider_permission_mode] == :yolo
    assert config.permission_source == :example_default_bypass
  end

  test "exact_text_match?/2 trims surrounding whitespace but still enforces exact content" do
    assert Common.exact_text_match?("  LIVE_QUERY_OK\n", "LIVE_QUERY_OK")
    refute Common.exact_text_match?("LIVE_QUERY_OK extra", "LIVE_QUERY_OK")
    refute Common.exact_text_match?(nil, "LIVE_QUERY_OK")
  end

  test "examples record when permission mode comes from the CLI flag" do
    assert {:ok, config} =
             Common.build_example_config(
               ["--provider", "amp", "--permission-mode", "plan"],
               @script_name,
               @description,
               @default_prompt
             )

    assert config.provider_opts[:permission_mode] == :plan
    assert config.provider_opts[:provider_permission_mode] == :plan
    assert config.permission_source == :cli_flag
  end

  test "common example parser accepts the Ollama surface" do
    assert {:ok, config} =
             Common.build_example_config(
               [
                 "--provider",
                 "claude",
                 "--ollama",
                 "--model",
                 "haiku",
                 "--ollama-model",
                 "llama3.2"
               ],
               @script_name,
               @description,
               @default_prompt
             )

    payload = Keyword.fetch!(config.provider_opts, :model_payload)

    assert payload.provider_backend == :ollama
    assert payload.requested_model == "haiku"
    assert payload.resolved_model == "llama3.2"
    assert payload.env_overrides["ANTHROPIC_AUTH_TOKEN"] == "ollama"
  end

  test "common example parser accepts the Codex Ollama surface for arbitrary local models" do
    assert {:ok, config} =
             Common.build_example_config(
               [
                 "--provider",
                 "codex",
                 "--ollama",
                 "--ollama-model",
                 "llama3.2"
               ],
               @script_name,
               @description,
               @default_prompt
             )

    payload = Keyword.fetch!(config.provider_opts, :model_payload)

    assert payload.provider_backend == :oss
    assert payload.backend_metadata["oss_provider"] == "ollama"
    assert payload.resolved_model == "llama3.2"
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
      session_opts: [provider: :codex, lane: :core, cli_path: @cli_path, model: "gpt-5.4"],
      provider_opts: [
        provider: :codex,
        cli_path: @cli_path,
        model: "gpt-5.4",
        permission_mode: :bypass,
        provider_permission_mode: :yolo
      ],
      permission_source: :example_default_bypass
    }

    assert Common.sdk_bridge_opts(config) == [
             provider: :codex,
             cli_path: @cli_path,
             model: "gpt-5.4",
             permission_mode: :bypass,
             provider_permission_mode: :yolo
           ]
  end
end
