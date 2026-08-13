defmodule CtfServer.Workers.CompetitionSweeper do
  @moduledoc """
  Runs every minute. Once the competition window has ended, tears down every
  in-flight challenge VM to free the hardware. Idempotent: attempts already
  deprovisioning are skipped, so repeated ticks converge to no-ops.
  """
  use Oban.Worker, queue: :deprovision, max_attempts: 3

  alias CtfServer.{Challenges, Competition}

  @impl Oban.Worker
  def perform(_job) do
    if Competition.current_phase() == :after do
      Challenges.list_vm_attempts_in_flight()
      |> Enum.reject(&(&1.status == :deprovisioning))
      |> Enum.each(&Challenges.teardown_at_competition_end/1)
    end

    :ok
  end
end
