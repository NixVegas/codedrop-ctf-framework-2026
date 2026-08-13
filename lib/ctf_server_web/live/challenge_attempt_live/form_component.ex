defmodule CtfServerWeb.ChallengeAttemptLive.FormComponent do
  use CtfServerWeb, :live_component

  alias CtfServer.Challenges

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Use this form to manage challenge_attempt records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="challenge_attempt-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input
          field={@form[:group]}
          type="select"
          label="Group"
          prompt="Choose a group"
          options={@group_options}
        />
        <.input
          field={@form[:level]}
          type="select"
          label="Level"
          prompt="Choose a level"
          options={[1, 2, 3, 4]}
        />
        <.input field={@form[:earned_score]} type="number" label="Earned Points" />
        <.input
          field={@form[:status]}
          type="select"
          label="Status"
          prompt="Choose a value"
          options={Ecto.Enum.values(CtfServer.ChallengeAttempt, :status)}
        />
        <.input
          field={@form[:team_id]}
          type="select"
          label="Team"
          prompt="Choose a value"
          options={CtfServer.Teams.get_teams() |> Enum.map(&{&1.name, &1.id})}
        />
        <:actions>
          <.button phx-disable-with="Saving...">Save Challenge attempt</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{challenge_attempt: challenge_attempt} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:group_options, group_options())
     |> assign_new(:form, fn ->
       to_form(Challenges.change_challenge_attempt(challenge_attempt))
     end)}
  end

  # Derive the group dropdown from the live challenge catalog so a newly added
  # group (e.g. "erinyes") shows up without editing this form.
  defp group_options do
    Challenges.get_available_challenges()
    |> Enum.map(&CtfServer.Challenge.group/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @impl true
  def handle_event("validate", %{"challenge_attempt" => challenge_attempt_params}, socket) do
    changeset =
      Challenges.change_challenge_attempt(
        socket.assigns.challenge_attempt,
        challenge_attempt_params
      )

    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"challenge_attempt" => challenge_attempt_params}, socket) do
    save_challenge_attempt(socket, socket.assigns.action, challenge_attempt_params)
  end

  defp save_challenge_attempt(socket, :edit, challenge_attempt_params) do
    case Challenges.update_challenge_attempt(
           socket.assigns.challenge_attempt,
           challenge_attempt_params
         ) do
      {:ok, challenge_attempt} ->
        notify_parent({:saved, challenge_attempt})

        {:noreply,
         socket
         |> put_flash(:info, "Challenge attempt updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_challenge_attempt(socket, :new, challenge_attempt_params) do
    case Challenges.create_challenge_attempt(challenge_attempt_params) do
      {:ok, challenge_attempt} ->
        notify_parent({:saved, challenge_attempt})

        {:noreply,
         socket
         |> put_flash(:info, "Challenge attempt created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
