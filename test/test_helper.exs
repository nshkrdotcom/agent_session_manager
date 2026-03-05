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

ExUnit.start(exclude: ASM.TestSupport.Capabilities.default_excludes())
