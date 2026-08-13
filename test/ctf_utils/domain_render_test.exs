defmodule CtfUtils.DomainRenderTest do
  use ExUnit.Case, async: true

  @challenges Path.join(:code.priv_dir(:ctf_server), "challenges")

  # Both layouts: a single-VM challenge's domain.xml.eex, and a cluster's
  # per-role nodes/<role>.domain.xml.eex.
  @templates (Path.wildcard(Path.join(@challenges, "*/domain.xml.eex")) ++
                Path.wildcard(Path.join(@challenges, "*/nodes/*.domain.xml.eex")))
             |> Enum.sort()

  defp render(path) do
    EEx.eval_file(path,
      domain_name: "ctf-vm-test",
      image_path: "/tmp/overlay.qcow2",
      network_name: "ctf-test",
      ssh_port: 26004,
      guest_mac: "52:54:00:ab:cd:ef",
      guest_ip: "10.60.2.2",
      gateway_ip: "10.60.2.1",
      subnet: "10.60.2.0",
      # Cluster nodes only. `hub_mode` marks the domain for the qemu hook's
      # bridge learning-off; see CtfUtils.VMUtils.domain_assigns/4.
      hub_mode: true,
      os_block: "<os><type arch='x86_64'>hvm</type><boot dev='hd'/></os>",
      cpu_block: ""
    )
  end

  test "there are 3 challenge domain templates" do
    assert length(@templates) == 3
  end

  for path <- @templates do
    @path path

    # "erinyes_3/builder" for a cluster node, "basic_nix_1" for a single VM.
    # Bare dirname would name every cluster template "nodes" and collide.
    name =
      case Path.split(path) |> Enum.take(-3) do
        [challenge, "nodes", file] ->
          "#{challenge}/#{String.replace(file, ".domain.xml.eex", "")}"

        [_, challenge, _] ->
          challenge
      end

    test "#{name} renders a ctf network filter, its params, pinned MAC and hook metadata" do
      xml = render(@path)

      # Every challenge VM is on a ctf filter: one of the two egress filters
      # (ctf-egress, or the internet-preferring ctf-egress-internet), or the
      # peer-only ctf-cluster-internal.
      #
      # Which variable an egress filter references is a *deployment* choice, not
      # a template one: `clusterLocal` picks $SUBNET when true and $GATEWAY when
      # false (nix/ctf-libvirt.nix), and both filters set it via mkDefault, so
      # prod can flip either. libvirt refuses to instantiate a filter whose
      # variables it cannot resolve but ignores parameters the filter doesn't
      # reference, so every egress filterref passes BOTH — the extra one is
      # inert, and no template breaks on a policy flip.
      #
      # ctf-cluster-internal is hardcoded XML that can only ever use $SUBNET.
      cond do
        xml =~ "ctf-egress" ->
          assert xml =~ ~s(name='GATEWAY') or xml =~ ~s(name="GATEWAY")
          assert xml =~ "10.60.2.1"
          assert xml =~ ~s(name='SUBNET') or xml =~ ~s(name="SUBNET")
          assert xml =~ "10.60.2.0"

        xml =~ "ctf-cluster-internal" ->
          assert xml =~ ~s(name='SUBNET') or xml =~ ~s(name="SUBNET")
          assert xml =~ "10.60.2.0"

        true ->
          flunk("no ctf network filter in #{@path}")
      end

      # The pinned NIC drives the per-attempt DHCP reservation, so every node
      # has one.
      assert xml =~ ~s(<mac address="52:54:00:ab:cd:ef"/>)

      # The hook metadata drives the host DNAT path, and only an ingress node
      # has a forwarded port. A cluster peer gets ssh_port: nil and omits the
      # hook entirely — it is reached from its siblings, not from the host.
      if xml =~ "ssh-port" do
        assert xml =~ ~s(ssh-port="26004")
        assert xml =~ ~s(guest-ip="10.60.2.2")
      end

      # No SLiRP user-net — every challenge VM is reached via the DNAT hook.
      refute xml =~ "hostfwd"
    end
  end
end
