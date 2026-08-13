defmodule CtfServerWeb.ChallengeLive do
  use CtfServerWeb, :live_view

  alias CtfServer.Challenge
  alias CtfServer.ChallengeAttempt
  alias CtfServer.Challenges
  alias CtfServer.Competition
  alias CtfServer.Track
  alias CtfServerWeb.CompetitionGate
  alias CtfUtils.PubSubUtils

  def mount(_params, _session, socket) do
    if connected?(socket) and socket.assigns.current_team do
      :ok = PubSubUtils.sub_team_updates(socket.assigns.current_team.id)
    end

    socket = CompetitionGate.on_mount(socket)

    {:ok, assign(socket, :challenge, nil)}
  end

  def handle_params(%{"group" => raw_group, "level" => raw_level}, _, socket)
      when is_binary(raw_group) and is_binary(raw_group) and raw_group != "" and raw_level != "" do
    with {level, ""} <- Integer.parse(raw_level, 10),
         {:ok, challenge} <- Challenges.get_challenge_by_group_and_level(raw_group, level) do
      team = socket.assigns.current_team
      form = to_form(%{"flag" => ""}, as: "flag")

      {:ok, html_doc, _deprecation_messages} =
        Challenge.description(challenge) |> Earmark.as_html()

      challenge_attempt =
        case Challenges.get_challenge_attempt_for_team(
               team,
               Challenge.group(challenge),
               Challenge.level(challenge)
             ) do
          {:ok, attempt} -> attempt
          {:error, :not_found} -> nil
        end

      {:noreply,
       socket
       |> assign(:page_title, "")
       |> assign(:challenge, challenge)
       |> assign(:challenge_attempt, challenge_attempt)
       |> assign(:challenge_name, Challenge.name(challenge))
       |> assign(:challenge_group, Challenge.group(challenge))
       |> assign(:challenge_level, Challenge.level(challenge))
       |> assign(:challenge_value, Challenge.max_score(challenge))
       |> assign(:challenge_description, html_doc)
       |> assign(:needs_vm, Challenges.needs_vm?(challenge))
       |> assign(:form, form)}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to find challenge.")
         |> push_navigate(to: ~p"/")}
    end
  end

  def handle_params(_params, _, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Unable to find challenge.")
     |> push_navigate(to: ~p"/")}
  end

  def handle_event("start_challenge", %{}, socket) do
    challenge = socket.assigns.challenge
    challenge_attempt = socket.assigns.challenge_attempt
    team = socket.assigns.current_team

    if is_nil(challenge_attempt) do
      # No challenge attempt in progress, so let's start one
      case Challenges.start_challenge_attempt(
             team,
             Challenge.group(challenge),
             Challenge.level(challenge)
           ) do
        {:ok, attempt} ->
          {:noreply,
           socket
           |> put_flash(:info, "Starting challenge!")
           |> assign(:challenge_attempt, attempt)}

        {:error, :vm_limit_reached} ->
          {:noreply, put_flash(socket, :error, vm_limit_message())}

        {:error, :already_in_progress} ->
          {:noreply,
           socket |> put_flash(:error, "Can't start a new attempt when one is in progress!")}

        {:error, :competition_closed} ->
          {:noreply, put_flash(socket, :error, "The competition is closed.")}
      end
    else
      {:noreply,
       socket |> put_flash(:error, "Can't start a new attempt when one is in progress!")}
    end
  end

  def handle_event("pause_instance", _params, socket) do
    lifecycle(socket, &Challenges.pause_challenge_attempt/1, "Pausing your VM…")
  end

  def handle_event("resume_instance", _params, socket) do
    lifecycle(socket, &Challenges.resume_challenge_attempt/1, "Resuming your VM…")
  end

  def handle_event("rebuild_instance", _params, socket) do
    lifecycle(
      socket,
      &Challenges.rebuild_challenge_attempt/1,
      "Rebuilding your VM from a clean image…"
    )
  end

  def handle_event("teardown_instance", _params, socket) do
    lifecycle(socket, &Challenges.teardown_challenge_attempt/1, "Tearing down your VM…")
  end

  def handle_event("attempt_capture", %{"flag" => %{"flag" => flag}}, socket) do
    if not Competition.challenges_open?() and not admin?(socket) do
      {:noreply, put_flash(socket, :error, "The competition is closed.")}
    else
      challenge = socket.assigns.challenge
      team = socket.assigns.current_team
      flag = String.trim(flag)
      group = Challenge.group(challenge)
      level = Challenge.level(challenge)

      CtfServer.Audit.submit_flag(team, group, level, flag)

      # The wrapper prefix is accepted case-insensitively (Nix{...} or nix{...}).
      if String.starts_with?(String.downcase(flag), "nix{") and String.ends_with?(flag, "}") do
        unwrapped_flag = flag |> String.slice(4..-2//1)

        case Challenge.score_challenge_attempt(challenge, team, unwrapped_flag) do
          {:ok, score} ->
            :ok = Challenges.complete_challenge_attempt(challenge, team, score)

            {:noreply,
             socket
             |> push_navigate(to: ~p"/dashboard")
             |> put_flash(:info, capture_flash(challenge, team, score))}

          {:error, _reason} ->
            CtfServer.Audit.submit_flag_failed(team, group, level, flag, "incorrect")

            {
              :noreply,
              socket
              |> put_flash(:error, "Flag incorrect!")
            }
        end
      else
        CtfServer.Audit.submit_flag_failed(team, group, level, flag, "malformed")

        {:noreply,
         socket
         |> put_flash(:error, "Flag must be in Nix{<flag>} form!")}
      end
    end
  end

  # The capture flash: the score line, plus an optional per-challenge message
  # (the CtfServer.CompletionMessage protocol) — score-aware, so a challenge can
  # nudge a partial finish or congratulate a full one. Challenges without an impl
  # fall back to nil (just the score line).
  defp capture_flash(challenge, team, score) do
    base = "Flag captured for #{score} points!"

    case CtfServer.CompletionMessage.message(challenge, team, score) do
      note when is_binary(note) and note != "" -> base <> " " <> note
      _ -> base
    end
  end

  # Runs a self-service lifecycle action (pause/resume/rebuild/teardown) on the
  # team's own current attempt and flashes the outcome. The attempt is scoped to
  # the current team, so a team can only ever act on its own instance.
  defp lifecycle(socket, fun, ok_message) do
    case socket.assigns.challenge_attempt do
      %ChallengeAttempt{} = attempt ->
        case fun.(attempt) do
          {:ok, _attempt} ->
            {:noreply, put_flash(socket, :info, ok_message)}

          {:error, :vm_limit_reached} ->
            {:noreply, put_flash(socket, :error, vm_limit_message())}

          {:error, :invalid_state} ->
            {:noreply, put_flash(socket, :error, "That action isn't available right now.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "No running instance.")}
    end
  end

  defp vm_limit_message do
    "You already have #{Challenges.max_vms_per_team()} VMs running — the most allowed at once. " <>
      "Pause or tear one down before starting another."
  end

  def handle_info({:attempt_updated, _attempt_id}, %{assigns: %{challenge: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_info({:attempt_updated, _attempt_id}, socket) do
    # The team topic covers all of the team's attempts, so re-read the one
    # for the challenge on this page. It may now be gone (e.g. an admin
    # reset), in which case the challenge is available to start again.
    challenge = socket.assigns.challenge
    team = socket.assigns.current_team

    attempt =
      case Challenges.get_challenge_attempt_for_team(
             team,
             Challenge.group(challenge),
             Challenge.level(challenge)
           ) do
        {:ok, attempt} -> CtfServer.Repo.preload(attempt, :team)
        {:error, :not_found} -> nil
      end

    {:noreply, assign(socket, :challenge_attempt, attempt)}
  end

  def handle_info(:competition_refresh, socket) do
    {:noreply, CompetitionGate.refresh(socket)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <.header>
        Challenge: {@challenge_name}

        <:subtitle>
          {Track.title(@challenge_group)} · level {@challenge_level} · worth
          <span class="font-semibold">{@challenge_value}</span>
          points.
        </:subtitle>
      </.header>

      <div id="challenge-description" phx-hook="CodeFences" class="my-6 challenge-description">
        {raw(@challenge_description)}
      </div>

      <.challenge_block
        :if={visible?(assigns)}
        attempt={@challenge_attempt}
        form={@form}
        needs_vm={@needs_vm}
      />

      <div :if={not visible?(assigns)} class="text-center">
        {holding_message(@competition_phase)}
      </div>
    </div>
    """
  end

  defp visible?(assigns), do: assigns.competition_phase == :during or admin?(assigns)

  defp admin?(%{assigns: %{current_team: %{is_admin: true}}}), do: true
  defp admin?(%{current_team: %{is_admin: true}}), do: true
  defp admin?(_), do: false

  defp holding_message(:before), do: "The competition has not started yet."
  defp holding_message(:after), do: "The competition is over."

  defp challenge_block(%{attempt: nil} = assigns) do
    ~H"""
    <div>
      <.button phx-click="start_challenge">Begin challenge!</.button>
    </div>
    """
  end

  # Provisioning and deprovisioning are waiting states, not actions — they used
  # to render as un-clickable buttons. They're status now.
  defp challenge_block(%{attempt: %ChallengeAttempt{status: :provisioning}} = assigns) do
    ~H"""
    <.status status={:provisioning} />
    """
  end

  defp challenge_block(%{attempt: %ChallengeAttempt{status: :deprovisioning}} = assigns) do
    ~H"""
    <.status status={:deprovisioning} />
    """
  end

  defp challenge_block(%{attempt: %ChallengeAttempt{status: :completed}} = assigns) do
    ~H"""
    <div class="my-4">
      <.status status={:completed} />
      <p class="mt-2">
        Challenge completed! You earned <span class="font-semibold">{@attempt.earned_score}</span>
        points.
      </p>
    </div>
    """
  end

  defp challenge_block(%{attempt: %ChallengeAttempt{status: :started}, needs_vm: false} = assigns) do
    ~H"""
    <div class="my-4">
      <p>
        This challenge is solved out in the world — no VM to log into. Capture the flag and submit it below.
      </p>
      <.flag_form form={@form} />
    </div>
    """
  end

  defp challenge_block(%{attempt: %ChallengeAttempt{status: :started}} = assigns) do
    ~H"""
    <div class="my-4">
      <p>Save the private key below to a file (e.g. <code>ctf.key</code>), then connect with:</p>
      <.code_block
        id={"ssh-command-#{@attempt.id}"}
        code={"chmod 600 ctf.key\nssh -i ctf.key -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p #{@attempt.port} ctf@#{Application.get_env(:ctf_server, :vm_ssh_host)}"}
      />

      <p>Your private key:</p>
      <.code_block id={"ssh-key-#{@attempt.id}"} code={@attempt.privkey} filename="ctf.key" />

      <.flag_form form={@form} />
      <.instance_controls paused={false} />
    </div>
    """
  end

  defp challenge_block(%{attempt: %ChallengeAttempt{status: :paused}} = assigns) do
    ~H"""
    <div class="my-4">
      <.status status={:paused} />
      <p class="mt-2">
        Your VM is <span class="font-semibold">paused</span>
        — it's powered off to free resources and can't be reached over SSH until you resume it.
      </p>

      <p>Your private key (for when you resume):</p>
      <.code_block id={"ssh-key-#{@attempt.id}"} code={@attempt.privkey} filename="ctf.key" />

      <.flag_form form={@form} />
      <.instance_controls paused={true} />
    </div>
    """
  end

  # The flag submission form, identical in every state that accepts one.
  attr :form, :any, required: true

  defp flag_form(assigns) do
    ~H"""
    <.simple_form for={@form} phx-submit="attempt_capture">
      <.input field={@form[:flag]} label="Flag" />
      <:actions>
        <.button>Capture</.button>
      </:actions>
    </.simple_form>
    """
  end

  # Self-service lifecycle buttons for a team's own VM instance.
  attr :paused, :boolean, required: true

  defp instance_controls(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2 mt-6">
      <.button :if={@paused} phx-click="resume_instance">Resume</.button>
      <.button :if={not @paused} phx-click="pause_instance">Pause</.button>
      <.button
        phx-click="rebuild_instance"
        data-confirm="Rebuild this VM from a clean image? Anything you changed inside it is lost."
      >
        Rebuild
      </.button>
      <.button
        class="!bg-red-700 hover:!bg-red-600"
        phx-click="teardown_instance"
        data-confirm="Tear down this VM? The instance is destroyed and the challenge returns to not-started."
      >
        Tear down
      </.button>
    </div>
    """
  end
end
