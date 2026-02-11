defmodule AgentSessionManager.Workspace.GitBackend do
  @moduledoc """
  Git-backed workspace snapshots, diffs, and rollback support.
  """

  alias AgentSessionManager.Config
  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Workspace.{Diff, Snapshot}

  @spec take_snapshot(String.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def take_snapshot(path, opts \\ []) when is_binary(path) do
    expanded_path = Path.expand(path)

    with :ok <- ensure_git_repo(expanded_path),
         {:ok, head_ref_raw} <- git(expanded_path, ["rev-parse", "HEAD"]) do
      head_ref = String.trim(head_ref_raw)

      case take_alternate_index_snapshot(expanded_path, head_ref) do
        {:ok, commit_ref, includes_untracked} ->
          dirty = commit_ref != head_ref

          {:ok,
           %Snapshot{
             backend: :git,
             path: expanded_path,
             ref: commit_ref,
             label: Keyword.get(opts, :label),
             captured_at: DateTime.utc_now(),
             metadata: %{
               head_ref: head_ref,
               dirty: dirty,
               includes_untracked: includes_untracked
             }
           }}

        {:error, _} = error ->
          error
      end
    end
  end

  # Uses an alternate GIT_INDEX_FILE to snapshot full workspace state
  # (tracked + untracked) without modifying HEAD or leaving stash entries.
  defp take_alternate_index_snapshot(path, head_ref) do
    tmp_index =
      Path.join(
        System.tmp_dir!(),
        "asm_git_index_#{System.unique_integer([:positive, :monotonic])}"
      )

    try do
      # Start from the current HEAD's tree in the alternate index
      with {:ok, _} <- git_env(path, ["read-tree", head_ref], %{"GIT_INDEX_FILE" => tmp_index}),
           # Stage all tracked + untracked files into the alternate index
           {:ok, _} <-
             git_env(path, ["add", "-A"], %{"GIT_INDEX_FILE" => tmp_index}),
           {:ok, tree_output} <-
             git_env(path, ["write-tree"], %{"GIT_INDEX_FILE" => tmp_index}) do
        tree_ref = String.trim(tree_output)

        # Check if tree matches HEAD's tree (i.e. workspace is clean)
        case git(path, ["rev-parse", "#{head_ref}^{tree}"]) do
          {:ok, head_tree_raw} ->
            head_tree = String.trim(head_tree_raw)

            if tree_ref == head_tree do
              # Clean workspace - use HEAD directly
              {:ok, head_ref, true}
            else
              # Dirty workspace - create a dangling commit object
              case git_env(
                     path,
                     ["commit-tree", tree_ref, "-p", head_ref, "-m", "asm workspace snapshot"],
                     %{"GIT_INDEX_FILE" => tmp_index}
                   ) do
                {:ok, commit_output} ->
                  {:ok, String.trim(commit_output), true}

                {:error, _} = error ->
                  error
              end
            end

          {:error, _} = error ->
            error
        end
      end
    after
      File.rm(tmp_index)
    end
  end

  @spec diff(Snapshot.t(), Snapshot.t(), keyword()) :: {:ok, Diff.t()} | {:error, Error.t()}
  def diff(before_snapshot, after_snapshot, opts \\ [])

  def diff(
        %Snapshot{backend: :git} = before_snapshot,
        %Snapshot{backend: :git} = after_snapshot,
        opts
      ) do
    with :ok <- ensure_same_workspace(before_snapshot, after_snapshot),
         {:ok, changed_paths_output} <-
           git(before_snapshot.path, [
             "diff",
             "--name-only",
             before_snapshot.ref,
             after_snapshot.ref
           ]),
         {:ok, numstat_output} <-
           git(before_snapshot.path, [
             "diff",
             "--numstat",
             before_snapshot.ref,
             after_snapshot.ref
           ]),
         {:ok, patch, patch_metadata} <-
           maybe_capture_patch(before_snapshot, after_snapshot, opts) do
      changed_paths =
        changed_paths_output
        |> String.split("\n", trim: true)
        |> Enum.uniq()
        |> Enum.sort()

      {insertions, deletions} = parse_numstat(numstat_output)

      {:ok,
       %Diff{
         backend: :git,
         from_ref: before_snapshot.ref,
         to_ref: after_snapshot.ref,
         files_changed: length(changed_paths),
         insertions: insertions,
         deletions: deletions,
         changed_paths: changed_paths,
         patch: patch,
         metadata: patch_metadata
       }}
    end
  end

  def diff(_before, _after, _opts) do
    {:error, Error.new(:validation_error, "Git diff requires git snapshots")}
  end

  @spec rollback(Snapshot.t(), keyword()) :: :ok | {:error, Error.t()}
  def rollback(snapshot, opts \\ [])

  def rollback(%Snapshot{backend: :git, path: path, ref: ref}, _opts) do
    with :ok <- ensure_git_repo(path),
         {:ok, _tag} <- create_safety_tag(path),
         {:ok, _} <- git(path, ["reset", "--hard", ref]) do
      :ok
    end
  end

  def rollback(_snapshot, _opts) do
    {:error, Error.new(:validation_error, "Git rollback requires git snapshot")}
  end

  defp ensure_same_workspace(%Snapshot{path: left}, %Snapshot{path: right}) do
    if left == right do
      :ok
    else
      {:error, Error.new(:validation_error, "Snapshots must belong to the same workspace path")}
    end
  end

  defp ensure_git_repo(path) do
    if File.dir?(Path.join(path, ".git")) do
      :ok
    else
      case git(path, ["rev-parse", "--show-toplevel"]) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp maybe_capture_patch(before_snapshot, after_snapshot, opts) do
    case Keyword.get(opts, :capture_patch, false) do
      true ->
        max_patch_bytes = Keyword.get(opts, :max_patch_bytes, Config.get(:max_patch_bytes))

        with {:ok, patch_output} <-
               git(before_snapshot.path, [
                 "diff",
                 "--patch",
                 before_snapshot.ref,
                 after_snapshot.ref
               ]) do
          build_patch_capture_result(patch_output, max_patch_bytes)
        end

      false ->
        {:ok, nil, %{patch_truncated: false}}
    end
  end

  defp build_patch_capture_result(patch, max_patch_bytes) do
    patch_bytes = byte_size(patch)

    case patch_bytes > max_patch_bytes do
      true -> {:ok, nil, %{patch_truncated: true, patch_bytes: patch_bytes}}
      false -> {:ok, patch, %{patch_truncated: false, patch_bytes: patch_bytes}}
    end
  end

  defp parse_numstat(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce({0, 0}, fn line, {insertions, deletions} ->
      case String.split(line, "\t", parts: 3) do
        [ins, del, _path] ->
          {
            insertions + parse_numstat_number(ins),
            deletions + parse_numstat_number(del)
          }

        _ ->
          {insertions, deletions}
      end
    end)
  end

  defp parse_numstat_number("-"), do: 0

  defp parse_numstat_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> 0
    end
  end

  defp create_safety_tag(path) do
    tag =
      "asm_rollback_#{System.system_time(:millisecond)}_#{System.unique_integer([:positive, :monotonic])}"

    with {:ok, _} <- git(path, ["tag", "-f", tag, "HEAD"]) do
      {:ok, tag}
    end
  end

  defp git(path, args) do
    git_env(path, args, %{})
  end

  defp git_env(path, args, env) when map_size(env) == 0 do
    case System.cmd("git", args, stderr_to_stdout: true, cd: path) do
      {output, 0} ->
        {:ok, output}

      {output, _status} ->
        {:error, Error.new(:storage_error, "git command failed: #{String.trim(output)}")}
    end
  rescue
    exception ->
      {:error, Error.new(:storage_error, "git command failed: #{Exception.message(exception)}")}
  end

  defp git_env(path, args, env) do
    env_list = Enum.map(env, fn {k, v} -> {k, v} end)
    cmd_opts = [stderr_to_stdout: true, cd: path, env: env_list]

    case System.cmd("git", args, cmd_opts) do
      {output, 0} ->
        {:ok, output}

      {output, _status} ->
        {:error, Error.new(:storage_error, "git command failed: #{String.trim(output)}")}
    end
  rescue
    exception ->
      {:error, Error.new(:storage_error, "git command failed: #{Exception.message(exception)}")}
  end
end
