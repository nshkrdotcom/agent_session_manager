Code.require_file("common.exs", __DIR__)

defmodule ASM.Examples.LiveCodexAppServerDynamicTools do
  @moduledoc false

  alias ASM.{Examples.Common, HostTool}

  @tool_name "echo_json"
  @sentinel "ASM_HOST_TOOL_OK"
  @default_prompt """
  Use the echo_json dynamic tool exactly once with message "#{@sentinel}".
  After the tool result is returned, reply with a one-sentence summary of the tool output.
  """

  def main do
    config =
      Common.example_config!(
        Path.basename(__ENV__.file),
        "Run a live ASM Codex app-server dynamic host-tool turn.",
        String.trim(@default_prompt),
        provider_sdk?: true
      )

    Common.assert_provider!(config, :codex)
    ensure_codex_sdk!(config)

    session = Common.start_session!(config)

    try do
      %{events: events, result: result} =
        Common.stream_to_result!(session, config.prompt, app_server_opts(config))

      request = find_host_tool_event!(events, :host_tool_requested)
      response = find_host_tool_event!(events, :host_tool_completed)

      unless request.payload.tool_name == @tool_name do
        fail!("expected #{@tool_name} request, got #{inspect(request.payload.tool_name)}")
      end

      unless response.payload.success? do
        fail!("expected successful host tool response, got #{inspect(response.payload)}")
      end

      assert_app_server_result!(result)
      assert_non_empty_text!(result.text)

      Common.print_result_summary(result, label: "codex_app_server_dynamic_tool")

      IO.puts("""
      dynamic_tool_requested=#{request.payload.tool_name}
      dynamic_tool_request_id=#{request.payload.id}
      dynamic_tool_provider_session_id=#{request.payload.provider_session_id}
      dynamic_tool_response_success=#{response.payload.success?}
      """)
    after
      _ = ASM.stop_session(session)
    end
  end

  defp ensure_codex_sdk!(config) do
    Common.ensure_provider_sdk_loaded!(:codex,
      sdk_root: config.sdk_root,
      cli_path: Keyword.get(config.session_opts, :cli_path)
    )
  end

  defp app_server_opts(config) do
    [
      lane: :sdk,
      app_server: true,
      cwd: Keyword.get(config.session_opts, :cwd) || File.cwd!(),
      host_tools: [host_tool_spec()],
      tools: %{@tool_name => &execute_echo_json/2},
      stream_timeout_ms: 120_000,
      backend_opts: [run_opts: [timeout_ms: 120_000]]
    ]
  end

  defp host_tool_spec do
    HostTool.Spec.new!(
      name: @tool_name,
      description: "Echoes JSON arguments back to the Codex turn through the host runtime.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "message" => %{
            "type" => "string",
            "description" => "Message to echo."
          }
        },
        "required" => ["message"],
        "additionalProperties" => false
      }
    )
  end

  defp execute_echo_json(args, request) do
    {:ok,
     %{
       "tool" => request.tool_name,
       "requestId" => request.id,
       "marker" => @sentinel,
       "arguments" => args
     }}
  end

  defp find_host_tool_event!(events, kind) do
    case Enum.find(events, &(&1.kind == kind)) do
      nil -> fail!("expected #{inspect(kind)} event, got #{inspect(Enum.map(events, & &1.kind))}")
      event -> event
    end
  end

  defp assert_app_server_result!(result) do
    metadata = result.metadata || %{}

    cond do
      metadata[:lane] != :sdk ->
        fail!("expected sdk lane metadata, got #{inspect(metadata[:lane])}")

      metadata[:runtime] != ASM.ProviderBackend.SDK.CodexAppServer ->
        fail!("expected Codex app-server runtime, got #{inspect(metadata[:runtime])}")

      :host_tools not in Map.get(metadata, :capabilities, []) ->
        fail!("expected :host_tools capability in result metadata")

      true ->
        :ok
    end
  end

  defp assert_non_empty_text!(text) when is_binary(text) do
    if String.trim(text) == "" do
      fail!("expected non-empty final assistant text")
    end
  end

  defp assert_non_empty_text!(_text), do: fail!("expected non-empty final assistant text")

  defp fail!(message) do
    IO.puts(message)
    System.halt(1)
  end
end

ASM.Examples.LiveCodexAppServerDynamicTools.main()
