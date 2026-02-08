defmodule AgentSessionManager.Workspace.GitBackend do
  @moduledoc """
  Git-backed workspace snapshots, diffs, and rollback support.
  """

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Workspace.{Diff, Snapshot}

  @default_patch_bytes 1_048_576

  @spec take_snapshot(String.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def take_snapshot(path, opts \\ []) when is_binary(path) do
    expanded_path = Path.expand(path)

    with :ok <- ensure_git_repo(expanded_path),
         {:ok, head_ref} <- git(expanded_path, ["rev-parse", "HEAD"]),
         {:ok, stash_ref} <- git(expanded_path, ["stash", "create"]) do
      ref =
        stash_ref
        |> String.trim()
        |> case do
          "" -> String.trim(head_ref)
          value -> value
        end

      {:ok,
       %Snapshot{
         backend: :git,
         path: expanded_path,
         ref: ref,
         label: Keyword.get(opts, :label),
         captured_at: DateTime.utc_now(),
         metadata: %{head_ref: String.trim(head_ref), dirty: ref != String.trim(head_ref)}
       }}
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
        max_patch_bytes = Keyword.get(opts, :max_patch_bytes, @default_patch_bytes)

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
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
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
