defmodule ASM.Telemetry do
  @moduledoc """
  Telemetry helpers for standard ASM runtime lifecycle signals.
  """

  @spec run_started(String.t(), String.t(), atom()) :: :ok
  def run_started(session_id, run_id, provider) do
    execute([:asm, :run, :started], %{}, %{
      session_id: session_id,
      run_id: run_id,
      provider: provider
    })
  end

  @spec run_completed(String.t(), String.t(), atom(), term()) :: :ok
  def run_completed(session_id, run_id, provider, status) do
    execute([:asm, :run, :completed], %{}, %{
      session_id: session_id,
      run_id: run_id,
      provider: provider,
      status: status
    })
  end

  @spec remote_connect_start(map()) :: :ok
  def remote_connect_start(metadata) when is_map(metadata) do
    execute([:asm, :remote, :connect, :start], %{}, metadata)
  end

  @spec remote_connect_stop(map(), non_neg_integer()) :: :ok
  def remote_connect_stop(metadata, duration_ms)
      when is_map(metadata) and is_integer(duration_ms) do
    execute([:asm, :remote, :connect, :stop], %{duration_ms: duration_ms}, metadata)
  end

  @spec remote_preflight_start(map()) :: :ok
  def remote_preflight_start(metadata) when is_map(metadata) do
    execute([:asm, :remote, :preflight, :start], %{}, metadata)
  end

  @spec remote_preflight_stop(map(), non_neg_integer()) :: :ok
  def remote_preflight_stop(metadata, duration_ms)
      when is_map(metadata) and is_integer(duration_ms) do
    execute([:asm, :remote, :preflight, :stop], %{duration_ms: duration_ms}, metadata)
  end

  @spec remote_rpc_start_transport_start(map()) :: :ok
  def remote_rpc_start_transport_start(metadata) when is_map(metadata) do
    execute([:asm, :remote, :rpc_start_transport, :start], %{}, metadata)
  end

  @spec remote_rpc_start_transport_stop(map(), non_neg_integer()) :: :ok
  def remote_rpc_start_transport_stop(metadata, duration_ms)
      when is_map(metadata) and is_integer(duration_ms) do
    execute([:asm, :remote, :rpc_start_transport, :stop], %{duration_ms: duration_ms}, metadata)
  end

  @spec remote_attach_start(map()) :: :ok
  def remote_attach_start(metadata) when is_map(metadata) do
    execute([:asm, :remote, :attach, :start], %{}, metadata)
  end

  @spec remote_attach_stop(map(), non_neg_integer()) :: :ok
  def remote_attach_stop(metadata, duration_ms)
      when is_map(metadata) and is_integer(duration_ms) do
    execute([:asm, :remote, :attach, :stop], %{duration_ms: duration_ms}, metadata)
  end

  @spec remote_error(map()) :: :ok
  def remote_error(metadata) when is_map(metadata) do
    execute([:asm, :remote, :error], %{}, metadata)
  end

  @spec execute([atom()], map(), map()) :: :ok
  def execute(event_name, measurements, metadata)
      when is_list(event_name) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(event_name, measurements, metadata)
  end
end
