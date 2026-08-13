defmodule CtfServer.Repo.Migrations.CreateChallengeAttempt do
  use Ecto.Migration

  def change do
    create table(:challenge_attempt, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group, :string
      add :level, :integer
      add :status, :string
      add :flag, :string
      add :port, :integer
      add :team_id, references(:teams, on_delete: :nothing, type: :binary_id)
      add :completed_at, :utc_datetime_usec, default: nil
      add :earned_score, :integer, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:challenge_attempt, [:team_id])
  end
end
