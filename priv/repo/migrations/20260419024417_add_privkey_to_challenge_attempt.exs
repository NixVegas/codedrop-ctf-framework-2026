defmodule CtfServer.Repo.Migrations.AddPrivkeyToChallengeAttempt do
  use Ecto.Migration

  def change do
    alter table(:challenge_attempt) do
      add :privkey, :text
    end
  end
end
