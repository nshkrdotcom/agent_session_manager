defmodule AgentSessionManager.PubSub.TopicTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.PubSub.Topic

  describe "build_session_topic/2" do
    test "builds topic with default prefix" do
      assert Topic.build_session_topic("ses_abc") == "asm:session:ses_abc"
    end

    test "builds topic with custom prefix" do
      assert Topic.build_session_topic("myapp", "ses_abc") == "myapp:session:ses_abc"
    end
  end

  describe "build_run_topic/3" do
    test "builds topic with default prefix" do
      assert Topic.build_run_topic("ses_abc", "run_def") ==
               "asm:session:ses_abc:run:run_def"
    end

    test "builds topic with custom prefix" do
      assert Topic.build_run_topic("myapp", "ses_abc", "run_def") ==
               "myapp:session:ses_abc:run:run_def"
    end
  end

  describe "build_type_topic/3" do
    test "builds topic with atom type" do
      assert Topic.build_type_topic("ses_abc", :tool_call_started) ==
               "asm:session:ses_abc:type:tool_call_started"
    end

    test "builds topic with string type" do
      assert Topic.build_type_topic("ses_abc", "custom_type") ==
               "asm:session:ses_abc:type:custom_type"
    end

    test "builds topic with custom prefix" do
      assert Topic.build_type_topic("myapp", "ses_abc", :run_completed) ==
               "myapp:session:ses_abc:type:run_completed"
    end
  end

  describe "build/2" do
    test "defaults to session scope" do
      event = %{session_id: "ses_abc", run_id: "run_def", type: :message_streamed}
      assert Topic.build(event) == "asm:session:ses_abc"
    end

    test "builds session-scoped topic" do
      event = %{session_id: "ses_abc", run_id: "run_def"}
      assert Topic.build(event, scope: :session) == "asm:session:ses_abc"
    end

    test "builds run-scoped topic" do
      event = %{session_id: "ses_abc", run_id: "run_def"}
      assert Topic.build(event, scope: :run) == "asm:session:ses_abc:run:run_def"
    end

    test "builds type-scoped topic" do
      event = %{session_id: "ses_abc", run_id: "run_def", type: :tool_call_started}
      assert Topic.build(event, scope: :type) == "asm:session:ses_abc:type:tool_call_started"
    end

    test "respects custom prefix" do
      event = %{session_id: "ses_abc", run_id: "run_def"}
      assert Topic.build(event, prefix: "myapp", scope: :session) == "myapp:session:ses_abc"
    end
  end
end
