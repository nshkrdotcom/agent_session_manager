defmodule ASM.Execution.ConfigTest do
  use ASM.TestCase

  alias ASM.Execution.Config

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

  test "resolve/2 rejects invalid execution_mode" do
    assert {:error, error} = Config.resolve([execution_mode: :somewhere], [])
    assert error.kind == :config_invalid
    assert error.domain == :config
    assert error.message =~ "execution_mode"
  end

  test "resolve/2 preserves non-empty allowed_tools and explicit approval_posture :none" do
    session_stream_opts = [
      surface_kind: :leased_ssh,
      transport_options: %{startup_mode: :lazy},
      workspace_root: "/tmp/runtime",
      allowed_tools: ["shell", "read"],
      approval_posture: :none,
      lease_ref: "lease-1",
      surface_ref: "surface-1",
      target_id: "target-1",
      boundary_class: :isolated,
      observability: %{suite: :phase_c}
    ]

    assert {:ok, cfg} = Config.resolve(session_stream_opts, [])
    assert Map.get(cfg, :surface_kind) == :leased_ssh
    assert Map.get(cfg, :transport_options) == [startup_mode: :lazy]
    assert Map.get(cfg, :workspace_root) == "/tmp/runtime"
    assert Map.get(cfg, :allowed_tools) == ["shell", "read"]
    assert Map.get(cfg, :approval_posture) == :none
    assert Map.get(cfg, :lease_ref) == "lease-1"
    assert Map.get(cfg, :surface_ref) == "surface-1"
    assert Map.get(cfg, :target_id) == "target-1"
    assert Map.get(cfg, :boundary_class) == :isolated
    assert Map.get(cfg, :observability) == %{suite: :phase_c}
  end
end
