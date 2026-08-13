defmodule CtfServer.ChallengeAttempt do
  use Ecto.Schema
  import Ecto.Changeset
  alias CtfServer.Accounts.Team

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "challenge_attempt" do
    field :group, :string
    field :level, :integer

    field :status, Ecto.Enum,
      values: [:untouched, :provisioning, :started, :paused, :deprovisioning, :completed]

    # A staff-only JSON "answer key" for the attempt (base/full flags, planted
    # secrets, ...). Admin-display only — scoring never reads it. See
    # ChallengeBehavior.reference_values/1.
    field :flag, :map
    field :port, :integer
    field :privkey, :string
    field :earned_score, :integer, default: 0

    belongs_to :team, Team
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(challenge_attempt, attrs) do
    challenge_attempt
    |> cast(attrs, [:level, :group, :status, :team_id, :flag, :port, :privkey, :earned_score])
    |> validate_required([:level, :group, :status, :team_id])
  end
end
