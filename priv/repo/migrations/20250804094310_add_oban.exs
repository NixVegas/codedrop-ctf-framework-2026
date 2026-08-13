defmodule CtfServer.Repo.Migrations.AddOban do
  use Ecto.Migration

  # Pinned to 12 — the schema version this migration actually created, because
  # it was written and run against Oban 2.19 whose `current_version` was 12. It
  # was unpinned (`Oban.Migration.up()`), which meant the resulting schema
  # depended on whichever Oban happened to be installed when it ran. Later
  # upgrades add their own migration (see `upgrade_oban_to_v14`) so that a
  # freshly created database converges on the same schema as the deployed one.
  def up, do: Oban.Migration.up(version: 12)

  def down, do: Oban.Migration.down(version: 1)
end
