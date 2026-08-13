defmodule CtfServer.AccountsConfirmationTest do
  # These tests toggle the global :skip_account_confirmation setting, so they
  # must not run concurrently with other tests that register teams.
  use CtfServer.DataCase, async: false

  alias CtfServer.Accounts

  import CtfServer.AccountsFixtures

  defp put_skip_account_confirmation(value) do
    previous = Application.get_env(:ctf_server, :skip_account_confirmation)
    Application.put_env(:ctf_server, :skip_account_confirmation, value)
    on_exit(fn -> Application.put_env(:ctf_server, :skip_account_confirmation, previous) end)
  end

  describe "register_team/1 with skip_account_confirmation enabled" do
    setup do
      put_skip_account_confirmation(true)
    end

    test "confirms the team immediately" do
      {:ok, team} = Accounts.register_team(valid_team_attributes())
      assert team.confirmed_at
    end
  end

  describe "register_team/1 with skip_account_confirmation disabled" do
    setup do
      put_skip_account_confirmation(false)
    end

    test "leaves the team unconfirmed" do
      {:ok, team} = Accounts.register_team(valid_team_attributes())
      assert is_nil(team.confirmed_at)
    end
  end

  describe "admin_register_team/1" do
    test "confirms the team even when skip_account_confirmation is disabled" do
      put_skip_account_confirmation(false)

      {:ok, team} = Accounts.admin_register_team(valid_team_attributes())
      assert team.confirmed_at
    end

    test "validates the attributes" do
      {:error, changeset} = Accounts.admin_register_team(%{name: "", email: "bad", password: "x"})

      assert %{
               name: ["can't be blank"],
               email: ["must have the @ sign and no spaces"],
               password: ["should be at least 12 character(s)"]
             } = errors_on(changeset)
    end
  end

  describe "admin_confirm_team/1" do
    test "confirms an unconfirmed team" do
      team = team_fixture()
      assert is_nil(team.confirmed_at)

      {:ok, confirmed} = Accounts.admin_confirm_team(team)
      assert confirmed.confirmed_at
    end
  end

  describe "generate_team_reset_password_code/1" do
    test "returns a code usable by the reset password flow exactly once" do
      team = team_fixture()
      code = Accounts.generate_team_reset_password_code(team)

      assert reset_team = Accounts.get_team_by_reset_password_token(code)
      assert reset_team.id == team.id

      {:ok, _} =
        Accounts.reset_team_password(reset_team, %{
          password: "new valid password",
          password_confirmation: "new valid password"
        })

      refute Accounts.get_team_by_reset_password_token(code)
      assert Accounts.get_team_by_email_and_password(team.email, "new valid password")
    end
  end
end
