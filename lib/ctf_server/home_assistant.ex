defmodule CtfServer.HomeAssistant do
  @moduledoc """
  Fire-and-forget Home Assistant webhook notifications.

  When a flag is captured the backend POSTs to a Home Assistant webhook so the
  space can react (e.g. flash the lights). The webhook URL comes from the
  `:ha_webhook_url` app env (set from `services.ctf-server.homeAssistantWebhookUrl`
  in the NixOS module). When it is unset/blank, notifications are silently
  skipped.

  It is strictly best-effort: the POST runs in an unlinked background task and any
  error is logged and swallowed, so a slow or dead webhook never blocks or breaks
  scoring.
  """
  require Logger

  @doc """
  Notify Home Assistant that `team` captured a flag on `group`/`level` for
  `score` points. Returns `:ok` immediately; the HTTP POST happens in the
  background.
  """
  def flag_captured(team, group, level, score) do
    case webhook_url() do
      url when is_binary(url) and url != "" ->
        payload = %{
          event: "flag_captured",
          team: Map.get(team, :name),
          group: group,
          level: level,
          score: score
        }

        Task.start(fn -> post(url, payload) end)
        :ok

      _ ->
        :ok
    end
  end

  defp webhook_url, do: Application.get_env(:ctf_server, :ha_webhook_url)

  # `retry: false` keeps this a single shot. Req would otherwise retry transient
  # failures, and a webhook that only flashes lights is not worth holding a task
  # open for — the previous Finch call did not retry either.
  #
  # `finch: CtfServer.Finch` reuses the pool started in `CtfServer.Application`
  # (also Swoosh's mail adapter) rather than letting Req start its own default.
  defp post(url, payload) do
    case Req.post(url,
           json: payload,
           finch: CtfServer.Finch,
           receive_timeout: 5_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Home Assistant webhook returned HTTP #{status}")

      {:error, reason} ->
        Logger.warning("Home Assistant webhook failed: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("Home Assistant webhook error: #{Exception.message(e)}")
  end
end
