defmodule Mix.Tasks.Ctf.GenInvites do
  @shortdoc "Generates one-time invite codes and prints them"
  @moduledoc """
      mix ctf.gen_invites COUNT [--words N]

  Generates COUNT unique one-time invite codes (default 3 words each), inserts
  them, and prints each one.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [words: :integer])

    count =
      case rest do
        [n | _] -> String.to_integer(n)
        [] -> Mix.raise("usage: mix ctf.gen_invites COUNT [--words N]")
      end

    CtfServer.MixHelpers.start_app_insert_only()

    {:ok, codes} =
      CtfServer.Accounts.generate_invite_codes(count, words: opts[:words] || 3)

    Enum.each(codes, &Mix.shell().info(&1))
    Mix.shell().info("\n#{length(codes)} code(s) generated.")
  end
end
