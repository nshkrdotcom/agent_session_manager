defmodule ASM.InferenceEndpoint.Server do
  @moduledoc false

  use GenServer

  @accept_timeout 250
  @max_header_bytes 64 * 1024
  @recv_timeout 5_000

  alias ASM.InferenceEndpoint.LeaseStore
  alias ASM.Migration.MainCompat

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))
  end

  @spec base_url_root() :: {:ok, String.t()} | {:error, term()}
  def base_url_root, do: GenServer.call(__MODULE__, :base_url_root)

  @impl true
  def init(:ok) do
    {:ok,
     %{
       listener: nil,
       port: nil,
       acceptor_pid: nil,
       acceptor_ref: nil
     }}
  end

  @impl true
  def handle_call(:base_url_root, _from, state) do
    case ensure_listener(state) do
      {:ok, next_state} ->
        {:reply, {:ok, "http://127.0.0.1:#{next_state.port}"}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{acceptor_ref: ref} = state) do
    {:noreply, %{state | listener: nil, port: nil, acceptor_pid: nil, acceptor_ref: nil}}
  end

  defp ensure_listener(%{listener: listener} = state) when is_port(listener), do: {:ok, state}

  defp ensure_listener(state) do
    with {:ok, listener} <-
           :gen_tcp.listen(0, [
             :binary,
             packet: :raw,
             active: false,
             reuseaddr: true,
             ip: {127, 0, 0, 1}
           ]),
         {:ok, port} <- :inet.port(listener),
         {:ok, acceptor_pid} <-
           Task.Supervisor.start_child(ASM.TaskSupervisor, fn -> accept_loop(listener) end) do
      acceptor_ref = Process.monitor(acceptor_pid)

      {:ok,
       %{
         state
         | listener: listener,
           port: port,
           acceptor_pid: acceptor_pid,
           acceptor_ref: acceptor_ref
       }}
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp accept_loop(listener) do
    case :gen_tcp.accept(listener, @accept_timeout) do
      {:ok, socket} ->
        _ =
          Task.Supervisor.start_child(ASM.TaskSupervisor, fn ->
            handle_socket(socket)
          end)

        accept_loop(listener)

      {:error, :timeout} ->
        accept_loop(listener)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_socket(socket) do
    _ = :inet.setopts(socket, active: false)

    case read_request(socket) do
      {:ok, request} ->
        dispatch(socket, request)

      {:error, {status, message}} ->
        send_error(socket, status, message)
    end
  after
    _ = :gen_tcp.close(socket)
  end

  defp dispatch(socket, %{method: method, path: path, headers: headers, body: body}) do
    case {method, String.split(path, "/", trim: true)} do
      {"GET", ["leases", lease_ref, "health"]} ->
        with {:ok, lease} <- fetch_lease(lease_ref),
             :ok <- authorize(headers, lease.auth_token) do
          send_json(socket, 200, %{
            status: "ok",
            endpoint_id: lease.endpoint_id,
            lease_ref: lease_ref,
            provider: lease.provider
          })
        else
          {:error, :unauthorized} -> send_error(socket, 401, "unauthorized")
          :error -> send_error(socket, 404, "unknown lease")
        end

      {"POST", ["leases", lease_ref, "v1", "chat", "completions"]} ->
        with {:ok, lease} <- fetch_lease(lease_ref),
             :ok <- authorize(headers, lease.auth_token),
             {:ok, payload} <- decode_json(body),
             :ok <- validate_model(payload, lease),
             :ok <- validate_request_capabilities(payload, lease),
             {:ok, prompt} <- MainCompat.input_to_prompt(payload) do
          dispatch_completion(socket, lease, payload, prompt)
        else
          {:error, :unauthorized} -> send_error(socket, 401, "unauthorized")
          :error -> send_error(socket, 404, "unknown lease")
          {:error, {:invalid_request, message}} -> send_error(socket, 400, message)
          {:error, %ASM.Error{} = error} -> send_error(socket, 400, error.message)
        end

      {_method, _segments} ->
        send_error(socket, 404, "not found")
    end
  end

  defp complete(socket, lease, prompt) do
    case run_completion(lease, prompt) do
      {:ok, result} ->
        send_json(socket, 200, completion_response(lease, result))

      {:error, %ASM.Error{} = error} ->
        send_error(socket, 500, error.message)
    end
  end

  defp dispatch_completion(socket, lease, payload, prompt) do
    case stream_request?(payload) do
      true -> stream_completion(socket, lease, prompt)
      false -> complete(socket, lease, prompt)
    end
  end

  defp stream_completion(socket, lease, prompt) do
    with {:ok, session} <- ASM.start_session(session_opts(lease)),
         :ok <- send_stream_headers(socket),
         {:ok, result} <- stream_run(socket, session, lease, prompt) do
      _ = send_sse(socket, stream_finish_chunk(lease, result))
      _ = send_sse(socket, "[DONE]")
      finish_chunked(socket)
    else
      {:error, %ASM.Error{} = error} ->
        send_error(socket, 500, error.message)
    end
  end

  defp stream_run(socket, session, lease, prompt) do
    result =
      try do
        events =
          session
          |> ASM.stream(prompt, run_opts(lease))
          |> Enum.reduce([], fn event, acc ->
            case ASM.Event.text_delta(event) do
              nil -> :ok
              "" -> :ok
              delta -> _ = send_sse(socket, stream_delta_chunk(lease, delta))
            end

            [event | acc]
          end)
          |> Enum.reverse()

        {:ok, ASM.Stream.final_result(events)}
      after
        _ = ASM.stop_session(session)
      end

    result
  end

  defp run_completion(lease, prompt) do
    with {:ok, session} <- ASM.start_session(session_opts(lease)) do
      try do
        ASM.query(session, prompt, run_opts(lease))
      after
        _ = ASM.stop_session(session)
      end
    end
  end

  defp session_opts(lease) do
    [provider: lease.provider] ++ Keyword.get(runtime_override_opts(), :session_opts, [])
  end

  defp run_opts(lease) do
    runtime_override_opts()
    |> Keyword.get(:query_opts, [])
    |> Keyword.put_new(:model, lease.model_identity)
    |> maybe_put(:backend_module, runtime_override_opts()[:backend_module])
    |> maybe_put(:backend_opts, runtime_override_opts()[:backend_opts])
  end

  defp runtime_override_opts do
    Application.get_env(:agent_session_manager, ASM.InferenceEndpoint, [])
  end

  defp validate_model(payload, lease) do
    requested_model = value(payload, :model)

    if is_nil(requested_model) or to_string(requested_model) == lease.model_identity do
      :ok
    else
      {:error,
       {:invalid_request,
        "endpoint is pinned to model #{lease.model_identity}, got #{inspect(requested_model)}"}}
    end
  end

  defp validate_request_capabilities(payload, lease) do
    cond do
      stream_request?(payload) and not lease.endpoint_capabilities.streaming? ->
        {:error, {:invalid_request, "streaming is not published for this endpoint"}}

      request_uses_tools?(payload) ->
        {:error,
         {:invalid_request, "tool-bearing requests are not supported on cli completion endpoints"}}

      true ->
        :ok
    end
  end

  defp stream_request?(payload) do
    case value(payload, :stream, false) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp request_uses_tools?(payload) do
    non_empty_list?(value(payload, :tools, [])) or
      value(payload, :tool_choice) not in [nil, :none, "none"]
  end

  defp non_empty_list?(value) when is_list(value), do: value != []
  defp non_empty_list?(_value), do: false

  defp fetch_lease(lease_ref), do: LeaseStore.fetch(lease_ref)

  defp authorize(headers, auth_token) do
    case Map.get(headers, "authorization") do
      "Bearer " <> ^auth_token -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = payload} -> {:ok, payload}
      {:ok, _other} -> {:error, {:invalid_request, "request body must be a JSON object"}}
      {:error, error} -> {:error, {:invalid_request, Exception.message(error)}}
    end
  end

  defp send_stream_headers(socket) do
    :gen_tcp.send(
      socket,
      [
        "HTTP/1.1 200 OK\r\n",
        "content-type: text/event-stream\r\n",
        "cache-control: no-cache\r\n",
        "connection: close\r\n",
        "transfer-encoding: chunked\r\n",
        "\r\n"
      ]
    )
  end

  defp send_sse(socket, data) when is_binary(data) do
    send_chunk(socket, "data: " <> data <> "\n\n")
  end

  defp send_sse(socket, %{} = data) do
    send_chunk(socket, "data: " <> Jason.encode!(data) <> "\n\n")
  end

  defp finish_chunked(socket) do
    :gen_tcp.send(socket, "0\r\n\r\n")
  end

  defp send_chunk(socket, chunk) when is_binary(chunk) do
    size = Integer.to_string(byte_size(chunk), 16)
    :gen_tcp.send(socket, [size, "\r\n", chunk, "\r\n"])
  end

  defp completion_response(lease, result) do
    %{
      id: "chatcmpl_#{lease.endpoint_id}",
      object: "chat.completion",
      created: System.system_time(:second),
      model: lease.model_identity,
      choices: [
        %{
          index: 0,
          message: %{
            role: "assistant",
            content: result.text
          },
          finish_reason: openai_finish_reason(result.stop_reason)
        }
      ]
    }
  end

  defp stream_delta_chunk(lease, delta) do
    %{
      id: "chatcmpl_#{lease.endpoint_id}",
      object: "chat.completion.chunk",
      created: System.system_time(:second),
      model: lease.model_identity,
      choices: [
        %{
          index: 0,
          delta: %{content: delta},
          finish_reason: nil
        }
      ]
    }
  end

  defp stream_finish_chunk(lease, result) do
    %{
      id: "chatcmpl_#{lease.endpoint_id}",
      object: "chat.completion.chunk",
      created: System.system_time(:second),
      model: lease.model_identity,
      choices: [
        %{
          index: 0,
          delta: %{},
          finish_reason: openai_finish_reason(result.stop_reason)
        }
      ]
    }
  end

  defp openai_finish_reason(:end_turn), do: "stop"
  defp openai_finish_reason(:stop), do: "stop"
  defp openai_finish_reason(:length), do: "length"
  defp openai_finish_reason(:tool_calls), do: "tool_calls"
  defp openai_finish_reason(:user_cancelled), do: "cancelled"
  defp openai_finish_reason(nil), do: "stop"
  defp openai_finish_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp openai_finish_reason(reason) when is_binary(reason), do: reason

  defp send_json(socket, status, %{} = payload) do
    body = Jason.encode!(payload)
    send_response(socket, status, "application/json", body)
  end

  defp send_error(socket, status, message) when is_binary(message) do
    send_json(socket, status, %{
      error: %{
        message: message,
        type: "invalid_request_error",
        code: error_code(status)
      }
    })
  end

  defp send_response(socket, status, content_type, body) when is_binary(body) do
    :gen_tcp.send(
      socket,
      [
        "HTTP/1.1 ",
        Integer.to_string(status),
        " ",
        reason_phrase(status),
        "\r\n",
        "content-type: ",
        content_type,
        "\r\n",
        "content-length: ",
        Integer.to_string(byte_size(body)),
        "\r\n",
        "connection: close\r\n",
        "\r\n",
        body
      ]
    )
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(400), do: "Bad Request"
  defp reason_phrase(401), do: "Unauthorized"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(500), do: "Internal Server Error"

  defp error_code(400), do: "invalid_request"
  defp error_code(401), do: "unauthorized"
  defp error_code(404), do: "not_found"
  defp error_code(_status), do: "runtime_error"

  defp read_request(socket) do
    with {:ok, raw_headers, body_prefix} <- recv_headers(socket, ""),
         {:ok, request_line, headers} <- parse_headers(raw_headers),
         {:ok, method, path} <- parse_request_line(request_line),
         {:ok, body} <- recv_body(socket, headers, body_prefix) do
      {:ok, %{method: method, path: path, headers: headers, body: body}}
    end
  end

  defp recv_headers(_socket, buffer) when byte_size(buffer) > @max_header_bytes do
    {:error, {400, "request headers exceeded #{@max_header_bytes} bytes"}}
  end

  defp recv_headers(socket, buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {index, 4} ->
        headers = binary_part(buffer, 0, index)
        body_prefix = binary_part(buffer, index + 4, byte_size(buffer) - index - 4)
        {:ok, headers, body_prefix}

      :nomatch ->
        case :gen_tcp.recv(socket, 0, @recv_timeout) do
          {:ok, chunk} ->
            recv_headers(socket, buffer <> chunk)

          {:error, reason} ->
            {:error, {400, "failed to read request headers: #{inspect(reason)}"}}
        end
    end
  end

  defp parse_headers(raw_headers) do
    case String.split(raw_headers, "\r\n") do
      [request_line | header_lines] ->
        headers = Enum.reduce(header_lines, %{}, &parse_header_line/2)

        {:ok, request_line, headers}

      _other ->
        {:error, {400, "malformed HTTP request"}}
    end
  end

  defp parse_header_line(line, acc) do
    case String.split(line, ":", parts: 2) do
      [name, value] ->
        Map.put(acc, String.downcase(String.trim(name)), String.trim(value))

      _other ->
        acc
    end
  end

  defp parse_request_line(request_line) do
    case String.split(request_line, " ", parts: 3) do
      [method, path, _version] -> {:ok, method, path}
      _other -> {:error, {400, "malformed request line"}}
    end
  end

  defp recv_body(socket, headers, body_prefix) do
    content_length =
      headers
      |> Map.get("content-length", "0")
      |> Integer.parse()
      |> case do
        {value, ""} when value >= 0 -> value
        _ -> 0
      end

    remaining = max(content_length - byte_size(body_prefix), 0)

    case recv_exact(socket, remaining, body_prefix) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {400, "failed to read request body: #{inspect(reason)}"}}
    end
  end

  defp recv_exact(_socket, 0, body), do: {:ok, body}

  defp recv_exact(socket, remaining, body) do
    case :gen_tcp.recv(socket, remaining, @recv_timeout) do
      {:ok, chunk} when byte_size(chunk) == remaining ->
        {:ok, body <> chunk}

      {:ok, chunk} ->
        recv_exact(socket, remaining - byte_size(chunk), body <> chunk)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
end
