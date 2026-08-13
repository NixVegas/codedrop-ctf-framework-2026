ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(CtfServer.Repo, :manual)

# Owns the ETS table backing the stubbed libvirt backend (config/test.exs
# points :vm_backend at it), so no test ever reads or destroys real VMs.
{:ok, _pid} = CtfServer.StubVMBackend.start_link()
