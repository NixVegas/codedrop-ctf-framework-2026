defmodule CtfServer.TeamsTest do
  use CtfServer.DataCase

  alias CtfServer.Teams
  import CtfServer.AccountsFixtures
  import CtfServer.ChallengesFixtures

  describe "get_teams/0" do
    test "returns empty array when no teams" do
      assert Teams.get_teams() == []
    end

    test "returns the team if the email exists" do
      team1 = team_fixture()
      team2 = team_fixture()
      team3 = team_fixture()
      team4 = team_fixture()

      teams = Teams.get_teams()

      assert length(teams) == 4
      assert team1 in teams
      assert team2 in teams
      assert team3 in teams
      assert team4 in teams
    end
  end

  describe "get_teams_with_scores/0" do
    test "returns empty array when no teams" do
      assert Teams.get_teams_with_scores() == []
    end

    test "sums earned score per team across their completed attempts" do
      team1 = team_fixture()
      team2 = team_fixture()

      # team1 completes two challenges; team2 completes one.
      challenge_attempt_fixture(%{
        team_id: team1.id,
        group: "basic-nix",
        level: 1,
        status: :completed,
        earned_score: 100
      })

      challenge_attempt_fixture(%{
        team_id: team1.id,
        group: "basic-nix",
        level: 2,
        status: :completed,
        earned_score: 50
      })

      challenge_attempt_fixture(%{
        team_id: team2.id,
        group: "basic-nix",
        level: 1,
        status: :completed,
        earned_score: 70
      })

      scores = Map.new(Teams.get_teams_with_scores())

      assert scores[{team1.id, team1.name}] == 150
      assert scores[{team2.id, team2.name}] == 70
    end

    test "excludes teams with no completed attempts" do
      team = team_fixture()

      challenge_attempt_fixture(%{
        team_id: team.id,
        group: "basic-nix",
        level: 1,
        status: :started,
        earned_score: 0
      })

      assert Teams.get_teams_with_scores() == []
    end
  end
end
