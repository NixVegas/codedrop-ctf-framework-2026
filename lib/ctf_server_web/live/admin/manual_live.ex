defmodule CtfServerWeb.AdminManualLive do
  @moduledoc """
  The staff manual, browsable in-app: an ExDoc-style sidebar of guides on the
  left, the rendered guide on the right.

  Admin-only — it routes through the `:require_admin` pipeline. The solution
  guides are explicitly staff-only ("Do not ship to players"), so the same gate
  that protects the answer-key column protects these.
  """
  use CtfServerWeb, :live_view

  alias CtfServer.Manual

  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-8 md:flex-row">
      <nav class="shrink-0 md:w-64" aria-label="Manual contents">
        <.header>Manual</.header>

        <div :for={{group, pages} <- @groups} class="mt-4">
          <h3 class="text-xs font-semibold uppercase tracking-wide text-zinc-500">
            {group}
          </h3>
          <ul class="mt-1">
            <li :for={page <- pages}>
              <.link
                patch={~p"/admin/manual/#{page.slug}"}
                class={[
                  "block rounded px-2 py-1 text-sm hover:bg-zinc-50",
                  @page && @page.slug == page.slug && "bg-zinc-100 font-semibold"
                ]}
              >
                {page.title}
                <span :if={page.level} class="text-zinc-400">/{page.level}</span>
              </.link>
            </li>
          </ul>
        </div>
      </nav>

      <main class="min-w-0 flex-1">
        <div :if={@page} class="challenge-description">
          {raw(@page.html)}
        </div>

        <div :if={is_nil(@page)} class="text-zinc-600">
          <p>
            Staff reference for every challenge: the flag derivation, intended solve,
            hint ladder, and the pre-event steps a challenge depends on.
          </p>
          <p class="mt-2">Pick a guide from the list.</p>
          <p class="mt-6 text-sm text-zinc-500">
            {@count} guides. These are staff-only — do not share their contents with players.
          </p>
        </div>
      </main>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:groups, Manual.pages_by_group())
     |> assign(:count, length(Manual.pages()))
     |> assign(:page, nil)}
  end

  def handle_params(%{"slug" => slug}, _uri, socket) do
    case Manual.get_page(slug) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "No such guide.")
         |> assign(:page, nil)
         |> assign(:page_title, "Manual")}

      page ->
        {:noreply,
         socket
         |> assign(:page, page)
         |> assign(:page_title, "Manual · #{page.title}")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(:page, nil) |> assign(:page_title, "Manual")}
  end
end
