defmodule ASM.Extensions.Workspace.GitBackend do
  @moduledoc """
  Git-backed workspace snapshots, diffs, and rollback.
  """

  @behaviour ASM.Extensions.Workspace.Backend

  alias ASM.{Error, Event}
  alias ASM.Extensions.Workspace.{Diff, Snapshot}

  @impl true
  def snapshot(root, _opts) when is_binary(root) do
    with :ok <- ensure_git_available(),
         {:ok, normalized_root} <- normalize_root(root),
         {:ok, repo_root} <- resolve_repo_root(normalized_root),
         :ok <- ensure_repo_root!(normalized_root, repo_root),
         {:ok, tree} <- workspace_tree(repo_root) do
      {:ok,
       %Snapshot{
         id: Event.generate_id(),
         backend: :git,
         root: repo_root,
         fingerprint: tree,
         captured_at: DateTime.utc_now(),
         metadata: %{
           repo_root: repo_root,
           tree: tree,
           head: current_head(repo_root)
         }
       }}
    end
  end

  @impl true
  def diff(%Snapshot{} = from_snapshot, %Snapshot{} = to_snapshot, _opts) do
    with :ok <- validate_snapshots(from_snapshot, to_snapshot),
         {:ok, repo_root} <- snapshot_repo_root(from_snapshot),
         {:ok, from_tree} <- snapshot_tree(from_snapshot),
         {:ok, to_tree} <- snapshot_tree(to_snapshot),
         :ok <- ensure_tree_exists(repo_root, from_tree),
         :ok <- ensure_tree_exists(repo_root, to_tree),
         {:ok, output} <-
           run_git(
             repo_root,
             ["diff", "--name-status", "--no-renames", from_tree, to_tree, "--"],
             "compute git workspace diff"
           ),
         {:ok, paths_by_kind} <- parse_name_status(output) do
      {:ok,
       %Diff{
         backend: :git,
         from_snapshot_id: from_snapshot.id,
         to_snapshot_id: to_snapshot.id,
         added: Enum.sort(paths_by_kind.added),
         modified: Enum.sort(paths_by_kind.modified),
         deleted: Enum.sort(paths_by_kind.deleted),
         metadata: %{from_tree: from_tree, to_tree: to_tree}
       }}
    end
  end

  @impl true
  def rollback(%Snapshot{} = snapshot, _opts) do
    with :ok <- ensure_git_available(),
         {:ok, repo_root} <- snapshot_repo_root(snapshot),
         :ok <- ensure_repo_root!(snapshot.root, repo_root),
         :ok <- ensure_head_matches(snapshot, repo_root),
         {:ok, target_tree} <- snapshot_tree(snapshot),
         :ok <- ensure_tree_exists(repo_root, target_tree),
         {:ok, guard_tree} <- workspace_tree(repo_root) do
      rollback_with_guard(repo_root, target_tree, guard_tree)
    end
  end

  @spec available?(String.t()) :: boolean()
  def available?(root) when is_binary(root) do
    with :ok <- ensure_git_available(),
         {:ok, normalized_root} <- normalize_root(root),
         {:ok, repo_root} <- resolve_repo_root(normalized_root),
         :ok <- ensure_repo_root!(normalized_root, repo_root) do
      true
    else
      _ -> false
    end
  end

  defp validate_snapshots(%Snapshot{backend: :git, root: root_a}, %Snapshot{
         backend: :git,
         root: root_b
       }) do
    if same_path?(root_a, root_b) do
      :ok
    else
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "git backend diff requires snapshots from the same repository root"
       )}
    end
  end

  defp validate_snapshots(%Snapshot{}, %Snapshot{}) do
    {:error,
     Error.new(
       :config_invalid,
       :config,
       "git backend diff requires git snapshots"
     )}
  end

  defp snapshot_repo_root(%Snapshot{metadata: %{repo_root: repo_root}})
       when is_binary(repo_root) do
    {:ok, repo_root}
  end

  defp snapshot_repo_root(%Snapshot{root: root}) when is_binary(root), do: {:ok, root}

  defp snapshot_repo_root(%Snapshot{}) do
    {:error,
     Error.new(
       :config_invalid,
       :config,
       "git snapshot metadata is missing repository root"
     )}
  end

  defp snapshot_tree(%Snapshot{metadata: %{tree: tree}}) when is_binary(tree) and tree != "",
    do: {:ok, tree}

  defp snapshot_tree(%Snapshot{fingerprint: fingerprint})
       when is_binary(fingerprint) and fingerprint != "" do
    {:ok, fingerprint}
  end

  defp snapshot_tree(%Snapshot{}) do
    {:error,
     Error.new(
       :config_invalid,
       :config,
       "git snapshot metadata is missing tree fingerprint"
     )}
  end

  defp ensure_repo_root!(requested_root, repo_root) do
    if same_path?(requested_root, repo_root) do
      :ok
    else
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "git backend requires workspace root to be the repository root"
       )}
    end
  end

  defp normalize_root(root) do
    expanded = Path.expand(root)

    if File.dir?(expanded) do
      {:ok, expanded}
    else
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "workspace root does not exist or is not a directory: #{inspect(root)}"
       )}
    end
  end

  defp resolve_repo_root(root) do
    with {:ok, output} <- run_git(root, ["rev-parse", "--show-toplevel"], "resolve git root") do
      {:ok, String.trim(output)}
    end
  end

  defp current_head(repo_root) do
    case run_git(repo_root, ["rev-parse", "HEAD"], "read current git HEAD") do
      {:ok, output} -> String.trim(output)
      {:error, _reason} -> nil
    end
  end

  defp workspace_tree(repo_root) do
    temp_index = temp_index_path()
    env = [{"GIT_INDEX_FILE", temp_index}]

    result =
      with {:ok, _} <-
             run_git(repo_root, ["add", "-A", "--", "."], "capture workspace tree", env: env),
           {:ok, output} <- run_git(repo_root, ["write-tree"], "capture workspace tree", env: env) do
        {:ok, String.trim(output)}
      end

    _ = File.rm(temp_index)
    result
  end

  defp ensure_head_matches(%Snapshot{metadata: %{head: nil}}, _repo_root), do: :ok

  defp ensure_head_matches(%Snapshot{metadata: %{head: expected_head}}, repo_root)
       when is_binary(expected_head) do
    case current_head(repo_root) do
      ^expected_head ->
        :ok

      current_head when is_binary(current_head) ->
        {:error,
         Error.new(
           :unknown,
           :runtime,
           "refusing workspace rollback because git HEAD changed since snapshot",
           cause: %{expected_head: expected_head, current_head: current_head}
         )}

      nil ->
        {:error,
         Error.new(
           :unknown,
           :runtime,
           "refusing workspace rollback because current git HEAD cannot be resolved"
         )}
    end
  end

  defp ensure_head_matches(%Snapshot{}, _repo_root), do: :ok

  defp ensure_tree_exists(repo_root, tree) when is_binary(tree) do
    case run_git(repo_root, ["cat-file", "-e", "#{tree}^{tree}"], "validate git tree") do
      {:ok, _} ->
        :ok

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp rollback_with_guard(repo_root, target_tree, guard_tree) do
    case restore_tree(repo_root, target_tree) do
      :ok ->
        :ok

      {:error, %Error{} = rollback_error} ->
        case restore_tree(repo_root, guard_tree) do
          :ok ->
            {:error,
             Error.new(
               :unknown,
               :runtime,
               "workspace rollback failed; workspace restored to pre-rollback state",
               cause: rollback_error
             )}

          {:error, %Error{} = recovery_error} ->
            {:error,
             Error.new(
               :unknown,
               :runtime,
               "workspace rollback failed and recovery rollback also failed",
               cause: %{rollback_error: rollback_error, recovery_error: recovery_error}
             )}
        end
    end
  end

  defp restore_tree(repo_root, tree) do
    with :ok <- ensure_tree_exists(repo_root, tree),
         :ok <- checkout_tree(repo_root, tree),
         :ok <- clear_index_staging(repo_root),
         {:ok, target_files} <- tree_files(repo_root, tree),
         {:ok, workspace_files} <- current_workspace_files(repo_root) do
      delete_extra_paths(repo_root, workspace_files -- target_files)
    end
  end

  defp checkout_tree(repo_root, tree) do
    if tree_empty?(repo_root, tree) do
      :ok
    else
      case run_git(repo_root, ["checkout", tree, "--", "."], "restore workspace from git tree") do
        {:ok, _} -> :ok
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  defp clear_index_staging(repo_root) do
    case run_git(repo_root, ["reset", "--mixed", "--quiet"], "reset index after rollback") do
      {:ok, _} -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp tree_empty?(repo_root, tree) do
    case run_git(repo_root, ["ls-tree", "-r", "--name-only", tree], "inspect git tree entries") do
      {:ok, output} -> String.trim(output) == ""
      {:error, _} -> false
    end
  end

  defp tree_files(repo_root, tree) do
    with {:ok, output} <-
           run_git(repo_root, ["ls-tree", "-r", "--name-only", "-z", tree], "list git tree files") do
      {:ok, parse_null_terminated(output)}
    end
  end

  defp current_workspace_files(repo_root) do
    with {:ok, output} <-
           run_git(
             repo_root,
             ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
             "list workspace files"
           ) do
      {:ok, parse_null_terminated(output)}
    end
  end

  defp delete_extra_paths(_repo_root, []), do: :ok

  defp delete_extra_paths(repo_root, paths) when is_list(paths) do
    paths
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn relative_path, :ok ->
      with :ok <- validate_relative_delete_path(relative_path),
           {:ok, absolute_path} <- resolve_delete_target(repo_root, relative_path),
           :ok <- remove_path(absolute_path) do
        {:cont, :ok}
      else
        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp validate_relative_delete_path(path) when is_binary(path) do
    cond do
      path in ["", ".", ".."] ->
        {:error,
         Error.new(
           :unknown,
           :runtime,
           "invalid rollback delete path",
           cause: path
         )}

      Path.type(path) == :absolute ->
        {:error,
         Error.new(
           :unknown,
           :runtime,
           "rollback delete path must be relative",
           cause: path
         )}

      Enum.any?(Path.split(path), &(&1 == ".." or &1 == ".git")) ->
        {:error,
         Error.new(
           :unknown,
           :runtime,
           "rollback delete path is unsafe",
           cause: path
         )}

      true ->
        :ok
    end
  end

  defp resolve_delete_target(repo_root, relative_path) do
    root = Path.expand(repo_root)
    absolute_path = Path.expand(relative_path, root)

    if String.starts_with?(absolute_path, root <> "/") do
      {:ok, absolute_path}
    else
      {:error,
       Error.new(
         :unknown,
         :runtime,
         "rollback delete target escapes workspace root",
         cause: %{root: root, path: relative_path}
       )}
    end
  end

  defp remove_path(path) do
    case File.rm_rf(path) do
      {:ok, _removed} ->
        :ok

      {:error, reason, failed_path} ->
        {:error,
         Error.new(
           :unknown,
           :runtime,
           "failed to remove rollback path",
           cause: %{path: failed_path, reason: reason}
         )}
    end
  end

  defp parse_name_status(output) when is_binary(output) do
    parsed =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce_while({:ok, %{added: [], modified: [], deleted: []}}, fn line, {:ok, acc} ->
        case parse_name_status_line(line) do
          {:ok, kind, path} ->
            {:cont, {:ok, append_name_status(acc, kind, path)}}

          {:error, %Error{} = error} ->
            {:halt, {:error, error}}
        end
      end)

    case parsed do
      {:ok, %{added: added, modified: modified, deleted: deleted}} ->
        {:ok,
         %{added: Enum.uniq(added), modified: Enum.uniq(modified), deleted: Enum.uniq(deleted)}}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp parse_name_status_line(line) do
    case String.split(line, "\t", parts: 2) do
      [status, path] ->
        {:ok, name_status_kind(status), path}

      _other ->
        {:error,
         Error.new(
           :unknown,
           :runtime,
           "invalid git diff --name-status output line",
           cause: line
         )}
    end
  end

  defp append_name_status(acc, :added, path), do: %{acc | added: [path | acc.added]}
  defp append_name_status(acc, :deleted, path), do: %{acc | deleted: [path | acc.deleted]}
  defp append_name_status(acc, :modified, path), do: %{acc | modified: [path | acc.modified]}

  defp name_status_kind("A"), do: :added
  defp name_status_kind("D"), do: :deleted
  defp name_status_kind(_), do: :modified

  defp parse_null_terminated(binary) when is_binary(binary) do
    binary
    |> String.split(<<0>>, trim: true)
    |> Enum.sort()
  end

  defp run_git(root, args, operation, opts \\ [])
       when is_binary(root) and is_list(args) and is_binary(operation) do
    env = Keyword.get(opts, :env, [])

    case System.cmd("git", ["-C", root] ++ args, stderr_to_stdout: true, env: env) do
      {output, 0} ->
        {:ok, output}

      {output, status} ->
        {:error,
         Error.new(
           :unknown,
           :runtime,
           "#{operation} failed",
           cause: %{status: status, args: args, output: String.trim(output)}
         )}
    end
  rescue
    error in ErlangError ->
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "git executable is not available",
         cause: error
       )}
  end

  defp ensure_git_available do
    case System.cmd("git", ["--version"], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "git executable is unavailable",
           cause: %{status: status, output: String.trim(output)}
         )}
    end
  rescue
    error in ErlangError ->
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "git executable is unavailable",
         cause: error
       )}
  end

  defp temp_index_path do
    Path.join(
      System.tmp_dir!(),
      "asm-workspace-git-index-#{System.unique_integer([:positive])}"
    )
  end

  defp same_path?(left, right) do
    Path.expand(left) == Path.expand(right)
  end
end
