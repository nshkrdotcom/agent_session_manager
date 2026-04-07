defmodule ASM.LiveSSHTest do
  use ExUnit.Case, async: false

  alias ASM.Error
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
      Keyword.put(
        original,
        :runtime_loader,
        OptionalSDK.loaded_runtime_loader([:amp, :claude, :codex, :gemini])
      )
    )

    on_exit(fn ->
      Application.put_env(:agent_session_manager, ASM.ProviderRegistry, original)
    end)

    :ok
  end

  test "live SSH: ASM.query/3 executes over the core lane with a remote execution_surface" do
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

  test "live SSH: ASM.query/3 executes over the sdk lane with a remote execution_surface" do
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

  test "live SSH: ASM.query/3 surfaces remote Claude auth failures or a successful reply over the sdk lane" do
    case asm_query(:claude, "Reply with exactly: ASM_CLAUDE_LIVE_SSH_OK",
           lane: :sdk,
           cli_path: LiveSSH.provider_command(:claude)
         ) do
      {:ok, result} ->
        assert result.metadata.lane == :sdk
        assert result.text =~ "ASM_CLAUDE_LIVE_SSH_OK"

      {:error, %Error{kind: :auth_error} = error} ->
        assert error.message =~ "authentication" or error.message =~ "login"

      {:error, %Error{kind: :cli_not_found} = error} ->
        assert error.message =~ "Claude CLI not found"
    end
  end

  test "live SSH: ASM.query/3 surfaces remote Gemini CLI misses as structured sdk errors" do
    case asm_query(:gemini, "Reply with exactly: ASM_GEMINI_LIVE_SSH_OK", lane: :sdk) do
      {:ok, result} ->
        assert result.metadata.lane == :sdk
        assert is_binary(result.text)
        assert result.text != ""

      {:error, %Error{kind: :cli_not_found} = error} ->
        assert error.message =~ "Gemini CLI not found"

      {:error, %Error{kind: :auth_error} = error} ->
        assert error.message =~ "authentication"
    end
  end

  test "live SSH: ASM.query/3 surfaces remote Amp CLI misses as structured sdk errors" do
    case asm_query(:amp, "Reply with exactly: ASM_AMP_LIVE_SSH_OK", lane: :sdk) do
      {:ok, result} ->
        assert result.metadata.lane == :sdk
        assert is_binary(result.text)
        assert result.text != ""

      {:error, %Error{kind: :cli_not_found} = error} ->
        assert error.message =~ "Amp CLI not found"

      {:error, %Error{kind: :auth_error} = error} ->
        assert error.message =~ "authentication"
    end
  end

  defp asm_query(provider, prompt, opts)
       when is_atom(provider) and is_binary(prompt) and is_list(opts) do
    opts =
      opts
      |> Keyword.put_new(:execution_surface, LiveSSH.execution_surface())
      |> Keyword.put_new(:stream_timeout_ms, 120_000)
      |> Keyword.update(:cli_path, nil, fn
        nil -> nil
        value -> value
      end)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    ASM.query(provider, prompt, opts)
  end
end
