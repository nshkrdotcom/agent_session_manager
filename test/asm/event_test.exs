defmodule ASM.EventTest do
  use ExUnit.Case, async: true

  alias ASM.Event

  test "generate_id/0 returns 26-char crockford base32 id" do
    id = Event.generate_id()

    assert String.length(id) == 26
    assert id =~ ~r/^[0-9A-HJKMNP-TV-Z]{26}$/
  end

  test "generate_id_at/1 returns different ids for same timestamp" do
    timestamp = 1_700_000_000_000
    id1 = Event.generate_id_at(timestamp)
    id2 = Event.generate_id_at(timestamp)

    assert id1 != id2
  end

  test "generate_id_at/1 validates input" do
    assert_raise ArgumentError, fn -> Event.generate_id_at(-1) end
    assert_raise ArgumentError, fn -> Event.generate_id_at("bad") end
  end
end
