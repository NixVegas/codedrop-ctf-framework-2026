defmodule CtfServer.Challenges.TestNoVmChallenge do
  @moduledoc """
  A minimal no-VM challenge used only in the test environment to exercise the
  no-VM provisioning path (see `CtfServer.Challenges.needs_vm?/1`).

  It declares no VM by returning `nil` from `vm_base_config/0`, so provisioning
  must skip port checkout and transition straight to `:started`. Its flag is a
  deterministic per-team value, mirroring the real challenges.
  """
  @behaviour CtfServer.ChallengeBehavior
  defstruct []

  def group, do: "test-no-vm"
  def level, do: 1
  def max_score, do: 10
  def name, do: "Test No-VM Challenge"

  # Declares that this challenge needs no VM, per the behaviour contract.
  def vm_base_config, do: nil

  def description, do: "Test-only no-VM challenge."

  @doc false
  def flag_for(%CtfServer.Accounts.Team{} = team) do
    :crypto.hash(:sha256, "test-no-vm:#{team.id}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defimpl CtfServer.Challenge do
    alias CtfServer.Accounts.Team

    def name(_challenge), do: @for.name()
    def description(_challenge), do: @for.description()
    def group(_challenge), do: @for.group()
    def level(_challenge), do: @for.level()
    def max_score(_challenge), do: @for.max_score()

    def create_flag(_challenge, %Team{} = team), do: {:ok, @for.flag_for(team)}

    def instantiate_challenge_attempt(_challenge, _attempt, _pubkey), do: :ok

    def cleanup_challenge_attempt(_challenge, _attempt), do: :ok

    def score_challenge_attempt(challenge, %Team{} = team, flag) do
      if flag == @for.flag_for(team) do
        {:ok, max_score(challenge)}
      else
        {:error, "Wrong flag."}
      end
    end
  end
end
