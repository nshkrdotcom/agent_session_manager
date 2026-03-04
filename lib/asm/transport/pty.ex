defmodule ASM.Transport.PTY do
  @moduledoc false

  alias ASM.Provider

  @spec maybe_wrap(Provider.t(), String.t(), [String.t()]) :: {String.t(), [String.t()]}
  def maybe_wrap(%Provider{name: :claude}, program, args) do
    case System.find_executable("script") do
      nil ->
        {program, args}

      script_program ->
        command = shell_join([program | args])
        {script_program, ["-q", "-c", command, "/dev/null"]}
    end
  end

  def maybe_wrap(_provider, program, args), do: {program, args}

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
