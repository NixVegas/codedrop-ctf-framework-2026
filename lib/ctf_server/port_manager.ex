defmodule CtfServer.PortManager do
  @moduledoc """
  DB-backed port allocation for challenge attempt VMs.

  Uses a PostgreSQL advisory lock to serialize port checkouts,
  querying active ChallengeAttempts to determine which ports are in use.

  Ports are implicitly freed when an attempt moves to :completed status.
  """

  import Ecto.Query
  alias CtfServer.ChallengeAttempt
  alias CtfServer.Repo

  @advisory_lock_key 737_001

  @doc """
  Checks out a free port and assigns it to the given challenge attempt.

  Uses an advisory lock to prevent concurrent workers from racing on the same port.
  Returns `{:ok, port}` or `{:error, :exhausted}`.
  """
  @spec checkout_port(ChallengeAttempt.t()) :: {:ok, integer()} | {:error, :exhausted}
  def checkout_port(%ChallengeAttempt{} = attempt) do
    port_range = Application.fetch_env!(:ctf_server, :vm_port_range)

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [@advisory_lock_key])

      used_ports =
        from(a in ChallengeAttempt,
          where: a.status in [:provisioning, :started, :paused, :deprovisioning],
          where: not is_nil(a.port),
          select: a.port
        )
        |> Repo.all()
        |> MapSet.new()

      case Enum.find(port_range, fn port -> port not in used_ports end) do
        nil ->
          Repo.rollback(:exhausted)

        port ->
          {1, _} =
            from(a in ChallengeAttempt, where: a.id == ^attempt.id)
            |> Repo.update_all(set: [port: port])

          port
      end
    end)
  end
end
