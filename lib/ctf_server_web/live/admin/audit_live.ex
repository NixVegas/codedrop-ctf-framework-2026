defmodule CtfServerWeb.AdminAuditLive do
  use CtfServerWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias CtfServer.Accounts.Team
  alias CtfServer.Audit
  alias CtfServer.Repo

  @per_page 50

  def render(assigns) do
    ~H"""
    <div>
      <.header>
        Audit trail
        <:subtitle>
          Account, auth, and challenge lifecycle events, newest first.
        </:subtitle>
      </.header>

      <div
        :if={@scope_team}
        class="mt-6 flex items-center gap-3 rounded border border-zinc-300 bg-zinc-50 px-4 py-2"
      >
        <span class="text-sm text-zinc-900">
          Showing events concerning <span class="font-bold">{@scope_team.name}</span>
          ({@scope_team.email})
        </span>
        <.link patch={self_path(%{@filters | team: nil, page: 1})} class="text-sm underline">
          Clear
        </.link>
      </div>

      <form id="audit-filter" phx-change="filter" class="mt-6 flex flex-wrap items-end gap-4">
        <label class="block">
          <span class="block text-sm font-semibold leading-6">Topic</span>
          <select
            name="topic"
            class="mt-1 block rounded-md border-zinc-300 py-1.5 text-sm focus:border-zinc-400 focus:ring-0"
          >
            <option value="" selected={@filters.topic == nil}>all</option>
            <option :for={topic <- @topics} value={topic} selected={@filters.topic == topic}>
              {topic}
            </option>
          </select>
        </label>
        <label class="block grow max-w-xs">
          <span class="block text-sm font-semibold leading-6">Search</span>
          <input
            type="text"
            name="q"
            value={@filters.q}
            placeholder="event or principal email"
            phx-debounce="300"
            class="mt-1 block w-full rounded-md border-zinc-300 py-1.5 text-sm focus:border-zinc-400 focus:ring-0"
          />
        </label>
      </form>

      <p :if={@page.events == []} class="mt-8 text-zinc-600">
        No audit events match.
      </p>

      <div :if={@page.events != []} class="overflow-x-auto">
        <table id="audit-events" class="mt-4 w-full table-fixed">
          <thead class="border-b border-zinc-300 text-left text-sm">
            <tr>
              <th class="w-44 py-2 pr-6 font-semibold">At</th>
              <th class="py-2 pr-6 font-semibold">Event</th>
              <th class="w-56 py-2 font-semibold">Principal</th>
            </tr>
          </thead>
          <tbody
            :for={event <- @page.events}
            id={"audit-event-#{event.id}"}
            class="border-b border-zinc-200 text-sm"
          >
            <tr>
              <td class="py-3 pr-6 align-top">
                <span class="whitespace-nowrap font-mono text-xs">
                  {format_time(event.occurred_at)}
                </span>
              </td>
              <td class="break-all py-3 pr-6 font-semibold text-zinc-900">
                {event.topic}.{event.event}
              </td>
              <td class="py-3">
                <.link
                  :if={event.principal}
                  navigate={~p"/admin/teams/#{event.principal.id}"}
                  class="underline"
                >
                  {event.principal.email}
                </.link>
                <span :if={is_nil(event.principal)}>—</span>
              </td>
            </tr>
            <tr :if={event.details != %{}}>
              <td colspan="3" class="pb-3">
                <aside class="overflow-x-auto rounded bg-zinc-50 px-3 py-2">
                  <pre class="font-mono text-xs">{format_details(event.details)}</pre>
                </aside>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="mt-6 flex items-center justify-between text-sm">
        <span class="text-zinc-600">
          {@page.total} event(s) — page {@page.page} of {@page.total_pages}
        </span>
        <div class="flex gap-4">
          <.link
            :if={@page.page > 1}
            patch={self_path(%{@filters | page: @page.page - 1})}
            class="font-semibold underline"
          >
            ← Newer
          </.link>
          <.link
            :if={@page.page < @page.total_pages}
            patch={self_path(%{@filters | page: @page.page + 1})}
            class="font-semibold underline"
          >
            Older →
          </.link>
        </div>
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Audit trail", topics: list_topics())}
  end

  def handle_params(params, _uri, socket) do
    scope_team =
      case params["team"] do
        id when is_binary(id) and id != "" -> Repo.get(Team, id)
        _ -> nil
      end

    filters = %{
      topic: presence(params["topic"]),
      q: presence(params["q"]),
      team: scope_team && scope_team.id,
      page: parse_page(params["page"])
    }

    page =
      Audit.list_events(
        topic: filters.topic,
        team: scope_team,
        q: filters.q,
        page: filters.page,
        per_page: @per_page
      )

    {:noreply, assign(socket, filters: filters, scope_team: scope_team, page: page)}
  end

  def handle_event("filter", %{"topic" => topic, "q" => q}, socket) do
    filters = %{socket.assigns.filters | topic: presence(topic), q: presence(q), page: 1}
    {:noreply, push_patch(socket, to: self_path(filters))}
  end

  # Rebuilds the page's own URL from the filter state, dropping empty params
  # so the address bar stays shareable and clean.
  defp self_path(filters) do
    params =
      [
        topic: filters.topic,
        q: filters.q,
        team: filters.team,
        page: if(filters.page > 1, do: filters.page)
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    ~p"/admin/audit?#{params}"
  end

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp parse_page(nil), do: 1

  defp parse_page(value) do
    case Integer.parse(value) do
      {page, ""} when page >= 1 -> page
      _ -> 1
    end
  end

  defp list_topics do
    Repo.all(from e in CtfServer.Audit.Event, distinct: true, select: e.topic, order_by: e.topic)
  end

  # Second precision reads fine in a table; the full µs timestamp is still
  # in the DB for forensics.
  defp format_time(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%SZ")
  end

  defp format_details(details) when details == %{}, do: ""
  defp format_details(details), do: Jason.encode!(details, pretty: true)
end
