defmodule CtfServerWeb.CompetitionGate do
  @moduledoc """
  LiveView glue for the competition window: assigns the current phase,
  subscribes to window changes, and schedules a one-shot timer to the next
  boundary so a connected view flips exactly at start/end.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  alias CtfServer.Competition
  alias CtfUtils.PubSubUtils

  # `Process.send_after/3` rejects delays past `erlang`'s max timer value
  # (a bit over 136 years). A boundary that far out (e.g. a `starts_at` left
  # unset for a distant future default) would crash the mount, so reschedule
  # checks are capped well under that ceiling; the timer just fires again and
  # recomputes rather than needing to land exactly on a boundary that far away.
  @max_schedule_ms :timer.hours(24 * 30)

  @doc "Call in mount/3. Assigns :competition_phase; subscribes + schedules when connected."
  def on_mount(socket) do
    if connected?(socket) do
      :ok = PubSubUtils.sub_competition()
      schedule_boundary(socket)
    end

    assign(socket, :competition_phase, Competition.current_phase())
  end

  @doc "Call from handle_info(:competition_refresh, ...). Recomputes + reschedules."
  def refresh(socket) do
    if connected?(socket), do: schedule_boundary(socket)
    assign(socket, :competition_phase, Competition.current_phase())
  end

  defp schedule_boundary(socket) do
    now = DateTime.utc_now()

    case Competition.next_boundary(Competition.get(), now) do
      nil ->
        :ok

      boundary ->
        ms =
          boundary
          |> DateTime.diff(now, :millisecond)
          |> Kernel.+(1000)
          |> max(1000)
          |> min(@max_schedule_ms)

        Process.send_after(self(), :competition_refresh, ms)
    end

    socket
  end
end
