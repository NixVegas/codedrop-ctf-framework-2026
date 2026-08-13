defmodule CtfServerWeb.CompetitionChallengeTest do
  use CtfServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CtfServer.AccountsFixtures
  import CtfServer.ChallengesFixtures
  alias CtfServer.Competition

  @before_window %{starts_at: ~U[2999-01-01 00:00:00Z], ends_at: nil}
  @after_window %{starts_at: ~U[2020-01-01 00:00:00Z], ends_at: ~U[2020-01-02 00:00:00Z]}

  describe "dashboard holding" do
    test "before start, a non-admin team sees the holding message, not the challenge list", %{
      conn: conn
    } do
      team = team_fixture()
      {:ok, _} = Competition.update(Competition.get(), @before_window)

      {:ok, _lv, html} = conn |> log_in_team(team) |> live(~p"/dashboard")

      assert html =~ "The competition has not started yet."
      refute html =~ "Level 1"
    end

    test "after end, a non-admin team sees the holding message and a leaderboard link", %{
      conn: conn
    } do
      team = team_fixture()
      {:ok, _} = Competition.update(Competition.get(), @after_window)

      {:ok, _lv, html} = conn |> log_in_team(team) |> live(~p"/dashboard")

      assert html =~ "The competition is over."
      assert html =~ ~s(href="/leaderboard")
      refute html =~ "Level 1"
    end

    test "before start, an admin still sees the normal dashboard", %{conn: conn} do
      admin = admin_team_fixture()
      {:ok, _} = Competition.update(Competition.get(), @before_window)

      {:ok, _lv, html} = conn |> log_in_team(admin) |> live(~p"/dashboard")

      refute html =~ "The competition has not started yet."
      assert html =~ "Level 1"
    end

    test "after end, an admin still sees the normal dashboard", %{conn: conn} do
      admin = admin_team_fixture()
      {:ok, _} = Competition.update(Competition.get(), @after_window)

      {:ok, _lv, html} = conn |> log_in_team(admin) |> live(~p"/dashboard")

      refute html =~ "The competition is over."
      assert html =~ "Level 1"
    end
  end

  describe "challenge page holding" do
    test "before start, a non-admin team sees the holding message and no start button", %{
      conn: conn
    } do
      team = team_fixture()
      {:ok, _} = Competition.update(Competition.get(), @before_window)

      {:ok, _lv, html} = conn |> log_in_team(team) |> live(~p"/challenge/basic-nix/1")

      assert html =~ "The competition has not started yet."
      refute html =~ "Begin challenge!"
    end

    test "after end, a non-admin team sees the holding message and no capture form", %{
      conn: conn
    } do
      team = team_fixture()

      challenge_attempt_fixture(%{
        team_id: team.id,
        group: "basic-nix",
        level: 1,
        status: :started,
        port: 2222
      })

      {:ok, _} = Competition.update(Competition.get(), @after_window)

      {:ok, _lv, html} = conn |> log_in_team(team) |> live(~p"/challenge/basic-nix/1")

      assert html =~ "The competition is over."
      refute html =~ "phx-submit=\"attempt_capture\""
    end

    test "before start, an admin still sees the normal challenge page", %{conn: conn} do
      admin = admin_team_fixture()
      {:ok, _} = Competition.update(Competition.get(), @before_window)

      {:ok, _lv, html} = conn |> log_in_team(admin) |> live(~p"/challenge/basic-nix/1")

      refute html =~ "The competition has not started yet."
      assert html =~ "Begin challenge!"
    end
  end

  describe "attempt_capture scoring guard" do
    test "a non-admin cannot score a flag while the competition is closed", %{conn: conn} do
      team = team_fixture()

      challenge_attempt_fixture(%{
        team_id: team.id,
        group: "basic-nix",
        level: 1,
        status: :started,
        port: 2222
      })

      {:ok, _} = Competition.update(Competition.get(), @after_window)

      {:ok, lv, _html} = conn |> log_in_team(team) |> live(~p"/challenge/basic-nix/1")

      correct =
        :crypto.hash(:sha256, CtfServer.Challenges.BasicNix1.generate_seed(team))
        |> Base.encode16(case: :lower)

      html = render_submit(lv, "attempt_capture", %{"flag" => %{"flag" => "Nix{#{correct}}"}})

      assert html =~ "The competition is closed."
      refute html =~ "Flag captured"

      {:ok, attempt} =
        CtfServer.Challenges.get_challenge_attempt_for_team(team, "basic-nix", 1)

      assert attempt.status == :started
    end

    test "an admin can still score a flag while the competition is closed", %{conn: conn} do
      admin = admin_team_fixture()

      challenge_attempt_fixture(%{
        team_id: admin.id,
        group: "basic-nix",
        level: 1,
        status: :started,
        port: 2222
      })

      {:ok, _} = Competition.update(Competition.get(), @after_window)

      {:ok, lv, _html} = conn |> log_in_team(admin) |> live(~p"/challenge/basic-nix/1")

      correct =
        :crypto.hash(:sha256, CtfServer.Challenges.BasicNix1.generate_seed(admin))
        |> Base.encode16(case: :lower)

      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               render_submit(lv, "attempt_capture", %{
                 "flag" => %{"flag" => "Nix{#{correct}}"}
               })

      # `complete_challenge_attempt/3` moves the attempt to :deprovisioning and
      # queues the teardown job (Oban runs in :manual mode in tests, so the
      # transition to :completed happens later); reaching :deprovisioning is
      # proof the guard let the capture through.
      {:ok, attempt} =
        CtfServer.Challenges.get_challenge_attempt_for_team(admin, "basic-nix", 1)

      assert attempt.status == :deprovisioning
    end

    test "a stale :during assign does not let a non-admin score after the window closes", %{
      conn: conn
    } do
      team = team_fixture()

      challenge_attempt_fixture(%{
        team_id: team.id,
        group: "basic-nix",
        level: 1,
        status: :started,
        port: 2222
      })

      # Mount while the window is still open, so the socket's cached
      # `competition_phase` assign lands on `:during`.
      {:ok, lv, _html} = conn |> log_in_team(team) |> live(~p"/challenge/basic-nix/1")

      # Close the window directly in the DB, bypassing `Competition.update/2`
      # (and its pubsub broadcast) so the live socket's cached assign is never
      # refreshed. It stays stuck on `:during` even though the DB now says
      # the competition is closed.
      Competition.get()
      |> Ecto.Changeset.change(%{
        starts_at: ~U[2020-01-01 00:00:00.000000Z],
        ends_at: ~U[2020-01-02 00:00:00.000000Z]
      })
      |> CtfServer.Repo.update!()

      correct =
        :crypto.hash(:sha256, CtfServer.Challenges.BasicNix1.generate_seed(team))
        |> Base.encode16(case: :lower)

      html = render_submit(lv, "attempt_capture", %{"flag" => %{"flag" => "Nix{#{correct}}"}})

      assert html =~ "The competition is closed."
      refute html =~ "Flag captured"

      {:ok, attempt} =
        CtfServer.Challenges.get_challenge_attempt_for_team(team, "basic-nix", 1)

      assert attempt.status == :started
    end
  end
end
