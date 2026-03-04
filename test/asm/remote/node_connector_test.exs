defmodule ASM.Remote.NodeConnectorTest do
  use ASM.TestCase

  alias ASM.Remote.NodeConnector

  setup do
    NodeConnector.reset_cookie_book()
    :ok
  end

  test "ensure_connected/2 enforces local cookie conflict guard" do
    cfg = %{
      remote_node: :"asm@cookie-guard",
      remote_cookie: :cookie_a,
      remote_connect_timeout_ms: 20
    }

    opts = [
      node_alive_fun: fn -> true end,
      set_cookie_fun: fn _node, _cookie -> true end,
      connect_fun: fn _node -> true end
    ]

    assert :ok = NodeConnector.ensure_connected(cfg, opts)
    assert :ok = NodeConnector.ensure_connected(cfg, opts)

    assert {:error, :cookie_conflict} =
             NodeConnector.ensure_connected(
               %{cfg | remote_cookie: :cookie_b},
               opts
             )
  end

  test "ensure_connected/2 normalizes connect timeout and immediate failures" do
    cfg = %{remote_node: :"asm@connect-timeout", remote_connect_timeout_ms: 20}
    common = [node_alive_fun: fn -> true end]

    assert {:error, :remote_connect_timeout} =
             NodeConnector.ensure_connected(
               cfg,
               common ++ [connect_fun: fn _node -> Process.sleep(200) end]
             )

    assert {:error, :remote_connect_failed} =
             NodeConnector.ensure_connected(cfg, common ++ [connect_fun: fn _node -> false end])
  end

  test "ensure_connected/2 fails when distribution is disabled" do
    cfg = %{remote_node: :"asm@dist-disabled", remote_connect_timeout_ms: 20}

    assert {:error, :distribution_not_enabled} =
             NodeConnector.ensure_connected(cfg, node_alive_fun: fn -> false end)
  end

  test "preflight/2 rejects incompatible remote capabilities" do
    cfg = %{remote_node: :"asm@cap-mismatch", remote_rpc_timeout_ms: 50}

    rpc_fun = fn
      _node, Code, :ensure_loaded?, [ASM.Remote.TransportStarter], _timeout ->
        true

      _node,
      :erlang,
      :function_exported,
      [ASM.Remote.TransportStarter, :start_transport, 1],
      _timeout ->
        true

      _node, ASM.Remote.Capabilities, :handshake, [], _timeout ->
        %{asm_version: "0.9.0", otp_release: "27", capabilities: []}

      _node, Process, :whereis, [ASM.Remote.TransportSupervisor], _timeout ->
        self()

      _node, _mod, _fun, _args, _timeout ->
        :ok
    end

    assert {:error, {:remote_capability_mismatch, _details}} =
             NodeConnector.preflight(cfg, rpc_fun: rpc_fun)
  end

  test "preflight/2 rejects incompatible remote version" do
    cfg = %{remote_node: :"asm@version-mismatch", remote_rpc_timeout_ms: 50}

    rpc_fun = fn
      _node, Code, :ensure_loaded?, [ASM.Remote.TransportStarter], _timeout ->
        true

      _node,
      :erlang,
      :function_exported,
      [ASM.Remote.TransportStarter, :start_transport, 1],
      _timeout ->
        true

      _node, ASM.Remote.Capabilities, :handshake, [], _timeout ->
        %{
          asm_version: "0.8.0",
          otp_release: :erlang.system_info(:otp_release) |> List.to_string(),
          capabilities: [
            :remote_transport_start_v1,
            :startup_lease_timeout_v1,
            :transport_call_timeout_v1
          ]
        }

      _node, Process, :whereis, [ASM.Remote.TransportSupervisor], _timeout ->
        self()

      _node, _mod, _fun, _args, _timeout ->
        :ok
    end

    assert {:error, {:remote_version_mismatch, _details}} =
             NodeConnector.preflight(cfg, rpc_fun: rpc_fun)
  end
end
