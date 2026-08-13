defmodule CtfServerWeb.TeamRegistrationLive do
  use CtfServerWeb, :live_view

  alias CtfServer.Accounts
  alias CtfServer.Accounts.Team
  alias CtfServer.Locality
  alias CtfServer.RateLimiter
  alias CtfServerWeb.CompetitionGate

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm">
      <.header class="text-center">
        Register for an account
        <:subtitle>
          Already registered?
          <.link navigate={~p"/teams/log_in"} class="font-semibold hover:underline">
            Log in
          </.link>
          to your account now.
        </:subtitle>
      </.header>

      <.simple_form
        :if={@competition_phase == :during}
        for={@form}
        id="registration_form"
        phx-submit="save"
        phx-change="validate"
        phx-trigger-action={@trigger_submit}
        action={~p"/teams/log_in?_action=registered"}
        method="post"
      >
        <.error :if={@check_errors}>
          Oops, something went wrong! Please check the errors below.
        </.error>

        <.input field={@form[:name]} type="text" label="Name" required />
        <.input field={@form[:email]} type="email" label="Email" required />
        <.input field={@form[:password]} type="password" label="Password" required />

        <.input
          :if={@require_code? and not @local?}
          type="text"
          name="team[invite_code]"
          id="team_invite_code"
          value={@invite_code}
          label="Invite code"
        />

        <:actions>
          <.button phx-disable-with="Creating account..." class="w-full">Create an account</.button>
        </:actions>
      </.simple_form>

      <div :if={@competition_phase != :during} class="text-center">
        Registration is closed.
      </div>
    </div>
    """
  end

  def mount(_params, session, socket) do
    changeset = Accounts.change_team_registration(%Team{})
    socket = CompetitionGate.on_mount(socket)

    # `connect_info` is only readable during mount (it raises afterwards), so
    # locality and the client IP are resolved once here and cached in assigns.
    # Every `handle_event` runs over an already-connected socket, so by the
    # time "save" fires, mount has already recomputed these from the real
    # connect_info. The client cannot influence them.
    {local?, client_ip} =
      if connected?(socket) do
        client_locality(socket)
      else
        {Map.get(session, "client_local", false), nil}
      end

    socket =
      socket
      |> assign(trigger_submit: false, check_errors: false, invite_code: "")
      |> assign(
        local?: local?,
        client_ip: client_ip,
        require_code?: Accounts.require_invite_codes?()
      )
      |> assign_form(changeset)

    {:ok, socket, temporary_assigns: [form: nil]}
  end

  def handle_info(:competition_refresh, socket) do
    {:noreply, CompetitionGate.refresh(socket)}
  end

  # Before this module defined any handle_info/2, LiveView silently dropped
  # unmatched messages (e.g. the test mailer delivering `{:email, _}` to
  # self()). Defining handle_info/2 above opts out of that leniency, so keep
  # the same behavior explicitly for anything that isn't ours.
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  def handle_event("save", %{"team" => team_params}, socket) do
    opts = [local?: socket.assigns.local?, client_ip: socket.assigns.client_ip]

    case RateLimiter.check(:register, socket.assigns.client_ip || "unknown") do
      {:deny, _retry_after} ->
        {:noreply,
         socket
         |> assign(check_errors: true)
         |> put_flash(:error, "Too many attempts. Please wait a moment and try again.")}

      {:allow, _count} ->
        save_team(socket, team_params, opts)
    end
  end

  def handle_event("validate", %{"team" => team_params}, socket) do
    changeset = Accounts.change_team_registration(%Team{}, team_params)

    {:noreply,
     socket
     |> assign(invite_code: Map.get(team_params, "invite_code", ""))
     |> assign_form(Map.put(changeset, :action, :validate))}
  end

  defp save_team(socket, team_params, opts) do
    case Accounts.register_team(team_params, opts) do
      {:ok, team} ->
        unless Accounts.skip_account_confirmation?() do
          {:ok, _} =
            Accounts.deliver_team_confirmation_instructions(
              team,
              &url(~p"/teams/confirm/#{&1}")
            )
        end

        changeset = Accounts.change_team_registration(team)
        {:noreply, socket |> assign(trigger_submit: true) |> assign_form(changeset)}

      {:error, :invalid_invite_code} ->
        {:noreply,
         socket
         |> assign(check_errors: true)
         |> put_flash(:error, "That invite code is not valid or has already been used.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign(check_errors: true) |> assign_form(changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "team")

    if changeset.valid? do
      assign(socket, form: form, check_errors: false)
    else
      assign(socket, form: form)
    end
  end

  # Only valid to call during mount. `get_connect_info/2` raises once the
  # LiveView has finished mounting.
  defp client_locality(socket) do
    info = %{
      x_headers: get_connect_info(socket, :x_headers) || [],
      peer_data: get_connect_info(socket, :peer_data)
    }

    ip = Locality.client_ip(info)
    {Locality.local?(ip), ip_to_string(ip)}
  end

  defp ip_to_string(nil), do: nil
  defp ip_to_string(ip), do: ip |> :inet.ntoa() |> to_string()
end
