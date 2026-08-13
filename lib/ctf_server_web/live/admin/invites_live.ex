defmodule CtfServerWeb.AdminInvitesLive do
  use CtfServerWeb, :live_view

  alias CtfServer.Accounts

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl">
      <.header>
        Invite codes
        <:subtitle>
          {@counts.total} total, {@counts.unused} unused, {@counts.redeemed} redeemed.
        </:subtitle>
      </.header>

      <.simple_form for={@form} id="gen_form" phx-submit="generate">
        <div class="flex gap-4">
          <.input field={@form[:count]} type="number" label="How many" min="1" value="10" />
          <.input field={@form[:words]} type="number" label="Words per code" min="2" value="3" />
        </div>
        <:actions>
          <.button phx-disable-with="Generating...">Generate codes</.button>
        </:actions>
      </.simple_form>

      <div :if={@fresh != []} class="mt-6">
        <.header class="text-left">New codes (copy now)</.header>
        <ul class="mt-2 font-mono text-sm">
          <li :for={code <- @fresh}>{code}</li>
        </ul>
      </div>

      <.header class="mt-10 text-left">All codes</.header>
      <.table id="codes" rows={@codes}>
        <:col :let={c} label="Code"><span class="font-mono">{c.code}</span></:col>
        <:col :let={c} label="Status">
          {if c.redeemed_at, do: "redeemed", else: "unused"}
        </:col>
        <:col :let={c} label="Team">{c.redeemed_by_team && c.redeemed_by_team.name}</:col>
        <:col :let={c} label="Redeemed at">{c.redeemed_at}</:col>
      </.table>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    {:ok, socket |> assign(fresh: []) |> load()}
  end

  def handle_event("generate", %{"count" => count, "words" => words}, socket) do
    case {parse_pos_int(count, 1000), parse_pos_int(words, 8)} do
      {{:ok, count}, {:ok, words}} ->
        {:ok, codes} =
          Accounts.generate_invite_codes(count, words: words, actor: socket.assigns.current_team)

        {:noreply, socket |> assign(fresh: codes) |> load()}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Enter a positive whole number of codes (<=1000) and words (2-8)."
         )}
    end
  end

  # A positive integer no greater than `max`; `:error` otherwise.
  defp parse_pos_int(str, max) do
    case Integer.parse(str) do
      {n, ""} when n > 0 and n <= max -> {:ok, n}
      _ -> :error
    end
  end

  defp load(socket) do
    socket
    |> assign(codes: Accounts.list_invite_codes(), counts: Accounts.count_invite_codes())
    |> assign(form: to_form(%{"count" => "10", "words" => "3"}))
  end
end
