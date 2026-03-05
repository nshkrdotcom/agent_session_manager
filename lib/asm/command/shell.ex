defmodule ASM.Command.Shell do
  @moduledoc """
  Builds safe shell command invocations with allow/deny policy controls.
  """

  alias ASM.{Command, Error}
  alias ASM.Provider.Resolver

  @behaviour Command

  @forbidden_operator_chars [?\n, ?\r, ?;, ?|, ?&, ?<, ?>, ?`]
  @whitespace [?\s, ?\t]

  @impl true
  @spec build(String.t(), keyword()) ::
          {:ok, Resolver.CommandSpec.t(), [String.t()]} | {:error, Error.t()}
  def build(prompt, opts) when is_binary(prompt) and is_list(opts) do
    with {:ok, command_spec} <- Resolver.resolve(:shell, opts),
         {:ok, tokens} <- tokenize(prompt),
         :ok <- enforce_policy(tokens, opts) do
      command = tokens |> Enum.map_join(" ", &shell_escape/1)
      {:ok, command_spec, ["-lc", "exec " <> command]}
    end
  end

  defp tokenize(command) when is_binary(command) do
    trimmed = String.trim(command)

    cond do
      trimmed == "" ->
        {:error, policy_error("Shell command must not be empty")}

      String.contains?(trimmed, "$(") ->
        {:error, policy_error("Shell command contains unsupported token: $(")}

      true ->
        trimmed
        |> String.to_charlist()
        |> consume(:normal, [], [], nil)
    end
  end

  defp consume([], :normal, [], [], _last_char),
    do: {:error, policy_error("Shell command is empty")}

  defp consume([], :normal, current, tokens, _last_char) do
    {:ok, Enum.reverse(push_token(tokens, current))}
  end

  defp consume([], quote, _current, _tokens, _last_char) when quote in [:single, :double] do
    {:error, policy_error("Shell command has unterminated quotes")}
  end

  defp consume([char | rest], :normal, current, tokens, _last_char) when char in @whitespace do
    consume(rest, :normal, [], push_token(tokens, current), char)
  end

  defp consume([char | _rest], :normal, _current, _tokens, _last_char)
       when char in @forbidden_operator_chars do
    {:error, policy_error("Shell command contains forbidden operator: #{<<char::utf8>>}")}
  end

  defp consume([?\\], :normal, _current, _tokens, _last_char) do
    {:error, policy_error("Shell command ends with incomplete escape")}
  end

  defp consume([?\\, escaped | rest], :normal, current, tokens, _last_char) do
    consume(rest, :normal, [escaped | current], tokens, escaped)
  end

  defp consume([?' | rest], :normal, current, tokens, _last_char) do
    consume(rest, :single, current, tokens, ?')
  end

  defp consume([?" | rest], :normal, current, tokens, _last_char) do
    consume(rest, :double, current, tokens, ?")
  end

  defp consume([char | rest], :normal, current, tokens, _last_char) do
    consume(rest, :normal, [char | current], tokens, char)
  end

  defp consume([?' | rest], :single, current, tokens, _last_char) do
    consume(rest, :normal, current, tokens, ?')
  end

  defp consume([char | rest], :single, current, tokens, _last_char) do
    consume(rest, :single, [char | current], tokens, char)
  end

  defp consume([?" | rest], :double, current, tokens, _last_char) do
    consume(rest, :normal, current, tokens, ?")
  end

  defp consume([?\\], :double, _current, _tokens, _last_char) do
    {:error, policy_error("Shell command ends with incomplete escape")}
  end

  defp consume([?\\, escaped | rest], :double, current, tokens, _last_char) do
    consume(rest, :double, [escaped | current], tokens, escaped)
  end

  defp consume([char | rest], :double, current, tokens, _last_char) do
    consume(rest, :double, [char | current], tokens, char)
  end

  defp enforce_policy([command | _tokens], opts) do
    executable = command |> to_string() |> Path.basename()
    allowed = normalize_command_list(Keyword.get(opts, :allowed_commands, []))
    denied = normalize_command_list(Keyword.get(opts, :denied_commands, []))

    cond do
      executable in denied ->
        {:error, policy_error("Command '#{executable}' is denied")}

      allowed != [] and executable not in allowed ->
        {:error, policy_error("Command '#{executable}' is not in the allowed list")}

      true ->
        :ok
    end
  end

  defp enforce_policy([], _opts), do: {:error, policy_error("Shell command is empty")}

  defp push_token(tokens, []), do: tokens
  defp push_token(tokens, current), do: [current |> Enum.reverse() |> to_string() | tokens]

  defp normalize_command_list(commands) when is_list(commands) do
    commands
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> Path.basename()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_command_list(_other), do: []

  defp shell_escape(value) do
    value
    |> to_string()
    |> String.replace("'", "'\"'\"'")
    |> then(&"'#{&1}'")
  end

  defp policy_error(message) do
    Error.new(:policy_violation, :config, message)
  end
end
