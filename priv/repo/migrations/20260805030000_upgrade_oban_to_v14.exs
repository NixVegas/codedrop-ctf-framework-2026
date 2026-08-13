defmodule CtfServer.Repo.Migrations.UpgradeObanToV14 do
  use Ecto.Migration

  # Oban 2.19 -> 2.23 moves the required schema from version 12 to 14. The
  # original `add_oban` migration is already recorded as run, so Ecto will
  # never re-run it and the deployed database would otherwise stay at 12 while
  # the new Oban expects 14.
  #
  #   v13 — indexes on (state, cancelled_at) and (state, discarded_at)
  #   v14 — adds the 'suspended' value to the oban_job_state enum
  #
  # `Oban.Migration.up/1` is a no-op when the schema is already at the target,
  # so this is safe on a database created fresh under Oban 2.23.
  def up, do: Oban.Migration.up(version: 14)

  def down, do: Oban.Migration.down(version: 12)
end
