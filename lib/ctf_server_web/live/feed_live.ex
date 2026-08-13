defmodule CtfServerWeb.FeedLive do
  @moduledoc """
  The live activity feed, in two flavours from one implementation.

  `/feed` is public and meant for a projector; `/admin/feed` is the same list
  with the rejection reason attached. The detail level is decided here from the
  route, never from anything the client sends.

  Neither flavour can render a submitted flag: `CtfServer.Feed` builds its
  entries from an allowlist and never reads that field.
  """
  use CtfServerWeb, :live_view

  alias CtfServer.Feed
  alias CtfServerWeb.CompetitionGate
  alias CtfUtils.PubSubUtils

  @limit 60

  def render(assigns) do
    ~H"""
    <div>
      <.header>
        Activity
        <:subtitle>
          {if @detail == :admin,
            do: "Live challenge activity, with rejection reasons.",
            else: "Live challenge activity."}
        </:subtitle>
      </.header>

      <p :if={not @visible} class="mt-6">
        The competition has not started yet.
      </p>

      <p :if={@visible and @entries == []} class="mt-6 text-zinc-600">
        Nothing yet. Activity appears here as teams start challenges and capture flags.
      </p>

      <ul :if={@visible} id="feed-entries" class="mt-6 divide-y divide-zinc-200">
        <li :for={entry <- @entries} id={"feed-#{entry.id}"} class="flex items-baseline gap-3 py-2">
          <time class="w-20 shrink-0 font-mono text-xs text-zinc-600">
            {format_time(entry.at)}
          </time>
          <span class={["w-20 shrink-0 text-sm font-semibold", kind_class(entry.kind)]}>
            {kind_label(entry.kind)}
          </span>
          <span class="min-w-0 flex-1">
            <span class="font-semibold">{entry.team || "—"}</span>
            <span class="text-zinc-600">
              {challenge_label(entry)}
            </span>
            <span :if={entry.score} class="text-zinc-600">· {entry.score} pts</span>
            <span :if={@detail == :admin and Map.get(entry, :reason)} class="text-zinc-500">
              · {entry.reason}
            </span>
          </span>
        </li>
      </ul>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = PubSubUtils.sub_feed()

    detail = detail_for(socket)

    socket =
      socket
      |> CompetitionGate.on_mount()
      |> assign(:detail, detail)
      |> assign(:page_title, "Activity")
      |> load()

    {:ok, socket}
  end

  def handle_info(:feed_activity, socket), do: {:noreply, load(socket)}

  def handle_info(:competition_refresh, socket) do
    {:noreply, socket |> CompetitionGate.refresh() |> load()}
  end

  # Admins see the feed before the competition opens; everyone else waits, so a
  # public page can't be used to watch staff smoke-testing challenges.
  defp load(socket) do
    visible = visible?(socket.assigns)

    entries =
      if visible do
        Feed.recent(limit: @limit, detail: socket.assigns.detail)
      else
        []
      end

    socket |> assign(:visible, visible) |> assign(:entries, entries)
  end

  defp visible?(assigns) do
    assigns.competition_phase in [:during, :after] or admin?(assigns)
  end

  defp admin?(%{current_team: %{is_admin: true}}), do: true
  defp admin?(_assigns), do: false

  defp detail_for(socket) do
    if socket.assigns[:live_action] == :admin and admin?(socket.assigns),
      do: :admin,
      else: :public
  end

  defp challenge_label(%{group: group, level: level})
       when is_binary(group) and not is_nil(level) do
    "#{CtfServer.Track.title(group)} #{level}"
  end

  defp challenge_label(_entry), do: ""

  defp kind_label(:started), do: "started"
  defp kind_label(:captured), do: "captured"
  defp kind_label(:missed), do: "missed"

  defp kind_class(:captured), do: "text-green-700"
  defp kind_class(:missed), do: "text-amber-700"
  defp kind_class(:started), do: "text-zinc-600"

  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M:%S")
end
