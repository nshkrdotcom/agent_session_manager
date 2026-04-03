defmodule ASM.SessionControl do
  @moduledoc """
  Provider-native session control helpers for historical resume and
  interrupt-then-intervene flows.
  """

  alias ASM.{Error, Provider, ProviderRegistry, Session}

  defmodule Entry do
    @moduledoc """
    Standardized provider-native resumable session entry.
    """

    @enforce_keys [:provider, :id]
    defstruct [
      :provider,
      :id,
      :label,
      :cwd,
      :updated_at,
      :source_kind,
      metadata: %{},
      raw: %{}
    ]

    @type t :: %__MODULE__{
            provider: atom(),
            id: String.t(),
            label: String.t() | nil,
            cwd: String.t() | nil,
            updated_at: String.t() | nil,
            source_kind: atom() | nil,
            metadata: map(),
            raw: map()
          }
  end

  @type provider_or_session :: Provider.provider_name() | pid()
  @type resume_target :: :checkpoint | :latest | String.t()

  @spec list_provider_sessions(provider_or_session(), keyword()) ::
          {:ok, [Entry.t()]} | {:error, Error.t()}
  def list_provider_sessions(provider_or_session, opts \\ []) when is_list(opts) do
    with {:ok, %Provider{} = provider} <- resolve_provider(provider_or_session),
         {:ok, runtime} <- fetch_runtime(provider),
         true <- function_exported?(runtime, :list_provider_sessions, 1) || missing_list_error(),
         {:ok, sessions} <- runtime.list_provider_sessions(opts) do
      {:ok, Enum.map(sessions, &normalize_entry(provider.name, &1))}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(
           :runtime,
           :provider,
           "provider session listing failed: #{inspect(reason)}",
           cause: reason
         )}
    end
  end

  @spec pause(pid(), String.t()) :: :ok | {:error, Error.t()}
  def pause(session, run_id) when is_pid(session) and is_binary(run_id) do
    Session.Server.pause_run(session, run_id)
  end

  @spec checkpoint(pid()) :: {:ok, map() | nil} | {:error, Error.t()}
  def checkpoint(session) when is_pid(session) do
    Session.Server.checkpoint(session)
  end

  @spec resume_run(pid(), String.t(), keyword()) ::
          {:ok, String.t(), pid() | :queued} | {:error, Error.t()}
  def resume_run(session, prompt, opts \\ [])
      when is_pid(session) and is_binary(prompt) and is_list(opts) do
    Session.Server.resume_run(session, prompt, opts)
  end

  @spec intervene(pid(), String.t(), String.t(), keyword()) ::
          {:ok, String.t(), pid() | :queued} | {:error, Error.t()}
  def intervene(session, run_id, prompt, opts \\ [])
      when is_pid(session) and is_binary(run_id) and is_binary(prompt) and is_list(opts) do
    Session.Server.intervene(session, run_id, prompt, opts)
  end

  @spec continuation_from_checkpoint(map() | nil, keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def continuation_from_checkpoint(checkpoint, opts \\ []) when is_list(opts) do
    checkpoint
    |> continuation_target(Keyword.get(opts, :target, :checkpoint))
    |> build_continuation()
  end

  defp continuation_target(checkpoint, :checkpoint),
    do: {:checkpoint, checkpoint_provider_session_id(checkpoint)}

  defp continuation_target(_checkpoint, :latest), do: :latest

  defp continuation_target(_checkpoint, target) when is_binary(target) and target != "",
    do: {:exact, target}

  defp continuation_target(_checkpoint, other), do: {:invalid, other}

  defp build_continuation({:checkpoint, provider_session_id})
       when is_binary(provider_session_id) and provider_session_id != "" do
    {:ok, %{strategy: :exact, provider_session_id: provider_session_id}}
  end

  defp build_continuation({:checkpoint, _missing}) do
    {:error,
     Error.new(
       :config_invalid,
       :provider,
       "session checkpoint does not contain a resumable provider session id"
     )}
  end

  defp build_continuation(:latest), do: {:ok, %{strategy: :latest}}

  defp build_continuation({:exact, provider_session_id}) do
    {:ok, %{strategy: :exact, provider_session_id: provider_session_id}}
  end

  defp build_continuation({:invalid, other}) do
    {:error,
     Error.new(
       :config_invalid,
       :config,
       "invalid resume target #{inspect(other)}; expected :checkpoint, :latest, or a session id"
     )}
  end

  defp checkpoint_provider_session_id(checkpoint) do
    checkpoint = checkpoint || %{}

    Map.get(checkpoint, :provider_session_id) ||
      Map.get(checkpoint, "provider_session_id")
  end

  defp resolve_provider(session) when is_pid(session) do
    with {:ok, %{provider: provider}} <- ASM.session_info(session) do
      Provider.resolve(provider)
    end
  end

  defp resolve_provider(provider_or_session), do: Provider.resolve(provider_or_session)

  defp fetch_runtime(%Provider{name: name}) do
    case ProviderRegistry.provider_info(name) do
      {:ok, %{sdk_runtime: runtime, sdk_available?: true}} when is_atom(runtime) ->
        {:ok, runtime}

      {:ok, %{sdk_runtime: _runtime}} ->
        {:error,
         Error.new(
           :config_invalid,
           :provider,
           "sdk runtime is unavailable for provider #{inspect(name)}"
         )}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp missing_list_error do
    {:error,
     Error.new(
       :config_invalid,
       :provider,
       "provider runtime does not publish a list_provider_sessions/1 surface"
     )}
  end

  defp normalize_entry(provider, %Entry{} = entry), do: %{entry | provider: provider}

  defp normalize_entry(provider, attrs) when is_map(attrs) do
    %Entry{
      provider: provider,
      id: to_string(Map.fetch!(attrs, :id)),
      label: fetch_optional(attrs, :label),
      cwd: fetch_optional(attrs, :cwd),
      updated_at: fetch_optional(attrs, :updated_at),
      source_kind: fetch_optional(attrs, :source_kind),
      metadata: normalize_map(Map.get(attrs, :metadata, Map.get(attrs, "metadata", %{}))),
      raw: normalize_map(attrs)
    }
  end

  defp fetch_optional(attrs, key) when is_map(attrs) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}
end
