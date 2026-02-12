defmodule AgentSessionManager.Rendering.Studio.ToolSummary do
  @moduledoc """
  Generates human-readable spinner text and summary lines for tool calls.

  Used by `StudioRenderer` to transform raw tool event data into concise
  one-line descriptions suitable for terminal display.
  """

  @type tool_info :: %{
          optional(:name) => String.t(),
          optional(:input) => map() | nil,
          optional(:output) => String.t() | map() | nil,
          optional(:exit_code) => integer() | nil,
          optional(:duration_ms) => integer() | nil,
          optional(:status) => :completed | :failed | :running
        }

  @spec spinner_text(tool_info()) :: String.t()
  def spinner_text(%{name: name} = tool_info) do
    tool = normalize_name(name)
    input = normalize_input(tool_info)
    spinner_text_for(tool, input)
  end

  def spinner_text(_), do: "Using tool"

  @spec summary_line(tool_info()) :: String.t()
  def summary_line(%{name: name} = tool_info) do
    tool = normalize_name(name)
    input = normalize_input(tool_info)
    output = normalize_output(Map.get(tool_info, :output))
    status = normalize_status(tool_info)
    duration = format_duration(Map.get(tool_info, :duration_ms))
    output_size = format_size(if(output == "", do: nil, else: String.length(output)))
    summary_line_for(tool, input, output, status, duration, output_size, tool_info)
  end

  def summary_line(_), do: "tool complete"

  @spec preview_lines(tool_info(), non_neg_integer()) :: [String.t()]
  def preview_lines(tool_info, max_lines) do
    case normalize_output(Map.get(tool_info, :output)) do
      "" ->
        []

      output ->
        output
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(-max_lines)
    end
  end

  @spec format_size(non_neg_integer() | nil) :: String.t()
  def format_size(nil), do: ""
  def format_size(n) when n < 1000, do: "#{n} chars"
  def format_size(n) when n < 10_000, do: "#{Float.round(n / 1000, 1)}k chars"
  def format_size(n), do: "#{div(n, 1000)}k chars"

  @spec shorten_path(String.t(), pos_integer()) :: String.t()
  def shorten_path(path, max_len \\ 60)

  def shorten_path(path, _max_len) when not is_binary(path), do: "file"

  def shorten_path(path, max_len) do
    if String.length(path) <= max_len do
      path
    else
      parts = Path.split(path)

      case parts do
        [first | rest] when length(rest) > 2 ->
          last_two = Enum.take(rest, -2)
          Path.join([first, "...", Path.join(last_two)])

        _ ->
          path
      end
    end
  end

  defp bash_summary(input, status, exit_code, output_size, duration) do
    command = input_value(input, "command") || "bash"
    command = truncate(command, 60)
    code = exit_code || if(status == :failed, do: 1, else: 0)

    result_prefix =
      if status == :failed do
        "Bash failed: #{command}"
      else
        "Ran: #{command}"
      end

    details =
      ["exit #{code}", output_size, duration]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(", ")

    "#{result_prefix} (#{details})"
  end

  defp spinner_text_for("bash", input) do
    case input_value(input, "command") do
      nil -> "Running bash"
      command -> "Running: #{truncate(command, 60)}"
    end
  end

  defp spinner_text_for("Read", input), do: "Reading #{path_from_input(input)}"
  defp spinner_text_for("Write", input), do: "Writing #{path_from_input(input)}"
  defp spinner_text_for("Edit", input), do: "Editing #{path_from_input(input)}"

  defp spinner_text_for("Glob", input),
    do: "Searching for #{input_value(input, "pattern") || "files"}"

  defp spinner_text_for("Grep", input) do
    pattern = input_value(input, "pattern") || "pattern"
    path = input_value(input, "path") || "."
    "Searching \"#{pattern}\" in #{path}"
  end

  defp spinner_text_for("Task", input),
    do: "Running task: #{input_value(input, "description") || "task"}"

  defp spinner_text_for("WebFetch", input) do
    "Fetching #{extract_host(input_value(input, "url")) || "web resource"}"
  end

  defp spinner_text_for("WebSearch", input) do
    query = input_value(input, "query") || ""
    "Searching: \"#{query}\""
  end

  defp spinner_text_for(tool, _input), do: "Using #{tool}"

  defp summary_line_for("bash", input, _output, status, duration, output_size, tool_info) do
    bash_summary(input, status, Map.get(tool_info, :exit_code), output_size, duration)
  end

  defp summary_line_for("Read", input, output, _status, _duration, _output_size, _tool_info) do
    "Read #{shorten_path(path_from_input(input))} (#{line_count(output)} lines)"
  end

  defp summary_line_for("Write", input, _output, _status, _duration, _output_size, _tool_info) do
    content = input_value(input, "content") || ""
    "Wrote #{shorten_path(path_from_input(input))} (#{line_count(content)} lines)"
  end

  defp summary_line_for("Edit", input, _output, _status, _duration, _output_size, _tool_info) do
    "Edited #{shorten_path(path_from_input(input))}"
  end

  defp summary_line_for("Glob", input, output, _status, _duration, _output_size, _tool_info) do
    pattern = input_value(input, "pattern") || "*"
    "Found #{line_count(output)} files matching #{pattern}"
  end

  defp summary_line_for("Grep", input, output, _status, _duration, _output_size, _tool_info) do
    pattern = input_value(input, "pattern") || "pattern"
    "Found #{line_count(output)} matches for \"#{pattern}\""
  end

  defp summary_line_for("Task", input, _output, _status, duration, _output_size, _tool_info) do
    description = input_value(input, "description") || "task"
    "Task complete: #{description}#{optional_suffix(duration)}"
  end

  defp summary_line_for(tool, _input, _output, _status, _duration, output_size, _tool_info) do
    "#{tool} complete#{optional_suffix(output_size)}"
  end

  defp path_from_input(input),
    do: input_value(input, "file_path") || input_value(input, "path") || "file"

  defp optional_suffix(""), do: ""
  defp optional_suffix(value), do: " (#{value})"

  defp normalize_name(name) when is_atom(name), do: normalize_name(Atom.to_string(name))
  defp normalize_name("Bash"), do: "bash"
  defp normalize_name("bash"), do: "bash"
  defp normalize_name(name) when is_binary(name) and name != "", do: name
  defp normalize_name(_), do: "tool"

  defp normalize_input(%{input: input}) when is_map(input), do: input
  defp normalize_input(_), do: %{}

  defp normalize_output(output) when is_binary(output), do: output
  defp normalize_output(%{output: output}), do: normalize_output(output)
  defp normalize_output(%{"output" => output}), do: normalize_output(output)
  defp normalize_output(nil), do: ""
  defp normalize_output(output) when is_map(output), do: inspect(output)
  defp normalize_output(other), do: to_string(other)

  defp normalize_status(%{status: :failed}), do: :failed
  defp normalize_status(%{status: "failed"}), do: :failed
  defp normalize_status(%{exit_code: code}) when is_integer(code) and code != 0, do: :failed
  defp normalize_status(_), do: :completed

  defp format_duration(duration_ms) when is_integer(duration_ms) and duration_ms > 2000 do
    "#{Float.round(duration_ms / 1000, 1)}s"
  end

  defp format_duration(_), do: ""

  defp line_count(nil), do: 0
  defp line_count(""), do: 0

  defp line_count(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> length()
  end

  defp input_value(input, key) when is_map(input) do
    value = Map.get(input, key) || Map.get(input, key_to_atom(key))
    if value in [nil, ""], do: nil, else: to_string(value)
  end

  defp key_to_atom("command"), do: :command
  defp key_to_atom("file_path"), do: :file_path
  defp key_to_atom("path"), do: :path
  defp key_to_atom("content"), do: :content
  defp key_to_atom("pattern"), do: :pattern
  defp key_to_atom("description"), do: :description
  defp key_to_atom("url"), do: :url
  defp key_to_atom("query"), do: :query
  defp key_to_atom(_), do: nil

  defp extract_host(nil), do: nil

  defp extract_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp truncate(text, max) when is_binary(text) do
    text = String.trim(text)

    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end
end
