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

unless Code.ensure_loaded?(ClaudeAgentSDK) do
  defmodule ClaudeAgentSDK do
    @moduledoc false

    use Boundary, check: [in: false, out: false]
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
              execution_surface: nil,
              model_payload: nil,
              model: nil,
              max_turns: nil,
              system_prompt: nil,
              append_system_prompt: nil,
              continue_conversation: nil,
              resume: nil,
              include_partial_messages: false,
              output_format: nil,
              timeout_ms: nil,
              thinking: nil,
              hooks: %{},
              # Completion-only controls; unset (nil) rather than [] so the
              # stub distinguishes "not requested" the way the real SDK does.
              tools: nil,
              setting_sources: nil,
              strict_mcp_config: nil,
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
      Code.ensure_loaded?(module)

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
              model: nil,
              reasoning_effort: nil,
              developer_instructions: nil,
              extra: %{}

    def new(attrs) when is_list(attrs) or is_map(attrs) do
      struct!(__MODULE__, Enum.into(attrs, %{}))
    end
  end
end

unless Code.ensure_loaded?(Codex.Options) do
  defmodule Codex.Options do
    @moduledoc false

    defstruct api_key: nil,
              base_url: nil,
              model_payload: nil,
              model: nil,
              reasoning_effort: nil,
              execution_surface: nil,
              codex_path_override: nil,
              codex_path: nil,
              model_personality: nil,
              hide_agent_reasoning: false

    def new(attrs) when is_list(attrs) or is_map(attrs) do
      attrs =
        attrs
        |> Enum.into(%{})
        |> Map.update(:api_key, nil, fn
          "" -> nil
          value -> value
        end)

      struct!(__MODULE__, attrs)
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
              sandbox: :default,
              ask_for_approval: nil,
              ephemeral: nil,
              ignore_user_config: false,
              ignore_rules: false,
              base_instructions: nil,
              additional_directories: [],
              skip_git_repo_check: false,
              web_search_mode: :disabled,
              web_search_mode_explicit: false,
              skills_enabled: nil,
              config_overrides: [],
              output_schema: nil,
              personality: nil,
              collaboration_mode: nil,
              dynamic_tools: [],
              transport: nil

    def new(attrs) when is_list(attrs) or is_map(attrs) do
      attrs = Enum.into(attrs, %{})

      web_search_mode_explicit =
        Map.has_key?(attrs, :web_search_mode) or Map.has_key?(attrs, "web_search_mode")

      attrs =
        attrs
        |> normalize_collaboration_mode()
        |> Map.put_new(:web_search_mode_explicit, web_search_mode_explicit)

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
              execution_surface: nil,
              thread: nil,
              output_schema_path: nil,
              env: %{},
              clear_env?: nil,
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
              resume: nil,
              transport: nil
  end
end

unless Code.ensure_loaded?(Codex.Items.AgentMessage) do
  defmodule Codex.Items.AgentMessage do
    @moduledoc false

    defstruct id: nil, type: :agent_message, text: nil, parsed: nil, phase: nil
  end
end

unless Code.ensure_loaded?(Codex.Events.TurnStarted) do
  defmodule Codex.Events.TurnStarted do
    @moduledoc false

    defstruct turn_id: nil, thread_id: nil
  end
end

unless Code.ensure_loaded?(Codex.Events.TurnCompleted) do
  defmodule Codex.Events.TurnCompleted do
    @moduledoc false

    defstruct thread_id: nil,
              turn_id: nil,
              response_id: nil,
              final_response: nil,
              usage: nil,
              status: nil,
              error: nil
  end
end

unless Code.ensure_loaded?(Codex.Events.ThreadTokenUsageUpdated) do
  defmodule Codex.Events.ThreadTokenUsageUpdated do
    @moduledoc false

    defstruct thread_id: nil, turn_id: nil, usage: %{}, delta: nil, rate_limits: nil
  end
end

unless Code.ensure_loaded?(Codex.Events.AccountRateLimitsUpdated) do
  defmodule Codex.Events.AccountRateLimitsUpdated do
    @moduledoc false

    defstruct rate_limits: %{}, thread_id: nil, turn_id: nil
  end
end

unless Code.ensure_loaded?(Codex.Events.ItemAgentMessageDelta) do
  defmodule Codex.Events.ItemAgentMessageDelta do
    @moduledoc false

    defstruct item: %{}, thread_id: nil, turn_id: nil
  end
end

unless Code.ensure_loaded?(Codex.Events.ItemCompleted) do
  defmodule Codex.Events.ItemCompleted do
    @moduledoc false

    defstruct item: nil, thread_id: nil, turn_id: nil
  end
end

unless Code.ensure_loaded?(Codex.Events.TurnFailed) do
  defmodule Codex.Events.TurnFailed do
    @moduledoc false

    defstruct error: %{}, thread_id: nil, turn_id: nil
  end
end

unless Code.ensure_loaded?(Codex.Events.TurnAborted) do
  defmodule Codex.Events.TurnAborted do
    @moduledoc false

    defstruct thread_id: nil, turn_id: nil, reason: nil
  end
end

unless Code.ensure_loaded?(Codex.Events.Error) do
  defmodule Codex.Events.Error do
    @moduledoc false

    defstruct message: nil,
              thread_id: nil,
              turn_id: nil,
              additional_details: nil,
              codex_error_info: nil,
              will_retry: nil
  end
end

unless Code.ensure_loaded?(Codex.Events.DynamicToolCallRequested) do
  defmodule Codex.Events.DynamicToolCallRequested do
    @moduledoc false

    defstruct id: nil,
              thread_id: nil,
              turn_id: nil,
              call_id: nil,
              tool_name: nil,
              arguments: %{}
  end
end

unless Code.ensure_loaded?(Codex.Events.RequestUserInput) do
  defmodule Codex.Events.RequestUserInput do
    @moduledoc false

    defstruct id: nil, thread_id: nil, turn_id: nil, item_id: nil, questions: []
  end
end

unless Code.ensure_loaded?(Codex.Events.CommandApprovalRequested) do
  defmodule Codex.Events.CommandApprovalRequested do
    @moduledoc false

    defstruct id: nil,
              thread_id: nil,
              turn_id: nil,
              item_id: nil,
              approval_id: nil,
              reason: nil,
              command: nil,
              cwd: nil
  end
end

unless Code.ensure_loaded?(Codex.Events.FileApprovalRequested) do
  defmodule Codex.Events.FileApprovalRequested do
    @moduledoc false

    defstruct id: nil, thread_id: nil, turn_id: nil, item_id: nil, reason: nil, grant_root: nil
  end
end

unless Code.ensure_loaded?(Codex.Events.PermissionsApprovalRequested) do
  defmodule Codex.Events.PermissionsApprovalRequested do
    @moduledoc false

    defstruct id: nil, thread_id: nil, turn_id: nil, item_id: nil, reason: nil, permissions: nil
  end
end

unless Code.ensure_loaded?(Codex.AppServer) do
  defmodule Codex.AppServer do
    @moduledoc false

    def connect(options, connect_opts) do
      if owner = Keyword.get(connect_opts, :test_owner) do
        send(owner, {:codex_app_server_options, options})
      end

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

    use Boundary, check: [in: false, out: false]

    def start_thread(%Codex.Options{} = codex_opts, %Codex.Thread.Options{} = thread_opts) do
      build_thread(codex_opts, thread_opts)
    end

    def resume_thread(
          thread_id,
          %Codex.Options{} = codex_opts,
          %Codex.Thread.Options{} = thread_opts
        )
        when is_binary(thread_id) or thread_id == :last do
      case thread_id do
        :last -> build_thread(codex_opts, thread_opts, nil, :last)
        id -> build_thread(codex_opts, thread_opts, id, nil)
      end
    end

    defp build_thread(codex_opts, thread_opts, thread_id \\ nil, resume \\ nil) do
      thread_id =
        if is_nil(thread_id) and is_nil(resume) do
          "thread-#{System.unique_integer([:positive])}"
        else
          thread_id
        end

      {:ok,
       %Codex.Thread{
         codex_opts: codex_opts,
         thread_opts: thread_opts,
         thread_id: thread_id,
         resume: resume,
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

      thread_opts =
        case Map.fetch!(exec_opts, :thread) do
          %{thread_opts: %Codex.Thread.Options{} = opts} -> opts
          %Codex.Thread.Options{} = opts -> opts
        end

      Session.start_session(
        provider: :codex,
        profile: CodexProfile,
        subscriber: Keyword.get(opts, :subscriber),
        metadata: Keyword.get(opts, :metadata, %{}),
        prompt: Keyword.fetch!(opts, :input),
        command: Map.get(codex_opts, :codex_path_override) || Map.get(codex_opts, :codex_path),
        cwd: Map.get(thread_opts, :working_directory),
        execution_surface: Map.get(exec_opts, :execution_surface),
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

unless Code.ensure_loaded?(AmpSdk) do
  defmodule AmpSdk do
    @moduledoc false

    use Boundary, check: [in: false, out: false]
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
              execution_surface: nil,
              mode: "smart",
              dangerously_allow_all: false,
              visibility: "workspace",
              settings_file: nil,
              log_level: nil,
              log_file: nil,
              env: %{},
              continue_thread: nil,
              mcp_config: nil,
              toolbox: nil,
              skills: nil,
              permissions: nil,
              labels: nil,
              thinking: false,
              governed_authority: nil,
              stream_timeout_ms: 300_000,
              max_stderr_buffer_bytes: 262_144,
              no_ide: false,
              no_notifications: false,
              no_color: false,
              no_jetbrains: false
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
