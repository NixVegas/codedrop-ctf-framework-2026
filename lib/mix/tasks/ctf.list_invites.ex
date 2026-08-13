defmodule Mix.Tasks.Ctf.ListInvites do
  @shortdoc "Lists invite codes and their redemption status"
  @moduledoc "    mix ctf.list_invites"
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    CtfServer.MixHelpers.start_app_insert_only()

    %{total: total, redeemed: redeemed, unused: unused} =
      CtfServer.Accounts.count_invite_codes()

    Mix.shell().info("#{total} total, #{unused} unused, #{redeemed} redeemed\n")

    for c <- CtfServer.Accounts.list_invite_codes() do
      status =
        if c.redeemed_at do
          "redeemed by #{c.redeemed_by_team && c.redeemed_by_team.name} at #{c.redeemed_at}"
        else
          "unused"
        end

      Mix.shell().info("  #{c.code}  #{status}")
    end
  end
end
