defmodule ASM.TestSupport.Capabilities do
  @moduledoc false

  @spec default_excludes() :: [atom()]
  def default_excludes do
    []
    |> maybe_exclude(:distributed, distributed_available?())
    |> maybe_exclude(:pty, pty_available?())
    |> Enum.reverse()
  end

  defp maybe_exclude(excludes, _tag, true), do: excludes
  defp maybe_exclude(excludes, tag, false), do: [tag | excludes]

  defp distributed_available? do
    case env_override("ASM_INCLUDE_DISTRIBUTED_TESTS") do
      :enabled ->
        true

      :disabled ->
        false

      :auto ->
        node_name = :"asm_capability_probe_#{System.unique_integer([:positive])}"

        case Node.start(node_name, :shortnames) do
          {:ok, _pid} ->
            Node.stop()
            true

          {:error, {:already_started, _pid}} ->
            true

          {:error, _reason} ->
            false
        end
    end
  end

  defp pty_available? do
    case env_override("ASM_INCLUDE_PTY_TESTS") do
      :enabled ->
        true

      :disabled ->
        false

      :auto ->
        auto_pty_available?()
    end
  end

  defp auto_pty_available? do
    case System.find_executable("script") do
      nil ->
        false

      script ->
        case System.cmd(script, ["-q", "-c", "true", "/dev/null"], stderr_to_stdout: true) do
          {_output, 0} -> true
          {_output, _status} -> false
        end
    end
  end

  defp env_override(var_name) do
    case System.get_env(var_name) do
      value when value in ["1", "true", "TRUE"] -> :enabled
      value when value in ["0", "false", "FALSE"] -> :disabled
      _ -> :auto
    end
  end
end

workspace_build_glob = fn repo, env ->
  Path.expand("../../#{repo}/_build/#{env}/lib/*/ebin", __DIR__)
end

workspace_provider_ebins =
  ["codex_sdk", "claude_agent_sdk", "gemini_cli_sdk", "amp_sdk"]
  |> Enum.flat_map(fn repo ->
    test_paths = workspace_build_glob.(repo, "test") |> Path.wildcard()

    if test_paths == [] do
      workspace_build_glob.(repo, "dev") |> Path.wildcard()
    else
      test_paths
    end
  end)
  |> Enum.uniq()

Code.prepend_paths(workspace_provider_ebins)

ExUnit.start(
  exclude: ASM.TestSupport.Capabilities.default_excludes(),
  assert_receive_timeout: 500
)

provider_registry_env = Application.get_env(:agent_session_manager, ASM.ProviderRegistry, [])

Application.put_env(
  :agent_session_manager,
  ASM.ProviderRegistry,
  Keyword.put(provider_registry_env, :runtime_loader, fn _runtime -> false end)
)
