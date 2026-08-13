defmodule CtfServer.PubSubTest do
  use CtfServer.DataCase, async: true

  alias CtfServer.Challenges
  alias CtfUtils.PubSubUtils

  import CtfServer.AccountsFixtures
  import CtfServer.ChallengesFixtures

  describe "team attempt topic" do
    test "pub_attempt_update reaches a subscriber of that team" do
      team = team_fixture()
      other = team_fixture()
      attempt = challenge_attempt_fixture(%{team_id: team.id, status: :started})

      :ok = PubSubUtils.sub_team_updates(team.id)
      :ok = PubSubUtils.pub_attempt_update(attempt)

      assert_receive {:attempt_updated, id}
      assert id == attempt.id

      # a different team's subscriber must not receive it
      :ok = PubSubUtils.sub_team_updates(other.id)
      :ok = PubSubUtils.pub_attempt_update(attempt)
      assert_receive {:attempt_updated, _}
      refute_receive {:attempt_updated, _}, 50
    end

    test "starting a challenge broadcasts the new attempt on the team topic" do
      team = team_fixture()
      :ok = PubSubUtils.sub_team_updates(team.id)

      {:ok, attempt} = Challenges.start_challenge_attempt(team, "basic-nix", 1)

      assert_receive {:attempt_updated, id}
      assert id == attempt.id
    end

    test "force shutdown and reset broadcast on the team topic" do
      team = team_fixture()
      attempt = challenge_attempt_fixture(%{team_id: team.id, status: :started, port: 2222})
      :ok = PubSubUtils.sub_team_updates(team.id)

      {:ok, _} = Challenges.force_shutdown_attempt(attempt)
      assert_receive {:attempt_updated, _}

      {:ok, _} = Challenges.reset_challenge_attempt_instance(attempt)
      assert_receive {:attempt_updated, _}
    end
  end

  describe "leaderboard topic" do
    test "pub_leaderboard_update reaches a leaderboard subscriber" do
      :ok = PubSubUtils.sub_leaderboard()
      :ok = PubSubUtils.pub_leaderboard_update()

      assert_receive :leaderboard_updated
    end
  end
end
