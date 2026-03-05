defmodule ASM.Extensions.PubSub.Adapters.Local do
  @moduledoc """
  Local in-node PubSub adapter built on `Registry` duplicate keys.

  Broadcast message contract:
  - each subscriber receives `{:asm_pubsub, topic, payload}`
  """

  @behaviour ASM.Extensions.PubSub.Adapter

  alias ASM.Error

  @default_registry :asm_ext_pubsub

  @type registry_ref :: atom() | pid()
  @type state :: %{registry: registry_ref()}

  @spec start_link(keyword()) :: GenServer.on_start() | {:error, Error.t()}
  def start_link(opts \\ []) when is_list(opts) do
    with {:ok, registry} <- normalize_registry(Keyword.get(opts, :registry, @default_registry)) do
      case registry do
        name when is_atom(name) ->
          Registry.start_link(keys: :duplicate, name: name)

        _pid ->
          {:error, config_error("local adapter start_link/1 requires atom :registry name")}
      end
    end
  end

  @impl true
  def init(opts) when is_list(opts) do
    auto_start? = Keyword.get(opts, :auto_start, true)

    with {:ok, registry} <- normalize_registry(Keyword.get(opts, :registry, @default_registry)),
         :ok <- ensure_registry(registry, auto_start?) do
      {:ok, %{registry: registry}}
    end
  end

  @impl true
  def broadcast(%{registry: registry}, topic, message) when is_binary(topic) do
    Registry.dispatch(registry, topic, fn entries ->
      Enum.each(entries, fn {pid, _meta} -> send(pid, message) end)
    end)

    :ok
  rescue
    error in [ArgumentError] ->
      {:error, runtime_error("local pubsub broadcast failed", error)}
  catch
    :exit, reason ->
      {:error, runtime_error("local pubsub broadcast failed", reason)}
  end

  @impl true
  def subscribe(%{registry: registry}, topic) when is_binary(topic) do
    case Registry.register(registry, topic, :ok) do
      {:ok, _owner} ->
        :ok

      {:error, {:already_registered, _owner}} ->
        :ok

      {:error, reason} ->
        {:error, runtime_error("local pubsub subscribe failed", reason)}
    end
  rescue
    error in [ArgumentError] ->
      {:error, runtime_error("local pubsub subscribe failed", error)}
  catch
    :exit, reason ->
      {:error, runtime_error("local pubsub subscribe failed", reason)}
  end

  defp ensure_registry(registry, true) do
    if is_pid(registry) do
      if Process.alive?(registry) do
        :ok
      else
        {:error, config_error("local pubsub registry pid is not alive: #{inspect(registry)}")}
      end
    else
      do_ensure_registry_named(registry)
    end
  end

  defp ensure_registry(registry, false) do
    cond do
      is_pid(registry) and Process.alive?(registry) ->
        :ok

      is_atom(registry) and Process.whereis(registry) ->
        :ok

      is_pid(registry) ->
        {:error, config_error("local pubsub registry pid is not alive: #{inspect(registry)}")}

      true ->
        {:error, config_error("local pubsub registry is not started: #{inspect(registry)}")}
    end
  end

  defp do_ensure_registry_named(registry) do
    case Process.whereis(registry) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Registry.start_link(keys: :duplicate, name: registry) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            {:error, runtime_error("failed to start local pubsub registry", reason)}
        end
    end
  end

  defp normalize_registry(registry) when is_atom(registry), do: {:ok, registry}

  defp normalize_registry(registry) when is_pid(registry) do
    if Process.alive?(registry) do
      {:ok, registry}
    else
      {:error, config_error("local adapter :registry pid is not alive: #{inspect(registry)}")}
    end
  end

  defp normalize_registry(other) do
    {:error,
     config_error("local adapter :registry must be an atom or pid, got: #{inspect(other)}")}
  end

  defp config_error(message) do
    Error.new(:config_invalid, :config, message)
  end

  defp runtime_error(message, cause) do
    Error.new(:unknown, :runtime, message, cause: cause)
  end
end
