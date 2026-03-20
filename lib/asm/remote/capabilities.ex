defmodule ASM.Remote.Capabilities do
  @moduledoc """
  Remote node capability and compatibility handshake helpers.
  """

  @required_capabilities [
    :remote_backend_start_v1
  ]

  @type handshake_t :: %{
          required(:asm_version) => String.t(),
          required(:otp_release) => String.t(),
          required(:capabilities) => [atom()]
        }

  @spec handshake() :: handshake_t()
  def handshake do
    %{
      asm_version: current_asm_version(),
      otp_release: current_otp_release(),
      capabilities: @required_capabilities
    }
  end

  @spec required_capabilities() :: [atom()]
  def required_capabilities, do: @required_capabilities

  @spec version_compatible?(String.t(), String.t()) :: boolean()
  def version_compatible?(local_version, remote_version)
      when is_binary(local_version) and is_binary(remote_version) do
    with {:ok, {local_major, local_minor}} <- parse_major_minor(local_version),
         {:ok, {remote_major, remote_minor}} <- parse_major_minor(remote_version) do
      local_major == remote_major and local_minor == remote_minor
    else
      :error -> false
    end
  end

  @spec otp_major_compatible?(String.t(), String.t()) :: boolean()
  def otp_major_compatible?(local_release, remote_release)
      when is_binary(local_release) and is_binary(remote_release) do
    parse_otp_major(local_release) == parse_otp_major(remote_release)
  end

  @spec current_asm_version() :: String.t()
  def current_asm_version do
    case Application.spec(:agent_session_manager, :vsn) do
      nil -> "0.0.0"
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn -> to_string(vsn)
    end
  end

  @spec current_otp_release() :: String.t()
  def current_otp_release do
    :erlang.system_info(:otp_release)
    |> List.to_string()
  end

  defp parse_major_minor(version) do
    parts =
      version
      |> String.split(~r/[^0-9]+/, trim: true)
      |> Enum.take(2)

    case parts do
      [major, minor] ->
        with {major, ""} <- Integer.parse(major),
             {minor, ""} <- Integer.parse(minor) do
          {:ok, {major, minor}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_otp_major(release) when is_binary(release) do
    release
    |> String.trim()
    |> Integer.parse()
    |> case do
      {major, _rest} -> major
      :error -> nil
    end
  end
end
