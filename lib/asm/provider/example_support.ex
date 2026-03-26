defmodule ASM.Provider.ExampleSupport do
  @moduledoc false

  @enforce_keys [
    :cli_command,
    :cli_path_env,
    :install_hint,
    :model_env,
    :sdk_app,
    :sdk_repo_dir,
    :sdk_root_env
  ]
  defstruct [
    :cli_command,
    :cli_path_env,
    :install_hint,
    :model_env,
    :sdk_app,
    :sdk_repo_dir,
    :sdk_root_env,
    sdk_cli_env: nil
  ]

  @type t :: %__MODULE__{
          cli_command: String.t(),
          cli_path_env: String.t(),
          install_hint: String.t(),
          model_env: String.t(),
          sdk_app: atom(),
          sdk_repo_dir: String.t(),
          sdk_root_env: String.t(),
          sdk_cli_env: String.t() | nil
        }
end
