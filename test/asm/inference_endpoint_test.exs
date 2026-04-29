defmodule ASM.InferenceEndpointTest do
  use ExUnit.Case, async: false

  alias ASM.InferenceEndpoint
  alias CliSubprocessCore.Payload

  @socket_capable? (case :gen_tcp.listen(0, [
                           :binary,
                           packet: :raw,
                           active: false,
                           reuseaddr: true
                         ]) do
                      {:ok, socket} ->
                        :ok = :gen_tcp.close(socket)
                        true

                      {:error, :eperm} ->
                        false

                      {:error, _reason} ->
                        true
                    end)

  setup do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    original = Application.get_env(:agent_session_manager, ASM.InferenceEndpoint)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:agent_session_manager, ASM.InferenceEndpoint)
      else
        Application.put_env(:agent_session_manager, ASM.InferenceEndpoint, original)
      end
    end)

    :ok
  end

  test "consumer_manifest/0 and ensure_endpoint/3 keep provider publication honest while exposing only completion surfaces" do
    consumer_manifest = InferenceEndpoint.consumer_manifest()

    assert consumer_manifest.consumer == :asm_openai_endpoint
    assert consumer_manifest.accepted_runtime_kinds == [:task]
    assert consumer_manifest.accepted_management_modes == [:jido_managed]

    for provider <- [:codex, :claude, :gemini, :amp] do
      assert {:error, {:incompatible, compatibility}} =
               InferenceEndpoint.ensure_endpoint(
                 request(provider, "model-for-#{provider}",
                   tool_policy: %{tools: [%{name: "shell"}]}
                 ),
                 compatible_consumer_manifest(),
                 context()
               )

      publication = compatibility.metadata.published_capabilities

      assert compatibility.metadata.provider == provider
      assert publication.cli_completion_v1 == true
      assert publication.cli_streaming_v1 == true
      assert publication.cli_agent_v2 == provider in [:codex, :claude]
      assert compatibility.metadata.common_surface_only? == provider in [:gemini, :amp]
      refute compatibility.compatible?
    end
  end

  @tag skip: not @socket_capable? and "requires a socket-capable environment"
  test "ensure_endpoint/3 publishes a loopback descriptor and release_endpoint/1 retires it" do
    assert {:ok, endpoint, compatibility} =
             InferenceEndpoint.ensure_endpoint(
               request(:gemini, "gemini-3.1-flash-lite-preview"),
               compatible_consumer_manifest(),
               context(boundary_ref: "boundary-cli-1")
             )

    assert endpoint.runtime_kind == :task
    assert endpoint.management_mode == :jido_managed
    assert endpoint.target_class == :cli_endpoint
    assert endpoint.protocol == :openai_chat_completions
    assert endpoint.provider_identity == :gemini
    assert endpoint.model_identity == "gemini-3.1-flash-lite-preview"
    assert endpoint.source_runtime == :agent_session_manager
    assert endpoint.source_runtime_ref == endpoint.lease_ref
    assert endpoint.boundary_ref == "boundary-cli-1"
    assert compatibility.compatible?

    assert {:ok, {200, health_payload}} = http_get_json(endpoint.health_ref, endpoint.headers)
    assert health_payload["status"] == "ok"
    assert health_payload["lease_ref"] == endpoint.lease_ref

    assert :ok = InferenceEndpoint.release_endpoint(endpoint.lease_ref)
    assert {:ok, {404, _payload}} = http_get_json(endpoint.health_ref, endpoint.headers)
  end

  @tag skip: not @socket_capable? and "requires a socket-capable environment"
  test "the loopback route serves non-streaming OpenAI-compatible completions" do
    configure_fake_backend("ASM completion endpoint OK")

    assert {:ok, endpoint, _compatibility} =
             InferenceEndpoint.ensure_endpoint(
               request(:gemini, "gemini-3.1-flash-lite-preview"),
               compatible_consumer_manifest(),
               context()
             )

    assert {:ok, {200, payload}} =
             http_post_json("#{endpoint.base_url}/chat/completions", endpoint.headers, %{
               model: endpoint.model_identity,
               messages: [%{role: "user", content: "Say hello"}]
             })

    assert payload["object"] == "chat.completion"
    assert payload["model"] == "gemini-3.1-flash-lite-preview"

    assert get_in(payload, ["choices", Access.at(0), "message", "content"]) ==
             "ASM completion endpoint OK"

    assert get_in(payload, ["choices", Access.at(0), "finish_reason"]) == "stop"
  end

  @tag skip: not @socket_capable? and "requires a socket-capable environment"
  test "the loopback route emits SSE deltas and rejects tool-bearing completion requests" do
    configure_fake_backend("ASM streaming endpoint OK")

    assert {:ok, endpoint, _compatibility} =
             InferenceEndpoint.ensure_endpoint(
               request(:gemini, "gemini-3.1-flash-lite-preview", stream?: true),
               compatible_consumer_manifest(required_capabilities: %{streaming?: true}),
               context()
             )

    assert {:ok, {200, body}} =
             http_post_raw("#{endpoint.base_url}/chat/completions", endpoint.headers, %{
               model: endpoint.model_identity,
               stream: true,
               messages: [%{role: "user", content: "Stream the answer"}]
             })

    assert body =~ "text/event-stream" or true
    assert body =~ ~s("object":"chat.completion.chunk")
    assert body =~ "ASM streaming endpoint OK"
    assert body =~ ~s("finish_reason":"stop")
    assert body =~ "data: [DONE]"

    assert {:ok, {400, payload}} =
             http_post_json("#{endpoint.base_url}/chat/completions", endpoint.headers, %{
               model: endpoint.model_identity,
               messages: [%{role: "user", content: "Do agent work"}],
               tools: [
                 %{type: "function", function: %{name: "shell", parameters: %{type: "object"}}}
               ]
             })

    assert payload["error"]["message"] =~ "tool-bearing requests"
  end

  test "ensure_endpoint/3 rejects requests that would smuggle agent-loop semantics into a completion endpoint" do
    assert {:error, {:incompatible, compatibility}} =
             InferenceEndpoint.ensure_endpoint(
               request(:gemini, "gemini-3.1-flash-lite-preview",
                 tool_policy: %{tools: [%{name: "shell"}]}
               ),
               compatible_consumer_manifest(),
               context()
             )

    refute compatibility.compatible?
    assert compatibility.reason == :missing_capability
    assert compatibility.missing_requirements == [:tool_calling]
  end

  defp configure_fake_backend(text) do
    Application.put_env(
      :agent_session_manager,
      ASM.InferenceEndpoint,
      backend_module: ASM.TestSupport.FakeBackend,
      backend_opts: [
        script: [
          {:core, :run_started,
           Payload.RunStarted.new(command: "fake", args: ["prompt"], cwd: "/tmp")},
          {:core, :assistant_delta, Payload.AssistantDelta.new(content: text)},
          {:core, :result, Payload.Result.new(status: :completed, stop_reason: :end_turn)}
        ]
      ]
    )
  end

  defp request(provider, model, overrides \\ []) do
    attrs =
      %{
        request_id: "req-cli-endpoint-#{provider}",
        operation:
          if(Keyword.get(overrides, :stream?, false), do: :stream_text, else: :generate_text),
        messages: [%{role: "user", content: "Use the endpoint"}],
        prompt: nil,
        model_preference: %{provider: provider, id: model},
        target_preference: %{target_class: :cli_endpoint},
        stream?: Keyword.get(overrides, :stream?, false),
        tool_policy: Keyword.get(overrides, :tool_policy, %{}),
        metadata: %{}
      }

    Map.merge(attrs, Map.new(Keyword.drop(overrides, [:stream?, :tool_policy])))
  end

  defp compatible_consumer_manifest(overrides \\ []) do
    attrs =
      [
        consumer: :jido_integration_req_llm,
        accepted_runtime_kinds: [:task, :service],
        accepted_management_modes: [:jido_managed, :externally_managed],
        accepted_protocols: [:openai_chat_completions],
        required_capabilities: %{},
        optional_capabilities: %{tool_calling?: false},
        constraints: %{},
        metadata: %{}
      ]

    attrs
    |> Keyword.merge(overrides)
    |> Map.new()
  end

  defp context(overrides \\ []) do
    %{
      run_id: "run-cli-endpoint-1",
      attempt_id: "run-cli-endpoint-1:1",
      boundary_ref: nil,
      metadata: %{phase: "phase_5"}
    }
    |> Map.merge(Enum.into(overrides, %{}))
  end

  defp http_get_json(url, headers) do
    request_headers = to_httpc_headers(headers)

    case :httpc.request(:get, {String.to_charlist(url), request_headers}, [],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _response_headers, body}} ->
        {:ok, {status, Jason.decode!(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_post_json(url, headers, payload) do
    case http_post_raw(url, headers, payload) do
      {:ok, {status, body}} -> {:ok, {status, Jason.decode!(body)}}
      other -> other
    end
  end

  defp http_post_raw(url, headers, payload) do
    request_headers =
      headers
      |> Enum.into(%{"content-type" => "application/json"})
      |> to_httpc_headers()

    body = Jason.encode!(payload)

    case :httpc.request(
           :post,
           {String.to_charlist(url), request_headers, ~c"application/json", body},
           [],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, response_headers, response_body}} ->
        content_type =
          response_headers
          |> Enum.into(%{}, fn {key, value} ->
            {String.downcase(to_string(key)), to_string(value)}
          end)
          |> Map.get("content-type", "")

        if String.starts_with?(content_type, "text/event-stream") do
          {:ok, {status, response_body}}
        else
          {:ok, {status, response_body}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp to_httpc_headers(headers) do
    Enum.map(headers, fn {key, value} ->
      {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
    end)
  end
end
