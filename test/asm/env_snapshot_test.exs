defmodule ASM.EnvSnapshotTest do
  @moduledoc """
  Coverage for the allowlisted `config/runtime.exs` env snapshot: every
  variable ASM reads must stay resolvable, while unrelated secrets from the
  parent environment must not be copied into Application config.
  """
  use ExUnit.Case, async: true

  alias ASM.EnvSnapshot

  test "keeps every provider auth env key" do
    for provider <- [:claude, :codex, :amp, :antigravity, :cursor],
        key <- ASM.RuntimeAuth.provider_auth_env_keys(provider) do
      assert EnvSnapshot.allowed?(key),
             "#{key} is read via the #{provider} auth registry but not allowed by the snapshot"
    end
  end

  test "keeps the static selectors" do
    for key <- ~w(ASM_PERMISSION_MODE PATH HOME MIX_ENV CI LIVE_MODE LIVE_TESTS) do
      assert EnvSnapshot.allowed?(key)
    end
  end

  test "keeps provider-namespaced variables" do
    for key <- ~w(ASM_CLAUDE_MODEL ASM_CODEX_MODEL CLAUDE_CLI_PATH CODEX_PATH
                  OPENAI_API_KEY ANTHROPIC_API_KEY AMP_CLI_PATH CURSOR_MODEL
                  ANTIGRAVITY_LOG_FILE) do
      assert EnvSnapshot.allowed?(key)
    end
  end

  test "drops unrelated variables (secrets must not be copied)" do
    os_env = %{
      "DATABASE_URL" => "postgres://user:secret@host/db",
      "GITHUB_TOKEN" => "ghp_secret",
      "AWS_SECRET_ACCESS_KEY" => "aws_secret",
      "PATH" => "/usr/bin",
      "ASM_CLAUDE_MODEL" => "sonnet"
    }

    assert EnvSnapshot.take(os_env) == %{
             "PATH" => "/usr/bin",
             "ASM_CLAUDE_MODEL" => "sonnet"
           }
  end
end
