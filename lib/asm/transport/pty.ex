defmodule ASM.Transport.PTY do
  @moduledoc false

  alias ASM.Provider

  @spec maybe_wrap(Provider.t(), String.t(), [String.t()]) :: {String.t(), [String.t()]}
  def maybe_wrap(%Provider{name: :claude}, program, args) do
    case script_wrapper() do
      {:ok, script_program} ->
        command = shell_join([program | args])
        {script_program, ["-q", "-c", command, "/dev/null"]}

      :error ->
        {program, args}
    end
  end

  def maybe_wrap(_provider, program, args), do: {program, args}

  defp script_wrapper do
    case System.find_executable("script") do
      nil ->
        :error

      script_program ->
        if script_usable?(script_program), do: {:ok, script_program}, else: :error
    end
  end

  defp script_usable?(script_program) do
    case System.cmd(script_program, ["-q", "-c", "true", "/dev/null"], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  rescue
    _error -> false
  end

  defp shell_join(argv) when is_list(argv) do
    Enum.map_join(argv, " ", &shell_escape/1)
  end

  defp shell_escape(value) do
    value
    |> to_string()
    |> String.replace("'", "'\"'\"'")
    |> then(&"'#{&1}'")
  end
end
