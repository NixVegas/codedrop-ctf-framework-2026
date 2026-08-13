defmodule CtfServer.MixHelpersTest do
  @moduledoc """
  Mix tasks must not boot a job-processing Oban node.

  `config/runtime.exs` only makes release `eval` invocations insert-only
  (prod + no `PHX_SERVER`); mix tasks run as dev, so a plain
  `Mix.Task.run("app.start")` in a task starts live `provision`/
  `deprovision` queues. The task then exits in seconds, orphaning any job it
  dequeued as "executing".
  """
  use ExUnit.Case, async: true

  alias CtfServer.MixHelpers

  test "insert_only/1 disables execution but keeps the rest of the config" do
    config = [repo: CtfServer.Repo, queues: [provision: 5, deprovision: 5], plugins: [SomePlugin]]

    assert MixHelpers.insert_only(config) ==
             [repo: CtfServer.Repo, queues: false, plugins: false]
  end

  test "no ctf.* task starts the app directly" do
    offenders =
      "lib/mix/tasks/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ ~s|Mix.Task.run("app.start")|))

    assert offenders == [],
           "these tasks bypass CtfServer.MixHelpers.start_app_insert_only/0 and will " <>
             "run live Oban queues: #{Enum.join(offenders, ", ")}"
  end
end
