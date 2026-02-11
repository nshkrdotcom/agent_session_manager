defmodule SecretsRedaction do
  @moduledoc false

  # Demonstrates secrets redaction in the EventPipeline.
  #
  # This example:
  # 1. Enables redaction with categorized replacement
  # 2. Processes events containing various secret patterns through EventBuilder
  # 3. Shows redacted output vs original input
  # 4. Demonstrates the redact_map/2 public API for callback wrapping

  alias AgentSessionManager.Core.Event
  alias AgentSessionManager.Persistence.{EventBuilder, EventRedactor}

  @test_secrets [
    {"AWS Access Key", "Found credentials: AKIAIOSFODNN7EXAMPLE in config"},
    {"Anthropic API Key", "Using key sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890"},
    {"GitHub PAT", "Git token: ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkL"},
    {"Password", "DATABASE_PASSWORD=super_secret_password_123"},
    {"Connection String", "postgres://admin:s3cret@db.example.com:5432/production"},
    {"Private Key", "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA..."},
    {"Bearer Token",
     "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"},
    {"JWT Token",
     "Token: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"},
    {"No Secret", "This is perfectly safe text with no secrets at all"}
  ]

  def main(_args) do
    IO.puts("")
    IO.puts("=== Secrets Redaction Demo ===")
    IO.puts("")

    demo_event_builder_redaction()
    IO.puts("")
    demo_redact_map_api()
    IO.puts("")
    demo_custom_patterns()
    IO.puts("")

    IO.puts("Done.")
  end

  defp demo_event_builder_redaction do
    IO.puts("--- EventBuilder Pipeline Redaction (categorized) ---")
    IO.puts("")

    context = %{
      session_id: "ses_redaction_demo",
      run_id: "run_redaction_demo",
      provider: "demo",
      redaction: %{enabled: true, replacement: :categorized}
    }

    Enum.each(@test_secrets, fn {label, secret_text} ->
      raw = %{
        type: :tool_call_completed,
        data: %{
          tool_name: "bash",
          tool_output: secret_text,
          tool_input: %{command: "echo test"}
        }
      }

      case EventBuilder.process(raw, context) do
        {:ok, event} ->
          IO.puts("  #{label}:")
          IO.puts("    Input:  #{secret_text}")
          IO.puts("    Output: #{event.data.tool_output}")
          IO.puts("")

        {:error, error} ->
          IO.puts("  #{label}: ERROR - #{inspect(error)}")
      end
    end)
  end

  defp demo_redact_map_api do
    IO.puts("--- Public redact_map/2 API (for callback wrapping) ---")
    IO.puts("")

    raw_event = %{
      type: :tool_call_completed,
      data: %{
        tool_output: "API_KEY=sk-ant-api03-secretvalue1234567890abcdef and password=hunter2"
      }
    }

    redacted = EventRedactor.redact_map(raw_event, %{enabled: true, replacement: :categorized})

    IO.puts("  Original: #{inspect(raw_event.data.tool_output)}")
    IO.puts("  Redacted: #{inspect(redacted.data.tool_output)}")
    IO.puts("")

    IO.puts("  Usage pattern for event callbacks:")
    IO.puts("    event_callback = fn event_data ->")
    IO.puts("      EventRedactor.redact_map(event_data, %{enabled: true})")
    IO.puts("      |> MyApp.handle()")
    IO.puts("    end")
  end

  defp demo_custom_patterns do
    IO.puts("--- Custom Pattern Support ---")
    IO.puts("")

    custom_config = %{
      enabled: true,
      patterns: [{:internal_token, ~r/MYCO_TOKEN_[A-Z0-9]{32}/}],
      replacement: :categorized
    }

    event = build_demo_event("Found MYCO_TOKEN_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 in config")

    result = EventRedactor.redact(event, custom_config)

    IO.puts("  Custom pattern (appended to defaults):")
    IO.puts("    Input:  Found MYCO_TOKEN_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 in config")
    IO.puts("    Output: #{result.event.data.tool_output}")
    IO.puts("    Redaction count: #{result.redaction_count}")
    IO.puts("    Fields modified: #{inspect(result.fields_redacted)}")
    IO.puts("")

    replace_config = %{
      enabled: true,
      patterns: {:replace, [{:only_this, ~r/ONLY_SECRET_\w+/}]},
      replacement: "***"
    }

    event2 = build_demo_event("ONLY_SECRET_VALUE and AKIAIOSFODNN7EXAMPLE")
    result2 = EventRedactor.redact(event2, replace_config)

    IO.puts("  Replace mode (only custom, no defaults):")
    IO.puts("    Input:  ONLY_SECRET_VALUE and AKIAIOSFODNN7EXAMPLE")
    IO.puts("    Output: #{result2.event.data.tool_output}")
    IO.puts("    (Note: AWS key is NOT redacted because defaults were replaced)")
  end

  defp build_demo_event(tool_output) do
    {:ok, event} =
      Event.new(%{
        type: :tool_call_completed,
        session_id: "ses_demo",
        run_id: "run_demo",
        data: %{
          tool_name: "bash",
          tool_output: tool_output,
          tool_input: %{command: "test"}
        }
      })

    event
  end
end

SecretsRedaction.main(System.argv())
