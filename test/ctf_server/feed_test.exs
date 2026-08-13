defmodule CtfServer.FeedTest do
  use CtfServer.DataCase, async: true

  import CtfServer.AccountsFixtures

  alias CtfServer.Audit
  alias CtfServer.ChallengeAttempt
  alias CtfServer.Feed

  setup do
    # The feed reads rows, so audit writes have to be durable before assertions.
    previous = Application.get_env(:ctf_server, Audit, [])
    Application.put_env(:ctf_server, Audit, Keyword.put(previous, :sync, true))
    on_exit(fn -> Application.put_env(:ctf_server, Audit, previous) end)
    :ok
  end

  defp attempt(group \\ "basic-nix", level \\ 1) do
    %ChallengeAttempt{group: group, level: level}
  end

  describe "recent/1" do
    test "reports started, captured, and missed activity" do
      team = team_fixture(%{name: "Feeders"})

      :ok = Audit.start_attempt(team, attempt())
      :ok = Audit.complete_attempt(team, attempt(), 150)
      :ok = Audit.submit_flag_failed(team, "basic-nix", 1, "Nix{nope}", "incorrect")

      kinds = Feed.recent() |> Enum.map(& &1.kind) |> Enum.sort()

      assert kinds == [:captured, :missed, :started]
    end

    test "never exposes a submitted flag, at any detail level" do
      team = team_fixture(%{name: "Leaky"})
      secret = "Nix{super-secret-submission}"

      :ok = Audit.submit_flag(team, "basic-nix", 1, secret)
      :ok = Audit.submit_flag_failed(team, "basic-nix", 1, secret, "incorrect")

      for detail <- [:public, :admin] do
        rendered = detail |> then(&Feed.recent(detail: &1)) |> inspect()

        refute rendered =~ "super-secret-submission",
               "a submitted flag reached the #{detail} feed"
      end
    end

    test "skips bare submit_flag events, which would double-count every submission" do
      team = team_fixture(%{name: "Submitter"})

      :ok = Audit.submit_flag(team, "basic-nix", 1, "Nix{x}")

      assert Feed.recent() == []
    end

    test "leaves non-challenge activity out of the feed entirely" do
      team = team_fixture(%{name: "Logger Inner"})

      :ok = Audit.log_in(team)
      :ok = Audit.create_account(team)

      assert Feed.recent() == []
    end

    test "includes the rejection reason only for admins" do
      team = team_fixture(%{name: "Fumbler"})
      :ok = Audit.submit_flag_failed(team, "basic-nix", 1, "nope", "malformed")

      [public] = Feed.recent(detail: :public)
      [admin] = Feed.recent(detail: :admin)

      refute Map.has_key?(public, :reason)
      assert admin.reason == "malformed"
    end

    test "carries the team name, challenge, and score" do
      team = team_fixture(%{name: "Scorers"})
      :ok = Audit.complete_attempt(team, attempt("hacking-with-nix", 3), 200)

      assert [entry] = Feed.recent()
      assert entry.team == "Scorers"
      assert entry.group == "hacking-with-nix"
      assert entry.level == 3
      assert entry.score == 200
    end

    test "returns newest first and honours the limit" do
      team = team_fixture(%{name: "Busy"})
      for level <- 1..5, do: :ok = Audit.start_attempt(team, attempt("basic-nix", level))

      entries = Feed.recent(limit: 3)

      assert length(entries) == 3
      ats = Enum.map(entries, & &1.at)
      assert ats == Enum.sort(ats, {:desc, DateTime})
    end

    test "clamps an absurd limit rather than trying to serve it" do
      team = team_fixture(%{name: "Greedy"})
      :ok = Audit.start_attempt(team, attempt())

      assert Feed.recent(limit: 10_000_000) != []
      assert Feed.max_limit() == 200
    end
  end
end
