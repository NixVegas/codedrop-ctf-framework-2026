defmodule CtfServer.ChallengesTest do
  use CtfServer.DataCase

  alias CtfServer.Challenges

  describe "challenge_attempt" do
    alias CtfServer.ChallengeAttempt

    import CtfServer.ChallengesFixtures
    import CtfServer.AccountsFixtures

    @invalid_attrs %{name: nil, status: nil}

    test "list_challenge_attempt/0 returns all challenge_attempt" do
      team = team_fixture()
      challenge_attempt = challenge_attempt_fixture(%{team_id: team.id})
      # list_challenge_attempt/0 preloads :team, so compare against a preloaded copy.
      assert Challenges.list_challenge_attempt() == [
               CtfServer.Repo.preload(challenge_attempt, :team)
             ]
    end

    test "get_challenge_attempt!/1 returns the challenge_attempt with given id" do
      team = team_fixture()
      challenge_attempt = challenge_attempt_fixture(%{team_id: team.id})
      assert Challenges.get_challenge_attempt!(challenge_attempt.id) == challenge_attempt
    end

    test "create_challenge_attempt/1 with valid data creates a challenge_attempt" do
      team = team_fixture()
      valid_attrs = %{group: "test2-group", level: 9000, status: :untouched, team_id: team.id}

      assert {:ok, %ChallengeAttempt{} = challenge_attempt} =
               Challenges.create_challenge_attempt(valid_attrs)

      assert challenge_attempt.group == "test2-group"
      assert challenge_attempt.level == 9000
      assert challenge_attempt.status == :untouched
    end

    test "create_challenge_attempt/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Challenges.create_challenge_attempt(@invalid_attrs)
    end

    test "update_challenge_attempt/2 with valid data updates the challenge_attempt" do
      team = team_fixture()
      challenge_attempt = challenge_attempt_fixture(%{team_id: team.id})

      update_attrs = %{
        group: "new-test-group",
        level: 1337,
        status: :provisioning,
        flag: %{"flag" => "flagflag"}
      }

      assert {:ok, %ChallengeAttempt{} = challenge_attempt} =
               Challenges.update_challenge_attempt(challenge_attempt, update_attrs)

      assert challenge_attempt.group == "new-test-group"
      assert challenge_attempt.level == 1337
      assert challenge_attempt.status == :provisioning
      assert challenge_attempt.flag == %{"flag" => "flagflag"}
    end

    test "update_challenge_attempt/2 with invalid data returns error changeset" do
      team = team_fixture()
      challenge_attempt = challenge_attempt_fixture(%{team_id: team.id})

      assert {:error, %Ecto.Changeset{}} =
               Challenges.update_challenge_attempt(challenge_attempt, @invalid_attrs)

      assert challenge_attempt == Challenges.get_challenge_attempt!(challenge_attempt.id)
    end

    test "delete_challenge_attempt/1 deletes the challenge_attempt" do
      team = team_fixture()
      challenge_attempt = challenge_attempt_fixture(%{team_id: team.id})
      assert {:ok, %ChallengeAttempt{}} = Challenges.delete_challenge_attempt(challenge_attempt)

      assert_raise Ecto.NoResultsError, fn ->
        Challenges.get_challenge_attempt!(challenge_attempt.id)
      end
    end

    test "change_challenge_attempt/1 returns a challenge_attempt changeset" do
      team = team_fixture()
      challenge_attempt = challenge_attempt_fixture(%{team_id: team.id})
      assert %Ecto.Changeset{} = Challenges.change_challenge_attempt(challenge_attempt)
    end
  end
end
