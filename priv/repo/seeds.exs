# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     CtfServer.Repo.insert!(%CtfServer.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias CtfServer.Repo
alias CtfServer.Accounts.Team

# The bootstrap admin: ctf_admin@localhost / adminadmin.
#
# Built by hand rather than through `Team.registration_changeset/3` on purpose.
# That changeset enforces `min: 12` on passwords, which the agreed-on
# `adminadmin` does not meet — and the minimum should keep applying to every
# real team. Hashing here bypasses the length rule for this one seeded account
# without weakening the policy for registration, password reset, or settings.
#
# `confirmed_at` is set for the same reason `Accounts.register_team/2` sets it
# when `:skip_account_confirmation` is on: no confirmation mail reaches this
# account, so leaving it unconfirmed would only strand it.
now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

%Team{}
|> Ecto.Changeset.change(%{
  name: "ctf_admin",
  email: "ctf_admin@localhost",
  hashed_password: Argon2.hash_pwd_salt("adminadmin"),
  confirmed_at: now,
  is_admin: true
})
|> Repo.insert!()
