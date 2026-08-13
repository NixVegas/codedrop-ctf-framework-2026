defmodule CtfServerWeb.LeaderboardLive do
  use CtfServerWeb, :live_view

  alias CtfServer.ScoreboardCache
  alias CtfServerWeb.CompetitionGate
  alias CtfUtils.PubSubUtils

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl">
      <.header>Leaderboard</.header>

      <div :if={visible?(assigns)}>
        <%!-- phx-update="ignore" keeps LiveView out of the SVG Vega renders into;
              the data-spec attribute is still patched, which is what wakes the hook. --%>
        <div
          :if={@chart_spec}
          id="scoreboard-chart"
          phx-hook="VegaChart"
          phx-update="ignore"
          data-spec={@chart_spec}
          class="mt-6"
        />

        <.table id="team-rankings-table" rows={@teams}>
          <:col :let={team} label="Team Name">{team.name}</:col>
          <:col :let={team} label="Score">{team.current_score}</:col>
        </.table>
      </div>

      <div :if={not visible?(assigns)} class="text-center">
        The competition has not started yet.
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    # The throttled scoreboard topic, not the raw per-capture one: the cache
    # absorbs the storm and tells us when there is something new to draw.
    if connected?(socket), do: :ok = PubSubUtils.sub_scoreboard()

    socket = CompetitionGate.on_mount(socket)
    {:ok, load(socket)}
  end

  def handle_info(:scoreboard_refreshed, socket) do
    {:noreply, load(socket)}
  end

  def handle_info(:competition_refresh, socket) do
    {:noreply, CompetitionGate.refresh(socket)}
  end

  defp visible?(assigns),
    do: assigns.competition_phase in [:during, :after] or admin?(assigns)

  defp admin?(%{current_team: %{is_admin: true}}), do: true
  defp admin?(_), do: false

  # Both come from the shared cache: this process does no scoreboard query or
  # JSON encoding of its own, however many leaderboards are open.
  defp load(socket) do
    team_id = socket.assigns[:current_team] && socket.assigns.current_team.id

    socket
    |> assign(:teams, ScoreboardCache.standings())
    |> assign(:chart_spec, ScoreboardCache.spec_for(team_id))
  end
end
