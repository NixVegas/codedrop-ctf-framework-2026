defmodule Mix.Tasks.Ctf.BuildVmBases do
  @moduledoc """
  Builds base VM disk images for all challenges that ship a `vm.nix`.

  This is a thin wrapper around Nix: it runs `nix build .#vm-bases`, which
  evaluates and builds every `priv/challenges/<name>/vm.nix` into a qcow2
  using the flake's pinned nixpkgs. Nix handles caching, closure dedup, and
  parallelism — re-running when nothing changed is effectively free.

  The build is registered as a Nix GC root (`<vm_base_image_path>/.vm-bases`)
  so the store paths survive `nix-collect-garbage` while VMs depend on them.
  Each image is then symlinked to `{group}_{level}.qcow2` — the name the
  runtime provisioner and `mix ctf.test_vm` expect.

  ## Usage

      mix ctf.build_vm_bases
  """

  use Mix.Task

  @shortdoc "Builds base VM qcow2 images for challenges"

  @impl Mix.Task
  def run(_args) do
    CtfServer.MixHelpers.start_app_insert_only()

    output_dir = Application.fetch_env!(:ctf_server, :vm_base_image_path)
    File.mkdir_p!(output_dir)

    challenges_with_configs =
      CtfServer.Challenges.get_available_challenges()
      |> Enum.filter(&function_exported?(&1.__struct__, :vm_base_config, 0))

    if Enum.empty?(challenges_with_configs) do
      Mix.shell().info("No challenges with vm_base_config found.")
    else
      Mix.shell().info(
        "Building base VM images for #{length(challenges_with_configs)} challenge(s) via `nix build`..."
      )

      gcroot = Path.join(output_dir, ".vm-bases")

      args = [
        "build",
        ".#vm-bases",
        "--out-link",
        gcroot,
        "--print-out-paths",
        "--extra-experimental-features",
        "nix-command flakes"
      ]

      case System.cmd("nix", args, stderr_to_stdout: true) do
        {output, 0} ->
          store_path = output |> String.trim() |> String.split("\n") |> List.last()
          Mix.shell().info("  ✓ Built #{store_path}")
          link_images(gcroot, output_dir)

        {output, exit_code} ->
          Mix.raise("nix build failed (exit #{exit_code}):\n#{output}")
      end
    end
  end

  # Mirror every image name from the freshly built aggregate into the output
  # dir the provisioner reads. The aggregate (`.#vm-bases`) already names each
  # image under its runtime name(s) — one per single-VM challenge, one per
  # cluster node (`{group}_{level}_{role}.qcow2`) — so this is agnostic to how
  # many images a challenge produces.
  defp link_images(gcroot, output_dir) do
    # Stream the entries so we filter + symlink one at a time rather than
    # building intermediate lists. (`File.ls!` itself still returns the full
    # directory listing — the stdlib has no lazy readdir — but that's bounded
    # by the number of built images.)
    gcroot
    |> File.ls!()
    |> Stream.filter(&String.ends_with?(&1, ".qcow2"))
    |> Stream.each(fn name ->
      src = Path.join(gcroot, name)
      dest = Path.join(output_dir, name)
      _ = File.rm(dest)
      :ok = File.ln_s(src, dest)
      Mix.shell().info("  ✓ #{name}")
    end)
    |> Stream.run()
  end
end
