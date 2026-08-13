defmodule CtfServer.HomeAssistantTest do
  # async: false, since it toggles the global :ha_webhook_url app env.
  use ExUnit.Case, async: false

  alias CtfServer.HomeAssistant

  setup do
    prev = Application.get_env(:ctf_server, :ha_webhook_url)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:ctf_server, :ha_webhook_url, prev),
        else: Application.delete_env(:ctf_server, :ha_webhook_url)
    end)

    :ok
  end

  test "is a no-op when no webhook is configured" do
    Application.delete_env(:ctf_server, :ha_webhook_url)
    assert HomeAssistant.flag_captured(%{name: "team"}, "recon", 1, 150) == :ok
  end

  test "is a no-op for a blank webhook url" do
    Application.put_env(:ctf_server, :ha_webhook_url, "")
    assert HomeAssistant.flag_captured(%{name: "team"}, "recon", 1, 150) == :ok
  end

  @tag :capture_log
  test "returns :ok immediately when configured (POST is fired in the background)" do
    # An unreachable URL; the caller must not block or crash on it, and the
    # background failure is logged and swallowed. capture_log keeps that expected
    # warning out of the suite output.
    Application.put_env(:ctf_server, :ha_webhook_url, "http://127.0.0.1:1/api/webhook/x")
    assert HomeAssistant.flag_captured(%{name: "team"}, "social-engineering", 4, 1000) == :ok
    Process.sleep(50)
  end
end
