defmodule ASM.CompletionOnlyTest do
  use ASM.TestCase

  alias ASM.Options
  alias ASM.ProviderFeatures
  alias CliSubprocessCore.ProviderProfile
  alias CliSubprocessCore.ProviderProfiles.Claude, as: ClaudeProfile
  alias CliSubprocessCore.ProviderProfiles.Codex, as: CodexProfile

  describe "option plumbing" do
    test "capability manifest is total across every provider" do
      for provider <- [:claude, :codex] do
        manifest = ProviderFeatures.common_feature!(provider, :completion_only)

        assert manifest.supported? == true
        assert manifest.common_surface == true
        assert manifest.common_opts == [:completion_only]
        assert ProviderFeatures.supports_common_feature?(provider, :completion_only)
      end

      for provider <- [:amp, :antigravity, :cursor] do
        manifest = ProviderFeatures.common_feature!(provider, :completion_only)

        assert manifest.supported? == false
        assert manifest.common_surface == true
        assert manifest.common_opts == [:completion_only]
        refute ProviderFeatures.supports_common_feature?(provider, :completion_only)
      end
    end

    test "completion_only survives ASM validation and model finalization" do
      for {provider, schema} <- [
            {:claude, Options.Claude.schema()},
            {:codex, Options.Codex.schema()}
          ] do
        assert {:ok, finalized} = finalize(provider, schema, completion_only: true)
        assert Keyword.fetch!(finalized, :completion_only) == true
      end
    end

    test "completion_only defaults to false rather than being dropped" do
      assert {:ok, finalized} = finalize(:codex, Options.Codex.schema(), [])
      assert Keyword.fetch!(finalized, :completion_only) == false
    end

    test "providers without a completion-only posture fail on capability, not shape" do
      for {provider, schema} <- [
            {:amp, Options.Amp.schema()},
            {:antigravity, Options.Antigravity.schema()},
            {:cursor, Options.Cursor.schema()}
          ] do
        assert {:error, %ASM.Error{} = error} =
                 Options.validate(
                   [provider: provider, completion_only: true],
                   schema
                 )

        assert error.kind == :config_invalid
        assert error.domain == :config
        assert error.message =~ inspect(provider)
        assert error.message =~ ":completion_only"
        refute error.message =~ "unknown options"
        refute match?(%NimbleOptions.ValidationError{}, error.cause)
      end
    end

    test "completion_only false is accepted by every provider schema" do
      for {provider, schema} <- [
            {:amp, Options.Amp.schema()},
            {:antigravity, Options.Antigravity.schema()},
            {:claude, Options.Claude.schema()},
            {:codex, Options.Codex.schema()},
            {:cursor, Options.Cursor.schema()}
          ] do
        assert {:ok, validated} =
                 Options.validate([provider: provider, completion_only: false], schema)

        assert Keyword.fetch!(validated, :completion_only) == false
      end
    end
  end

  describe "core lane invocation" do
    test "a completion-only codex invocation is read-only and never approval-capable" do
      args =
        core_args(:codex, CodexProfile, Options.Codex.schema(),
          completion_only: true,
          permission_mode: :bypass,
          model: "gpt-5.4"
        )

      assert flag_value(args, "--sandbox") == "read-only"
      assert "--ephemeral" in args
      assert "--ignore-user-config" in args
      assert "--ignore-rules" in args
      assert ~s(approval_policy="never") in args
      assert ~s(web_search="disabled") in args
      assert "skills.include_instructions=false" in args
      assert "skills.bundled.enabled=false" in args
      refute "--dangerously-bypass-approvals-and-sandbox" in args
      refute "--full-auto" in args
    end

    test "a completion-only claude invocation exposes no tools, settings, or loose MCP" do
      args =
        core_args(:claude, ClaudeProfile, Options.Claude.schema(),
          completion_only: true,
          permission_mode: :bypass,
          model: "sonnet"
        )

      assert flag_value(args, "--tools") == ""
      assert flag_value(args, "--setting-sources") == ""
      assert "--strict-mcp-config" in args
      assert flag_value(args, "--permission-mode") == "plan"
      refute "--dangerously-skip-permissions" in args
    end

    test "without completion_only the caller's permission mode is still honored" do
      codex_args =
        core_args(:codex, CodexProfile, Options.Codex.schema(),
          permission_mode: :bypass,
          model: "gpt-5.4"
        )

      assert "--dangerously-bypass-approvals-and-sandbox" in codex_args
      refute ~s(approval_policy="never") in codex_args

      claude_args =
        core_args(:claude, ClaudeProfile, Options.Claude.schema(),
          permission_mode: :bypass,
          model: "sonnet"
        )

      refute "--strict-mcp-config" in claude_args
      refute "--tools" in claude_args
    end
  end

  defp finalize(provider, schema, opts) do
    with {:ok, validated} <-
           Options.validate([provider: provider] ++ opts, schema) do
      Options.finalize_provider_opts(provider, validated)
    end
  end

  defp core_args(provider, profile, schema, opts) do
    assert {:ok, finalized} = finalize(provider, schema, opts)

    finalized =
      Keyword.put(finalized, :command, System.find_executable("true") || "/usr/bin/true")

    assert {:ok, invocation, teardown} =
             ProviderProfile.normalize_build_result(
               profile.build_invocation(Keyword.put(finalized, :prompt, "hello"))
             )

    on_exit(teardown)

    invocation.args
  end

  defp flag_value(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> :missing
      index -> Enum.at(args, index + 1)
    end
  end
end
