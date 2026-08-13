defmodule CtfServer.CompletionMessageTest do
  use CtfServer.DataCase, async: true

  import CtfServer.AccountsFixtures

  alias CtfServer.CompletionMessage
  alias CtfServer.Challenges.BasicNix1

  test "a challenge without an impl falls back to nil (no extra message)" do
    team = team_fixture()
    # BasicNix1 does not implement CompletionMessage — the Any fallback applies.
    assert CompletionMessage.message(struct!(BasicNix1), team, 100) == nil
  end
end
