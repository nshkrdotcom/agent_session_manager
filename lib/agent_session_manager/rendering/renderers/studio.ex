defmodule AgentSessionManager.Rendering.Renderers.StudioRenderer do
  @moduledoc """
  CLI-grade interactive renderer for agent session events.

  Produces human-readable terminal output with:

  - Status indicators during tool execution (static `◐` symbol)
  - Tool call summaries instead of raw JSON output
  - Clean text streaming blocks with indentation
  - Visual separation between reasoning and tool actions

  Designed to match the output quality of Claude Code and Codex CLIs.

  ## Display Modes

  Three verbosity levels for tool output:

  - `:summary` (default) — One-line summary per tool call
  - `:preview` — Summary + last 3 lines of output
  - `:full` — Complete tool output with prefix

  ## Options

    * `:color` — Enable ANSI color output. Default `true`.
    * `:tool_output` — Tool output verbosity. Default `:summary`.
    * `:indent` — Base indentation (spaces). Default `2`.
    * `:tty` — Override TTY detection. Default: auto-detect via `:io.columns/0`.

  ## Output Format

      ● claude-sonnet-4-5 session started

        I'll implement the PubSub integration. Let me start by
        reading the existing sink modules.

      ◐ Reading lib/rendering/sink.ex
      ✓ Read lib/rendering/sink.ex (72 lines)
      ✓ Wrote test/pubsub_sink_test.exs (138 lines)

        Now running the tests.

      ◐ Running: mix test test/pubsub_test.exs
      ✓ Ran: mix test test/pubsub_test.exs (exit 0, 156 chars, 3.2s)

      ● Session complete (end_turn) — 847/312 tokens, 14 tools
  """

  @behaviour AgentSessionManager.Rendering.Renderer

  alias AgentSessionManager.Rendering.Studio.ANSI
  alias AgentSessionManager.Rendering.Studio.ToolSummary

  @type state :: %{
          color: boolean(),
          tool_output: :summary | :preview | :full,
          show_spinner: boolean(),
          indent: non_neg_integer(),
          is_tty: boolean(),
          phase: :idle | :text | :tool,
          current_tool: map() | nil,
          tool_count: non_neg_integer(),
          event_count: non_neg_integer(),
          total_input_tokens: non_neg_integer(),
          total_output_tokens: non_neg_integer()
        }

  @impl true
  def init(opts) do
    is_tty = Keyword.get(opts, :tty, ANSI.tty?())
    tool_output = normalize_tool_output(Keyword.get(opts, :tool_output, :summary))

    {:ok,
     %{
       color: Keyword.get(opts, :color, true),
       tool_output: tool_output,
       show_spinner: Keyword.get(opts, :show_spinner, true),
       indent: Keyword.get(opts, :indent, 2),
       is_tty: is_tty,
       phase: :idle,
       current_tool: nil,
       tool_count: 0,
       event_count: 0,
       total_input_tokens: 0,
       total_output_tokens: 0
     }}
  end

  @impl true
  def render_event(event, state) do
    state = %{state | event_count: state.event_count + 1}
    {iodata, new_state} = render(event, state)
    {:ok, iodata, new_state}
  end

  @impl true
  def finish(state), do: {:ok, [], state}

  defp render(%{type: :run_started, data: data}, state) do
    model = map_get(data, :model) || "unknown"
    icon = ANSI.blue(ANSI.info(), state.color)
    line = ["\n", indent(state), icon, " ", to_string(model), " session started\n"]
    {line, %{state | phase: :idle}}
  end

  defp render(%{type: :message_streamed, data: data}, state) do
    text = map_get(data, :delta) || map_get(data, :content) || ""
    {render_text(text, state), %{state | phase: :text}}
  end

  defp render(%{type: :tool_call_started, data: data}, state) do
    {close_text, state} = close_text_block(state)
    name = map_get(data, :tool_name) || "tool"
    input = map_get(data, :tool_input) || %{}
    spinner_text = ToolSummary.spinner_text(%{name: name, input: input})
    symbol = running_symbol(state)

    line =
      [indent(state), symbol, " ", spinner_text]
      |> maybe_newline(!state.is_tty)

    tool_state = %{
      name: name,
      id: map_get(data, :tool_call_id),
      input: input
    }

    {[close_text, line],
     %{state | phase: :tool, current_tool: tool_state, tool_count: state.tool_count + 1}}
  end

  defp render(%{type: :tool_call_completed, data: data}, state) do
    tool_info = build_tool_info(state.current_tool, data)
    summary = ToolSummary.summary_line(tool_info)
    icon = status_icon(tool_info, state)
    clear = if state.is_tty, do: ANSI.clear_line(), else: []
    line = [indent(state), icon, " ", summary, "\n"]
    extras = render_tool_output(tool_info, state)

    {[clear, line, extras], %{state | phase: :idle, current_tool: nil}}
  end

  defp render(%{type: :token_usage_updated, data: data}, state) do
    input_tokens = map_get(data, :input_tokens) || 0
    output_tokens = map_get(data, :output_tokens) || 0

    {[],
     %{
       state
       | total_input_tokens: input_tokens,
         total_output_tokens: output_tokens
     }}
  end

  defp render(%{type: :message_received}, state), do: {[], state}

  defp render(%{type: :run_completed, data: data}, state) do
    {close_text, state} = close_text_block(state)
    reason = map_get(data, :stop_reason) || "unknown"
    {input_tokens, output_tokens} = final_token_usage(data, state)

    icon = ANSI.blue(ANSI.info(), state.color)

    line = [
      "\n",
      indent(state),
      icon,
      " Session complete (",
      to_string(reason),
      ") — ",
      Integer.to_string(input_tokens),
      "/",
      Integer.to_string(output_tokens),
      " tokens, ",
      Integer.to_string(state.tool_count),
      " tools\n"
    ]

    {[close_text, line], %{state | phase: :idle}}
  end

  defp render(%{type: :run_failed, data: data}, state) do
    {close_text, state} = close_text_block(state)
    message = map_get(data, :error_message) || "unknown error"
    icon = ANSI.red(ANSI.failure(), state.color)
    {[close_text, "\n", indent(state), icon, " ", message, "\n"], %{state | phase: :idle}}
  end

  defp render(%{type: :run_cancelled}, state) do
    {close_text, state} = close_text_block(state)
    icon = ANSI.red(ANSI.failure(), state.color)
    {[close_text, "\n", indent(state), icon, " cancelled\n"], %{state | phase: :idle}}
  end

  defp render(%{type: :error_occurred, data: data}, state) do
    {close_text, state} = close_text_block(state)
    message = map_get(data, :error_message) || "unknown error"
    icon = ANSI.red(ANSI.failure(), state.color)
    {[close_text, indent(state), icon, " ", message, "\n"], %{state | phase: :idle}}
  end

  defp render(%{type: type}, state) do
    {close_text, state} = close_text_block(state)
    label = ANSI.dim("? #{type}", state.color)
    {[close_text, indent(state), label, "\n"], %{state | phase: :idle}}
  end

  defp render_text("", _state), do: []

  defp render_text(text, %{phase: :text}) do
    text
  end

  defp render_text(text, state) do
    ["\n", indent(state), text]
  end

  defp close_text_block(%{phase: :text} = state), do: {"\n", %{state | phase: :idle}}
  defp close_text_block(state), do: {[], state}

  defp render_tool_output(_tool_info, %{tool_output: :summary}), do: []

  defp render_tool_output(tool_info, %{tool_output: :preview} = state) do
    tool_info
    |> ToolSummary.preview_lines(3)
    |> prefixed_lines("│", state)
  end

  defp render_tool_output(tool_info, %{tool_output: :full} = state) do
    output = normalize_output(Map.get(tool_info, :output))

    output
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> prefixed_lines("┊", state)
  end

  defp prefixed_lines([], _prefix, _state), do: []

  defp prefixed_lines(lines, prefix, state) do
    line_indent = String.duplicate(" ", state.indent + 2)
    dim_prefix = ANSI.dim(prefix, state.color)

    Enum.map(lines, fn line ->
      [line_indent, dim_prefix, " ", ANSI.dim(line, state.color), "\n"]
    end)
  end

  defp build_tool_info(current_tool, data) do
    name = map_get(data, :tool_name) || map_get(current_tool, :name) || "tool"
    input = map_get(data, :tool_input) || map_get(current_tool, :input) || %{}
    output = map_get(data, :tool_output)
    exit_code = map_get(data, :exit_code)
    duration_ms = map_get(data, :duration_ms)
    status = normalize_status(map_get(data, :status), exit_code)

    %{
      name: name,
      input: input,
      output: output,
      exit_code: exit_code,
      duration_ms: duration_ms,
      status: status
    }
  end

  defp status_icon(%{status: :failed}, state), do: ANSI.red(ANSI.failure(), state.color)
  defp status_icon(_, state), do: ANSI.green(ANSI.success(), state.color)

  defp running_symbol(%{show_spinner: false} = state), do: ANSI.blue(ANSI.info(), state.color)
  defp running_symbol(state), do: ANSI.cyan(ANSI.running(), state.color)

  defp final_token_usage(data, state) do
    if state.total_input_tokens == 0 and state.total_output_tokens == 0 do
      usage = map_get(data, :token_usage) || %{}
      {map_get(usage, :input_tokens) || 0, map_get(usage, :output_tokens) || 0}
    else
      {state.total_input_tokens, state.total_output_tokens}
    end
  end

  defp normalize_status(status, _exit_code) when status in [:failed, "failed"], do: :failed

  defp normalize_status(_status, exit_code) when is_integer(exit_code) and exit_code != 0,
    do: :failed

  defp normalize_status(_, _), do: :completed

  defp normalize_tool_output(mode) when mode in [:summary, :preview, :full], do: mode
  defp normalize_tool_output(_), do: :summary

  defp map_get(nil, _key), do: nil

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_, _), do: nil

  defp normalize_output(nil), do: ""
  defp normalize_output(output) when is_binary(output), do: output
  defp normalize_output(output), do: to_string(output)

  defp maybe_newline(parts, true), do: [parts, "\n"]
  defp maybe_newline(parts, false), do: parts

  defp indent(state), do: String.duplicate(" ", state.indent)
end
