defmodule CtfServer.Teams do
  @moduledoc """
  The Teams context.
  """

  import Ecto.Query, warn: false
  alias CtfServer.Repo

  alias CtfServer.Accounts.Team
  alias CtfServer.ChallengeAttempt
  alias CtfServer.Challenges

  @doc """
  Get teams.

  ## Examples

      iex> get_teams()
      [%Team{}]

      iex> get_teams()
      nil

  """
  def get_teams() do
    Repo.all(Team)
  end

  @doc """
  Get teams with score information

  ## Examples

      iex> get_teams_with_scores()
      [%Team{}]

      iex> get_teams_with_scores()
      nil

  """
  def get_teams_with_scores() do
    challenges = Challenges.list_challenge_attempt()

    scored =
      challenges
      |> Enum.filter(fn %ChallengeAttempt{} = ca ->
        ca.status == :completed
      end)
      |> Enum.map(fn %ChallengeAttempt{} = ca ->
        {ca.team.id, ca.team.name, ca.earned_score}
      end)
      |> Enum.group_by(fn {tid, name, _earned_score} -> {tid, name} end)
      |> Enum.map(fn {team_id, v} ->
        {team_id, Enum.reduce(v, 0, fn {_tid, _, score}, acc -> acc + score end)}
      end)

    scored
  end
end
