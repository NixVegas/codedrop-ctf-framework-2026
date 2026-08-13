defmodule CtfServer.CompetitionTest do
  use CtfServer.DataCase, async: true

  alias CtfServer.Competition

  defp at(iso), do: elem(DateTime.from_iso8601(iso), 1)

  describe "phase/2 (pure)" do
    test "nil bounds are always during" do
      c = %Competition{starts_at: nil, ends_at: nil}
      assert Competition.phase(c, at("2026-08-06T12:00:00Z")) == :during
    end

    test "before start" do
      c = %Competition{starts_at: at("2026-08-06T11:00:00Z"), ends_at: at("2026-08-09T20:00:00Z")}
      assert Competition.phase(c, at("2026-08-06T10:59:00Z")) == :before
    end

    test "during window" do
      c = %Competition{starts_at: at("2026-08-06T11:00:00Z"), ends_at: at("2026-08-09T20:00:00Z")}
      assert Competition.phase(c, at("2026-08-07T00:00:00Z")) == :during
    end

    test "at/after end" do
      c = %Competition{starts_at: at("2026-08-06T11:00:00Z"), ends_at: at("2026-08-09T20:00:00Z")}
      assert Competition.phase(c, at("2026-08-09T20:00:00Z")) == :after
    end
  end

  describe "open helpers (DB singleton)" do
    test "default seeded window is open" do
      assert Competition.current_phase() == :during
      assert Competition.challenges_open?()
      assert Competition.scoreboard_visible?()
      assert Competition.registration_open?()
    end

    test "after end: scoreboard visible, challenges and registration closed" do
      {:ok, _} =
        Competition.update(Competition.get(), %{
          starts_at: at("2020-01-01T00:00:00Z"),
          ends_at: at("2020-01-02T00:00:00Z")
        })

      refute Competition.challenges_open?()
      refute Competition.registration_open?()
      assert Competition.scoreboard_visible?()
    end
  end

  test "next_boundary/2 returns the next crossing" do
    c = %Competition{starts_at: at("2026-08-06T11:00:00Z"), ends_at: at("2026-08-09T20:00:00Z")}
    assert Competition.next_boundary(c, at("2026-08-06T10:00:00Z")) == at("2026-08-06T11:00:00Z")
    assert Competition.next_boundary(c, at("2026-08-07T00:00:00Z")) == at("2026-08-09T20:00:00Z")
    assert Competition.next_boundary(c, at("2026-08-10T00:00:00Z")) == nil
  end
end
