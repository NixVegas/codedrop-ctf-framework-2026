defmodule CtfServer.Repo.Migrations.CreateInviteCodes do
  use Ecto.Migration

  def change do
    create table(:invite_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :code, :string, null: false
      add :redeemed_at, :utc_datetime_usec
      add :redeemed_by_team_id, references(:teams, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:invite_codes, [:code])
    create index(:invite_codes, [:redeemed_at])

    alter table(:teams) do
      add :registered_remote, :boolean, null: false, default: false
      add :registration_ip, :string
    end
  end
end
