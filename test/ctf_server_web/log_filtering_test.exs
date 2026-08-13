defmodule CtfServerWeb.LogFilteringTest do
  # Guards the `:filter_parameters` config (config/config.exs) so the request
  # logger never records passwords or one-time invite codes (CWE-532).
  use ExUnit.Case, async: true

  test "password variants and invite codes are redacted from logged params" do
    params = %{
      "team" => %{
        "email" => "player@example.com",
        "password" => "hunter2",
        "current_password" => "old-hunter2",
        "password_confirmation" => "hunter2",
        "invite_code" => "drawterm-libhomfly-pmount"
      }
    }

    filtered = Phoenix.Logger.filter_values(params)

    assert filtered["team"]["password"] == "[FILTERED]"
    assert filtered["team"]["current_password"] == "[FILTERED]"
    assert filtered["team"]["password_confirmation"] == "[FILTERED]"
    assert filtered["team"]["invite_code"] == "[FILTERED]"
    # Non-sensitive params are untouched.
    assert filtered["team"]["email"] == "player@example.com"
  end
end
