defmodule ASM.Provider do
  @moduledoc """
  Provider definition data and resolver entrypoint.
  """

  alias ASM.Error
  alias ASM.Provider.Claude
  alias ASM.Provider.CodexExec
  alias ASM.Provider.Gemini
  alias ASM.Provider.Profile

  @enforce_keys [
    :name,
    :display_name,
    :binary_names,
    :env_var,
    :parser,
    :command_builder,
    :profile
  ]
  defstruct [
    :name,
    :display_name,
    :binary_names,
    :env_var,
    :install_command,
    :min_version,
    :parser,
    :command_builder,
    :profile,
    options_schema: [],
    supports_streaming: true,
    supports_control: false,
    supports_resume: false,
    supports_thinking: false,
    supports_tools: false,
    npm_package: nil,
    npx_package: nil,
    disable_npx_env: nil,
    metadata: %{}
  ]

  @type provider_name :: :claude | :codex | :codex_exec | :gemini | atom()

  @type t :: %__MODULE__{
          name: provider_name(),
          display_name: String.t(),
          binary_names: [String.t()],
          env_var: String.t() | nil,
          install_command: String.t() | nil,
          min_version: String.t() | nil,
          parser: module(),
          command_builder: module(),
          profile: Profile.t(),
          options_schema: keyword(),
          supports_streaming: boolean(),
          supports_control: boolean(),
          supports_resume: boolean(),
          supports_thinking: boolean(),
          supports_tools: boolean(),
          npm_package: String.t() | nil,
          npx_package: String.t() | nil,
          disable_npx_env: String.t() | nil,
          metadata: map()
        }

  @callback provider() :: t()

  @spec resolve(t() | provider_name()) :: {:ok, t()} | {:error, Error.t()}
  def resolve(%__MODULE__{} = provider), do: {:ok, provider}

  def resolve(:claude), do: {:ok, Claude.provider()}
  def resolve(:codex), do: {:ok, CodexExec.provider()}
  def resolve(:codex_exec), do: {:ok, CodexExec.provider()}
  def resolve(:gemini), do: {:ok, Gemini.provider()}

  def resolve(name) when is_atom(name),
    do:
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "Unknown provider: #{inspect(name)}",
         cause: %{provider: name}
       )}

  def resolve(other) do
    {:error,
     Error.new(
       :config_invalid,
       :config,
       "Provider must be an atom or %ASM.Provider{}, got: #{inspect(other)}",
       cause: %{provider: other}
     )}
  end

  @spec resolve!(t() | provider_name()) :: t()
  def resolve!(provider_or_name) do
    case resolve(provider_or_name) do
      {:ok, provider} ->
        provider

      {:error, %Error{} = error} ->
        raise ArgumentError, Exception.message(error)
    end
  end
end
