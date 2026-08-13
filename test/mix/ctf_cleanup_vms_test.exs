defmodule Mix.Tasks.Ctf.CleanupVmsTest do
  @moduledoc """
  The nuclear cleanup must reap through `CtfUtils.VMUtils` (so `undefine`
  carries the `--managed-save --nvram` flags a post-reboot host needs, and
  overlays go with the domain) and must *fail loudly*: the previous version
  shelled out to a bare `virsh undefine` and ignored the exit code, so after
  a host reboot it printed "Destroying domain..." for every domain and
  reported success while leaking every definition.

  Libvirt is stubbed (`CtfServer.StubVMBackend`).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias CtfServer.StubVMBackend

  defp run_task do
    capture_io(fn -> Mix.Tasks.Ctf.CleanupVms.run([]) end)
  end

  # The failure report goes to stderr; capture it too so a passing suite
  # stays quiet.
  defp run_task_expecting_failure(message \\ ~r//) do
    capture_io(:stderr, fn ->
      capture_io(fn ->
        assert_raise Mix.Error, message, fn -> Mix.Tasks.Ctf.CleanupVms.run([]) end
      end)
    end)
  end

  test "reaps every ctf domain and network, leaving non-ctf networks alone" do
    StubVMBackend.set_domains([{"ctf-vm-aaa-web", "running"}, {"ctf-vm-bbb", "shut off"}])
    StubVMBackend.set_networks([{"ctf-aaa", "active"}, {"default", "active"}])

    output = run_task()

    assert StubVMBackend.destroyed() == [
             {:domain, "ctf-vm-aaa-web"},
             {:domain, "ctf-vm-bbb"},
             {:network, "ctf-aaa"}
           ]

    assert output =~ "Cleaned up 2 domain(s) and 1 network(s)."
  end

  test "nothing to do when libvirt has no ctf resources" do
    StubVMBackend.set_domains([])
    StubVMBackend.set_networks([{"default", "active"}])

    assert run_task() =~ "Nothing to clean up."
    assert StubVMBackend.destroyed() == []
  end

  test "a domain that cannot be undefined fails the task instead of reporting success" do
    StubVMBackend.set_domains([{"ctf-vm-saved-web", "shut off"}])
    StubVMBackend.set_networks([])
    StubVMBackend.fail_next_destroy("Refusing to undefine while domain managed save image exists")

    stderr = run_task_expecting_failure(~r/Cleanup incomplete — 1 resource\(s\) left behind/)

    assert stderr =~
             "domain ctf-vm-saved-web: Refusing to undefine while domain managed save image exists"
  end

  test "one bad domain does not stop the rest from being reaped" do
    StubVMBackend.set_domains([{"ctf-vm-saved-web", "shut off"}, {"ctf-vm-fine-web", "running"}])
    StubVMBackend.set_networks([{"ctf-fine", "active"}])
    StubVMBackend.fail_next_destroy("managed save image exists")

    run_task_expecting_failure()

    assert StubVMBackend.destroyed() == [
             {:domain, "ctf-vm-fine-web"},
             {:network, "ctf-fine"}
           ]
  end
end
