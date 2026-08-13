defmodule CtfServer.MixHelpers do
  @moduledoc """
  Shared setup for the `ctf.*` mix tasks.
  """

  @doc """
  Starts the app for a one-off command *without* joining the Oban cluster as
  a job-processing node.

  `config/runtime.exs` already makes release `eval` invocations insert-only,
  for the reason spelled out there: a one-off command exits as soon as its
  work returns, so a job its Oban dequeued first is orphaned mid-run as
  "executing". That guard is scoped to prod, and mix tasks run as dev — so
  without this every `mix ctf.*` invocation boots live `provision`/
  `deprovision` queues and can steal a real team's job.

  For `ctf.cleanup_vms` that is worse than an orphaned job: it could dequeue
  a provision job and start building the very VMs it is in the middle of
  destroying. `ctf.build_vm_bases` holds the queues open for the minutes it
  spends building images.

  Inserting still works — only execution is off.
  """
  def start_app_insert_only do
    # Apply all config (including runtime.exs) *before* overriding, so the
    # override can't be clobbered by config `app.start` would apply itself.
    Mix.Task.run("app.config")

    Application.put_env(
      :ctf_server,
      Oban,
      insert_only(Application.fetch_env!(:ctf_server, Oban))
    )

    Mix.Task.run("app.start")
  end

  @doc "The Oban config in `opts`, with job execution disabled."
  def insert_only(opts), do: Keyword.merge(opts, queues: false, plugins: false)
end
