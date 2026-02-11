# Model Configuration

AgentSessionManager centralizes all model identifiers, default models, and
per-token pricing in the `AgentSessionManager.Models` module. This guide
explains how to inspect, override, and extend these settings.

## Default Models

Each provider adapter has a default model that is used when no `:model` option
is passed to `start_link/1`:

| Provider | Default Model | Source |
|----------|---------------|--------|
| Claude   | `"claude-haiku-4-5-20251001"` | `Models.default_model(:claude)` |
| Codex    | `nil` (SDK selects its own) | `Models.default_model(:codex)` |
| AMP      | `nil` (SDK selects its own) | `Models.default_model(:amp)` |

### Querying the Default at Runtime

```elixir
AgentSessionManager.Models.default_model(:claude)
# => "claude-haiku-4-5-20251001"
```

### Overriding via Application Config

Add the following to your `config/config.exs` (or environment-specific config):

```elixir
config :agent_session_manager, AgentSessionManager.Models,
  claude_default_model: "claude-sonnet-4-5-20250929"
```

This override takes effect at runtime without recompilation.

### Overriding per Adapter Instance

Pass the `:model` option directly when starting an adapter:

```elixir
{:ok, adapter} = ClaudeAdapter.start_link(model: "claude-opus-4-6")
```

This always takes precedence over the default.

## Pricing Table

The `Models` module ships a built-in pricing table used by
`AgentSessionManager.Cost.CostCalculator` for cost estimation.

### Structure

The pricing table is a nested map keyed by provider name:

```elixir
%{
  "claude" => %{
    default: %{input: 0.000003, output: 0.000015},
    models: %{
      "claude-opus-4-6" => %{
        input: 0.000015,
        output: 0.000075,
        cache_read: 0.0000015,
        cache_creation: 0.00001875
      },
      "claude-sonnet-4-5" => %{...},
      "claude-haiku-4-5" => %{...}
    }
  },
  "codex" => %{
    default: %{input: 0.000003, output: 0.000015},
    models: %{
      "o3"        => %{input: 0.000010, output: 0.000040},
      "o3-mini"   => %{input: 0.0000011, output: 0.0000044},
      "gpt-4o"    => %{input: 0.0000025, output: 0.000010},
      "gpt-4o-mini" => %{input: 0.00000015, output: 0.0000006}
    }
  },
  "amp" => %{
    default: %{input: 0.000003, output: 0.000015},
    models: %{}
  }
}
```

All rates are in **USD per token**.

### Model Resolution

The cost calculator resolves rates in this order:

1. **Exact match** -- `"claude-opus-4-6"` matches the key directly.
2. **Prefix match** -- `"claude-sonnet-4-5-20250929"` matches the
   `"claude-sonnet-4-5"` prefix, allowing versioned model IDs to resolve
   without explicit entries for every date suffix.
3. **Provider default** -- if no model key matches, the provider's `default`
   rates are used.
4. **Error** -- if the provider is not in the table at all, `{:error, :no_rates}`
   is returned.

### Overriding the Pricing Table

Replace the entire table via application config:

```elixir
config :agent_session_manager, AgentSessionManager.Models,
  pricing_table: %{
    "claude" => %{
      default: %{input: 0.000003, output: 0.000015},
      models: %{
        "claude-opus-4-6" => %{input: 0.000020, output: 0.000080}
      }
    }
  }
```

Or pass a custom table directly to the cost calculator:

```elixir
CostCalculator.calculate(tokens, "claude", "claude-opus-4-6", my_pricing_table)
```

### Listing Known Models

```elixir
AgentSessionManager.Models.model_names()
# => ["claude-haiku-4-5", "claude-opus-4-6", "claude-sonnet-4-5",
#     "gpt-4o", "gpt-4o-mini", "o3", "o3-mini"]
```

## Reasoning Effort (Codex)

The Codex adapter extracts reasoning effort from CLI thread metadata at
runtime. There is no hardcoded default -- the effort level is determined by
the Codex CLI and reported in the `run_started` event:

```elixir
%{
  type: :run_started,
  data: %{
    confirmed_reasoning_effort: "medium",
    confirmation_source: "codex_cli.thread_started"
  }
}
```

Pass a reasoning effort when starting the Codex adapter:

```elixir
CodexAdapter.start_link(
  working_directory: "/my/project",
  sdk_opts: [reasoning_effort: :medium]
)
```

## Thinking Mode (AMP)

The AMP adapter accepts a `:thinking` option that defaults to `false`:

```elixir
AmpAdapter.start_link(thinking: true)
```

## Updating Models and Prices

When provider APIs introduce new models or change pricing:

1. Edit `lib/agent_session_manager/models.ex` -- update `@claude_default_model`,
   add model entries to `@default_pricing_table`, etc.
2. Run `mix test` -- all tests reference the central `Models` module (or
   `AgentSessionManager.Test.Models` for test fixtures), so a single change
   propagates everywhere.
3. If you add a brand-new provider, add a `default_model/1` clause and a new
   provider entry in the pricing table.

## Test Fixtures

Test code uses `AgentSessionManager.Test.Models` (defined in
`test/support/test_models.ex`) to centralize test fixture model strings:

```elixir
AgentSessionManager.Test.Models.claude_model()        # => "claude-haiku-4-5-20251001"
AgentSessionManager.Test.Models.claude_sonnet_model()  # => "claude-sonnet-4-5-20250929"
AgentSessionManager.Test.Models.claude_opus_model()    # => "claude-opus-4-6"
AgentSessionManager.Test.Models.codex_model()          # => "gpt-5.3-codex"
AgentSessionManager.Test.Models.reasoning_effort_high()    # => "xhigh"
AgentSessionManager.Test.Models.reasoning_effort_medium()  # => :medium
```

Changing a model name in `Test.Models` updates every test that references it.
