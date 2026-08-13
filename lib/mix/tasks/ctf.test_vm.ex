defmodule Mix.Tasks.Ctf.TestVm do
  @moduledoc """
  Boots a challenge VM for manual testing.

  Creates a CoW overlay from the base image, injects a test SSH key via
  guestfish, and launches the VM with SSH forwarded. The base image is
  never modified.

  ## Usage

      mix ctf.test_vm basic-nix 1
      mix ctf.test_vm basic-nix 1 --port 2222

  Press Ctrl-a x to kill the VM.
  """

  use Mix.Task

  @shortdoc "Boot a challenge VM for manual testing"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [port: :integer])
    ssh_port = Keyword.get(opts, :port, 2222)

    case positional do
      [group, level_str] ->
        level = String.to_integer(level_str)
        test_vm(group, level, ssh_port)

      _ ->
        Mix.shell().error("Usage: mix ctf.test_vm <group> <level> [--port PORT]")
        Mix.shell().error("Example: mix ctf.test_vm basic-nix 1")
    end
  end

  defp test_vm(group, level, ssh_port) do
    base_image_dir =
      Application.get_env(
        :ctf_server,
        :vm_base_image_path,
        Path.join(File.cwd!(), "priv/vm_bases")
      )

    base_image = Path.join(base_image_dir, "#{group}_#{level}.qcow2")

    unless File.exists?(base_image) do
      Mix.raise("Base image not found: #{base_image}\nRun `mix ctf.build_vm_bases` first.")
    end

    {:ok, tmp_dir} = Temp.mkdir(prefix: "ctf-test")
    overlay_path = Path.join(tmp_dir, "test-overlay.qcow2")
    key_path = Path.join(tmp_dir, "test-key")
    pubkey_path = "#{key_path}.pub"

    # Generate test SSH key
    Mix.shell().info("Generating test SSH keypair...")

    {_, 0} =
      System.cmd("ssh-keygen", ["-t", "ed25519", "-f", key_path, "-N", ""],
        stderr_to_stdout: true
      )

    pubkey = File.read!(pubkey_path)

    # Create overlay
    Mix.shell().info("Creating overlay...")
    {:ok, _} = CtfUtils.VMUtils.create_overlay(base_image, overlay_path)

    # Inject the SSH key plus the same login banner players get. These VMs
    # don't show /etc/motd over SSH, so the banner is delivered through the
    # ctf user's ~/.bash_profile (see CtfServer.ChallengeBanner).
    banner_files =
      case CtfServer.Challenges.get_challenge_by_group_and_level(group, level) do
        {:ok, challenge} -> CtfServer.ChallengeBanner.login_files(challenge)
        {:error, :not_found} -> []
      end

    Mix.shell().info("Injecting SSH key and banner...")

    :ok =
      CtfUtils.VMUtils.inject_files(
        overlay_path,
        [{"/home/ctf/.ssh/authorized_keys", pubkey}] ++ banner_files
      )

    Mix.shell().info("")
    Mix.shell().info("=== VM ready ===")
    Mix.shell().info("SSH in from another terminal:")
    Mix.shell().info("")

    Mix.shell().info(
      "  ssh -i #{key_path} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -p #{ssh_port} ctf@localhost"
    )

    Mix.shell().info("")
    Mix.shell().info("Press Ctrl-a x to kill the VM.")
    Mix.shell().info("================")
    Mix.shell().info("")

    # Boot VM — this blocks until the VM exits
    Port.open(
      {:spawn_executable, System.find_executable("qemu-system-x86_64")},
      [
        :binary,
        :nouse_stdio,
        args: [
          "-drive",
          "file=#{overlay_path},format=qcow2,if=virtio",
          "-m",
          "1024",
          "-nographic",
          "-net",
          "nic",
          "-net",
          "user,hostfwd=tcp::#{ssh_port}-:22"
        ]
      ]
    )

    # Wait for the VM process to exit
    receive do
      {_, {:exit_status, _}} -> :ok
    end

    # Cleanup
    File.rm_rf!(tmp_dir)
    Mix.shell().info("Cleaned up test files.")
  end
end
