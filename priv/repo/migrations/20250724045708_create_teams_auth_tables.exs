defmodule CtfServer.Repo.Migrations.CreateTeamsAuthTables do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:teams, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :email, :citext, null: false
      add :hashed_password, :string, null: false
      add :confirmed_at, :utc_datetime_usec
      add :is_admin, :boolean, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:teams, [:email])
    create unique_index(:teams, [:name])

    create table(:teams_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:teams_tokens, [:team_id])
    create unique_index(:teams_tokens, [:context, :token])
  end
end
