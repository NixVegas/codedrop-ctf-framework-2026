defmodule CtfServerWeb.AdminTeamsLive do
  use CtfServerWeb, :live_view

  alias CtfServer.Accounts
  alias CtfServer.Accounts.Team

  def render(assigns) do
    ~H"""
    <div>
      <.header>
        Team management
        <:subtitle>Register teams, confirm accounts, and hand out password reset codes.</:subtitle>
      </.header>

      <div class="mt-8 max-w-sm">
        <.header class="text-left">Register a team</.header>

        <.simple_form
          for={@form}
          id="admin_registration_form"
          phx-submit="create"
          phx-change="validate"
        >
          <.error :if={@check_errors}>
            Oops, something went wrong! Please check the errors below.
          </.error>

          <.input field={@form[:name]} type="text" label="Name" required />
          <.input field={@form[:email]} type="email" label="Email" required />
          <.input field={@form[:password]} type="password" label="Password" required />

          <:actions>
            <.button phx-disable-with="Creating team..." class="w-full">Create team</.button>
          </:actions>
        </.simple_form>
      </div>

      <div
        :if={@reset_code}
        id="reset-code-panel"
        class="mt-8 rounded border border-zinc-300 bg-zinc-50 p-4"
      >
        <p class="font-semibold">
          One-time password reset link for {@reset_code.team.name} ({@reset_code.team.email}):
        </p>
        <p class="mt-2 break-all font-mono text-sm" id="reset-code-url">
          {@reset_code.url}
        </p>
        <p class="mt-2 text-sm text-zinc-600">
          Valid for 1 day and usable once. It is shown only here — copy it before leaving the page.
        </p>
      </div>

      <.table
        id="teams"
        rows={@teams}
        row_id={&"teams-#{&1.id}"}
        row_click={fn team -> JS.navigate(~p"/admin/teams/#{team}") end}
      >
        <:col :let={team} label="Name">{team.name}</:col>
        <:col :let={team} label="Email">{team.email}</:col>
        <:col :let={team} label="Confirmed">{if team.confirmed_at, do: "yes", else: "no"}</:col>
        <:col :let={team} label="Admin">{if team.is_admin, do: "yes", else: "no"}</:col>
        <:col :let={team} label="Login">{if team.disabled_at, do: "disabled", else: "enabled"}</:col>
        <:action :let={team}>
          <.link
            :if={is_nil(team.confirmed_at)}
            phx-click="confirm"
            phx-value-id={team.id}
            data-confirm={"Confirm #{team.name}?"}
          >
            Confirm
          </.link>
        </:action>
        <:action :let={team}>
          <.link
            phx-click="reset_code"
            phx-value-id={team.id}
            data-confirm={"Generate a one-time password reset code for #{team.name}?"}
          >
            Reset code
          </.link>
        </:action>
      </.table>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Team management", check_errors: false, reset_code: nil)
      |> assign(teams: Accounts.list_teams())
      |> assign_form(Accounts.change_team_registration(%Team{}))

    {:ok, socket}
  end

  def handle_event("validate", %{"team" => team_params}, socket) do
    changeset = Accounts.change_team_registration(%Team{}, team_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("create", %{"team" => team_params}, socket) do
    case Accounts.admin_register_team(team_params, socket.assigns.current_team) do
      {:ok, team} ->
        socket =
          socket
          |> put_flash(:info, "Team #{team.name} registered and confirmed.")
          |> assign(teams: Accounts.list_teams())
          |> assign_form(Accounts.change_team_registration(%Team{}))

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign(check_errors: true) |> assign_form(changeset)}
    end
  end

  def handle_event("confirm", %{"id" => id}, socket) do
    {:ok, team} = Accounts.admin_confirm_team(Accounts.get_team!(id), socket.assigns.current_team)

    socket =
      socket
      |> put_flash(:info, "Team #{team.name} confirmed.")
      |> assign(teams: Accounts.list_teams())

    {:noreply, socket}
  end

  def handle_event("reset_code", %{"id" => id}, socket) do
    team = Accounts.get_team!(id)
    code = Accounts.generate_team_reset_password_code(team, socket.assigns.current_team)

    reset_code = %{team: team, url: url(~p"/teams/reset_password/#{code}")}
    {:noreply, assign(socket, reset_code: reset_code)}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "team")

    if changeset.valid? do
      assign(socket, form: form, check_errors: false)
    else
      assign(socket, form: form)
    end
  end
end
