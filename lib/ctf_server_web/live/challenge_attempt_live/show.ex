defmodule CtfServerWeb.ChallengeAttemptLive.Show do
  use CtfServerWeb, :live_view

  alias CtfServer.Challenges

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:challenge_attempt, Challenges.get_challenge_attempt!(id))}
  end

  defp page_title(:show), do: "Show Challenge attempt"
  defp page_title(:edit), do: "Edit Challenge attempt"
end
