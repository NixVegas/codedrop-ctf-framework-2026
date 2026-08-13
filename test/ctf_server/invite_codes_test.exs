defmodule CtfServer.InviteCodesTest do
  use CtfServer.DataCase, async: false

  alias CtfServer.Accounts.InviteCode
  alias CtfServer.Repo

  test "insert_changeset accepts a code and enforces uniqueness" do
    assert {:ok, _} = Repo.insert(InviteCode.insert_changeset("alpha-beta-gamma"))

    assert {:error, changeset} = Repo.insert(InviteCode.insert_changeset("alpha-beta-gamma"))
    assert %{code: ["has already been taken"]} = errors_on(changeset)
  end

  alias CtfServer.Accounts

  describe "generate_invite_codes/2" do
    test "inserts the requested count of unique codes" do
      {:ok, codes} = Accounts.generate_invite_codes(5)
      assert length(codes) == 5
      assert length(Enum.uniq(codes)) == 5
      assert Accounts.count_invite_codes() == %{total: 5, redeemed: 0, unused: 5}
    end

    test "honors the word count" do
      {:ok, [code]} = Accounts.generate_invite_codes(1, words: 2)
      assert length(String.split(code, "-")) == 2
    end
  end

  describe "register_team/2 invite gating" do
    setup do
      Application.put_env(:ctf_server, :require_invite_codes, true)
      on_exit(fn -> Application.put_env(:ctf_server, :require_invite_codes, false) end)
      :ok
    end

    defp reg_attrs(extra \\ %{}) do
      Map.merge(
        %{
          "name" => "T#{System.unique_integer([:positive])}",
          "email" => "t#{System.unique_integer([:positive])}@example.com",
          "password" => "hello world!"
        },
        extra
      )
    end

    test "local client registers without a code" do
      assert {:ok, team} = Accounts.register_team(reg_attrs(), local?: true)
      refute team.registered_remote
    end

    test "remote client without a code is rejected" do
      assert {:error, :invalid_invite_code} = Accounts.register_team(reg_attrs(), local?: false)
    end

    test "remote client with a valid code registers and consumes the code" do
      {:ok, [code]} = Accounts.generate_invite_codes(1)

      assert {:ok, team} =
               Accounts.register_team(reg_attrs(%{"invite_code" => code}), local?: false)

      assert team.registered_remote

      # the same code cannot be reused
      assert {:error, :invalid_invite_code} =
               Accounts.register_team(reg_attrs(%{"invite_code" => code}), local?: false)
    end

    test "toggle off lets a remote client register with no code" do
      Application.put_env(:ctf_server, :require_invite_codes, false)
      assert {:ok, _team} = Accounts.register_team(reg_attrs(), local?: false)
    end
  end
end
