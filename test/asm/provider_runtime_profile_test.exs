defmodule ASM.ProviderRuntimeProfileTest do
  use ASM.SerialTestCase

  @cli_config_app :cli_subprocess_core
  @cli_config_key :provider_runtime_profiles

  setup do
    previous_cli_config = Application.get_env(@cli_config_app, @cli_config_key)
    previous_registry_config = Application.get_env(:agent_session_manager, ASM.ProviderRegistry)

    on_exit(fn ->
      restore_env(@cli_config_app, @cli_config_key, previous_cli_config)
      restore_env(:agent_session_manager, ASM.ProviderRegistry, previous_registry_config)
    end)

    Application.delete_env(@cli_config_app, @cli_config_key)
    :ok
  end

  test "normal ASM queries use CLI core runtime profiles through the core backend" do
    profiles =
      Map.new(provider_cases(), fn {provider, scenario_ref, line, _content} ->
        {provider, [scenario_ref: scenario_ref, stdout_frames: [line], exit: :normal]}
      end)

    Application.put_env(@cli_config_app, @cli_config_key, profiles: profiles)

    Enum.each(provider_cases(), fn {provider, scenario_ref, _line, content} ->
      assert {:ok, result} =
               ASM.query(provider, "normal ASM public call",
                 session_id:
                   "asm-provider-runtime-#{provider}-#{System.unique_integer([:positive])}",
                 lane: :auto
               )

      assert result.text == content
      assert result.metadata.lane == :core
      assert result.metadata.backend == ASM.ProviderBackend.Core
      assert result.metadata.provider_runtime_profile?
      assert result.metadata.provider_runtime_profile_mode == :lower_simulation
      assert result.metadata.provider_runtime_profile_ref == scenario_ref
      assert result.metadata.provider_runtime_profile_source == :cli_subprocess_core_config
    end)
  end

  test "active runtime profile forces auto lane to core even when sdk runtime is available" do
    put_runtime_loader(fn _runtime -> true end)

    Application.put_env(@cli_config_app, @cli_config_key,
      profiles: %{
        codex: [
          scenario_ref: "phase5prelim://asm/codex-forced-core",
          stdout: ~s({"type":"response.output_text.delta","delta":"forced core"}\n),
          exit: :normal
        ]
      }
    )

    assert {:ok, resolution} = ASM.ProviderRegistry.resolve(:codex, lane: :auto)

    assert resolution.preferred_lane == :sdk
    assert resolution.lane == :core
    assert resolution.lane_fallback_reason == :provider_runtime_profile
    assert resolution.backend == ASM.ProviderBackend.Core

    assert resolution.observability.provider_runtime_profile_ref ==
             "phase5prelim://asm/codex-forced-core"

    assert {:ok, result} =
             ASM.query(:codex, "auto lane should not use sdk",
               session_id: "asm-runtime-forced-core-#{System.unique_integer([:positive])}",
               lane: :auto
             )

    assert result.text == "forced core"
    assert result.metadata.lane == :core
    assert result.metadata.lane_fallback_reason == :provider_runtime_profile
    assert result.metadata.provider_runtime_profile_ref == "phase5prelim://asm/codex-forced-core"
  end

  test "explicit sdk lane is rejected while a runtime profile is active" do
    put_runtime_loader(fn _runtime -> true end)

    Application.put_env(@cli_config_app, @cli_config_key,
      profiles: %{
        codex: [
          scenario_ref: "phase5prelim://asm/codex-no-sdk",
          stdout: ~s({"type":"response.output_text.delta","delta":"ignored"}\n)
        ]
      }
    )

    assert {:error, error} = ASM.query(:codex, "must not bypass", lane: :sdk)

    assert error.kind == :config_invalid
    assert error.domain == :config
    assert error.message =~ "sdk lane is unavailable"
    assert error.message =~ "phase5prelim://asm/codex-no-sdk"
  end

  test "required runtime profile fails before CLI resolution or spawn" do
    Application.put_env(@cli_config_app, @cli_config_key, required?: true, profiles: %{})

    assert {:error, error} =
             ASM.query(:claude, "must fail before provider CLI resolution", lane: :auto)

    assert error.kind == :config_invalid
    assert error.domain == :config
    assert error.provider == :claude
    assert error.message =~ "provider runtime profile required"
  end

  test "backend overrides cannot bypass an active runtime profile" do
    Application.put_env(@cli_config_app, @cli_config_key,
      profiles: %{
        claude: [
          scenario_ref: "phase5prelim://asm/no-backend-override",
          stdout: ~s({"type":"assistant_delta","delta":"ignored"}\n)
        ]
      }
    )

    assert {:error, error} =
             ASM.query(:claude, "must not use fake backend",
               backend_module: ASM.TestSupport.FakeBackend
             )

    assert error.kind == :config_invalid
    assert error.domain == :config
    assert error.message =~ "backend override"
    assert error.message =~ "phase5prelim://asm/no-backend-override"
  end

  defp provider_cases do
    [
      {:claude, "phase5prelim://asm/claude",
       ~s({"type":"assistant_delta","delta":"claude asm","session_id":"claude-asm"}\n),
       "claude asm"},
      {:codex, "phase5prelim://asm/codex",
       ~s({"type":"response.output_text.delta","delta":"codex asm","session_id":"codex-asm"}\n),
       "codex asm"},
      {:gemini, "phase5prelim://asm/gemini",
       ~s({"type":"message","role":"assistant","delta":true,"content":"gemini asm","session_id":"gemini-asm"}\n),
       "gemini asm"},
      {:amp, "phase5prelim://asm/amp",
       ~s({"type":"message_streamed","delta":"amp asm","session_id":"amp-asm"}\n), "amp asm"}
    ]
  end

  defp put_runtime_loader(fun) when is_function(fun, 1) do
    Application.put_env(:agent_session_manager, ASM.ProviderRegistry, runtime_loader: fun)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
