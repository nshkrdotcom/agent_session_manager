defmodule AgentSessionManager.Core.ProviderErrorTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.ProviderError

  describe "normalize/3" do
    test "returns stable provider_error contract without speculative keys" do
      {provider_error, details} =
        ProviderError.normalize(:codex, %{
          kind: "transport_exit",
          message: "codex executable exited with status 2",
          details: %{
            exit_status: 2,
            stderr: "permission denied",
            stderr_truncated?: true,
            original_kind: "transport_exit"
          }
        })

      assert Enum.sort(Map.keys(provider_error)) == [
               :exit_code,
               :kind,
               :message,
               :provider,
               :stderr,
               :truncated?
             ]

      assert provider_error.provider == :codex
      assert provider_error.kind == :transport_exit
      assert provider_error.exit_code == 2
      assert provider_error.stderr == "permission denied"
      assert provider_error.truncated? == true
      assert details == %{original_kind: "transport_exit"}
    end

    test "truncates stderr by byte and line limits" do
      stderr = Enum.map_join(1..6, "\n", &"line#{&1}")

      {provider_error, _details} =
        ProviderError.normalize(
          :amp,
          %{
            details: %{
              kind: "transport_exit",
              stderr: stderr
            }
          },
          max_bytes: 11,
          max_lines: 3
        )

      assert provider_error.provider == :amp
      assert provider_error.kind == :transport_exit
      assert provider_error.stderr == "line1\nline2"
      assert provider_error.truncated? == true
    end
  end
end
