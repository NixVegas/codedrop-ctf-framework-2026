defmodule CtfServerWeb.ChallengeAttemptLive.Index do
  use CtfServerWeb, :live_view

  alias CtfServer.Challenges
  alias CtfServer.ChallengeAttempt

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :challenge_attempt_collection, Challenges.list_challenge_attempt())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Challenge attempt")
    |> assign(:challenge_attempt, Challenges.get_challenge_attempt!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Challenge attempt")
    |> assign(:challenge_attempt, %ChallengeAttempt{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Challenge attempt")
    |> assign(:challenge_attempt, nil)
  end

  @impl true
  def handle_info(
        {CtfServerWeb.ChallengeAttemptLive.FormComponent, {:saved, challenge_attempt}},
        socket
      ) do
    # The row template renders team.name, so preload :team before (re)streaming.
    challenge_attempt = CtfServer.Repo.preload(challenge_attempt, :team)
    {:noreply, stream_insert(socket, :challenge_attempt_collection, challenge_attempt)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    challenge_attempt = Challenges.get_challenge_attempt!(id)
    {:ok, _} = Challenges.delete_challenge_attempt(challenge_attempt)

    {:noreply, stream_delete(socket, :challenge_attempt_collection, challenge_attempt)}
  end
end
