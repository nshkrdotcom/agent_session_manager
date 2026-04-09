defmodule ASM.Execution.ConfigTest do
  use ASM.TestCase

  alias ASM.Execution.Config

  @execution_surface_contract_version CliSubprocessCore.ExecutionSurface.__struct__().contract_version

  setup do
    original = Application.get_env(:agent_session_manager, Config)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:agent_session_manager, Config)
      else
        Application.put_env(:agent_session_manager, Config, original)
      end
    end)

    :ok
  end

  test "resolve/2 merges execution config with precedence app -> session -> run -> driver_opts" do
    Application.put_env(:agent_session_manager, Config,
      execution_mode: :local,
      remote_connect_timeout_ms: 3_000,
      remote_rpc_timeout_ms: 12_000,
      remote_boot_lease_timeout_ms: 10_000,
      remote_bootstrap_mode: :require_prestarted,
      transport_call_timeout_ms: 4_000
    )

    session_stream_opts = [
      execution_mode: :remote_node,
      transport_call_timeout_ms: 5_000,
      driver_opts: [
        remote_node: :"asm@session-a",
        remote_connect_timeout_ms: 6_000,
        remote_cookie: :session_cookie
      ]
    ]

    run_stream_opts = [
      transport_call_timeout_ms: 7_000,
      driver_opts: [
        remote_node: :"asm@run-b",
        remote_rpc_timeout_ms: 18_000,
        remote_bootstrap_mode: :ensure_started,
        remote_transport_call_timeout_ms: 9_000
      ]
    ]

    assert {:ok, cfg} = Config.resolve(session_stream_opts, run_stream_opts)
    assert cfg.execution_mode == :remote_node
    assert cfg.transport_call_timeout_ms == 9_000
    assert cfg.remote.remote_node == :"asm@run-b"
    assert cfg.remote.remote_cookie == :session_cookie
    assert cfg.remote.remote_connect_timeout_ms == 6_000
    assert cfg.remote.remote_rpc_timeout_ms == 18_000
    assert cfg.remote.remote_boot_lease_timeout_ms == 10_000
    assert cfg.remote.remote_bootstrap_mode == :ensure_started
  end

  test "execution config publishes the Wave 5 lower-boundary vocabulary and metadata keys" do
    assert Config.execution_plane_contracts() == [
             "BoundarySessionDescriptor.v1",
             "ExecutionRoute.v1",
             "AttachGrant.v1",
             "CredentialHandleRef.v1",
             "ExecutionEvent.v1",
             "ExecutionOutcome.v1",
             "ProcessExecutionIntent.v1",
             "JsonRpcExecutionIntent.v1"
           ]

    assert Config.boundary_contract_keys() == [
             "descriptor",
             "route",
             "attach_grant",
             "replay",
             "approval",
             "callback",
             "identity"
           ]
  end

  test "resolve/2 rejects invalid execution_mode" do
    assert {:error, error} = Config.resolve([execution_mode: :somewhere], [])
    assert error.kind == :config_invalid
    assert error.domain == :config
    assert error.message =~ "execution_mode"
  end

  test "resolve/2 preserves non-empty allowed_tools and explicit approval_posture :none" do
    session_stream_opts = [
      execution_surface: [
        contract_version: @execution_surface_contract_version,
        surface_kind: :ssh_exec,
        transport_options: %{destination: "runtime.example"},
        lease_ref: "lease-1",
        surface_ref: "surface-1",
        target_id: "target-1",
        boundary_class: :isolated,
        observability: %{suite: :phase_c}
      ],
      workspace_root: "/tmp/runtime",
      allowed_tools: ["shell", "read"],
      approval_posture: :none
    ]

    assert {:ok, cfg} = Config.resolve(session_stream_opts, [])
    assert cfg.execution_surface.contract_version == @execution_surface_contract_version
    assert cfg.execution_surface.surface_kind == :ssh_exec
    assert cfg.execution_surface.transport_options == [destination: "runtime.example"]
    assert cfg.execution_surface.lease_ref == "lease-1"
    assert cfg.execution_surface.surface_ref == "surface-1"
    assert cfg.execution_surface.target_id == "target-1"
    assert cfg.execution_surface.boundary_class == :isolated
    assert cfg.execution_surface.observability == %{suite: :phase_c}
    assert cfg.execution_environment.workspace_root == "/tmp/runtime"
    assert cfg.execution_environment.allowed_tools == ["shell", "read"]
    assert cfg.execution_environment.approval_posture == :none
    assert cfg.execution_environment.permission_mode == :bypass
  end

  test "resolve/2 merges session and run execution_surface values canonically" do
    session_stream_opts = [
      execution_surface: %{
        "contract_version" => @execution_surface_contract_version,
        "surface_kind" => :ssh_exec,
        "transport_options" => [destination: "session.example"],
        "target_id" => "session-target",
        "observability" => %{scope: :session}
      }
    ]

    run_stream_opts = [
      execution_surface: [
        transport_options: [port: 2222],
        lease_ref: "lease-42",
        observability: %{scope: :run}
      ]
    ]

    assert {:ok, cfg} = Config.resolve(session_stream_opts, run_stream_opts)
    assert cfg.execution_surface.contract_version == @execution_surface_contract_version
    assert cfg.execution_surface.surface_kind == :ssh_exec
    assert cfg.execution_surface.transport_options[:destination] == "session.example"
    assert cfg.execution_surface.transport_options[:port] == 2222
    assert cfg.execution_surface.target_id == "session-target"
    assert cfg.execution_surface.lease_ref == "lease-42"
    assert cfg.execution_surface.observability == %{scope: :run}
  end

  test "resolve/2 validates remote-node schema-owned fields" do
    assert {:error, error} =
             Config.resolve(
               [execution_mode: :remote_node, driver_opts: [remote_node: :asm@test]],
               driver_opts: [remote_cookie: "not-an-atom"]
             )

    assert error.kind == :config_invalid
    assert error.message =~ "remote_cookie"
  end

  test "resolve/2 rejects legacy execution-surface keys" do
    assert {:error, error} =
             Config.resolve([surface_kind: :ssh_exec], [])

    assert error.kind == :config_invalid
    assert error.message =~ "legacy execution-surface keys"
    assert error.message =~ ":execution_surface"
  end
end
