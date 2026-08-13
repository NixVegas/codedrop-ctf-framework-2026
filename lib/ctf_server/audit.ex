defmodule CtfServer.Audit do
  @moduledoc """
  Audit trail of account, auth, and challenge lifecycle events.

  All events funnel through `audit/5`, which can never be seen to fail by
  the caller: the database write happens in a throwaway supervised task
  (inline in tests), any error is logged and swallowed, and the return
  value is always `:ok`.

  Callers use the event-specific wrappers (`create_account/2`, `log_in/1`,
  `start_attempt/2`, ...) rather than calling `audit/5` directly, so the
  event taxonomy lives in this module alone.
  """

  import Ecto.Query, warn: false
  require Logger

  alias CtfServer.Audit.Event
  alias CtfServer.Accounts.Team
  alias CtfServer.Repo

  ## Core

  @doc """
  Records an audit event. Always returns `:ok`.

  * `topic` - coarse grouping, e.g. `"account"`, `"auth"`, `"challenge"`
  * `event` - what happened within the topic, e.g. `"create"`, `"log_in"`
  * `principal` - the `%Team{}` the event happened as (or `nil`); admin
    actions record the admin as principal with the target team in details
  * `time` - when it happened; defaults to now
  * `details` - map of extra context stored as JSON
  """
  def audit(topic, event, principal, time \\ nil, details) do
    attrs = %{
      topic: topic,
      event: event,
      principal_id: principal && principal.id,
      occurred_at: time || DateTime.utc_now(),
      details: Map.new(details)
    }

    write = fn ->
      try do
        result =
          %Event{}
          |> Event.changeset(attrs)
          |> Repo.insert()

        # Wake the activity feed once the row is durable. Best-effort, like the
        # write itself: a missed broadcast costs a late refresh, never an event.
        with {:ok, _event} <- result do
          CtfUtils.PubSubUtils.pub_feed_activity(topic, event)
        end

        result
      rescue
        error ->
          Logger.error(
            "failed to record audit event #{topic}.#{event}: #{Exception.message(error)}"
          )
      catch
        kind, reason ->
          Logger.error(
            "failed to record audit event #{topic}.#{event}: #{kind} #{inspect(reason)}"
          )
      end
    end

    try do
      if sync?() do
        write.()
      else
        Task.Supervisor.start_child(CtfServer.Audit.TaskSupervisor, write)
      end
    rescue
      error ->
        Logger.error(
          "failed to dispatch audit event #{topic}.#{event}: #{Exception.message(error)}"
        )
    catch
      kind, reason ->
        Logger.error(
          "failed to dispatch audit event #{topic}.#{event}: #{kind} #{inspect(reason)}"
        )
    end

    :ok
  end

  defp sync? do
    :ctf_server
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:sync, false)
  end

  ## Event wrappers

  def create_account(%Team{} = team, actor \\ nil) do
    {principal, details} = about(team, actor, %{email: team.email})
    audit("account", "create", principal, details)
  end

  def confirm_account(%Team{} = team, actor \\ nil) do
    {principal, details} = about(team, actor, %{})
    audit("account", "confirm", principal, details)
  end

  def disable_login(%Team{} = team, actor, details \\ %{}) do
    {principal, details} = about(team, actor, Map.new(details))
    audit("account", "disable_login", principal, details)
  end

  def enable_login(%Team{} = team, actor) do
    {principal, details} = about(team, actor, %{})
    audit("account", "enable_login", principal, details)
  end

  @doc "An admin generated a batch of invite codes."
  def generate_invite_codes(count, actor \\ nil) do
    audit("invite_code", "generate", actor, %{count: count})
  end

  # Logins are audited as attempt/succeed/fail. The team may be nil when the
  # email doesn't match an account — the attempt/fail events still record,
  # with the (length-capped) email in details.

  def log_in_attempted(team, email) do
    audit("auth", "log_in_attempted", team, %{email: String.slice(email, 0, 160)})
  end

  def log_in(%Team{} = team), do: audit("auth", "log_in", team, %{email: team.email})

  def log_in_failed(team, email) do
    audit("auth", "log_in_failed", team, %{email: String.slice(email, 0, 160)})
  end

  # Password resets are audited as attempt/succeed/fail.

  def reset_password_attempted(%Team{} = team) do
    audit("auth", "reset_password_attempted", team, %{})
  end

  def reset_password(%Team{} = team), do: audit("auth", "reset_password", team, %{})

  def reset_password_failed(%Team{} = team, details \\ %{}) do
    audit("auth", "reset_password_failed", team, details)
  end

  def create_reset_code(%Team{} = team, actor) do
    {principal, details} = about(team, actor, %{})
    audit("auth", "create_reset_code", principal, details)
  end

  def start_attempt(%Team{} = team, attempt) do
    audit("challenge", "start", team, %{group: attempt.group, level: attempt.level})
  end

  def complete_attempt(%Team{} = team, attempt, score) do
    audit("challenge", "complete", team, %{
      group: attempt.group,
      level: attempt.level,
      score: score
    })
  end

  # Flag submission is audited as attempt/succeed/fail: every submission
  # records "submit_flag", rejections record "submit_flag_failed" with the
  # reason, and success is the "complete" event (logged with the score).

  def submit_flag(%Team{} = team, group, level, flag) do
    audit("challenge", "submit_flag", team, %{group: group, level: level, flag: flag})
  end

  def submit_flag_failed(%Team{} = team, group, level, flag, reason) do
    audit("challenge", "submit_flag_failed", team, %{
      group: group,
      level: level,
      flag: flag,
      reason: reason
    })
  end

  def force_shutdown_attempt(attempt, actor) do
    audit("challenge", "force_shutdown", actor, %{
      team_id: attempt.team_id,
      group: attempt.group,
      level: attempt.level
    })
  end

  def reset_attempt(attempt, actor) do
    audit("challenge", "reset", actor, %{
      team_id: attempt.team_id,
      group: attempt.group,
      level: attempt.level
    })
  end

  # Reaping leaked libvirt resources is an admin-initiated destructive act
  # with no attempt record behind it, so the resource name is the subject.

  def destroy_orphan_domain(domain, actor) do
    audit("vm", "destroy_orphan_domain", actor, %{domain: domain})
  end

  def destroy_stray_network(network, actor) do
    audit("vm", "destroy_stray_network", actor, %{network: network})
  end

  def teardown_attempt(attempt, actor) do
    lifecycle_event("teardown", attempt, actor)
  end

  def rebuild_attempt(attempt, actor) do
    lifecycle_event("rebuild", attempt, actor)
  end

  def pause_attempt(attempt, actor) do
    lifecycle_event("pause", attempt, actor)
  end

  def resume_attempt(attempt, actor) do
    lifecycle_event("resume", attempt, actor)
  end

  # Instance-lifecycle actions (teardown/rebuild/pause/resume) may be driven by
  # the team itself (actor nil -> team is principal) or by an admin (actor is
  # principal, target team pointed at via details).
  defp lifecycle_event(event, attempt, nil) do
    audit("challenge", event, %Team{id: attempt.team_id}, %{
      group: attempt.group,
      level: attempt.level
    })
  end

  defp lifecycle_event(event, attempt, actor) do
    audit("challenge", event, actor, %{
      team_id: attempt.team_id,
      group: attempt.group,
      level: attempt.level
    })
  end

  # Self-service events record the team as principal; admin actions record
  # the admin as principal and point at the team through details.
  defp about(team, nil, details), do: {team, details}

  defp about(team, actor, details) do
    {actor, Map.merge(details, %{team_id: team.id, team_email: team.email})}
  end

  ## Queries

  @doc """
  Lists the most recent audit events concerning a team, newest first:
  events the team was principal for, plus admin actions targeting it.
  """
  def list_events_for_team(%Team{} = team, limit \\ 100) do
    Repo.all(
      from e in scope_to_team(Event, team),
        order_by: [desc: e.occurred_at],
        limit: ^limit,
        preload: :principal
    )
  end

  @doc """
  Pages through audit events, newest first, with optional filters.

  Options:

    * `:topic` — only events with this topic (e.g. `"auth"`)
    * `:team` — a `%Team{}`: only events concerning it (as principal, or as
      the target of an admin action)
    * `:q` — case-insensitive substring match on the event name or the
      principal's email
    * `:page` / `:per_page` — 1-based page selection (defaults 1 / 50)

  Returns `%{events: events, page: page, per_page: per_page, total: total,
  total_pages: total_pages}` with `page` clamped to the available range.
  """
  def list_events(opts \\ []) do
    per_page = opts |> Keyword.get(:per_page, 50) |> max(1)

    query =
      Event
      |> maybe_filter_topic(Keyword.get(opts, :topic))
      |> maybe_scope_to_team(Keyword.get(opts, :team))
      |> maybe_search(Keyword.get(opts, :q))

    total = Repo.aggregate(query, :count)
    total_pages = max(ceil(total / per_page), 1)
    page = opts |> Keyword.get(:page, 1) |> max(1) |> min(total_pages)

    events =
      Repo.all(
        from e in query,
          order_by: [desc: e.occurred_at],
          limit: ^per_page,
          offset: ^((page - 1) * per_page),
          preload: :principal
      )

    %{events: events, page: page, per_page: per_page, total: total, total_pages: total_pages}
  end

  defp maybe_filter_topic(query, topic) when topic in [nil, ""], do: query
  defp maybe_filter_topic(query, topic), do: from(e in query, where: e.topic == ^topic)

  defp maybe_scope_to_team(query, nil), do: query
  defp maybe_scope_to_team(query, %Team{} = team), do: scope_to_team(query, team)

  defp scope_to_team(query, %Team{} = team) do
    from e in query,
      where:
        e.principal_id == ^team.id or
          fragment("?->>'team_id' = ?", e.details, ^team.id)
  end

  defp maybe_search(query, q) when q in [nil, ""], do: query

  defp maybe_search(query, q) do
    pattern = "%#{sanitize_like(q)}%"

    from e in query,
      left_join: p in assoc(e, :principal),
      where: ilike(e.event, ^pattern) or ilike(p.email, ^pattern)
  end

  # Escape LIKE metacharacters so a search for "50%" matches literally.
  defp sanitize_like(q) do
    String.replace(q, ~r/([\\%_])/, "\\\\\\1")
  end
end
