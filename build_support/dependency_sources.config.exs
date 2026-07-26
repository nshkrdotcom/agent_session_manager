%{
  deps: %{
    cli_subprocess_core: %{
      path: "../cli_subprocess_core",
      github: %{repo: "nshkrdotcom/cli_subprocess_core", branch: "main"},
      hex: "~> 0.3.0",
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    },
    cursor_cli_sdk: %{
      path: "../cursor_cli_sdk",
      github: %{repo: "nshkrdotcom/cursor_cli_sdk", branch: "main"},
      hex: "~> 0.2.0",
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    }
  }
}
