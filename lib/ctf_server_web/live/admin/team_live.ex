defmodule CtfServerWeb.AdminTeamLive do
  use CtfServerWeb, :live_view

  alias CtfServer.Accounts
  alias CtfServer.Challenges
  alias CtfServerWeb.TeamAuth
  alias CtfUtils.PubSubUtils

  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@team.name}
        <:subtitle>{@team.email}</:subtitle>
        <:actions>
          <.link
            :if={is_nil(@team.confirmed_at)}
            phx-click="confirm"
            data-confirm={"Confirm #{@team.name}?"}
          >
            <.button>Confirm</.button>
          </.link>
          <.link
            phx-click="reset_code"
            data-confirm={"Generate a one-time password reset code for #{@team.name}?"}
          >
            <.button>Reset code</.button>
          </.link>
          <.link
            :if={is_nil(@team.disabled_at) and not @team.is_admin}
            phx-click="nuke"
            data-confirm={"Nuke #{@team.name}? This disables login, kicks their sessions, and kills their challenge instances."}
          >
            <.button class="!bg-red-700">Nuke</.button>
          </.link>
          <.link
            :if={@team.disabled_at}
            phx-click="enable_login"
            data-confirm={"Re-enable login for #{@team.name}?"}
          >
            <.button>Re-enable login</.button>
          </.link>
        </:actions>
      </.header>

      <.list>
        <:item title="Confirmed">{if @team.confirmed_at, do: "yes", else: "no"}</:item>
        <:item title="Admin">{if @team.is_admin, do: "yes", else: "no"}</:item>
        <:item title="Login">
          {if @team.disabled_at, do: "disabled since #{@team.disabled_at}", else: "enabled"}
        </:item>
        <:item title="Registered">{@team.inserted_at}</:item>
      </.list>

      <div
        :if={@reset_code}
        id="reset-code-panel"
        class="mt-8 rounded border border-zinc-300 bg-zinc-50 p-4"
      >
        <p class="font-bold text-zinc-900">
          One-time password reset link for {@team.name}:
        </p>
        <p class="mt-2 break-all font-mono text-sm text-zinc-900" id="reset-code-url">
          {@reset_code}
        </p>
        <p class="mt-2 text-sm text-zinc-700">
          Valid for 1 day and usable once. It is shown only here — copy it before leaving the page.
        </p>
      </div>

      <.header class="mt-12 text-left">Challenge attempts</.header>
      <p :if={@attempts == []} class="mt-4 text-zinc-600">
        No challenge attempts yet.
      </p>
      <.table :if={@attempts != []} id="attempts" rows={@attempts}>
        <:col :let={attempt} label="Challenge">{attempt.group} / {attempt.level}</:col>
        <:col :let={attempt} label="Status">{attempt.status}</:col>
        <:col :let={attempt} label="SSH port">{attempt.port || "—"}</:col>
        <:col :let={attempt} label="Score">{attempt.earned_score || "—"}</:col>
        <:col :let={attempt} label="Started">{attempt.inserted_at}</:col>
        <:col :let={attempt} label="Flag">
          <pre class="max-w-[16rem] overflow-x-auto rounded bg-zinc-50 px-2 py-1 font-mono text-xs">{format_flag(attempt.flag)}</pre>
        </:col>
        <:action :let={attempt}>
          <.link
            :if={attempt.status == :started}
            phx-click="pause_instance"
            phx-value-id={attempt.id}
            data-confirm={"Pause the VM for #{attempt.group}/#{attempt.level}? It powers off (freeing resources) but keeps its disk and port so it can be resumed."}
          >
            Pause
          </.link>
          <.link
            :if={attempt.status == :paused}
            phx-click="resume_instance"
            phx-value-id={attempt.id}
            data-confirm={"Resume the VM for #{attempt.group}/#{attempt.level}?"}
          >
            Resume
          </.link>
        </:action>
        <:action :let={attempt}>
          <.link
            :if={attempt.status in [:started, :paused]}
            phx-click="rebuild_instance"
            phx-value-id={attempt.id}
            data-confirm={"Rebuild the VM for #{attempt.group}/#{attempt.level} from a clean image? In-VM changes are lost; the flag is unchanged."}
          >
            Rebuild
          </.link>
        </:action>
        <:action :let={attempt}>
          <.link
            :if={attempt.status in [:provisioning, :started, :paused]}
            phx-click="force_shutdown"
            phx-value-id={attempt.id}
            data-confirm={"Force shutdown the VM for #{attempt.group}/#{attempt.level}? The team will not be able to restart it."}
          >
            Force shutdown
          </.link>
        </:action>
        <:action :let={attempt}>
          <.link
            :if={attempt.status in [:provisioning, :started, :paused, :completed]}
            phx-click="reset_instance"
            phx-value-id={attempt.id}
            data-confirm={"Reset #{attempt.group}/#{attempt.level}? Any running VM is destroyed and the attempt is removed (including a recorded completion and its score), so the team can start over."}
          >
            Reset
          </.link>
        </:action>
      </.table>

      <.header class="mt-12 text-left">Audit events</.header>
      <p class="mt-4">
        <.link navigate={~p"/admin/audit?team=#{@team.id}"} class="font-semibold underline">
          View this team's audit trail →
        </.link>
      </p>

      <.back navigate={~p"/admin/teams"}>Back to teams</.back>
    </div>
    """
  end

  def mount(%{"id" => id}, _session, socket) do
    case CtfServer.Repo.get(Accounts.Team, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Team not found.")
         |> push_navigate(to: ~p"/admin/teams")}

      team ->
        if connected?(socket), do: :ok = PubSubUtils.sub_team_updates(team.id)

        {:ok,
         socket
         |> assign(page_title: team.name, reset_code: nil)
         |> assign(team: team)
         |> refresh()}
    end
  end

  def handle_event("confirm", _params, socket) do
    {:ok, team} = Accounts.admin_confirm_team(socket.assigns.team, socket.assigns.current_team)

    {:noreply,
     socket
     |> put_flash(:info, "Team #{team.name} confirmed.")
     |> assign(team: team)
     |> refresh()}
  end

  def handle_event("reset_code", _params, socket) do
    code =
      Accounts.generate_team_reset_password_code(
        socket.assigns.team,
        socket.assigns.current_team
      )

    {:noreply,
     socket
     |> assign(reset_code: url(~p"/teams/reset_password/#{code}"))
     |> refresh()}
  end

  def handle_event("nuke", _params, socket) do
    team = socket.assigns.team

    if team.is_admin do
      {:noreply, put_flash(socket, :error, "Admin accounts cannot be nuked.")}
    else
      {:ok, team, session_tokens} =
        Accounts.disable_team_login(team, socket.assigns.current_team)

      TeamAuth.disconnect_team_sessions(session_tokens)
      {:ok, killed} = Challenges.kill_active_attempts_for_team(team, socket.assigns.current_team)

      {:noreply,
       socket
       |> put_flash(
         :info,
         "Team #{team.name} nuked: login disabled, #{length(session_tokens)} session(s) kicked, #{length(killed)} instance(s) shut down."
       )
       |> assign(team: team)
       |> refresh()}
    end
  end

  def handle_event("enable_login", _params, socket) do
    {:ok, team} = Accounts.enable_team_login(socket.assigns.team, socket.assigns.current_team)

    {:noreply,
     socket
     |> put_flash(:info, "Login re-enabled for #{team.name}.")
     |> assign(team: team)
     |> refresh()}
  end

  def handle_event("force_shutdown", %{"id" => id}, socket) do
    attempt = Challenges.get_challenge_attempt!(id)

    {:ok, attempt} = Challenges.force_shutdown_attempt(attempt, socket.assigns.current_team)

    {:noreply,
     socket
     |> put_flash(:info, "Shutting down #{attempt.group}/#{attempt.level}.")
     |> refresh()}
  end

  def handle_event("reset_instance", %{"id" => id}, socket) do
    attempt = Challenges.get_challenge_attempt!(id)

    {:ok, attempt} =
      Challenges.reset_challenge_attempt_instance(attempt, socket.assigns.current_team)

    {:noreply,
     socket
     |> put_flash(:info, "Resetting #{attempt.group}/#{attempt.level}.")
     |> refresh()}
  end

  def handle_event("pause_instance", %{"id" => id}, socket) do
    attempt = Challenges.get_challenge_attempt!(id)

    case Challenges.pause_challenge_attempt(attempt, socket.assigns.current_team) do
      {:ok, attempt} ->
        {:noreply,
         socket |> put_flash(:info, "Pausing #{attempt.group}/#{attempt.level}.") |> refresh()}

      {:error, :invalid_state} ->
        {:noreply, put_flash(socket, :error, "That instance can't be paused right now.")}
    end
  end

  def handle_event("resume_instance", %{"id" => id}, socket) do
    attempt = Challenges.get_challenge_attempt!(id)

    case Challenges.resume_challenge_attempt(attempt, socket.assigns.current_team) do
      {:ok, attempt} ->
        {:noreply,
         socket |> put_flash(:info, "Resuming #{attempt.group}/#{attempt.level}.") |> refresh()}

      {:error, :vm_limit_reached} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The team is at its #{Challenges.max_vms_per_team()}-VM running limit; pause or tear one down first."
         )}

      {:error, :invalid_state} ->
        {:noreply, put_flash(socket, :error, "That instance can't be resumed right now.")}
    end
  end

  def handle_event("rebuild_instance", %{"id" => id}, socket) do
    attempt = Challenges.get_challenge_attempt!(id)

    {:ok, attempt} = Challenges.rebuild_challenge_attempt(attempt, socket.assigns.current_team)

    {:noreply,
     socket
     |> put_flash(:info, "Rebuilding #{attempt.group}/#{attempt.level}.")
     |> refresh()}
  end

  def handle_info({:attempt_updated, _attempt_id}, socket) do
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    assign(socket, attempts: Challenges.list_attempts_for_team(socket.assigns.team))
  end

  # The attempt's answer-key blob (a JSON map), pretty-printed for the admin
  # table. Tolerates a nil flag and, defensively, a legacy plain string.
  defp format_flag(nil), do: "—"
  defp format_flag(map) when is_map(map), do: Jason.encode!(map, pretty: true)
  defp format_flag(other), do: to_string(other)
end
