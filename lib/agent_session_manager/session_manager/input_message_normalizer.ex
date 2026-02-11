defmodule AgentSessionManager.SessionManager.InputMessageNormalizer do
  @moduledoc false

  @spec extract(map()) :: [map()]
  def extract(%{messages: messages}) when is_list(messages), do: normalize_messages(messages)
  def extract(%{"messages" => messages}) when is_list(messages), do: normalize_messages(messages)
  def extract(%{prompt: prompt}) when is_binary(prompt) and prompt != "", do: user_prompt(prompt)

  def extract(%{"prompt" => prompt}) when is_binary(prompt) and prompt != "",
    do: user_prompt(prompt)

  def extract(_input), do: []

  defp normalize_messages(messages) do
    messages
    |> Enum.map(&normalize_message/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_message(message) when is_map(message) do
    role = Map.get(message, :role) || Map.get(message, "role")
    content = Map.get(message, :content) || Map.get(message, "content")
    build_event_payload(role, content)
  end

  defp normalize_message(_message), do: nil

  defp build_event_payload(role, content) do
    normalized_content = normalize_content(content)

    if normalized_content == "" do
      nil
    else
      %{
        role: normalize_role(role),
        content: normalized_content
      }
    end
  end

  defp normalize_role(role) when role in [:system, :user, :assistant, :tool],
    do: Atom.to_string(role)

  defp normalize_role(role) when is_binary(role) and role != "", do: String.downcase(role)
  defp normalize_role(_role), do: "user"

  defp normalize_content(nil), do: ""
  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content(content), do: inspect(content)

  defp user_prompt(prompt), do: [%{role: "user", content: prompt}]
end
