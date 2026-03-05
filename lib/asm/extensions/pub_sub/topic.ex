defmodule ASM.Extensions.PubSub.Topic do
  @moduledoc """
  Canonical topic strategy for PubSub event fanout.

  Scopes:
  - `:all` -> `asm:events`
  - `:session` -> `asm:session:<session_id>`
  - `:run` -> `asm:session:<session_id>:run:<run_id>`
  """

  alias ASM.{Error, Event}

  @type scope :: :all | :session | :run

  @default_prefix "asm"
  @default_scopes [:session, :run]

  @spec default_prefix() :: String.t()
  def default_prefix, do: @default_prefix

  @spec default_scopes() :: [scope()]
  def default_scopes, do: @default_scopes

  @spec all(String.t()) :: String.t()
  def all(prefix \\ @default_prefix) when is_binary(prefix), do: "#{prefix}:events"

  @spec session(String.t(), String.t()) :: String.t()
  def session(session_id, prefix \\ @default_prefix)
      when is_binary(session_id) and is_binary(prefix) do
    "#{prefix}:session:#{session_id}"
  end

  @spec run(String.t(), String.t(), String.t()) :: String.t()
  def run(session_id, run_id, prefix \\ @default_prefix)
      when is_binary(session_id) and is_binary(run_id) and is_binary(prefix) do
    "#{prefix}:session:#{session_id}:run:#{run_id}"
  end

  @spec for_event(Event.t(), keyword()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def for_event(%Event{} = event, opts \\ []) when is_list(opts) do
    scopes = Keyword.get(opts, :scopes, @default_scopes)
    prefix = Keyword.get(opts, :prefix, @default_prefix)

    with {:ok, normalized_prefix} <- normalize_prefix(prefix),
         {:ok, normalized_scopes} <- normalize_scopes(scopes) do
      topics =
        normalized_scopes
        |> Enum.map(&topic_for_scope(&1, event, normalized_prefix))
        |> Enum.uniq()

      {:ok, topics}
    end
  end

  defp topic_for_scope(:all, _event, prefix), do: all(prefix)

  defp topic_for_scope(:session, %Event{session_id: session_id}, prefix) do
    session(session_id, prefix)
  end

  defp topic_for_scope(:run, %Event{session_id: session_id, run_id: run_id}, prefix) do
    run(session_id, run_id, prefix)
  end

  defp normalize_prefix(prefix) when is_binary(prefix) do
    if String.trim(prefix) == "" do
      {:error, config_error(":prefix must be a non-empty string")}
    else
      {:ok, prefix}
    end
  end

  defp normalize_prefix(other) do
    {:error, config_error(":prefix must be a non-empty string, got: #{inspect(other)}")}
  end

  defp normalize_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.reduce_while({:ok, []}, fn
      scope, {:ok, acc} when scope in [:all, :session, :run] ->
        {:cont, {:ok, [scope | acc]}}

      invalid, _acc ->
        {:halt,
         {:error,
          config_error(
            ":scopes entries must be :all, :session, or :run, got: #{inspect(invalid)}"
          )}}
    end)
    |> case do
      {:ok, reversed_scopes} -> {:ok, Enum.reverse(reversed_scopes)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp normalize_scopes(other) do
    {:error, config_error(":scopes must be a list, got: #{inspect(other)}")}
  end

  defp config_error(message) do
    Error.new(:config_invalid, :config, message)
  end
end
