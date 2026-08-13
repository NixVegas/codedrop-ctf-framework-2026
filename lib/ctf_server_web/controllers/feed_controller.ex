defmodule CtfServerWeb.FeedController do
  @moduledoc """
  A scrapable JSON view of the activity feed.

  Public and unauthenticated by design — it is the machine-readable twin of
  `/feed`, for dashboards, bots, and anything else that wants to watch the CTF
  without holding a websocket open.

  Always `:public` detail: rejection reasons stay in the admin LiveView, and
  submitted flags are never exposed anywhere (see `CtfServer.Feed`).
  """
  use CtfServerWeb, :controller

  alias CtfServer.Competition
  alias CtfServer.Feed

  def index(conn, params) do
    if Competition.scoreboard_visible?() do
      entries = Feed.recent(limit: limit(params), detail: :public)

      json(conn, %{
        entries: Enum.map(entries, &render_entry/1),
        count: length(entries),
        max_limit: Feed.max_limit()
      })
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{error: "the competition has not started yet", entries: []})
    end
  end

  # Unparseable or absent limits fall back to the default rather than erroring:
  # this is a scraping endpoint, and a 500 on a typo helps nobody.
  defp limit(%{"limit" => raw}) when is_binary(raw) do
    case Integer.parse(raw) do
      {limit, _rest} -> limit
      :error -> nil
    end
  end

  defp limit(_params), do: nil

  defp render_entry(entry) do
    %{
      id: entry.id,
      at: entry.at,
      kind: entry.kind,
      team: entry.team,
      challenge: challenge(entry),
      group: entry.group,
      level: entry.level,
      score: entry.score
    }
  end

  defp challenge(%{group: group, level: level}) when is_binary(group) and not is_nil(level) do
    "#{group}/#{level}"
  end

  defp challenge(_entry), do: nil
end
