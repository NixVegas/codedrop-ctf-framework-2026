defmodule CtfServerWeb.TeamForgotPasswordLive do
  use CtfServerWeb, :live_view

  alias CtfServer.Accounts
  alias CtfServer.Locality
  alias CtfServer.RateLimiter

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm">
      <.header class="text-center">
        Forgot your password?
        <:subtitle>We'll send a password reset link to your inbox</:subtitle>
      </.header>

      <.simple_form for={@form} id="reset_password_form" phx-submit="send_email">
        <.input field={@form[:email]} type="email" placeholder="Email" required />
        <:actions>
          <.button phx-disable-with="Sending..." class="w-full">
            Send password reset instructions
          </.button>
        </:actions>
      </.simple_form>
      <p class="text-center text-sm mt-4">
        <.link href={~p"/teams/register"}>Register</.link>
        | <.link href={~p"/teams/log_in"}>Log in</.link>
      </p>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    # `connect_info` is only readable during mount, so resolve the client IP
    # once here for the rate limiter (see handle_event/3).
    client_ip = if connected?(socket), do: client_ip(socket), else: nil
    {:ok, assign(socket, form: to_form(%{}, as: "team"), client_ip: client_ip)}
  end

  def handle_event("send_email", %{"team" => %{"email" => email}}, socket) do
    # Always show the same message so the flow stays enumeration-safe, and rate
    # limit by client IP so it can't be used to blast reset emails (CWE-307).
    info =
      "If your email is in our system, you will receive instructions to reset your password shortly."

    case RateLimiter.check(:password_reset, socket.assigns.client_ip || "unknown") do
      {:allow, _count} ->
        if team = Accounts.get_team_by_email(email) do
          Accounts.deliver_team_reset_password_instructions(
            team,
            &url(~p"/teams/reset_password/#{&1}")
          )
        end

      {:deny, _retry_after} ->
        :ok
    end

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> redirect(to: ~p"/")}
  end

  # Only valid during mount; get_connect_info/2 raises afterwards.
  defp client_ip(socket) do
    info = %{
      x_headers: get_connect_info(socket, :x_headers) || [],
      peer_data: get_connect_info(socket, :peer_data)
    }

    case Locality.client_ip(info) do
      ip when is_tuple(ip) -> ip |> :inet.ntoa() |> to_string()
      _ -> nil
    end
  end
end
