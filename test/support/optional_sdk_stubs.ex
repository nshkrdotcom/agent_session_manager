defmodule ASM.TestSupport.OptionalSDK do
  @moduledoc false

  def loaded_runtime_loader(providers) when is_list(providers) do
    loaded_runtimes =
      providers
      |> Enum.map(&ASM.Provider.resolve!/1)
      |> Enum.map(& &1.sdk_runtime)
      |> MapSet.new()

    fn runtime ->
      MapSet.member?(loaded_runtimes, runtime)
    end
  end
end

unless Code.ensure_loaded?(ClaudeAgentSDK.Transport) do
  defmodule ClaudeAgentSDK.Transport do
    @moduledoc false

    @callback start(keyword()) :: GenServer.on_start()
    @callback start_link(keyword()) :: GenServer.on_start()
    @callback send(pid(), binary()) :: :ok | {:error, term()}
    @callback subscribe(pid(), pid()) :: :ok | {:error, term()}
    @callback close(pid()) :: :ok | {:error, term()}
    @callback status(pid()) :: term()
  end
end

unless Code.ensure_loaded?(ClaudeAgentSDK.Options) do
  defmodule ClaudeAgentSDK.Options do
    @moduledoc false

    defstruct cwd: nil,
              env: %{},
              path_to_claude_code_executable: nil,
              permission_mode: nil,
              model_payload: nil,
              model: nil,
              max_turns: nil,
              system_prompt: nil,
              append_system_prompt: nil,
              include_partial_messages: false,
              output_format: nil,
              timeout_ms: nil,
              thinking: nil,
              hooks: %{},
              enable_file_checkpointing: false

    def new(attrs) when is_list(attrs) or is_map(attrs) do
      struct!(__MODULE__, Enum.into(attrs, %{}))
    end
  end
end

unless Code.ensure_loaded?(ClaudeAgentSDK.Hooks) do
  defmodule ClaudeAgentSDK.Hooks do
    @moduledoc false
  end
end

unless Code.ensure_loaded?(ClaudeAgentSDK.Hooks.Matcher) do
  defmodule ClaudeAgentSDK.Hooks.Matcher do
    @moduledoc false

    defstruct [:tool, handlers: []]

    def new(tool, handlers) when is_binary(tool) and is_list(handlers) do
      %__MODULE__{tool: tool, handlers: handlers}
    end
  end
end

unless Code.ensure_loaded?(ClaudeAgentSDK.Hooks.Output) do
  defmodule ClaudeAgentSDK.Hooks.Output do
    @moduledoc false

    def allow, do: %{decision: :allow}
  end
end

unless Code.ensure_loaded?(ClaudeAgentSDK.Permission) do
  defmodule ClaudeAgentSDK.Permission do
    @moduledoc false
  end
end

unless Code.ensure_loaded?(ClaudeAgentSDK.ControlProtocol.Protocol) do
  defmodule ClaudeAgentSDK.ControlProtocol.Protocol do
    @moduledoc false
  end
end

unless Code.ensure_loaded?(ClaudeAgentSDK.Client) do
  defmodule ClaudeAgentSDK.Client do
    @moduledoc false

    use GenServer

    defstruct [
      :transport,
      :transport_api,
      :request_id,
      :server_info,
      initialized?: false,
      init_waiters: []
    ]

    def start_link(options, client_opts) when is_list(client_opts) do
      GenServer.start_link(__MODULE__, {options, client_opts})
    end

    def await_init_sent(client, timeout) when is_pid(client) do
      GenServer.call(client, :await_init_sent, timeout)
    end

    def await_initialized(client, timeout) when is_pid(client) do
      GenServer.call(client, :await_initialized, timeout)
    end

    def get_server_info(client) when is_pid(client) do
      GenServer.call(client, :get_server_info)
    end

    def stop(client) when is_pid(client), do: GenServer.stop(client, :normal)

    @impl true
    def init({options, client_opts}) do
      transport_api = Keyword.fetch!(client_opts, :transport)
      transport_opts = [options: options] ++ Keyword.get(client_opts, :transport_opts, [])

      with {:ok, transport} <- start_transport(transport_api, transport_opts),
           :ok <- transport_api.subscribe(transport, self()),
           {:ok, request_id, init_payload} <- encode_initialize_request() do
        :ok = transport_api.send(transport, init_payload)

        {:ok,
         %__MODULE__{
           transport: transport,
           transport_api: transport_api,
           request_id: request_id,
           server_info: %{}
         }}
      end
    end

    @impl true
    def handle_call(:await_init_sent, _from, %__MODULE__{} = state) do
      {:reply, {:ok, state.request_id}, state}
    end

    def handle_call(:await_initialized, _from, %__MODULE__{initialized?: true} = state) do
      {:reply, :ok, state}
    end

    def handle_call(:await_initialized, from, %__MODULE__{} = state) do
      {:noreply, %{state | init_waiters: [from | state.init_waiters]}}
    end

    def handle_call(:get_server_info, _from, %__MODULE__{} = state) do
      {:reply, state.server_info, state}
    end

    @impl true
    def handle_info({:transport_message, payload}, %__MODULE__{} = state)
        when is_binary(payload) do
      case Jason.decode(payload) do
        {:ok,
         %{
           "type" => "control_response",
           "response" => %{
             "subtype" => "success",
             "request_id" => request_id,
             "response" => response
           }
         }}
        when request_id == state.request_id ->
          Enum.each(state.init_waiters, &GenServer.reply(&1, :ok))

          {:noreply,
           %{
             state
             | initialized?: true,
               init_waiters: [],
               server_info: response || %{}
           }}

        _other ->
          {:noreply, state}
      end
    end

    def handle_info(_message, state), do: {:noreply, state}

    defp start_transport(module, opts) do
      cond do
        function_exported?(module, :start_link, 1) -> module.start_link(opts)
        function_exported?(module, :start, 1) -> module.start(opts)
        true -> {:error, {:unsupported_transport, module}}
      end
    end

    defp encode_initialize_request do
      request_id = "claude-init-#{System.unique_integer([:positive])}"

      payload = %{
        "type" => "control_request",
        "request_id" => request_id,
        "request" => %{
          "subtype" => "initialize",
          "hooks" => %{}
        }
      }

      {:ok, request_id, Jason.encode!(payload)}
    end
  end
end

unless Code.ensure_loaded?(ClaudeAgentSDK.Runtime.CLI) do
  defmodule ClaudeAgentSDK.Runtime.CLI do
    @moduledoc false

    alias CliSubprocessCore.ProviderProfiles.Claude

    def capabilities do
      Claude.capabilities()
    end
  end
end

unless Code.ensure_loaded?(Codex.Protocol.CollaborationMode) do
  defmodule Codex.Protocol.CollaborationMode do
    @moduledoc false

    defstruct mode: nil,
              model: "",
              reasoning_effort: nil,
              developer_instructions: nil

    def new(attrs) when is_list(attrs) or is_map(attrs) do
      struct!(__MODULE__, Enum.into(attrs, %{}))
    end
  end
end

unless Code.ensure_loaded?(Codex.Options) do
  defmodule Codex.Options do
    @moduledoc false

    defstruct model_payload: nil,
              model: nil,
              reasoning_effort: nil,
              codex_path_override: nil,
              codex_path: nil,
              model_personality: nil,
              hide_agent_reasoning: false

    def new(attrs) when is_list(attrs) or is_map(attrs) do
      struct!(__MODULE__, Enum.into(attrs, %{}))
    end
  end
end

unless Code.ensure_loaded?(Codex.Thread.Options) do
  defmodule Codex.Thread.Options do
    @moduledoc false

    alias Codex.Protocol.CollaborationMode

    defstruct working_directory: nil,
              cd: nil,
              approval_timeout_ms: nil,
              oss: nil,
              local_provider: nil,
              model_provider: nil,
              full_auto: false,
              dangerously_bypass_approvals_and_sandbox: false,
              output_schema: nil,
              personality: nil,
              collaboration_mode: nil,
              transport: nil

    def new(attrs) when is_list(attrs) or is_map(attrs) do
      attrs =
        attrs
        |> Enum.into(%{})
        |> normalize_collaboration_mode()

      struct!(__MODULE__, attrs)
    end

    defp normalize_collaboration_mode(%{"collaboration_mode" => %{} = mode} = attrs) do
      Map.put(attrs, "collaboration_mode", CollaborationMode.new(mode))
    end

    defp normalize_collaboration_mode(%{collaboration_mode: %{} = mode} = attrs) do
      Map.put(attrs, :collaboration_mode, CollaborationMode.new(mode))
    end

    defp normalize_collaboration_mode(attrs), do: attrs
  end
end

unless Code.ensure_loaded?(Codex.Exec.Options) do
  defmodule Codex.Exec.Options do
    @moduledoc false

    defstruct codex_opts: nil,
              thread: nil,
              timeout_ms: nil,
              max_stderr_buffer_bytes: nil

    def new(attrs) when is_list(attrs) or is_map(attrs) do
      struct!(__MODULE__, Enum.into(attrs, %{}))
    end
  end
end

unless Code.ensure_loaded?(Codex.Thread) do
  defmodule Codex.Thread do
    @moduledoc false

    defstruct codex_opts: nil,
              thread_opts: nil,
              thread_id: nil,
              transport: nil
  end
end

unless Code.ensure_loaded?(Codex.AppServer) do
  defmodule Codex.AppServer do
    @moduledoc false

    def connect(_options, _connect_opts) do
      pid =
        spawn_link(fn ->
          receive do
            :disconnect -> :ok
          end
        end)

      {:ok, pid}
    end

    def disconnect(pid) when is_pid(pid) do
      Process.exit(pid, :normal)
      :ok
    catch
      :exit, _reason -> :ok
    end
  end
end

unless Code.ensure_loaded?(Codex.MCP.Client) do
  defmodule Codex.MCP.Client do
    @moduledoc false
  end
end

unless Code.ensure_loaded?(Codex.Realtime) do
  defmodule Codex.Realtime do
    @moduledoc false
  end
end

unless Code.ensure_loaded?(Codex.Voice) do
  defmodule Codex.Voice do
    @moduledoc false
  end
end

unless Code.ensure_loaded?(Codex) do
  defmodule Codex do
    @moduledoc false

    def start_thread(%Codex.Options{} = codex_opts, %Codex.Thread.Options{} = thread_opts) do
      {:ok,
       %Codex.Thread{
         codex_opts: codex_opts,
         thread_opts: thread_opts,
         thread_id: "thread-#{System.unique_integer([:positive])}",
         transport: thread_opts.transport
       }}
    end
  end
end

unless Code.ensure_loaded?(Codex.Runtime.Exec) do
  defmodule Codex.Runtime.Exec do
    @moduledoc false

    alias CliSubprocessCore.ProviderProfiles.Codex, as: CodexProfile
    alias CliSubprocessCore.Session

    def start_session(opts) when is_list(opts) do
      exec_opts = Keyword.fetch!(opts, :exec_opts)
      codex_opts = Map.fetch!(exec_opts, :codex_opts)
      thread_opts = Map.fetch!(exec_opts, :thread)

      Session.start_session(
        provider: :codex,
        profile: CodexProfile,
        subscriber: Keyword.get(opts, :subscriber),
        metadata: Keyword.get(opts, :metadata, %{}),
        prompt: Keyword.fetch!(opts, :input),
        command: Map.get(codex_opts, :codex_path_override) || Map.get(codex_opts, :codex_path),
        cwd: Map.get(thread_opts, :working_directory),
        model_payload: Map.get(codex_opts, :model_payload),
        output_schema: Map.get(thread_opts, :output_schema),
        provider_permission_mode: permission_mode(thread_opts)
      )
    end

    def send_input(session, input, _opts \\ []), do: Session.send_input(session, input)
    def end_input(session), do: Session.end_input(session)
    def interrupt(session), do: Session.interrupt(session)
    def close(session), do: Session.close(session)
    def subscribe(session, pid, ref), do: Session.subscribe(session, pid, ref)
    def info(session), do: Session.info(session)
    def capabilities, do: CodexProfile.capabilities()

    defp permission_mode(%{dangerously_bypass_approvals_and_sandbox: true}), do: :yolo
    defp permission_mode(%{full_auto: true}), do: :auto_edit
    defp permission_mode(_thread_opts), do: :default
  end
end

unless Code.ensure_loaded?(GeminiCliSdk.Options) do
  defmodule GeminiCliSdk.Options do
    @moduledoc false

    defstruct model_payload: nil,
              model: nil,
              yolo: false,
              approval_mode: nil,
              sandbox: false,
              extensions: [],
              cwd: nil,
              env: %{},
              timeout_ms: nil,
              max_stderr_buffer_bytes: nil

    def validate!(options), do: options
  end
end

unless Code.ensure_loaded?(GeminiCliSdk.Runtime.CLI) do
  defmodule GeminiCliSdk.Runtime.CLI do
    @moduledoc false

    alias CliSubprocessCore.ProviderProfiles.Gemini

    def capabilities do
      Gemini.capabilities()
    end
  end
end

unless Code.ensure_loaded?(AmpSdk.Types) do
  defmodule AmpSdk.Types do
    @moduledoc false
  end
end

unless Code.ensure_loaded?(AmpSdk.Types.Options) do
  defmodule AmpSdk.Types.Options do
    @moduledoc false

    defstruct model_payload: nil,
              cwd: nil,
              mode: "smart",
              dangerously_allow_all: false,
              env: %{},
              thinking: false,
              stream_timeout_ms: nil,
              max_stderr_buffer_bytes: nil,
              no_ide: false,
              no_notifications: false
  end
end

unless Code.ensure_loaded?(AmpSdk.Runtime.CLI) do
  defmodule AmpSdk.Runtime.CLI do
    @moduledoc false

    alias CliSubprocessCore.ProviderProfiles.Amp

    def capabilities do
      Amp.capabilities()
    end
  end
end
