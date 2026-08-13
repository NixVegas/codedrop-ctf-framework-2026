defmodule CtfServer.Competition do
  @moduledoc """
  The single global competition window. `starts_at`/`ends_at` are UTC and
  nullable; a nil bound is unbounded, so the default (both nil) is always
  `:during` (open). Admins bypass the window in the web/context layers.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias CtfServer.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "competition" do
    field :starts_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The singleton competition row (seeded by the migration)."
  def get, do: Repo.one!(from c in __MODULE__, order_by: [asc: c.inserted_at], limit: 1)

  @doc "Updates the window and broadcasts a refresh. Both bounds may be nil."
  def update(%__MODULE__{} = competition, attrs) do
    result =
      competition
      |> cast(attrs, [:starts_at, :ends_at])
      |> validate_window()
      |> Repo.update()

    with {:ok, _} <- result, do: CtfUtils.PubSubUtils.pub_competition()
    result
  end

  defp validate_window(changeset) do
    starts = get_field(changeset, :starts_at)
    ends = get_field(changeset, :ends_at)

    if starts && ends && DateTime.compare(starts, ends) == :gt do
      add_error(changeset, :ends_at, "must be at or after starts_at")
    else
      changeset
    end
  end

  @doc "Pure phase for a given window and instant."
  def phase(%__MODULE__{starts_at: starts, ends_at: ends}, %DateTime{} = now) do
    cond do
      starts && DateTime.compare(now, starts) == :lt -> :before
      ends && DateTime.compare(now, ends) != :lt -> :after
      true -> :during
    end
  end

  @doc "The next boundary strictly after `now`, or nil if none remains."
  def next_boundary(%__MODULE__{starts_at: starts, ends_at: ends}, %DateTime{} = now) do
    [starts, ends]
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(DateTime.compare(&1, now) == :gt))
    |> Enum.sort(DateTime)
    |> List.first()
  end

  def current_phase(now \\ DateTime.utc_now()), do: phase(get(), now)
  def challenges_open?(now \\ DateTime.utc_now()), do: current_phase(now) == :during
  def scoreboard_visible?(now \\ DateTime.utc_now()), do: current_phase(now) in [:during, :after]
  def registration_open?(now \\ DateTime.utc_now()), do: current_phase(now) == :during
end
