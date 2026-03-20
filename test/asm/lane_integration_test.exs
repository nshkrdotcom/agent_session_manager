defmodule ASM.LaneIntegrationTest do
  use ASM.SerialTestCase

  setup do
    original = Application.get_env(:agent_session_manager, ASM.ProviderRegistry)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:agent_session_manager, ASM.ProviderRegistry)
      else
        Application.put_env(:agent_session_manager, ASM.ProviderRegistry, original)
      end
    end)

    :ok
  end

  test "auto lane falls back to core when sdk runtime kits are unavailable" do
    put_runtime_loader(fn
      Codex.Runtime.Exec -> false
      runtime -> Code.ensure_loaded?(runtime)
    end)

    script = write_script!(codex_success_script("CORE_LANE_OK"))
    session = start_session!(:codex)

    assert {:ok, result} =
             ASM.query(session, "say core",
               lane: :auto,
               cli_path: script
             )

    assert result.text == "CORE_LANE_OK"
    assert result.metadata.requested_lane == :auto
    assert result.metadata.preferred_lane == :core
    assert result.metadata.lane == :core
    assert result.metadata.execution_mode == :local
    assert result.metadata.sdk_available? == false

    assert :ok = ASM.stop_session(session)
  end

  test "auto lane uses the sdk backend when the runtime kit is present" do
    put_runtime_loader(fn
      Codex.Runtime.Exec -> true
      runtime -> Code.ensure_loaded?(runtime)
    end)

    script = write_script!(codex_success_script("SDK_LANE_OK"))
    session = start_session!(:codex)

    assert {:ok, result} =
             ASM.query(session, "say sdk",
               lane: :auto,
               cli_path: script
             )

    assert result.text == "SDK_LANE_OK"
    assert result.metadata.requested_lane == :auto
    assert result.metadata.preferred_lane == :sdk
    assert result.metadata.lane == :sdk
    assert result.metadata.execution_mode == :local
    assert result.metadata.backend == ASM.ProviderBackend.SDK
    assert result.metadata.sdk_available? == true

    assert :ok = ASM.stop_session(session)
  end

  test "explicit lane overrides force local core and sdk backends" do
    put_runtime_loader(fn
      Codex.Runtime.Exec -> true
      runtime -> Code.ensure_loaded?(runtime)
    end)

    core_script = write_script!(codex_success_script("CORE_OVERRIDE_OK"))
    sdk_script = write_script!(codex_success_script("SDK_OVERRIDE_OK"))
    session = start_session!(:codex)

    assert {:ok, core_result} =
             ASM.query(session, "force core",
               lane: :core,
               cli_path: core_script
             )

    assert core_result.text == "CORE_OVERRIDE_OK"
    assert core_result.metadata.requested_lane == :core
    assert core_result.metadata.preferred_lane == :core
    assert core_result.metadata.lane == :core
    assert core_result.metadata.backend == ASM.ProviderBackend.Core

    assert {:ok, sdk_result} =
             ASM.query(session, "force sdk",
               lane: :sdk,
               cli_path: sdk_script
             )

    assert sdk_result.text == "SDK_OVERRIDE_OK"
    assert sdk_result.metadata.requested_lane == :sdk
    assert sdk_result.metadata.preferred_lane == :sdk
    assert sdk_result.metadata.lane == :sdk
    assert sdk_result.metadata.backend == ASM.ProviderBackend.SDK

    assert :ok = ASM.stop_session(session)
  end

  defp start_session!(provider) when is_atom(provider) do
    session_id = "asm-lane-#{System.unique_integer([:positive])}"
    {:ok, session} = ASM.start_session(session_id: session_id, provider: provider)
    session
  end

  defp put_runtime_loader(fun) when is_function(fun, 1) do
    Application.put_env(:agent_session_manager, ASM.ProviderRegistry, runtime_loader: fun)
  end

  defp codex_success_script(text) do
    """
    #!/usr/bin/env bash
    set -euo pipefail
    echo '{"type":"thread.started","thread_id":"thread-1"}'
    echo '{"type":"turn.started"}'
    echo '{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"#{text}"}}'
    echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
    """
  end

  defp write_script!(contents) do
    path = Path.join(System.tmp_dir!(), "asm-lane-#{System.unique_integer([:positive])}.sh")
    File.write!(path, contents)
    File.chmod!(path, 0o755)
    path
  end
end
