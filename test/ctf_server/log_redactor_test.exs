defmodule CtfServer.LogRedactorTest do
  # Guards the :logger filter that scrubs secrets out of structured log events,
  # so a LiveView (or any gen_server) crash can't dump a plaintext password in
  # its "Last message" report (CWE-532 / CWE-209).
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CtfServer.LogRedactor

  defp filtered_msg(msg) do
    %{msg: msg} = LogRedactor.filter(%{level: :error, msg: msg, meta: %{}}, [])
    msg
  end

  test "redacts password fields nested in a report map, keeps the rest" do
    {:report, report} =
      filtered_msg(
        {:report, %{last_message: %{"team" => %{"password" => "hunter2", "email" => "a@b.c"}}}}
      )

    assert get_in(report, [:last_message, "team", "password"]) == "[REDACTED]"
    assert get_in(report, [:last_message, "team", "email"]) == "a@b.c"
  end

  test "redacts the password variants and invite codes" do
    {:report, report} =
      filtered_msg(
        {:report,
         %{
           "current_password" => "old",
           "password_confirmation" => "new",
           "invite_code" => "drawterm-libhomfly",
           "name" => "keep me"
         }}
      )

    assert report["current_password"] == "[REDACTED]"
    assert report["password_confirmation"] == "[REDACTED]"
    assert report["invite_code"] == "[REDACTED]"
    assert report["name"] == "keep me"
  end

  test "redacts inside keyword-list reports (the gen_server crash shape)" do
    {:report, report} =
      filtered_msg(
        {:report,
         [
           label: {:gen_server, :terminate},
           last_message: %{"team" => %{"password" => "hunter2"}}
         ]}
      )

    assert get_in(report[:last_message], ["team", "password"]) == "[REDACTED]"
    assert report[:label] == {:gen_server, :terminate}
  end

  test "redacts format+args messages" do
    {format, [arg]} = filtered_msg({~c"params=~p", [%{"password" => "hunter2"}]})
    assert format == ~c"params=~p"
    assert arg == %{"password" => "[REDACTED]"}
  end

  test "recurses into structs and keeps their type and other fields" do
    msg = %Phoenix.Socket.Message{
      event: "save",
      payload: %{"team" => %{"password" => "hunter2"}}
    }

    {:report, %{message: message}} = filtered_msg({:report, %{message: msg}})

    assert %Phoenix.Socket.Message{event: "save"} = message
    assert get_in(message.payload, ["team", "password"]) == "[REDACTED]"
  end

  test "does not raise on non-collection terms like pids and refs" do
    {:report, report} =
      filtered_msg({:report, %{pid: self(), ref: make_ref(), password: "hunter2"}})

    assert report.password == "[REDACTED]"
    assert is_pid(report.pid)
    assert is_reference(report.ref)
  end

  test "the filter is installed, so a real report is scrubbed end to end" do
    log =
      capture_log(fn ->
        :logger.error(%{last_message: %{"team" => %{"password" => "hunter2"}}})
      end)

    refute log =~ "hunter2"
    assert log =~ "[REDACTED]"
  end
end
