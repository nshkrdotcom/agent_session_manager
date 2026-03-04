defmodule ASM.Execution.Config do
  @moduledoc """
  Normalized execution-mode configuration with precedence-aware merging.
  """

  alias ASM.Error

  @valid_execution_modes [:local, :remote_node]
  @valid_bootstrap_modes [:require_prestarted, :ensure_started]

  @enforce_keys [:execution_mode, :transport_call_timeout_ms]
  defstruct [
    :execution_mode,
    :transport_call_timeout_ms,
    remote: nil
  ]

  @type remote_t :: %{
          required(:remote_node) => atom(),
          required(:remote_cookie) => atom() | nil,
          required(:remote_connect_timeout_ms) => pos_integer(),
          required(:remote_rpc_timeout_ms) => pos_integer(),
          required(:remote_boot_lease_timeout_ms) => pos_integer(),
          required(:remote_bootstrap_mode) => :require_prestarted | :ensure_started,
          required(:remote_cwd) => String.t() | nil
        }

  @type t :: %__MODULE__{
          execution_mode: :local | :remote_node,
          transport_call_timeout_ms: pos_integer(),
          remote: remote_t() | nil
        }

  @spec resolve(keyword(), keyword(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def resolve(session_stream_opts, run_stream_opts, opts \\ [])
      when is_list(session_stream_opts) and is_list(run_stream_opts) and is_list(opts) do
    app_cfg = app_config()
    session_driver_opts = normalize_keyword(Keyword.get(session_stream_opts, :driver_opts, []))
    run_driver_opts = normalize_keyword(Keyword.get(run_stream_opts, :driver_opts, []))
    merged_driver_opts = Keyword.merge(session_driver_opts, run_driver_opts)

    explicit_driver? = Keyword.get(opts, :explicit_driver?, false)

    with {:ok, execution_mode} <-
           resolve_execution_mode(app_cfg, session_stream_opts, run_stream_opts, explicit_driver?),
         {:ok, transport_call_timeout_ms} <-
           resolve_transport_call_timeout(
             app_cfg,
             session_stream_opts,
             run_stream_opts,
             merged_driver_opts
           ),
         {:ok, remote} <-
           resolve_remote_config(
             execution_mode,
             app_cfg,
             session_stream_opts,
             run_stream_opts,
             merged_driver_opts
           ) do
      {:ok,
       %__MODULE__{
         execution_mode: execution_mode,
         transport_call_timeout_ms: transport_call_timeout_ms,
         remote: remote
       }}
    end
  end

  defp resolve_execution_mode(_app_cfg, _session_stream_opts, _run_stream_opts, true) do
    {:ok, :local}
  end

  defp resolve_execution_mode(app_cfg, session_stream_opts, run_stream_opts, false) do
    mode =
      Keyword.get(run_stream_opts, :execution_mode) ||
        Keyword.get(session_stream_opts, :execution_mode) ||
        Keyword.get(app_cfg, :execution_mode, :local)

    if mode in @valid_execution_modes do
      {:ok, mode}
    else
      {:error,
       config_error(
         "invalid execution_mode #{inspect(mode)}; expected one of #{inspect(@valid_execution_modes)}"
       )}
    end
  end

  defp resolve_transport_call_timeout(
         app_cfg,
         session_stream_opts,
         run_stream_opts,
         merged_driver_opts
       ) do
    timeout_ms =
      Keyword.get(merged_driver_opts, :remote_transport_call_timeout_ms) ||
        Keyword.get(merged_driver_opts, :transport_call_timeout_ms) ||
        Keyword.get(run_stream_opts, :transport_call_timeout_ms) ||
        Keyword.get(session_stream_opts, :transport_call_timeout_ms) ||
        Keyword.get(app_cfg, :transport_call_timeout_ms, 5_000)

    case normalize_pos_integer(timeout_ms) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error,
         config_error(
           "transport_call_timeout_ms must be a positive integer, got: #{inspect(timeout_ms)}"
         )}
    end
  end

  defp resolve_remote_config(
         :local,
         _app_cfg,
         _session_stream_opts,
         _run_stream_opts,
         _driver_opts
       ),
       do: {:ok, nil}

  defp resolve_remote_config(
         :remote_node,
         app_cfg,
         session_stream_opts,
         run_stream_opts,
         driver_opts
       ) do
    remote_node =
      Keyword.get(driver_opts, :remote_node) ||
        Keyword.get(run_stream_opts, :remote_node) ||
        Keyword.get(session_stream_opts, :remote_node) ||
        Keyword.get(app_cfg, :remote_node)

    with {:ok, remote_node} <- validate_remote_node(remote_node),
         {:ok, remote_connect_timeout_ms} <-
           normalize_timeout(
             driver_opts,
             run_stream_opts,
             session_stream_opts,
             app_cfg,
             :remote_connect_timeout_ms,
             5_000
           ),
         {:ok, remote_rpc_timeout_ms} <-
           normalize_timeout(
             driver_opts,
             run_stream_opts,
             session_stream_opts,
             app_cfg,
             :remote_rpc_timeout_ms,
             15_000
           ),
         {:ok, remote_boot_lease_timeout_ms} <-
           normalize_timeout(
             driver_opts,
             run_stream_opts,
             session_stream_opts,
             app_cfg,
             :remote_boot_lease_timeout_ms,
             10_000
           ),
         {:ok, remote_bootstrap_mode} <-
           normalize_bootstrap_mode(
             Keyword.get(driver_opts, :remote_bootstrap_mode) ||
               Keyword.get(run_stream_opts, :remote_bootstrap_mode) ||
               Keyword.get(session_stream_opts, :remote_bootstrap_mode) ||
               Keyword.get(app_cfg, :remote_bootstrap_mode, :require_prestarted)
           ),
         {:ok, remote_cookie} <-
           normalize_remote_cookie(Keyword.get(driver_opts, :remote_cookie)),
         {:ok, remote_cwd} <- normalize_remote_cwd(Keyword.get(driver_opts, :remote_cwd)) do
      {:ok,
       %{
         remote_node: remote_node,
         remote_cookie: remote_cookie,
         remote_connect_timeout_ms: remote_connect_timeout_ms,
         remote_rpc_timeout_ms: remote_rpc_timeout_ms,
         remote_boot_lease_timeout_ms: remote_boot_lease_timeout_ms,
         remote_bootstrap_mode: remote_bootstrap_mode,
         remote_cwd: remote_cwd
       }}
    end
  end

  defp normalize_timeout(driver_opts, run_stream_opts, session_stream_opts, app_cfg, key, default) do
    value =
      Keyword.get(driver_opts, key) ||
        Keyword.get(run_stream_opts, key) ||
        Keyword.get(session_stream_opts, key) ||
        Keyword.get(app_cfg, key, default)

    case normalize_pos_integer(value) do
      {:ok, timeout} ->
        {:ok, timeout}

      :error ->
        {:error, config_error("#{key} must be a positive integer, got: #{inspect(value)}")}
    end
  end

  defp validate_remote_node(remote_node) when is_atom(remote_node) and not is_nil(remote_node),
    do: {:ok, remote_node}

  defp validate_remote_node(value) do
    {:error,
     config_error(
       "remote_node is required for :remote_node execution mode, got: #{inspect(value)}"
     )}
  end

  defp normalize_bootstrap_mode(mode) when mode in @valid_bootstrap_modes, do: {:ok, mode}

  defp normalize_bootstrap_mode(mode) do
    {:error,
     config_error(
       "remote_bootstrap_mode must be one of #{inspect(@valid_bootstrap_modes)}, got: #{inspect(mode)}"
     )}
  end

  defp normalize_remote_cookie(nil), do: {:ok, nil}
  defp normalize_remote_cookie(cookie) when is_atom(cookie), do: {:ok, cookie}

  defp normalize_remote_cookie(cookie) do
    {:error, config_error("remote_cookie must be an atom, got: #{inspect(cookie)}")}
  end

  defp normalize_remote_cwd(nil), do: {:ok, nil}
  defp normalize_remote_cwd(value) when is_binary(value) and value != "", do: {:ok, value}

  defp normalize_remote_cwd(value) do
    {:error, config_error("remote_cwd must be a non-empty string, got: #{inspect(value)}")}
  end

  defp normalize_pos_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp normalize_pos_integer(_value), do: :error

  defp normalize_keyword(value) when is_list(value), do: value
  defp normalize_keyword(_value), do: []

  defp app_config do
    defaults = [
      execution_mode: :local,
      remote_connect_timeout_ms: 5_000,
      remote_rpc_timeout_ms: 15_000,
      remote_boot_lease_timeout_ms: 10_000,
      remote_bootstrap_mode: :require_prestarted,
      transport_call_timeout_ms: 5_000
    ]

    Keyword.merge(defaults, Application.get_env(:agent_session_manager, __MODULE__, []))
  end

  defp config_error(message) do
    Error.new(:config_invalid, :config, message)
  end
end
