defmodule CtfServerWeb.TeamDashboardLive do
  alias CtfServer.Challenge
  alias CtfServer.Challenges
  alias CtfServer.Track
  alias CtfServerWeb.CompetitionGate
  alias CtfUtils.PubSubUtils
  use CtfServerWeb, :live_view

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl">
      <.header>
        Dashboard
        <:subtitle>{@current_team.name}</:subtitle>
      </.header>

      <h2 class="mt-10 text-lg font-semibold">Challenges</h2>

      <div :if={visible?(assigns)}>
        <section :for={{group, challenges} <- @groups} class="mt-6">
          <h3 class="font-semibold">{Track.title(group)}</h3>
          <p :if={Track.blurb(group)} class="mb-2 text-sm text-zinc-500">{Track.blurb(group)}</p>
          <ul class="divide-y divide-zinc-200 border border-zinc-200 rounded">
            <li :for={c <- challenges}>
              <.link
                patch={~p"/challenge/#{c.group}/#{c.level}"}
                class="flex items-center justify-between gap-4 px-4 py-3 hover:bg-zinc-50"
              >
                <span>
                  <span class="text-zinc-400">Level {c.level}</span>
                  <span :if={c.name} class="ml-2">{c.name}</span>
                </span>
                <.status status={c.status} />
              </.link>
            </li>
          </ul>
        </section>
      </div>

      <div :if={not visible?(assigns)} class="text-center">
        <p>{holding_message(@competition_phase)}</p>
        <.link
          :if={@competition_phase == :after}
          navigate={~p"/leaderboard"}
          class="font-semibold hover:underline"
        >
          View the leaderboard
        </.link>
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    case socket.assigns.current_team do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Not logged in to team!")
         |> push_navigate(to: ~p"/")}

      team ->
        if connected?(socket), do: :ok = PubSubUtils.sub_team_updates(team.id)

        socket = CompetitionGate.on_mount(socket)

        {:ok,
         socket
         |> assign(current_team: team)
         |> setup_progress()}
    end
  end

  defp setup_progress(socket) do
    team = socket.assigns.current_team |> CtfServer.Repo.preload(:challenge_attempts)

    # One pass over the available challenges for their names; looking each one
    # up individually would rescan :code.all_available/0 per row.
    names =
      Challenges.get_available_challenges()
      |> Map.new(fn c -> {{Challenge.group(c), Challenge.level(c)}, Challenge.name(c)} end)

    groups =
      Challenges.get_challenge_progress_for_team(team)
      |> Enum.map(fn {{group, level}, v} ->
        %{group: group, level: level, status: v.status, name: Map.get(names, {group, level})}
      end)
      |> Enum.sort_by(&{Track.order(&1.group), &1.group, &1.level})
      |> Enum.group_by(& &1.group)
      |> Enum.sort_by(fn {group, _} -> {Track.order(group), group} end)

    assign(socket, :groups, groups)
  end

  def handle_info({:attempt_updated, _attempt_id}, socket) do
    {:noreply, socket |> setup_progress()}
  end

  def handle_info(:competition_refresh, socket) do
    {:noreply, CompetitionGate.refresh(socket)}
  end

  defp visible?(assigns), do: assigns.competition_phase == :during or admin?(assigns)

  defp admin?(%{current_team: %{is_admin: true}}), do: true
  defp admin?(_), do: false

  defp holding_message(:before), do: "The competition has not started yet."
  defp holding_message(:after), do: "The competition is over."
end
