defmodule AgentSessionManager.Core.TranscriptBuilder do
  @moduledoc """
  Builds provider-agnostic transcripts from events and store-backed histories.
  """

  alias AgentSessionManager.Core.{Error, Event, Transcript}
  alias AgentSessionManager.Ports.SessionStore

  @store_query_keys [:run_id, :type, :since, :limit, :after, :before]

  @spec from_events([Event.t()], keyword()) :: {:ok, Transcript.t()} | {:error, Error.t()}
  def from_events(events, opts \\ []) when is_list(events) do
    with {:ok, session_id} <- resolve_session_id(events, opts) do
      sorted_events = sort_events(events)
      {messages, pending_stream} = build_messages(sorted_events, [], nil)
      messages = maybe_flush_stream(messages, pending_stream)

      transcript =
        Transcript.new(session_id,
          messages: messages,
          last_sequence: latest_sequence(sorted_events),
          last_timestamp: latest_timestamp(sorted_events),
          metadata: %{}
        )

      {:ok, maybe_truncate(transcript, opts)}
    end
  end

  @spec from_store(SessionStore.store(), String.t(), keyword()) ::
          {:ok, Transcript.t()} | {:error, Error.t()}
  def from_store(store, session_id, opts \\ []) when is_binary(session_id) do
    query_opts = Keyword.take(opts, @store_query_keys)

    with {:ok, events} <- SessionStore.get_events(store, session_id, query_opts) do
      from_events(events, Keyword.put(opts, :session_id, session_id))
    end
  end

  @spec update_from_store(SessionStore.store(), Transcript.t(), keyword()) ::
          {:ok, Transcript.t()} | {:error, Error.t()}
  def update_from_store(store, %Transcript{} = transcript, opts \\ []) do
    query_opts =
      opts
      |> Keyword.take(@store_query_keys)
      |> apply_incremental_cursor(transcript)

    with {:ok, events} <- SessionStore.get_events(store, transcript.session_id, query_opts),
         {:ok, increment} <- from_events(events, session_id: transcript.session_id) do
      merged =
        if events == [] do
          transcript
        else
          %Transcript{
            transcript
            | messages: transcript.messages ++ increment.messages,
              last_sequence: increment.last_sequence || transcript.last_sequence,
              last_timestamp: increment.last_timestamp || transcript.last_timestamp,
              metadata: Map.merge(transcript.metadata, increment.metadata)
          }
        end

      {:ok, maybe_truncate(merged, opts)}
    end
  end

  defp resolve_session_id(events, opts) do
    case Keyword.get(opts, :session_id) || infer_session_id(events) do
      session_id when is_binary(session_id) and session_id != "" ->
        {:ok, session_id}

      _ ->
        {:error, Error.new(:validation_error, "session_id is required to build transcript")}
    end
  end

  defp infer_session_id([]), do: nil
  defp infer_session_id([%Event{session_id: session_id} | _]), do: session_id
  defp infer_session_id([_ | rest]), do: infer_session_id(rest)

  defp sort_events(events) do
    events
    |> Enum.with_index()
    |> Enum.sort(fn {left, left_idx}, {right, right_idx} ->
      compare_events(left, left_idx, right, right_idx)
    end)
    |> Enum.map(fn {event, _idx} -> event end)
  end

  defp compare_events(left, left_idx, right, right_idx) do
    left_seq = left.sequence_number
    right_seq = right.sequence_number

    cond do
      is_integer(left_seq) and is_integer(right_seq) and left_seq != right_seq ->
        left_seq < right_seq

      is_integer(left_seq) and not is_integer(right_seq) ->
        true

      not is_integer(left_seq) and is_integer(right_seq) ->
        false

      true ->
        compare_without_sequence(left, left_idx, right, right_idx)
    end
  end

  defp compare_without_sequence(left, left_idx, right, right_idx) do
    timestamp_order = compare_timestamps(left.timestamp, right.timestamp)

    cond do
      timestamp_order == :lt ->
        true

      timestamp_order == :gt ->
        false

      safe_id(left) != safe_id(right) ->
        safe_id(left) <= safe_id(right)

      true ->
        left_idx <= right_idx
    end
  end

  defp compare_timestamps(nil, nil), do: :eq
  defp compare_timestamps(nil, _), do: :gt
  defp compare_timestamps(_, nil), do: :lt
  defp compare_timestamps(left, right), do: DateTime.compare(left, right)

  defp safe_id(%Event{id: id}) when is_binary(id), do: id
  defp safe_id(_), do: ""

  defp build_messages([], messages, pending_stream), do: {messages, pending_stream}

  defp build_messages([%Event{} = event | rest], messages, pending_stream) do
    {messages, pending_stream} =
      case event.type do
        :message_streamed ->
          append_stream_chunk(messages, pending_stream, event)

        :message_received ->
          append_message_received(messages, pending_stream, event)

        :message_sent ->
          append_message_sent(messages, pending_stream, event)

        :tool_call_started ->
          append_tool_call_started(messages, pending_stream, event)

        :tool_call_completed ->
          append_tool_result(messages, pending_stream, event)

        :tool_call_failed ->
          append_tool_result(messages, pending_stream, event)

        _ ->
          {messages, pending_stream}
      end

    build_messages(rest, messages, pending_stream)
  end

  defp append_stream_chunk(messages, pending_stream, %Event{} = event) do
    chunk =
      event.data
      |> stream_content()
      |> to_string_or_empty()

    if chunk == "" do
      {messages, pending_stream}
    else
      stream = pending_stream || %{content: "", metadata: %{}}

      {
        messages,
        %{
          content: stream.content <> chunk,
          metadata: merge_message_metadata(stream.metadata, event)
        }
      }
    end
  end

  defp append_message_received(messages, pending_stream, %Event{} = event) do
    role = normalize_role(event.data[:role], :assistant)

    if role == :assistant and pending_stream do
      content = to_string_or_empty(event.data[:content])
      content = if content == "", do: pending_stream.content, else: content
      message = base_message(:assistant, content, pending_stream.metadata)
      {messages ++ [message], nil}
    else
      flushed = maybe_flush_stream(messages, pending_stream)
      content = to_string_or_empty(event.data[:content])

      if content == "" do
        {flushed, nil}
      else
        message = base_message(role, content, event_metadata(event))
        {flushed ++ [message], nil}
      end
    end
  end

  defp append_message_sent(messages, pending_stream, %Event{} = event) do
    flushed = maybe_flush_stream(messages, pending_stream)
    role = normalize_role(event.data[:role], :user)
    content = to_string_or_empty(event.data[:content])

    if content == "" do
      {flushed, nil}
    else
      message = base_message(role, content, event_metadata(event))
      {flushed ++ [message], nil}
    end
  end

  defp append_tool_call_started(messages, pending_stream, %Event{} = event) do
    flushed = maybe_flush_stream(messages, pending_stream)
    tool_call_id = normalize_tool_call_id(event.data)

    message = %{
      role: :assistant,
      content: nil,
      tool_call_id: tool_call_id,
      tool_name: to_string_or_nil(event.data[:tool_name]),
      tool_input: normalize_tool_input(event.data),
      tool_output: nil,
      metadata: event_metadata(event)
    }

    {flushed ++ [message], nil}
  end

  defp append_tool_result(messages, pending_stream, %Event{} = event) do
    flushed = maybe_flush_stream(messages, pending_stream)
    tool_call_id = normalize_tool_call_id(event.data)
    tool_output = normalize_tool_output(event.data)

    message = %{
      role: :tool,
      content: nil,
      tool_call_id: tool_call_id,
      tool_name: to_string_or_nil(event.data[:tool_name]),
      tool_input: nil,
      tool_output: tool_output,
      metadata: event_metadata(event)
    }

    {flushed ++ [message], nil}
  end

  defp normalize_tool_call_id(data) when is_map(data) do
    data[:tool_call_id]
  end

  defp normalize_tool_call_id(_), do: nil

  defp normalize_tool_input(data) when is_map(data) do
    input = data[:tool_input]

    if is_map(input), do: input, else: nil
  end

  defp normalize_tool_input(_), do: nil

  defp normalize_tool_output(data) when is_map(data) do
    data[:tool_output]
  end

  defp normalize_tool_output(_), do: nil

  defp maybe_flush_stream(messages, nil), do: messages

  defp maybe_flush_stream(messages, pending_stream) do
    content = to_string_or_empty(pending_stream.content)

    if content == "" do
      messages
    else
      messages ++ [base_message(:assistant, content, pending_stream.metadata)]
    end
  end

  defp base_message(role, content, metadata) do
    %{
      role: role,
      content: content,
      tool_call_id: nil,
      tool_name: nil,
      tool_input: nil,
      tool_output: nil,
      metadata: metadata || %{}
    }
  end

  defp normalize_role(role, _default) when role in [:system, :user, :assistant, :tool], do: role

  defp normalize_role(role, default) when is_binary(role) do
    case String.downcase(role) do
      "system" -> :system
      "user" -> :user
      "assistant" -> :assistant
      "tool" -> :tool
      _ -> default
    end
  end

  defp normalize_role(_, default), do: default

  defp stream_content(data) when is_map(data) do
    data[:delta] || data[:content]
  end

  defp stream_content(_), do: nil

  defp event_metadata(%Event{} = event) do
    %{}
    |> maybe_put(:event_id, event.id)
    |> maybe_put(:run_id, event.run_id)
    |> maybe_put(:timestamp, event.timestamp)
    |> maybe_put(:sequence_number, event.sequence_number)
    |> Map.merge(event.metadata || %{})
  end

  defp merge_message_metadata(existing, event) do
    Map.merge(existing || %{}, event_metadata(event))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp latest_sequence(events) do
    events
    |> Enum.map(& &1.sequence_number)
    |> Enum.filter(&is_integer/1)
    |> case do
      [] -> nil
      sequence_numbers -> Enum.max(sequence_numbers)
    end
  end

  defp latest_timestamp([]), do: nil

  defp latest_timestamp(events) do
    events
    |> List.last()
    |> Map.get(:timestamp)
  end

  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(content) when is_binary(content), do: content
  defp to_string_or_empty(content), do: inspect(content)

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value), do: inspect(value)

  @default_chars_per_token 4

  defp maybe_truncate(%Transcript{} = transcript, opts) do
    transcript
    |> truncate_by_max_messages(opts)
    |> truncate_by_chars(opts)
  end

  defp truncate_by_max_messages(%Transcript{} = transcript, opts) do
    case Keyword.get(opts, :max_messages) do
      max when is_integer(max) and max > 0 ->
        %{transcript | messages: Enum.take(transcript.messages, -max)}

      _ ->
        transcript
    end
  end

  defp truncate_by_chars(%Transcript{} = transcript, opts) do
    max_chars = resolve_max_chars(opts)

    case max_chars do
      nil ->
        transcript

      budget when is_integer(budget) and budget > 0 ->
        trimmed = trim_messages_to_char_budget(Enum.reverse(transcript.messages), budget, 0, [])
        %{transcript | messages: trimmed}

      _ ->
        transcript
    end
  end

  defp resolve_max_chars(opts) do
    explicit = Keyword.get(opts, :max_chars)

    approx_tokens = Keyword.get(opts, :max_tokens_approx)

    cond do
      is_integer(explicit) and explicit > 0 ->
        explicit

      is_integer(approx_tokens) and approx_tokens > 0 ->
        approx_tokens * @default_chars_per_token

      true ->
        nil
    end
  end

  defp trim_messages_to_char_budget([], _budget, _used, acc), do: acc

  defp trim_messages_to_char_budget([msg | rest], budget, used, acc) do
    chars = message_char_count(msg)
    new_used = used + chars

    if new_used > budget do
      acc
    else
      trim_messages_to_char_budget(rest, budget, new_used, [msg | acc])
    end
  end

  defp message_char_count(%{content: content}) when is_binary(content), do: String.length(content)
  defp message_char_count(%{tool_name: name}) when is_binary(name), do: String.length(name)
  defp message_char_count(_), do: 0

  defp apply_incremental_cursor(query_opts, %Transcript{last_sequence: sequence})
       when is_integer(sequence) and sequence >= 0 do
    Keyword.put(query_opts, :after, sequence)
  end

  defp apply_incremental_cursor(query_opts, %Transcript{last_timestamp: %DateTime{} = timestamp}) do
    if Keyword.has_key?(query_opts, :since) do
      query_opts
    else
      Keyword.put(query_opts, :since, timestamp)
    end
  end

  defp apply_incremental_cursor(query_opts, _transcript), do: query_opts
end
