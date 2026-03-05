Code.require_file("live_support.exs", __DIR__)

defmodule ASM.Examples.LiveWorkspaceSnapshot do
  @moduledoc false

  alias ASM.{Error, Result}
  alias ASM.Examples.LiveSupport
  alias ASM.Extensions.Workspace
  alias ASM.Extensions.Workspace.Diff

  def run! do
    provider = provider_from_env()
    prompt = LiveSupport.prompt_from_argv_or_default("Reply with exactly: WORKSPACE_OK")
    workspace = workspace_dir(provider)
    keep_workspace? = keep_workspace?()
    artifact_relative_path = "run-artifact.txt"
    artifact_path = Path.join(workspace, artifact_relative_path)
    provider_opts = provider_opts(provider)
    session_id = "live-workspace-#{provider}-#{System.system_time(:millisecond)}"

    try do
      LiveSupport.ensure_cli!(provider, Keyword.take(provider_opts, [:cli_path]))
      init_workspace!(workspace)

      start_opts =
        provider_opts
        |> Keyword.put(:provider, provider)
        |> Keyword.put(:session_id, session_id)

      with {:ok, session} <- ASM.start_session(start_opts),
           {:ok, pre_snapshot} <- Workspace.snapshot(workspace, backend: :auto) do
        try do
          result = run_query!(session, prompt, workspace)

          File.write!(
            artifact_path,
            "provider=#{provider}\nrun_id=#{result.run_id}\ntext=#{inspect(result.text)}\n"
          )

          {:ok, post_snapshot} = Workspace.snapshot(workspace, backend: :auto)
          {:ok, diff} = Workspace.diff(pre_snapshot, post_snapshot)

          assert_artifact_diff!(diff, artifact_relative_path)

          :ok = Workspace.rollback(pre_snapshot)

          {:ok, restored_snapshot} = Workspace.snapshot(workspace, backend: :auto)
          {:ok, rollback_diff} = Workspace.diff(pre_snapshot, restored_snapshot)

          assert_clean_after_rollback!(rollback_diff, artifact_path)

          IO.puts("""

          [workspace]
          provider: #{provider}
          session_id: #{session_id}
          backend: #{pre_snapshot.backend}
          diff_summary: #{inspect(Diff.summary(diff))}
          rollback_summary: #{inspect(Diff.summary(rollback_diff))}
          workspace: #{workspace}
          """)

          LiveSupport.print_result(result)
        after
          _ = ASM.stop_session(session)
        end
      else
        {:error, %Error{} = error} ->
          IO.puts("workspace live example failed: #{Exception.message(error)}")
          System.halt(1)

        {:error, other} ->
          IO.puts("workspace live example failed: #{inspect(other)}")
          System.halt(1)
      end
    rescue
      error ->
        IO.puts("workspace live example crashed: #{Exception.message(error)}")
        System.halt(1)
    after
      if keep_workspace? do
        IO.puts("kept workspace directory: #{workspace}")
      else
        _ = File.rm_rf(workspace)
        IO.puts("removed workspace directory: #{workspace}")
      end
    end
  end

  defp run_query!(session, prompt, workspace) do
    case ASM.query(session, prompt, cwd: workspace) do
      {:ok, %Result{} = result} ->
        result

      {:error, %Error{} = error} ->
        raise error

      {:error, other} ->
        raise "query failed with unexpected error: #{inspect(other)}"
    end
  end

  defp assert_artifact_diff!(%Diff{} = diff, artifact_relative_path) do
    if artifact_relative_path in diff.added do
      :ok
    else
      IO.puts("expected workspace diff to include #{artifact_relative_path} in added paths")
      IO.puts("added=#{inspect(diff.added)} modified=#{inspect(diff.modified)}")
      System.halt(1)
    end
  end

  defp assert_clean_after_rollback!(%Diff{} = rollback_diff, artifact_path) do
    cond do
      not Diff.empty?(rollback_diff) ->
        IO.puts(
          "workspace rollback left residual changes: #{inspect(Diff.to_map(rollback_diff))}"
        )

        System.halt(1)

      File.exists?(artifact_path) ->
        IO.puts("workspace rollback failed to remove artifact: #{artifact_path}")
        System.halt(1)

      true ->
        :ok
    end
  end

  defp init_workspace!(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)

    run_git!(workspace, ["init", "--quiet"])
    run_git!(workspace, ["config", "user.name", "ASM Workspace Example"])
    run_git!(workspace, ["config", "user.email", "asm-workspace@example.com"])

    File.write!(Path.join(workspace, "README.md"), "# Workspace Snapshot Example\n")
    File.write!(Path.join(workspace, "state.txt"), "baseline\n")

    run_git!(workspace, ["add", "README.md", "state.txt"])
    run_git!(workspace, ["commit", "--quiet", "-m", "baseline workspace"])
  end

  defp run_git!(workspace, args) do
    case System.cmd("git", ["-C", workspace] ++ args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise "git command failed (status=#{status}): git #{Enum.join(args, " ")}\n#{output}"
    end
  end

  defp provider_from_env do
    case System.get_env("ASM_WORKSPACE_PROVIDER", "codex") do
      "claude" -> :claude
      "gemini" -> :gemini
      "codex" -> :codex
      other -> raise ArgumentError, "unsupported ASM_WORKSPACE_PROVIDER=#{inspect(other)}"
    end
  end

  defp provider_opts(provider) do
    []
    |> put_opt(:permission_mode, System.get_env("ASM_PERMISSION_MODE") || "auto")
    |> put_opt(:model, model_for(provider))
    |> put_opt(:cli_path, cli_path_for(provider))
  end

  defp model_for(:claude), do: System.get_env("ASM_CLAUDE_MODEL")
  defp model_for(:gemini), do: System.get_env("ASM_GEMINI_MODEL")
  defp model_for(:codex), do: System.get_env("ASM_CODEX_MODEL")

  defp cli_path_for(:claude), do: System.get_env("CLAUDE_CLI_PATH")
  defp cli_path_for(:gemini), do: System.get_env("GEMINI_CLI_PATH")
  defp cli_path_for(:codex), do: System.get_env("CODEX_PATH")

  defp workspace_dir(provider) do
    case System.get_env("ASM_WORKSPACE_DIR") do
      nil ->
        Path.join(
          System.tmp_dir!(),
          "asm-live-workspace-#{provider}-#{System.system_time(:millisecond)}"
        )

      value ->
        value
    end
  end

  defp keep_workspace? do
    System.get_env("ASM_WORKSPACE_KEEP_DIR") in ["1", "true", "TRUE"]
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, _key, ""), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end

ASM.Examples.LiveWorkspaceSnapshot.run!()
