defmodule AgentSessionManager.Workspace.Workspace do
  @moduledoc """
  Public workspace service that delegates to git/hash backends.
  """

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Workspace.{Diff, GitBackend, HashBackend, Snapshot}

  @spec take_snapshot(String.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def take_snapshot(path, opts \\ []) when is_binary(path) do
    backend = select_backend(path, opts)
    backend_module(backend).take_snapshot(path, opts)
  end

  @spec diff(Snapshot.t(), Snapshot.t(), keyword()) :: {:ok, Diff.t()} | {:error, Error.t()}
  def diff(before_snapshot, after_snapshot, opts \\ [])

  def diff(
        %Snapshot{backend: backend} = before_snapshot,
        %Snapshot{backend: backend} = after_snapshot,
        opts
      ) do
    backend_module(backend).diff(before_snapshot, after_snapshot, opts)
  end

  def diff(%Snapshot{}, %Snapshot{}, _opts) do
    {:error, Error.new(:validation_error, "Workspace snapshots must use the same backend")}
  end

  @spec rollback(Snapshot.t(), keyword()) :: :ok | {:error, Error.t()}
  def rollback(%Snapshot{backend: backend} = snapshot, opts \\ []) do
    backend_module(backend).rollback(snapshot, opts)
  end

  @spec detect_backend(String.t()) :: :git | :hash
  def detect_backend(path) when is_binary(path) do
    expanded = Path.expand(path)

    if File.dir?(Path.join(expanded, ".git")) do
      :git
    else
      case System.cmd("git", ["-C", expanded, "rev-parse", "--show-toplevel"],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :git
        _ -> :hash
      end
    end
  rescue
    _ -> :hash
  end

  @spec backend_for_path(String.t(), keyword()) :: :git | :hash
  def backend_for_path(path, opts \\ []) when is_binary(path) do
    select_backend(path, opts)
  end

  defp select_backend(path, opts) do
    case Keyword.get(opts, :strategy, :auto) do
      :auto -> detect_backend(path)
      :git -> :git
      :hash -> :hash
      _ -> detect_backend(path)
    end
  end

  defp backend_module(:git), do: GitBackend
  defp backend_module(:hash), do: HashBackend
end
