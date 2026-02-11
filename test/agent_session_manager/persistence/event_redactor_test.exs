defmodule AgentSessionManager.Persistence.EventRedactorTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.Event
  alias AgentSessionManager.Persistence.EventRedactor

  import AgentSessionManager.Test.Fixtures

  @pattern_cases [
    {:aws_access_key, "key is AKIAIOSFODNN7EXAMPLE here", "AKIAIOSFODNN7EXAMPLE",
     :tool_call_completed, :tool_output},
    {:aws_secret_key, "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
     "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", :tool_call_completed, :tool_output},
    {:gcp_api_key, "AIzaSyA1234567890abcdefghijklmnopqrstuvw",
     "AIzaSyA1234567890abcdefghijklmnopqrstuvw", :tool_call_completed, :tool_output},
    {:anthropic_key, "sk-ant-api03-abcdefghijklmnopqrstuvwx",
     "sk-ant-api03-abcdefghijklmnopqrstuvwx", :tool_call_completed, :tool_output},
    {:openai_key, "sk-proj-abcdefghijklmnopqrstuvwx", "sk-proj-abcdefghijklmnopqrstuvwx",
     :tool_call_completed, :tool_output},
    {:openai_legacy_key, "sk-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN1234",
     "sk-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN1234", :tool_call_completed, :tool_output},
    {:github_pat, "ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkL",
     "ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkL", :message_received, :content},
    {:github_oauth, "gho_aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkL",
     "gho_aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkL", :message_received, :content},
    {:github_app, "ghs_aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkL",
     "ghs_aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkL", :message_received, :content},
    {:github_refresh, "ghr_aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkL",
     "ghr_aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkL", :message_received, :content},
    {:github_fine_pat, "github_pat_11ABCDEFGHIJKLMNOPQRST_uvwxyz",
     "github_pat_11ABCDEFGHIJKLMNOPQRST_uvwxyz", :message_received, :content},
    {:gitlab_token, "glpat-abcdefghijklmnopqrst", "glpat-abcdefghijklmnopqrst", :message_received,
     :content},
    {:jwt_token,
     "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
     "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9", :tool_call_completed, :tool_output},
    {:bearer_token, "Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456",
     "Bearer abcdefghijklmnopqrstuvwxyz123456", :tool_call_completed, :tool_output},
    {:password, "PASSWORD: supersecret123", "supersecret123", :message_received, :content},
    {:api_key_generic, "api_key=sk12345678901234567890", "sk12345678901234567890",
     :tool_call_completed, :tool_output},
    {:secret_key, "secret_key = my_super_secret_value", "my_super_secret_value",
     :tool_call_completed, :tool_output},
    {:access_token, "access_token = my_access_token_value_123", "my_access_token_value_123",
     :tool_call_completed, :tool_output},
    {:auth_token, "auth_token = my_auth_token_value_456", "my_auth_token_value_456",
     :tool_call_completed, :tool_output},
    {:connection_string, "postgres://user:pass@localhost:5432/mydb",
     "postgres://user:pass@localhost:5432/mydb", :tool_call_completed, :tool_output},
    {:private_key, "-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN RSA PRIVATE KEY-----",
     :tool_call_completed, :tool_output},
    {:env_secret, "DATABASE_URL=postgres://user:pass@host/db",
     "DATABASE_URL=postgres://user:pass@host/db", :tool_call_completed, :tool_output}
  ]

  describe "default_patterns/0" do
    test "returns non-empty {atom, Regex.t()} tuples" do
      patterns = EventRedactor.default_patterns()

      assert is_list(patterns)
      assert match?([_ | _], patterns)

      assert Enum.all?(patterns, fn
               {category, %Regex{}} when is_atom(category) -> true
               _ -> false
             end)
    end
  end

  describe "redact/2 - pattern coverage" do
    for {category, sample, fragment, type, field} <- @pattern_cases do
      test "#{category} is redacted" do
        event = event_for_secret(unquote(type), unquote(field), unquote(sample))
        result = EventRedactor.redact(event, %{enabled: true})

        assert %Event{} = result.event
        refute inspect(result.event.data) =~ unquote(fragment)
        assert inspect(result.event.data) =~ "[REDACTED]"
        assert result.redaction_count > 0
      end
    end

    test "connection strings include redis variants" do
      event =
        event_for_secret(
          :tool_call_completed,
          :tool_output,
          "redis://admin:password@redis.example.com:6379"
        )

      result = EventRedactor.redact(event, %{enabled: true})
      refute inspect(result.event.data) =~ "redis://admin:password@redis.example.com:6379"
      assert result.redaction_count > 0
    end
  end

  describe "redact/2 - deep traversal" do
    test "redacts nested maps" do
      bearer = "Bearer abcdefghijklmnopqrstuvwxyz123456"

      event =
        build_event(
          type: :tool_call_started,
          data: %{
            tool_name: "http",
            tool_input: %{headers: %{"Authorization" => bearer}}
          }
        )

      result = EventRedactor.redact(event, %{enabled: true})

      refute inspect(result.event.data.tool_input) =~ bearer
      assert result.redaction_count > 0
    end

    test "redacts lists of content blocks" do
      event =
        build_event(
          type: :tool_call_completed,
          data: %{
            tool_name: "parser",
            messages: [%{content: "password=secret"}, %{content: "safe text"}]
          }
        )

      result = EventRedactor.redact(event, %{enabled: true})

      refute inspect(result.event.data.messages) =~ "password=secret"
      assert inspect(result.event.data.messages) =~ "safe text"
      assert result.redaction_count > 0
    end

    test "scans only string values in mixed structures" do
      event =
        build_event(
          type: :tool_call_completed,
          data: %{
            tool_name: "mixed",
            tool_output: "password=secret123",
            retries: 2,
            done: true,
            state: :ok,
            extra: nil
          }
        )

      result = EventRedactor.redact(event, %{enabled: true})

      assert result.event.data.retries == 2
      assert result.event.data.done
      assert result.event.data.state == :ok
      assert result.event.data.extra == nil
      refute result.event.data.tool_output =~ "secret123"
      assert result.redaction_count > 0
    end

    test "enforces max traversal depth" do
      event =
        build_event(
          type: :tool_call_completed,
          data: %{
            tool_name: "depth-test",
            tool_output:
              nested_secret_map(15, %{5 => "AKIAIOSFODNN7EXAMPLE", 12 => "password=hunter2"})
          }
        )

      result = EventRedactor.redact(event, %{enabled: true})

      assert get_in(result.event.data.tool_output, level_path(5) ++ [:secret]) =~ "[REDACTED]"

      assert get_in(result.event.data.tool_output, level_path(12) ++ [:secret]) ==
               "password=hunter2"
    end
  end

  describe "redact/2 - non-redaction" do
    test "passes through non-sensitive data unchanged" do
      event =
        build_event(
          type: :tool_call_completed,
          data: %{tool_name: "bash", tool_output: "normal output"}
        )

      result = EventRedactor.redact(event, %{enabled: true})
      assert result.event.data == event.data
      assert result.redaction_count == 0
      assert result.fields_redacted == []
    end

    test "never modifies integer/atom/boolean/nil values" do
      event =
        build_event(
          type: :run_started,
          data: %{tries: 1, state: :ok, ready: false, note: nil}
        )

      result = EventRedactor.redact(event, %{enabled: true})
      assert result.event.data == event.data
    end

    test "returns unchanged event for empty data maps" do
      event = build_event(type: :run_started, data: %{})
      result = EventRedactor.redact(event, %{enabled: true})
      assert result.event.data == %{}
      assert result.redaction_count == 0
    end

    test "skips exempt event types even when enabled" do
      for type <- [:session_created, :token_usage_updated] do
        event = build_event(type: type, data: %{value: "AKIAIOSFODNN7EXAMPLE"})
        result = EventRedactor.redact(event, %{enabled: true})

        assert result.event.data.value == "AKIAIOSFODNN7EXAMPLE"
        assert result.redaction_count == 0
        assert result.fields_redacted == []
      end
    end
  end

  describe "redact/2 - configuration" do
    test "disabled redaction returns event unchanged" do
      event = event_for_secret(:tool_call_completed, :tool_output, "password=secret123")
      result = EventRedactor.redact(event, %{enabled: false})
      assert result.event == event
      assert result.redaction_count == 0
      assert result.fields_redacted == []
    end

    test "custom replacement string is applied" do
      event = event_for_secret(:tool_call_completed, :tool_output, "password=secret123")
      result = EventRedactor.redact(event, %{enabled: true, replacement: "***"})
      assert result.event.data.tool_output == "***"
    end

    test "categorized replacement includes category labels" do
      event = event_for_secret(:tool_call_completed, :tool_output, "AKIAIOSFODNN7EXAMPLE")
      result = EventRedactor.redact(event, %{enabled: true, replacement: :categorized})

      assert result.event.data.tool_output =~ "[REDACTED:aws_access_key]"
      assert result.redaction_count > 0
    end

    test "custom patterns are appended to defaults" do
      event =
        event_for_secret(
          :tool_call_completed,
          :tool_output,
          "AKIAIOSFODNN7EXAMPLE and CUSTOM_SECRET_TOKEN_123"
        )

      result =
        EventRedactor.redact(event, %{
          enabled: true,
          patterns: [{:custom, ~r/CUSTOM_SECRET_\w+/}]
        })

      refute result.event.data.tool_output =~ "AKIAIOSFODNN7EXAMPLE"
      refute result.event.data.tool_output =~ "CUSTOM_SECRET_TOKEN_123"
      assert result.redaction_count >= 2
    end

    test "{:replace, patterns} overrides defaults entirely" do
      event =
        event_for_secret(
          :tool_call_completed,
          :tool_output,
          "ONLY_SECRET_VALUE and AKIAIOSFODNN7EXAMPLE"
        )

      result =
        EventRedactor.redact(event, %{
          enabled: true,
          patterns: {:replace, [{:only, ~r/ONLY_SECRET_\w+/}]},
          replacement: "***"
        })

      assert result.event.data.tool_output =~ "***"
      assert result.event.data.tool_output =~ "AKIAIOSFODNN7EXAMPLE"
      assert result.redaction_count == 1
    end

    test "deep_scan false scans only known fields for event type" do
      event =
        build_event(
          type: :message_received,
          data: %{
            content: "password=secret123",
            role: "assistant",
            extra: "api_key=not_redacted_with_deep_scan_false"
          }
        )

      result = EventRedactor.redact(event, %{enabled: true, deep_scan: false})

      refute result.event.data.content =~ "secret123"
      assert result.event.data.extra == "api_key=not_redacted_with_deep_scan_false"
    end

    test "scan_metadata true scans metadata in addition to data" do
      event =
        build_event(
          type: :tool_call_completed,
          data: %{tool_name: "bash", tool_output: "safe"},
          metadata: %{headers: "Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456"}
        )

      result = EventRedactor.redact(event, %{enabled: true, scan_metadata: true})

      refute inspect(result.event.metadata) =~ "Bearer abcdefghijklmnopqrstuvwxyz123456"
      assert result.redaction_count > 0
    end
  end

  describe "redact/2 - edge cases" do
    test "redacts multiple secrets in one field" do
      event =
        event_for_secret(
          :tool_call_completed,
          :tool_output,
          "key=AKIAIOSFODNN7EXAMPLE and password=hunter2"
        )

      result = EventRedactor.redact(event, %{enabled: true})

      refute result.event.data.tool_output =~ "AKIAIOSFODNN7EXAMPLE"
      refute result.event.data.tool_output =~ "hunter2"
      assert result.redaction_count >= 2
    end

    test "handles very large strings" do
      large = String.duplicate("normal text ", 10_000)
      event = event_for_secret(:tool_call_completed, :tool_output, large)
      result = EventRedactor.redact(event, %{enabled: true})

      assert result.event.data.tool_output == large
      assert result.redaction_count == 0
    end

    test "redacts secrets in unicode strings" do
      event = event_for_secret(:message_received, :content, "Votre cle: AKIAIOSFODNN7EXAMPLE")
      result = EventRedactor.redact(event, %{enabled: true})

      refute result.event.data.content =~ "AKIAIOSFODNN7EXAMPLE"
      assert result.redaction_count > 0
    end

    test "does not redact strings that are too short for pattern requirements" do
      event = event_for_secret(:message_received, :content, "ghp_short")
      result = EventRedactor.redact(event, %{enabled: true})

      assert result.event.data.content == "ghp_short"
      assert result.redaction_count == 0
    end

    test "handles nil values in data fields safely" do
      event =
        build_event(
          type: :tool_call_completed,
          data: %{tool_name: "bash", tool_output: nil}
        )

      result = EventRedactor.redact(event, %{enabled: true})

      assert result.event.data.tool_output == nil
      assert result.redaction_count == 0
    end
  end

  describe "redact_map/2" do
    test "redacts a plain map and returns a plain map" do
      raw = %{data: %{content: "password=secret123"}}
      redacted = EventRedactor.redact_map(raw, %{enabled: true})

      assert is_map(redacted)
      refute redacted.data.content =~ "secret123"
    end

    test "applies the same patterns as redact/2" do
      raw = %{data: %{content: "AKIAIOSFODNN7EXAMPLE"}}
      redacted = EventRedactor.redact_map(raw, %{enabled: true})
      refute redacted.data.content =~ "AKIAIOSFODNN7EXAMPLE"
    end

    test "returns just the map, not a result struct" do
      raw = %{data: %{content: "password=secret123"}}
      redacted = EventRedactor.redact_map(raw, %{enabled: true})
      refute Map.has_key?(redacted, :event)
      refute Map.has_key?(redacted, :redaction_count)
    end

    test "returns unchanged map when disabled" do
      raw = %{data: %{content: "password=secret123"}}
      assert EventRedactor.redact_map(raw, %{enabled: false}) == raw
    end

    test "supports custom patterns" do
      raw = %{data: %{content: "MYCO_TOKEN_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"}}

      redacted =
        EventRedactor.redact_map(raw, %{
          enabled: true,
          patterns: [{:internal_token, ~r/MYCO_TOKEN_[A-Z0-9]{32}/}]
        })

      refute redacted.data.content =~ "MYCO_TOKEN_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
    end
  end

  describe "redact/2 - result struct" do
    test "redaction_count tracks individual matches" do
      event =
        build_event(
          type: :tool_call_completed,
          data: %{
            tool_name: "bash",
            tool_output:
              "AKIAIOSFODNN7EXAMPLE password=hunter2 Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456"
          }
        )

      result = EventRedactor.redact(event, %{enabled: true})
      assert result.redaction_count == 3
    end

    test "fields_redacted tracks top-level keys that changed" do
      event =
        build_event(
          type: :tool_call_completed,
          data: %{
            tool_name: "bash",
            tool_output: "AKIAIOSFODNN7EXAMPLE",
            tool_input: %{command: "echo password=hunter2"}
          }
        )

      result = EventRedactor.redact(event, %{enabled: true})
      assert Enum.sort(result.fields_redacted) == [:tool_input, :tool_output]
    end

    test "no matches produce zero count and empty fields list" do
      event =
        build_event(
          type: :tool_call_completed,
          data: %{tool_name: "bash", tool_output: "safe output"}
        )

      result = EventRedactor.redact(event, %{enabled: true})
      assert result.redaction_count == 0
      assert result.fields_redacted == []
    end
  end

  defp event_for_secret(type, field, secret_value) do
    base_data =
      case type do
        :message_received ->
          %{content: "safe", role: "assistant"}

        :message_sent ->
          %{content: "safe", role: "user"}

        :tool_call_started ->
          %{tool_name: "bash", tool_input: %{command: "env"}}

        :tool_call_completed ->
          %{tool_name: "bash", tool_output: "safe", tool_input: %{command: "env"}}

        :error_occurred ->
          %{error_message: "safe"}

        _ ->
          %{}
      end

    build_event(type: type, data: Map.put(base_data, field, secret_value))
  end

  defp nested_secret_map(max_level, secrets) do
    Enum.reduce(max_level..1//-1, %{}, fn level, acc ->
      level_map =
        case Map.fetch(secrets, level) do
          {:ok, secret} -> Map.put(acc, :secret, secret)
          :error -> acc
        end

      %{:"level_#{level}" => level_map}
    end)
  end

  defp level_path(level) when is_integer(level) and level >= 1 do
    Enum.map(1..level, &String.to_atom("level_#{&1}"))
  end
end
