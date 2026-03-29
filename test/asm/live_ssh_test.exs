defmodule ASM.LiveSSHTest do
  use ExUnit.Case, async: false

  alias ASM.TestSupport.OptionalSDK
  alias CliSubprocessCore.TestSupport.LiveSSH

  @moduletag :live_ssh
  @moduletag timeout: 180_000

  @live_ssh_enabled LiveSSH.enabled?()

  if not @live_ssh_enabled do
    @moduletag skip: LiveSSH.skip_reason()
  end

  setup_all do
    original = Application.get_env(:agent_session_manager, ASM.ProviderRegistry, [])

    Application.put_env(
      :agent_session_manager,
      ASM.ProviderRegistry,
      Keyword.put(original, :runtime_loader, OptionalSDK.loaded_runtime_loader([:codex]))
    )

    on_exit(fn ->
      Application.put_env(:agent_session_manager, ASM.ProviderRegistry, original)
    end)

    {:ok,
     skip: not LiveSSH.runnable?("codex"),
     skip_reason:
       "Remote SSH target #{inspect(LiveSSH.destination())} does not have a runnable `codex --version`."}
  end

  test "live SSH: ASM.query/3 executes over the core lane with a remote execution_surface", %{
    skip: skip?,
    skip_reason: skip_reason
  } do
    if skip? do
      assert is_binary(skip_reason)
    else
      assert {:ok, result} =
               ASM.query(:codex, "Reply with exactly: ASM_CORE_LIVE_SSH_OK",
                 lane: :core,
                 permission_mode: :bypass,
                 skip_git_repo_check: true,
                 execution_surface: LiveSSH.execution_surface(),
                 stream_timeout_ms: 120_000
               )

      assert result.text =~ "ASM_CORE_LIVE_SSH_OK"
      assert result.metadata.lane == :core
    end
  end

  test "live SSH: ASM.query/3 executes over the sdk lane with a remote execution_surface", %{
    skip: skip?,
    skip_reason: skip_reason
  } do
    if skip? do
      assert is_binary(skip_reason)
    else
      assert {:ok, result} =
               ASM.query(:codex, "Reply with exactly: ASM_SDK_LIVE_SSH_OK",
                 lane: :sdk,
                 permission_mode: :bypass,
                 skip_git_repo_check: true,
                 execution_surface: LiveSSH.execution_surface(),
                 stream_timeout_ms: 120_000
               )

      assert result.text =~ "ASM_SDK_LIVE_SSH_OK"
      assert result.metadata.lane == :sdk
    end
  end
end
