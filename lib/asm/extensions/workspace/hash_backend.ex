defmodule ASM.Extensions.Workspace.HashBackend do
  @moduledoc """
  Filesystem hash backend used when git snapshots are unavailable.
  """

  @behaviour ASM.Extensions.Workspace.Backend

  alias ASM.{Error, Event}
  alias ASM.Extensions.Workspace.{Diff, Snapshot}

  @impl true
  def snapshot(root, _opts) when is_binary(root) do
    with :ok <- ensure_workspace_root(root),
         {:ok, file_hashes} <- collect_file_hashes(root),
         {:ok, fingerprint} <- manifest_fingerprint(file_hashes) do
      {:ok,
       %Snapshot{
         id: Event.generate_id(),
         backend: :hash,
         root: root,
         fingerprint: fingerprint,
         captured_at: DateTime.utc_now(),
         metadata: %{files: file_hashes}
       }}
    end
  end

  @impl true
  def diff(%Snapshot{} = from_snapshot, %Snapshot{} = to_snapshot, _opts) do
    with :ok <- validate_snapshots(from_snapshot, to_snapshot),
         {:ok, from_files} <- extract_files(from_snapshot),
         {:ok, to_files} <- extract_files(to_snapshot) do
      from_paths = Map.keys(from_files)
      to_paths = Map.keys(to_files)

      added = to_paths |> MapSet.new() |> MapSet.difference(MapSet.new(from_paths)) |> Enum.sort()

      deleted =
        from_paths |> MapSet.new() |> MapSet.difference(MapSet.new(to_paths)) |> Enum.sort()

      modified =
        from_paths
        |> MapSet.new()
        |> MapSet.intersection(MapSet.new(to_paths))
        |> Enum.filter(fn path -> Map.fetch!(from_files, path) != Map.fetch!(to_files, path) end)
        |> Enum.sort()

      {:ok,
       %Diff{
         backend: :hash,
         from_snapshot_id: from_snapshot.id,
         to_snapshot_id: to_snapshot.id,
         added: added,
         modified: modified,
         deleted: deleted,
         metadata: %{
           from_fingerprint: from_snapshot.fingerprint,
           to_fingerprint: to_snapshot.fingerprint
         }
       }}
    end
  end

  @impl true
  def rollback(%Snapshot{}, _opts) do
    {:error,
     Error.new(
       :unknown,
       :runtime,
       "workspace rollback is unsupported for hash backend snapshots"
     )}
  end

  defp ensure_workspace_root(root) do
    if File.dir?(root) do
      :ok
    else
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "workspace root does not exist or is not a directory: #{inspect(root)}"
       )}
    end
  end

  defp validate_snapshots(%Snapshot{backend: :hash, root: root_a}, %Snapshot{
         backend: :hash,
         root: root_b
       }) do
    if Path.expand(root_a) == Path.expand(root_b) do
      :ok
    else
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "hash backend diff requires snapshots from the same root"
       )}
    end
  end

  defp validate_snapshots(%Snapshot{}, %Snapshot{}) do
    {:error,
     Error.new(
       :config_invalid,
       :config,
       "hash backend diff requires hash snapshots"
     )}
  end

  defp extract_files(%Snapshot{metadata: %{files: files}}) when is_map(files), do: {:ok, files}

  defp extract_files(%Snapshot{}) do
    {:error,
     Error.new(
       :config_invalid,
       :config,
       "hash snapshot metadata is missing file hashes"
     )}
  end

  defp collect_file_hashes(root) do
    walk_tree(root, root, %{})
  end

  defp walk_tree(root, current_dir, acc) do
    case list_directory(current_dir) do
      {:ok, entries} ->
        reduce_entries(root, current_dir, Enum.sort(entries), acc)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp list_directory(current_dir) do
    case File.ls(current_dir) do
      {:ok, entries} ->
        {:ok, entries}

      {:error, reason} ->
        {:error,
         Error.new(
           :unknown,
           :runtime,
           "failed to list directory #{inspect(current_dir)}",
           cause: reason
         )}
    end
  end

  defp reduce_entries(_root, _current_dir, [], memo), do: {:ok, memo}

  defp reduce_entries(root, current_dir, [entry | rest], memo) do
    case process_entry(root, current_dir, entry, memo) do
      {:ok, next_memo} ->
        reduce_entries(root, current_dir, rest, next_memo)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp process_entry(root, current_dir, entry, memo) do
    absolute_path = Path.join(current_dir, entry)
    relative_path = Path.relative_to(absolute_path, root)

    case File.lstat(absolute_path) do
      {:ok, %File.Stat{type: type}} ->
        process_entry_by_type(type, root, absolute_path, relative_path, entry, memo)

      {:error, reason} ->
        {:error,
         Error.new(
           :unknown,
           :runtime,
           "failed to read filesystem entry #{inspect(relative_path)}",
           cause: reason
         )}
    end
  end

  defp process_entry_by_type(:directory, _root, _absolute_path, _relative_path, ".git", memo),
    do: {:ok, memo}

  defp process_entry_by_type(:directory, root, absolute_path, _relative_path, _entry, memo),
    do: walk_tree(root, absolute_path, memo)

  defp process_entry_by_type(:regular, _root, absolute_path, relative_path, _entry, memo) do
    with {:ok, hash} <- hash_file(absolute_path) do
      {:ok, Map.put(memo, relative_path, hash)}
    end
  end

  defp process_entry_by_type(:symlink, _root, absolute_path, relative_path, _entry, memo) do
    with {:ok, hash} <- hash_symlink(absolute_path, relative_path) do
      {:ok, Map.put(memo, relative_path, hash)}
    end
  end

  defp process_entry_by_type(_other, _root, _absolute_path, _relative_path, _entry, memo),
    do: {:ok, memo}

  defp hash_file(path) do
    case File.read(path) do
      {:ok, content} ->
        hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
        {:ok, hash}

      {:error, reason} ->
        {:error,
         Error.new(
           :unknown,
           :runtime,
           "failed to read file #{inspect(path)}",
           cause: reason
         )}
    end
  end

  defp hash_symlink(path, relative_path) do
    case File.read_link(path) do
      {:ok, target} ->
        hash =
          target
          |> then(&"symlink:#{&1}")
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)

        {:ok, hash}

      {:error, reason} ->
        {:error,
         Error.new(
           :unknown,
           :runtime,
           "failed to read symlink #{inspect(relative_path)}",
           cause: reason
         )}
    end
  end

  defp manifest_fingerprint(file_hashes) when is_map(file_hashes) do
    fingerprint_input =
      file_hashes
      |> Enum.sort_by(fn {path, _hash} -> path end)
      |> Enum.map_join("\n", fn {path, hash} -> "#{path}\u0000#{hash}" end)

    {:ok, :crypto.hash(:sha256, fingerprint_input) |> Base.encode16(case: :lower)}
  end
end
