defmodule CtfServer.NixEcosystemChallengesTest do
  use CtfServer.DataCase

  alias CtfServer.Challenge
  alias CtfServer.Challenges
  alias CtfServer.Challenges.NixEcosystem1

  import CtfServer.AccountsFixtures

  describe "NixEcosystem1 - Reading the Source" do
    test "is a no-VM challenge" do
      refute Challenges.needs_vm?(struct!(NixEcosystem1))
    end

    test "the flag is the sha256 of the configured path:line answer" do
      expected =
        :crypto.hash(:sha256, NixEcosystem1.answer()) |> Base.encode16(case: :lower)

      assert NixEcosystem1.expected_flag() == expected
    end

    test "create_flag is universal (same for every team) and matches the answer" do
      challenge = struct!(NixEcosystem1)
      {:ok, flag1} = Challenge.create_flag(challenge, team_fixture())
      {:ok, flag2} = Challenge.create_flag(challenge, team_fixture())

      assert flag1 == flag2
      assert flag1 == NixEcosystem1.expected_flag()
    end

    test "score accepts the expected flag and rejects anything else" do
      challenge = struct!(NixEcosystem1)
      team = team_fixture()

      assert {:ok, 100} =
               Challenge.score_challenge_attempt(challenge, team, NixEcosystem1.expected_flag())

      assert {:error, _} = Challenge.score_challenge_attempt(challenge, team, "not-the-flag")
    end

    test "instantiate and cleanup are no-ops" do
      challenge = struct!(NixEcosystem1)
      assert :ok = Challenge.instantiate_challenge_attempt(challenge, %{}, "pubkey")
      assert :ok = Challenge.cleanup_challenge_attempt(challenge, %{})
    end
  end
end
