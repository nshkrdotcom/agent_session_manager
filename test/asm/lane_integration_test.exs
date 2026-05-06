defmodule ASM.LaneIntegrationTest do
  use ASM.SerialTestCase

  alias CliSubprocessCore.TestSupport.FakeSSH

  setup do
    original = Application.get_env(:agent_session_manager, ASM.ProviderRegistry)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:agent_session_manager, ASM.ProviderRegistry)
      else
        Application.put_env(:agent_session_manager, ASM.ProviderRegistry, original)
      end
    end)

    :ok
  end

  test "auto lane falls back to core when sdk runtime kits are unavailable" do
    put_runtime_loader(fn
      Codex.Runtime.Exec -> false
      runtime -> Code.ensure_loaded?(runtime)
    end)

    script = write_script!(codex_success_script("CORE_LANE_OK"))
    session = start_session!(:codex)

    assert {:ok, result} =
             ASM.query(session, "say core",
               lane: :auto,
               cli_path: script
             )

    assert result.text == "CORE_LANE_OK"
    assert result.metadata.requested_lane == :auto
    assert result.metadata.preferred_lane == :core
    assert result.metadata.lane == :core
    assert result.metadata.execution_mode == :local
    assert result.metadata.sdk_available? == false

    assert :ok = ASM.stop_session(session)
  end

  test "auto lane uses the sdk backend when the runtime kit is present" do
    put_runtime_loader(fn
      Codex.Runtime.Exec -> true
      runtime -> Code.ensure_loaded?(runtime)
    end)

    script = write_script!(codex_success_script("SDK_LANE_OK"))
    session = start_session!(:codex)

    assert {:ok, result} =
             ASM.query(session, "say sdk",
               lane: :auto,
               cli_path: script
             )

    assert result.text == "SDK_LANE_OK"
    assert result.metadata.requested_lane == :auto
    assert result.metadata.preferred_lane == :sdk
    assert result.metadata.lane == :sdk
    assert result.metadata.execution_mode == :local
    assert result.metadata.backend == ASM.ProviderBackend.SDK
    assert result.metadata.sdk_available? == true

    assert :ok = ASM.stop_session(session)
  end

  test "explicit lane overrides force local core and sdk backends" do
    put_runtime_loader(fn
      Codex.Runtime.Exec -> true
      runtime -> Code.ensure_loaded?(runtime)
    end)

    core_script = write_script!(codex_success_script("CORE_OVERRIDE_OK"))
    sdk_script = write_script!(codex_success_script("SDK_OVERRIDE_OK"))
    session = start_session!(:codex)

    assert {:ok, core_result} =
             ASM.query(session, "force core",
               lane: :core,
               cli_path: core_script
             )

    assert core_result.text == "CORE_OVERRIDE_OK"
    assert core_result.metadata.requested_lane == :core
    assert core_result.metadata.preferred_lane == :core
    assert core_result.metadata.lane == :core
    assert core_result.metadata.backend == ASM.ProviderBackend.Core

    assert {:ok, sdk_result} =
             ASM.query(session, "force sdk",
               lane: :sdk,
               cli_path: sdk_script
             )

    assert sdk_result.text == "SDK_OVERRIDE_OK"
    assert sdk_result.metadata.requested_lane == :sdk
    assert sdk_result.metadata.preferred_lane == :sdk
    assert sdk_result.metadata.lane == :sdk
    assert sdk_result.metadata.backend == ASM.ProviderBackend.SDK

    assert :ok = ASM.stop_session(session)
  end

  test "core lane surfaces launcher resolution failures instead of timing out" do
    {root, cli_path, node_shim_dir} = build_broken_codex_launcher()
    session = start_session!(:codex)

    try do
      with_env(%{"HOME" => root, "PATH" => node_shim_dir, "ASDF_DIR" => nil}, fn ->
        assert {:error, error} =
                 ASM.query(session, "say broken",
                   lane: :core,
                   cli_path: cli_path,
                   stream_timeout_ms: 50
                 )

        assert error.kind == :cli_not_found
        assert error.domain == :provider
        assert String.contains?(error.message, "Codex CLI launcher")
        assert String.contains?(error.message, "stable executable")
      end)
    after
      assert :ok = ASM.stop_session(session)
      File.rm_rf(root)
    end
  end

  test "explicit sdk lane preserves :ssh_exec execution-surface routing with lease metadata" do
    put_runtime_loader(fn
      Codex.Runtime.Exec -> true
      runtime -> Code.ensure_loaded?(runtime)
    end)

    fake_ssh = FakeSSH.new!()
    script = write_script!(codex_success_script("SDK_STATIC_SSH_OK"))

    on_exit(fn ->
      FakeSSH.cleanup(fake_ssh)
    end)

    session =
      start_session!(
        :codex,
        execution_surface: [
          surface_kind: :ssh_exec,
          transport_options:
            FakeSSH.transport_options(fake_ssh,
              destination: "sdk-static-ssh.example",
              port: 2222
            )
        ]
      )

    assert {:ok, result} =
             ASM.query(session, "force sdk over ssh",
               lane: :sdk,
               cli_path: script
             )

    assert result.text == "SDK_STATIC_SSH_OK"
    assert result.metadata.requested_lane == :sdk
    assert result.metadata.preferred_lane == :sdk
    assert result.metadata.lane == :sdk
    assert result.metadata.execution_mode == :local
    assert result.metadata.backend == ASM.ProviderBackend.SDK
    assert FakeSSH.wait_until_written(fake_ssh, 1_000) == :ok

    assert String.contains?(
             FakeSSH.read_manifest!(fake_ssh),
             "destination=sdk-static-ssh.example"
           )

    assert :ok = ASM.stop_session(session)
  end

  test "explicit sdk lane preserves :ssh_exec execution-surface routing" do
    put_runtime_loader(fn
      Codex.Runtime.Exec -> true
      runtime -> Code.ensure_loaded?(runtime)
    end)

    fake_ssh = FakeSSH.new!()
    script = write_script!(codex_success_script("SDK_LEASED_SSH_OK"))

    on_exit(fn ->
      FakeSSH.cleanup(fake_ssh)
    end)

    session =
      start_session!(
        :codex,
        execution_surface: [
          surface_kind: :ssh_exec,
          transport_options:
            FakeSSH.transport_options(fake_ssh,
              destination: "sdk-leased-ssh.example"
            ),
          lease_ref: "lease-42"
        ]
      )

    assert {:ok, result} =
             ASM.query(session, "force sdk over leased ssh",
               lane: :sdk,
               cli_path: script
             )

    assert result.text == "SDK_LEASED_SSH_OK"
    assert result.metadata.requested_lane == :sdk
    assert result.metadata.preferred_lane == :sdk
    assert result.metadata.lane == :sdk
    assert result.metadata.execution_mode == :local
    assert result.metadata.backend == ASM.ProviderBackend.SDK
    assert FakeSSH.wait_until_written(fake_ssh, 1_000) == :ok

    assert String.contains?(
             FakeSSH.read_manifest!(fake_ssh),
             "destination=sdk-leased-ssh.example"
           )

    assert :ok = ASM.stop_session(session)
  end

  defp start_session!(provider, opts \\ []) when is_atom(provider) and is_list(opts) do
    session_id = "asm-lane-#{System.unique_integer([:positive])}"

    {:ok, session} =
      ASM.start_session(
        [session_id: session_id, provider: provider]
        |> Keyword.merge(opts)
      )

    session
  end

  defp put_runtime_loader(fun) when is_function(fun, 1) do
    Application.put_env(:agent_session_manager, ASM.ProviderRegistry, runtime_loader: fun)
  end

  defp codex_success_script(text) do
    completed_event =
      Jason.encode!(%{
        type: "item.completed",
        item: %{id: "item_1", type: "agent_message", text: text}
      })

    """
    #!/usr/bin/env bash
    set -euo pipefail
    echo '{"type":"thread.started","thread_id":"thread-1"}'
    echo '{"type":"turn.started"}'
    echo '#{completed_event}'
    echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
    """
  end

  defp write_script!(contents) do
    path = Path.join(System.tmp_dir!(), "asm-lane-#{System.unique_integer([:positive])}.sh")
    File.write!(path, contents)
    File.chmod!(path, 0o755)
    path
  end

  defp build_broken_codex_launcher do
    root = tmp_dir!("asm_codex_broken_launcher")
    launcher_dir = Path.join(root, "bin")
    shim_dir = Path.join(root, ".asdf/shims")

    File.mkdir_p!(launcher_dir)
    File.mkdir_p!(shim_dir)

    cli_path =
      write_executable!(
        launcher_dir,
        "codex",
        "#!/usr/bin/env node\nconsole.log('codex');\n"
      )

    write_executable!(
      shim_dir,
      "node",
      """
      #!/bin/sh
      exec asdf exec "node" "$@"
      """
    )

    {root, cli_path, shim_dir}
  end

  defp tmp_dir!(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp write_executable!(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    File.chmod!(path, 0o755)
    path
  end

  defp with_env(env, fun) when is_map(env) and is_function(fun, 0) do
    saved = Enum.map(env, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      fun.()
    after
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
