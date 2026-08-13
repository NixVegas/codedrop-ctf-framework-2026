defmodule CtfServer.ChallengesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CtfServer.Challenges` context.
  """

  @doc """
  Generate a challenge_attempt.
  """
  def challenge_attempt_fixture(attrs \\ %{}) do
    {:ok, challenge_attempt} =
      attrs
      |> Enum.into(%{
        group: "basic-nix",
        level: 1,
        status: :untouched
      })
      |> CtfServer.Challenges.create_challenge_attempt()

    challenge_attempt
  end
end
