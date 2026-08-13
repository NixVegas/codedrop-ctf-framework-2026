defmodule CtfServerWeb.AdminCompetitionLive do
  use CtfServerWeb, :live_view

  alias CtfServer.Competition

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-xl">
      <.header>
        Competition window
        <:subtitle>
          Times are UTC. Leave a field blank for no bound. Current phase: {@phase}.
        </:subtitle>
      </.header>

      <.simple_form for={@form} id="competition_form" phx-submit="save">
        <.input field={@form[:starts_at]} type="datetime-local" label="Starts at (UTC)" />
        <.input field={@form[:ends_at]} type="datetime-local" label="Ends at (UTC)" />
        <:actions>
          <.button phx-disable-with="Saving...">Save window</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    {:ok, load(socket)}
  end

  def handle_event("save", %{"competition" => params}, socket) do
    attrs = %{
      starts_at: parse(params["starts_at"]),
      ends_at: parse(params["ends_at"])
    }

    case Competition.update(Competition.get(), attrs) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Window updated.") |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "competition"))}
    end
  end

  # "" -> nil (clears the bound); "2026-08-06T11:00" (naive, UTC) -> DateTime.
  defp parse(nil), do: nil
  defp parse(""), do: nil

  defp parse(value) do
    value = if String.length(value) == 16, do: value <> ":00", else: value
    {:ok, naive} = NaiveDateTime.from_iso8601(value)
    DateTime.from_naive!(naive, "Etc/UTC")
  end

  defp load(socket) do
    competition = Competition.get()

    form =
      to_form(
        %{
          "starts_at" => fmt(competition.starts_at),
          "ends_at" => fmt(competition.ends_at)
        },
        as: "competition"
      )

    assign(socket, form: form, phase: Competition.phase(competition, DateTime.utc_now()))
  end

  # DateTime -> "YYYY-MM-DDTHH:MM" for the datetime-local input; nil -> "".
  defp fmt(nil), do: ""
  defp fmt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%dT%H:%M")
end
