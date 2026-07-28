defmodule ASM.InferenceEndpoint.PromptNormalizer do
  @moduledoc false

  @max_messages 128
  @max_prompt_bytes 262_144
  @roles ~w(system developer user assistant tool)

  @spec normalize(String.t() | map()) ::
          {:ok, String.t()} | {:error, {:invalid_request, String.t()}}
  def normalize(prompt) when is_binary(prompt), do: validate_prompt(prompt)

  def normalize(%{} = input) do
    case fetch(input, :prompt) do
      {:ok, nil} -> normalize_messages_field(input)
      {:ok, prompt} -> validate_prompt(prompt)
      :error -> normalize_messages_field(input)
    end
  end

  def normalize(_other), do: invalid("expected a prompt string or a messages array")

  defp normalize_messages_field(input) do
    case fetch(input, :messages) do
      {:ok, messages} -> normalize_messages(messages)
      :error -> invalid("expected a prompt string or a messages array")
    end
  end

  defp normalize_messages(messages) when is_list(messages) do
    case Enum.split(messages, @max_messages) do
      {[], []} ->
        invalid("messages must not be empty")

      {bounded, []} ->
        with {:ok, lines} <- normalize_message_lines(bounded) do
          {:ok, Enum.join(lines, "\n")}
        end

      {_bounded, _overflow} ->
        invalid("messages exceeds the #{@max_messages}-message limit")
    end
  end

  defp normalize_messages(_messages), do: invalid("messages must be an array")

  defp normalize_message_lines(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], 0}, fn {message, index}, {:ok, lines, bytes} ->
      case normalize_message(message, index) do
        {:ok, line} ->
          next_bytes = bytes + byte_size(line) + if(lines == [], do: 0, else: 1)

          if next_bytes <= @max_prompt_bytes do
            {:cont, {:ok, [line | lines], next_bytes}}
          else
            {:halt, invalid("prompt exceeds the #{@max_prompt_bytes}-byte limit")}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, lines, _bytes} -> {:ok, Enum.reverse(lines)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_message(%{} = message, index) do
    with {:ok, role} <- normalize_role(value(message, :role), index),
         {:ok, content} <- normalize_content(value(message, :content), index) do
      {:ok, role <> ": " <> content}
    end
  end

  defp normalize_message(_message, index) do
    invalid("messages[#{index}] must be an object")
  end

  defp normalize_role(role, index) when is_atom(role),
    do: normalize_role(Atom.to_string(role), index)

  defp normalize_role(role, index) when is_binary(role) do
    normalized = String.downcase(String.trim(role))

    if normalized in @roles do
      {:ok, normalized}
    else
      invalid("messages[#{index}].role is unsupported")
    end
  end

  defp normalize_role(_role, index), do: invalid("messages[#{index}].role must be a string")

  defp normalize_content(content, index) when is_binary(content) do
    cond do
      not String.valid?(content) or String.trim(content) == "" ->
        invalid("messages[#{index}].content must be a non-empty UTF-8 string")

      byte_size(content) > @max_prompt_bytes ->
        invalid("prompt exceeds the #{@max_prompt_bytes}-byte limit")

      true ->
        {:ok, content}
    end
  end

  defp normalize_content(_content, index) do
    invalid("messages[#{index}].content must be a non-empty UTF-8 string")
  end

  defp validate_prompt(prompt) when is_binary(prompt) do
    cond do
      not String.valid?(prompt) ->
        invalid("prompt must be valid UTF-8")

      String.trim(prompt) == "" ->
        invalid("prompt must not be empty")

      byte_size(prompt) > @max_prompt_bytes ->
        invalid("prompt exceeds the #{@max_prompt_bytes}-byte limit")

      true ->
        {:ok, prompt}
    end
  end

  defp validate_prompt(_prompt), do: invalid("prompt must be a string")

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp value(attrs, key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end

  defp invalid(message), do: {:error, {:invalid_request, message}}
end
