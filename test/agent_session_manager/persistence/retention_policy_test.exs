defmodule AgentSessionManager.Persistence.RetentionPolicyTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Persistence.RetentionPolicy

  describe "new/1" do
    test "creates policy with defaults" do
      policy = RetentionPolicy.new()
      assert policy.max_session_age_days == :infinity
      assert policy.max_completed_session_age_days == 90
      assert policy.hard_delete_after_days == 30
      assert policy.max_events_per_session == :infinity
      assert policy.batch_size == 100
      assert policy.exempt_statuses == [:active, :paused]
      assert policy.exempt_tags == ["pinned"]
      assert policy.prune_event_types_first == [:message_streamed, :token_usage_updated]
    end

    test "accepts custom values" do
      policy =
        RetentionPolicy.new(
          max_completed_session_age_days: 30,
          max_events_per_session: 5000,
          batch_size: 50
        )

      assert policy.max_completed_session_age_days == 30
      assert policy.max_events_per_session == 5000
      assert policy.batch_size == 50
    end
  end

  describe "validate/1" do
    test "passes for default policy" do
      assert :ok = RetentionPolicy.validate(RetentionPolicy.new())
    end

    test "passes for all-infinity policy" do
      policy =
        RetentionPolicy.new(
          max_session_age_days: :infinity,
          max_completed_session_age_days: :infinity,
          max_events_per_session: :infinity,
          hard_delete_after_days: :infinity
        )

      assert :ok = RetentionPolicy.validate(policy)
    end

    test "rejects invalid max_session_age_days" do
      policy = RetentionPolicy.new(max_session_age_days: -1)
      assert {:error, msg} = RetentionPolicy.validate(policy)
      assert msg =~ "max_session_age_days"
    end

    test "rejects invalid max_completed_session_age_days" do
      policy = RetentionPolicy.new(max_completed_session_age_days: 0)
      assert {:error, msg} = RetentionPolicy.validate(policy)
      assert msg =~ "max_completed_session_age_days"
    end

    test "rejects invalid batch_size" do
      policy = RetentionPolicy.new(batch_size: 0)
      assert {:error, msg} = RetentionPolicy.validate(policy)
      assert msg =~ "batch_size"
    end

    test "rejects archive_before_prune without archive_store" do
      policy = RetentionPolicy.new(archive_before_prune: true, archive_store: nil)
      assert {:error, msg} = RetentionPolicy.validate(policy)
      assert msg =~ "archive_store"
    end

    test "passes archive_before_prune with archive_store" do
      policy = RetentionPolicy.new(archive_before_prune: true, archive_store: :some_store)
      assert :ok = RetentionPolicy.validate(policy)
    end
  end
end
