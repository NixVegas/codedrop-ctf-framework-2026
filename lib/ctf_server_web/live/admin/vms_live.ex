defmodule CtfServerWeb.AdminVmsLive do
  use CtfServerWeb, :live_view

  alias CtfServer.Challenges
  alias CtfServer.VMInventory

  @refresh_ms 10_000

  def render(assigns) do
    ~H"""
    <div>
      <.header>
        VM inventory
        <:subtitle>
          Libvirt domains and networks cross-referenced with in-flight challenge
          attempts. Auto-refreshes every {div(@refresh_ms, 1000)} s.
        </:subtitle>
        <:actions>
          <.link phx-click="refresh">
            <.button>Refresh</.button>
          </.link>
        </:actions>
      </.header>

      <p class="mt-4 text-sm text-zinc-600">
        {length(@inventory.clusters)} in-flight attempt(s), {Enum.count(
          @inventory.clusters,
          & &1.ghost?
        )} ghost(s), {length(@inventory.orphaned_domains)} orphaned domain(s), {length(
          @inventory.stray_networks
        )} stray network(s)
        — snapshot taken {@refreshed_at}.
      </p>

      <.header class="mt-10 text-left">In-flight attempts</.header>
      <p :if={@inventory.clusters == []} class="mt-4 text-zinc-600">
        No attempts currently hold VM resources.
      </p>
      <.table :if={@inventory.clusters != []} id="clusters" rows={@inventory.clusters}>
        <:col :let={cluster} label="Team">
          <.link navigate={~p"/admin/teams/#{cluster.attempt.team_id}"} class="underline">
            {cluster.attempt.team.name}
          </.link>
        </:col>
        <:col :let={cluster} label="Challenge">
          {cluster.attempt.group} / {cluster.attempt.level}
        </:col>
        <:col :let={cluster} label="Status">
          {cluster.attempt.status}
          <div class="text-xs text-zinc-600">
            since {format_time(cluster.attempt.inserted_at)}
          </div>
        </:col>
        <:col :let={cluster} label="SSH port">{cluster.attempt.port || "—"}</:col>
        <:col :let={cluster} label="Nodes / network">
          <span :if={cluster.ghost?} class="font-semibold text-red-600">
            none — ghost attempt
          </span>
          <ul :if={not cluster.ghost?} class="font-mono text-xs">
            <li :for={node <- cluster.nodes}>
              {node.role}: <span class={state_class(node.state)}>{node.state}</span>
            </li>
          </ul>
          <div class="font-mono text-xs">
            net: <span class={state_class(cluster.network_state)}>{cluster.network_state}</span>
          </div>
        </:col>
        <:action :let={cluster}>
          <div class="flex w-32 flex-wrap justify-end gap-x-3 whitespace-normal">
            <.link
              :if={cluster.attempt.status == :started}
              phx-click="pause"
              phx-value-id={cluster.attempt.id}
              data-confirm={"Pause #{label_for(cluster)}? Its VMs power off (freeing resources) but keep their disks and port so they can be resumed."}
            >
              Pause
            </.link>
            <.link
              :if={cluster.attempt.status == :paused}
              phx-click="resume"
              phx-value-id={cluster.attempt.id}
              data-confirm={"Resume #{label_for(cluster)}?"}
            >
              Resume
            </.link>
            <.link
              :if={cluster.attempt.status in [:started, :paused]}
              phx-click="rebuild"
              phx-value-id={cluster.attempt.id}
              data-confirm={"Rebuild #{label_for(cluster)} from a clean image? In-VM changes are lost; the flag is unchanged."}
            >
              Rebuild
            </.link>
            <.link
              :if={cluster.attempt.status in [:provisioning, :started, :paused]}
              phx-click="force_shutdown"
              phx-value-id={cluster.attempt.id}
              data-confirm={"Force shutdown #{label_for(cluster)}? The team will not be able to restart it."}
            >
              Force shutdown
            </.link>
            <.link
              phx-click="reset"
              phx-value-id={cluster.attempt.id}
              data-confirm={"Reset #{label_for(cluster)}? Any running VMs are destroyed and the attempt is removed (including a recorded completion and its score), so the team can start over."}
            >
              Reset
            </.link>
          </div>
        </:action>
      </.table>

      <div :for={cluster <- @inventory.clusters}>
        <div
          :if={cluster.jobs != [] and (cluster.ghost? or cluster.attempt.status == :provisioning)}
          class="mt-4 rounded border border-zinc-300 bg-zinc-50 p-4"
        >
          <p class="text-sm font-bold text-zinc-900">
            Provisioning jobs for {label_for(cluster)}
          </p>
          <ul class="mt-2 space-y-2">
            <li :for={job <- cluster.jobs} class="text-xs">
              <span class="font-mono text-zinc-900">
                {short_worker(job.worker)} — {job.state} (try {job.attempt})
              </span>
              <pre
                :if={job.errors != []}
                class="mt-1 overflow-x-auto rounded bg-white px-2 py-1 font-mono text-xs"
              >{format_errors(job.errors)}</pre>
            </li>
          </ul>
        </div>
      </div>

      <.header class="mt-10 text-left">Orphaned domains</.header>
      <p :if={@inventory.orphaned_domains == []} class="mt-4 text-zinc-600">
        None — every ctf domain belongs to an in-flight attempt.
      </p>
      <div :if={@inventory.orphaned_domains != []}>
        <p class="mt-2 text-sm text-zinc-600">
          Leaked libvirt domains with no matching in-flight attempt. Destroy reaps
          one (refused if a live attempt has since claimed it);
          <code class="font-mono">mix ctf.cleanup_vms</code>
          reaps every ctf domain and network at once.
        </p>
        <.table id="orphaned-domains" rows={@inventory.orphaned_domains}>
          <:col :let={{name, _state}} label="Domain">
            <span class="font-mono text-xs">{name}</span>
          </:col>
          <:col :let={{_name, state}} label="State">
            <span class={state_class(state)}>{state}</span>
          </:col>
          <:action :let={{name, _state}}>
            <.link
              phx-click="destroy_orphan_domain"
              phx-value-name={name}
              data-confirm={"Destroy #{name}? The domain is undefined and its overlay disk removed. This is refused if the domain has since been claimed by a live attempt."}
            >
              Destroy
            </.link>
          </:action>
        </.table>
      </div>

      <.header class="mt-10 text-left">Stray networks</.header>
      <p :if={@inventory.stray_networks == []} class="mt-4 text-zinc-600">
        None — every ctf network belongs to an in-flight attempt.
      </p>
      <.table
        :if={@inventory.stray_networks != []}
        id="stray-networks"
        rows={@inventory.stray_networks}
      >
        <:col :let={{name, _state}} label="Network">
          <span class="font-mono text-xs">{name}</span>
        </:col>
        <:col :let={{_name, state}} label="State">
          <span class={state_class(state)}>{state}</span>
        </:col>
        <:action :let={{name, _state}}>
          <.link
            phx-click="destroy_stray_network"
            phx-value-name={name}
            data-confirm={"Destroy network #{name}? This is refused if it has since been claimed by a live attempt."}
          >
            Destroy
          </.link>
        </:action>
      </.table>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    {:ok,
     socket
     |> assign(page_title: "VM inventory", refresh_ms: @refresh_ms)
     |> take_snapshot()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, take_snapshot(socket)}
  end

  def handle_event("pause", %{"id" => id}, socket) do
    lifecycle(socket, id, &Challenges.pause_challenge_attempt/2, "Pausing")
  end

  def handle_event("resume", %{"id" => id}, socket) do
    lifecycle(socket, id, &Challenges.resume_challenge_attempt/2, "Resuming")
  end

  def handle_event("rebuild", %{"id" => id}, socket) do
    lifecycle(socket, id, &Challenges.rebuild_challenge_attempt/2, "Rebuilding")
  end

  def handle_event("force_shutdown", %{"id" => id}, socket) do
    lifecycle(socket, id, &Challenges.force_shutdown_attempt/2, "Shutting down")
  end

  def handle_event("reset", %{"id" => id}, socket) do
    lifecycle(socket, id, &Challenges.reset_challenge_attempt_instance/2, "Resetting")
  end

  def handle_event("destroy_orphan_domain", %{"name" => name}, socket) do
    case VMInventory.destroy_orphan_domain(name, socket.assigns.current_team) do
      :ok ->
        {:noreply,
         socket |> put_flash(:info, "Destroyed orphaned domain #{name}.") |> take_snapshot()}

      {:error, :not_orphaned} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{name} is no longer orphaned — a live attempt claims it now.")
         |> take_snapshot()}

      {:error, :not_a_ctf_domain} ->
        {:noreply, put_flash(socket, :error, "#{name} is not a challenge VM domain.")}

      {:error, {:undefine_failed, output}} ->
        {:noreply,
         socket
         |> put_flash(:error, "libvirt refused to undefine #{name}: #{output}")
         |> take_snapshot()}
    end
  end

  def handle_event("destroy_stray_network", %{"name" => name}, socket) do
    case VMInventory.destroy_stray_network(name, socket.assigns.current_team) do
      :ok ->
        {:noreply,
         socket |> put_flash(:info, "Destroyed stray network #{name}.") |> take_snapshot()}

      {:error, :not_stray} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{name} is no longer stray — a live attempt claims it now.")
         |> take_snapshot()}

      {:error, :not_a_ctf_network} ->
        {:noreply, put_flash(socket, :error, "#{name} is not a challenge network.")}
    end
  end

  def handle_info(:refresh, socket) do
    {:noreply, take_snapshot(socket)}
  end

  # Runs a lifecycle action on an attempt by id and re-snapshots, so the
  # inventory reflects the transition without waiting for the timer.
  defp lifecycle(socket, id, fun, gerund) do
    attempt = Challenges.get_challenge_attempt!(id)

    case fun.(attempt, socket.assigns.current_team) do
      {:ok, attempt} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{gerund} #{attempt.group}/#{attempt.level}.")
         |> take_snapshot()}

      {:error, :vm_limit_reached} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That team is at its #{Challenges.max_vms_per_team()}-VM running limit; pause or tear one down first."
         )}

      {:error, :invalid_state} ->
        {:noreply, put_flash(socket, :error, "That instance can't do that right now.")}
    end
  end

  defp take_snapshot(socket) do
    inventory = VMInventory.snapshot()

    # Only in-flight clusters that look wedged get their job history read —
    # a healthy running cluster needs no provisioning log.
    clusters =
      Enum.map(inventory.clusters, fn cluster ->
        jobs =
          if cluster.ghost? or cluster.attempt.status == :provisioning do
            Challenges.list_jobs_for_attempt(cluster.attempt.id)
          else
            []
          end

        Map.put(cluster, :jobs, jobs)
      end)

    assign(socket,
      inventory: %{inventory | clusters: clusters},
      refreshed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
  end

  defp label_for(cluster), do: "#{cluster.attempt.group}/#{cluster.attempt.level}"

  defp format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%SZ")

  defp short_worker(worker), do: worker |> String.split(".") |> List.last()

  # Oban stores each failure as a map with an "error" string (the formatted
  # exception/stacktrace); show the most recent first.
  defp format_errors(errors) do
    errors
    |> Enum.reverse()
    |> Enum.map_join("\n\n", fn error -> error["error"] || inspect(error) end)
  end

  defp state_class(state) when state in ["running", "active"], do: "text-green-700"
  defp state_class("missing"), do: "font-semibold text-red-600"
  defp state_class(_state), do: "text-amber-600"
end
