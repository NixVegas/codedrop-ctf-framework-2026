defmodule CtfServer.Repo.Migrations.AddTeamDisabledAndAuditEvents do
  use Ecto.Migration

  def change do
    alter table(:teams) do
      add :disabled_at, :utc_datetime_usec
    end

    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :topic, :string, null: false
      add :event, :string, null: false
      add :principal_id, references(:teams, type: :binary_id, on_delete: :nilify_all)
      add :details, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_events, [:principal_id, :occurred_at])
  end
end
