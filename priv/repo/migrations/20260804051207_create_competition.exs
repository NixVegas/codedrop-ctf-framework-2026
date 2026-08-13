defmodule CtfServer.Repo.Migrations.CreateCompetition do
  use Ecto.Migration

  def up do
    create table(:competition, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :starts_at, :utc_datetime_usec
      add :ends_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    # Seed the single row so get/0 always finds it. All-nil = unbounded = open.
    execute "INSERT INTO competition (id, inserted_at, updated_at) VALUES (gen_random_uuid(), now(), now())"
  end

  def down do
    drop table(:competition)
  end
end
