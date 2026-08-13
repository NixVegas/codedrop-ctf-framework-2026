defmodule CtfUtils.VMUtilsTest do
  use ExUnit.Case, async: true
  alias CtfUtils.VMUtils

  @attempt "c0179512-0ebe-4268-9e05-8f9ad0fe92c9"

  test "subnet octets are deterministic and in range" do
    {o3, o4} = VMUtils.subnet_octets(@attempt)
    assert o3 in 150..199
    assert o4 in 1..253
    assert VMUtils.subnet_octets(@attempt) == {o3, o4}
  end

  test "gateway_ip is .1 of the derived subnet" do
    {o3, o4} = VMUtils.subnet_octets(@attempt)
    assert VMUtils.gateway_ip(@attempt) == "10.#{o3}.#{o4}.1"
  end

  test "network_xml/2 enables NAT forward and keeps the derived subnet" do
    {o3, o4} = VMUtils.subnet_octets(@attempt)
    xml = VMUtils.network_xml(@attempt, 1)
    assert xml =~ "<forward mode='nat'/>" or xml =~ ~s(<forward mode="nat"/>)
    assert xml =~ "10.#{o3}.#{o4}.1"
    assert xml =~ ~s(netmask="255.255.255.0")
    assert xml =~ "ctf-#{@attempt}"
  end

  # --- Cluster (multi-node) helpers ---

  test "guest_ip/2 walks up from .2 per node index" do
    {o3, o4} = VMUtils.subnet_octets(@attempt)
    assert VMUtils.guest_ip(@attempt, 0) == "10.#{o3}.#{o4}.2"
    assert VMUtils.guest_ip(@attempt, 1) == "10.#{o3}.#{o4}.3"
    assert VMUtils.guest_ip(@attempt, 2) == "10.#{o3}.#{o4}.4"
  end

  test "guest_mac/2 is deterministic, QEMU-OUI, and distinct per node" do
    macs = for i <- 0..2, do: VMUtils.guest_mac(@attempt, i)

    for mac <- macs do
      assert mac =~ ~r/^52:54:00(:[0-9a-f]{2}){3}$/
    end

    assert length(Enum.uniq(macs)) == 3
    assert VMUtils.guest_mac(@attempt, 1) == VMUtils.guest_mac(@attempt, 1)
  end

  test "overlay_path/2 and domain_name/2 share the attempt prefix for discovery" do
    web = VMUtils.overlay_path(@attempt, "web")
    ing = VMUtils.overlay_path(@attempt, "ingress")
    assert Path.basename(web) == "#{@attempt}-web.qcow2"
    assert Path.basename(ing) == "#{@attempt}-ingress.qcow2"

    assert VMUtils.domain_name(@attempt, "web") == "ctf-vm-#{@attempt}-web"
    assert String.starts_with?(VMUtils.domain_name(@attempt, "ingress"), "ctf-vm-#{@attempt}-")
  end

  test "network_xml/2 pins one DHCP reservation per node" do
    {o3, o4} = VMUtils.subnet_octets(@attempt)
    xml = VMUtils.network_xml(@attempt, 3)

    for i <- 0..2 do
      assert xml =~
               ~s(<host mac="#{VMUtils.guest_mac(@attempt, i)}" ip="10.#{o3}.#{o4}.#{2 + i}"/>)
    end

    assert xml =~ "<forward mode='nat'/>"
  end
end
