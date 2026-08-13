defmodule CtfServer.Feed do
  @moduledoc """
  The live activity feed: challenges started, flags captured, submissions missed.

  Reads the same `audit_events` the admin audit log does, but exposes a narrow,
  deliberately sanitized view of them.

  ## What is never exposed

  `submit_flag` and `submit_flag_failed` audit details include the **raw
  submitted flag**. Nothing here ever reads that field, at any detail level.
  Flags are per-team (an HMAC of the team id), so a leaked one wouldn't score
  for anyone else — but publishing what teams type into the flag box is not
  something a public endpoint should do, and the event runs on a hostile
  network. `submit_flag` itself is skipped outright: every submission is either
  a `complete` or a `submit_flag_failed`, so including it would double-count.

  ## Detail levels

  * `:public` — kind, team name, challenge, score. Safe for the projector and
    for the JSON endpoint.
  * `:admin` — adds the rejection reason (`"incorrect"` / `"malformed"`), which
    tells staff whether a team is close or fumbling the format. Still no flag.
  """

  import Ecto.Query, warn: false

  alias CtfServer.Audit.Event
  alias CtfServer.Repo

  @default_limit 50
  @max_limit 200

  # The audit events that constitute "activity". Anything else — auth, account,
  # admin actions — stays out of the feed.
  @kinds %{
    "start" => :started,
    "complete" => :captured,
    "submit_flag_failed" => :missed
  }

  @doc """
  The most recent activity, newest first.

  ## Options

    * `:limit` — how many entries (default #{@default_limit}, capped at #{@max_limit})
    * `:detail` — `:public` (default) or `:admin`
  """
  def recent(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()
    detail = Keyword.get(opts, :detail, :public)
    events = Map.keys(@kinds)

    from(e in Event,
      where: e.topic == "challenge" and e.event in ^events,
      order_by: [desc: e.occurred_at, desc: e.id],
      limit: ^limit,
      preload: :principal
    )
    |> Repo.all()
    |> Enum.map(&entry(&1, detail))
  end

  @doc "The largest `:limit` the feed will serve."
  def max_limit, do: @max_limit

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)
  defp clamp_limit(_limit), do: @default_limit

  # Built field by field from `details` rather than by dropping keys from it:
  # an allowlist can't leak a field a future audit event starts recording.
  defp entry(%Event{} = event, detail) do
    entry = %{
      id: event.id,
      at: event.occurred_at,
      kind: Map.fetch!(@kinds, event.event),
      team: event.principal && event.principal.name,
      group: event.details["group"],
      level: event.details["level"],
      score: event.details["score"]
    }

    case detail do
      :admin -> Map.put(entry, :reason, event.details["reason"])
      :public -> entry
    end
  end
end
