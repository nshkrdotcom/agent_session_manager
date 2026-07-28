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

  @spec execute([atom()], map(), map()) :: :ok
  def execute(event_name, measurements, metadata)
      when is_list(event_name) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(event_name, measurements, metadata)
  end
end
