defmodule CtfServer.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CtfServer.Accounts` context.
  """

  def unique_team_email, do: "team#{System.unique_integer()}@example.com"
  def unique_team_name, do: "TEAM #{System.unique_integer()}"
  def valid_team_password, do: "hello world!"

  def valid_team_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_team_name(),
      email: unique_team_email(),
      password: valid_team_password()
    })
  end

  def team_fixture(attrs \\ %{}) do
    {:ok, team} =
      attrs
      |> valid_team_attributes()
      |> CtfServer.Accounts.register_team()

    team
  end

  def admin_team_fixture(attrs \\ %{}) do
    {:ok, team} =
      attrs
      |> team_fixture()
      |> Ecto.Changeset.change(%{is_admin: true})
      |> CtfServer.Repo.update()

    team
  end

  def extract_team_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end
end
