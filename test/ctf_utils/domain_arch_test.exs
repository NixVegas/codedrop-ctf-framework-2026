defmodule CtfUtils.DomainArchTest do
  use ExUnit.Case, async: true

  alias CtfUtils.VMUtils

  test "host_arch/0 returns a known atom" do
    assert VMUtils.host_arch() in [:x86_64, :aarch64]
  end

  test "domain_os_xml/0 and domain_cpu_xml/0 match the running host's arch" do
    case VMUtils.host_arch() do
      :aarch64 ->
        os_xml = VMUtils.domain_os_xml()
        assert os_xml =~ "firmware='efi'"
        assert os_xml =~ "machine='virt'"
        assert os_xml =~ ~s(<type arch='aarch64' machine='virt'>hvm</type>)
        assert os_xml =~ "<boot dev='hd'/>"

        assert VMUtils.domain_cpu_xml() =~ "host-passthrough"

      :x86_64 ->
        assert VMUtils.domain_os_xml() == """
               <os>
                 <type arch="x86_64">hvm</type>
                 <boot dev="hd"/>
               </os>\
               """

        assert VMUtils.domain_cpu_xml() == ""
    end
  end
end
