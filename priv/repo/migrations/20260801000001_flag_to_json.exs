defmodule CtfServer.Repo.Migrations.FlagToJson do
  use Ecto.Migration

  # `challenge_attempt.flag` becomes a JSON object (a staff-only "answer key"
  # blob) instead of a single wrapped-flag string. Challenges with more than one
  # flag/value (e.g. hacking-with-nix/1: base + full + smb password) record them
  # all here; the column is admin-only and never read for scoring, which stays
  # stateless (recomputed from the team). Existing single-flag rows are wrapped
  # as {"flag": "<old value>"} so nothing is lost.
  def up do
    execute """
    ALTER TABLE challenge_attempt
      ALTER COLUMN flag TYPE jsonb
      USING CASE WHEN flag IS NULL THEN NULL ELSE jsonb_build_object('flag', flag) END
    """
  end

  def down do
    execute """
    ALTER TABLE challenge_attempt
      ALTER COLUMN flag TYPE text
      USING CASE WHEN flag IS NULL THEN NULL ELSE (flag->>'flag') END
    """
  end
end
