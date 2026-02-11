defmodule AgentSessionManager.PubSub.Topic do
  @moduledoc """
  Topic naming conventions for ASM PubSub integration.

  Topics follow a hierarchical colon-separated scheme:

      {prefix}:session:{session_id}
      {prefix}:session:{session_id}:run:{run_id}
      {prefix}:session:{session_id}:type:{event_type}

  The default prefix is `"asm"`.

  ## Examples

      iex> Topic.build_session_topic("ses_abc123")
      "asm:session:ses_abc123"

      iex> Topic.build_run_topic("ses_abc123", "run_def456")
      "asm:session:ses_abc123:run:run_def456"

      iex> Topic.build(%{session_id: "ses_abc123", run_id: "run_def456"}, scope: :run)
      "asm:session:ses_abc123:run:run_def456"
  """

  @default_prefix "asm"

  @doc """
  Builds a topic string from an event map and options.

  ## Options

    * `:prefix` - Topic prefix. Default `"asm"`.
    * `:scope` - One of `:session`, `:run`, `:type`. Default `:session`.
  """
  @spec build(map(), keyword()) :: String.t()
  def build(event, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, @default_prefix)
    scope = Keyword.get(opts, :scope, :session)

    case scope do
      :session ->
        build_session_topic(prefix, event[:session_id])

      :run ->
        build_run_topic(prefix, event[:session_id], event[:run_id])

      :type ->
        build_type_topic(prefix, event[:session_id], event[:type])

      other ->
        raise ArgumentError,
              "invalid :scope #{inspect(other)} (expected :session, :run, or :type)"
    end
  end

  @doc """
  Builds a session-scoped topic.

      iex> Topic.build_session_topic("ses_abc123")
      "asm:session:ses_abc123"
  """
  @spec build_session_topic(String.t(), String.t()) :: String.t()
  def build_session_topic(prefix \\ @default_prefix, session_id) do
    "#{prefix}:session:#{session_id}"
  end

  @doc """
  Builds a run-scoped topic.

      iex> Topic.build_run_topic("ses_abc123", "run_def456")
      "asm:session:ses_abc123:run:run_def456"
  """
  @spec build_run_topic(String.t(), String.t(), String.t()) :: String.t()
  def build_run_topic(prefix \\ @default_prefix, session_id, run_id) do
    "#{prefix}:session:#{session_id}:run:#{run_id}"
  end

  @doc """
  Builds a type-scoped topic.

      iex> Topic.build_type_topic("ses_abc123", :tool_call_started)
      "asm:session:ses_abc123:type:tool_call_started"
  """
  @spec build_type_topic(String.t(), String.t(), atom() | String.t()) :: String.t()
  def build_type_topic(prefix \\ @default_prefix, session_id, type) do
    "#{prefix}:session:#{session_id}:type:#{type}"
  end
end
