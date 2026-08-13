defmodule CtfServer.StubVMBackend do
  @moduledoc """
  Test stub for the libvirt calls `CtfServer.VMInventory` makes.

  The suite must never touch the developer's real `qemu:///system` — reading
  it makes inventory tests depend on whatever VMs happen to exist, and the
  reap paths would *destroy* them. Tests set the domain/network listings
  they want with `set_domains/1` and `set_networks/1`, and read back what
  was destroyed with `destroyed/0`.

  State is owned by the test process and stored in an ETS table keyed by it,
  so `async: true` tests stay isolated. A LiveView under test runs in its
  *own* process, so lookups resolve the owner through `$callers` — the same
  mechanism Mox uses to let a spawned process see its caller's stubs.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Sets the `{name, state}` domain listing the owning test will see."
  def set_domains(domains), do: put(:domains, domains)

  @doc "Sets the `{name, state}` network listing the owning test will see."
  def set_networks(networks), do: put(:networks, networks)

  @doc "Resources destroyed through the stub, oldest first."
  def destroyed, do: get(:destroyed, []) |> Enum.reverse()

  ## Backend callbacks

  def list_domains, do: get(:domains, [])
  def list_networks, do: get(:networks, [])

  @doc """
  Makes the next domain destroy fail as libvirt would, e.g. when a managed
  save image blocks `undefine`.
  """
  def fail_next_destroy(output), do: put(:destroy_error, output)

  def destroy_domain_by_name("ctf-vm-" <> _ = domain) do
    case get(:destroy_error, nil) do
      nil ->
        record({:domain, domain})

      output ->
        put(:destroy_error, nil)
        {:error, {:undefine_failed, output}}
    end
  end

  def destroy_domain_by_name(_other), do: {:error, :not_a_ctf_domain}

  def destroy_network_by_name("ctf-" <> _ = network), do: record({:network, network})
  def destroy_network_by_name(_other), do: {:error, :not_a_ctf_network}

  defp record(entry) do
    put(:destroyed, [entry | get(:destroyed, [])])
    :ok
  end

  defp put(key, value), do: :ets.insert(@table, {{owner(), key}, value}) && :ok

  defp get(key, default) do
    case :ets.lookup(@table, {owner(), key}) do
      [{_key, value}] -> value
      [] -> default
    end
  end

  # The test process owns the state. Reads from a process it spawned (a
  # LiveView, a Task) resolve to the first ancestor that has state, so the
  # LiveView under test sees what its test set.
  defp owner do
    callers = [self() | Process.get(:"$callers", [])]

    Enum.find(callers, self(), fn pid ->
      Enum.any?(
        [:domains, :networks, :destroyed, :destroy_error],
        &:ets.member(@table, {pid, &1})
      )
    end)
  end
end
