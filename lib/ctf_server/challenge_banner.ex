defmodule CtfServer.ChallengeBanner do
  @moduledoc """
  Builds the per-challenge banner shown when a player SSHes into their VM.

  We deliberately don't force a shell — everyone lands in the same normal
  shell — but we greet them with the challenge name and a nudge toward the
  intended approach.

  The challenge VMs don't display `/etc/motd` over SSH (sshd runs with
  `PrintMotd no`, no `Banner`, and no `pam_motd` in the PAM stack), so the
  banner is delivered through the `ctf` user's `~/.bash_profile`, injected
  per-attempt into the overlay alongside the SSH key and challenge files.
  """

  alias CtfServer.Challenge

  # Printed by the login shell. Kept static; the per-challenge text lives in
  # ~/.ctf-banner so we never have to shell-quote it here.
  @bash_profile """
  # NixCTF: greet the player on interactive login. Injected per
  # challenge attempt; safe to delete.
  if [ -f "$HOME/.ctf-banner" ]; then
    cat "$HOME/.ctf-banner"
  fi
  if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
  fi
  """

  @bar String.duplicate("=", 68)

  # Fallback egress policy if the app isn't told the deployed one (dev/test).
  # Mirrors the ctf-libvirt defaults; prod overrides flow in via app config
  # (:vm_egress_allow_subnets / :vm_internal_zones, set from the NixOS module).
  @default_allow_subnets ["10.4.2.0/24"]
  @default_internal_zones ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]

  @doc """
  Renders the banner text for a challenge (the `%CtfServer.Challenges.*{}`
  struct).
  """
  def render(challenge, internet? \\ false) do
    """
    #{@bar}
     NixCTF
     #{Challenge.name(challenge)}
     #{Challenge.group(challenge)} / level #{Challenge.level(challenge)} / #{Challenge.max_score(challenge)} pts
    #{@bar}

    #{task_section(Challenge.description(challenge))}

    You're in an ordinary shell with everything you need. Poke around with
    the tools you know. Run `ctf-help` to see this again, or `ctf-help <command>`
    for quick usage on a tool (e.g. `ctf-help nix`). When you've found the flag,
    submit it on the web dashboard in Nix{...} form; the challenge's web page
    has the full hints.
    #{@bar}
     Network filtering (egress from this box)
    #{@bar}
    #{network_section(internet?)}
    #{@bar}
    """
  end

  @doc """
  Files to inject into an attempt overlay so the banner shows on login.

  Append to a challenge's `VMUtils.inject_files/2` list. Pass `internet?: true`
  for a node whose domain uses the `ctf-egress-internet` filter, so the banner
  states plainly that this box reaches the public internet.
  """
  def login_files(challenge, internet? \\ false) do
    [
      {"/home/ctf/.ctf-banner", render(challenge, internet?)},
      {"/home/ctf/.bash_profile", @bash_profile}
    ]
  end

  # A human-readable listing of the egress nwfilter policy every challenge VM
  # runs under (see nix/ctf-libvirt.nix). The exact CIDRs come from app config
  # (set from the NixOS module) so this stays in sync with the deployed rules;
  # dev/test falls back to the module defaults. `internet?` is whether this box's
  # domain uses the internet egress filter, stated explicitly for the player.
  defp network_section(internet?) do
    allow = Application.get_env(:ctf_server, :vm_egress_allow_subnets, @default_allow_subnets)
    deny = Application.get_env(:ctf_server, :vm_internal_zones, @default_internal_zones)

    reachable_targets =
      ["your own /24 (any cluster peers)" | allow] ++
        if internet?, do: ["the public internet (any other address)"], else: []

    reachable = Enum.map(reachable_targets, &"  reachable  #{&1}")
    blocked = Enum.map(deny, &"  blocked    #{&1}")

    verdict =
      if internet? do
        [
          "  >> This challenge HAS public internet access. <<",
          "  Other CTF machines and the arena fabric are still blocked."
        ]
      else
        [
          "  >> This challenge has NO public internet access. <<",
          "  The public internet, other CTF machines, and the arena fabric",
          "  are all blocked; only the addresses above are reachable."
        ]
      end

    ([
       "This box's outbound traffic is firewalled. Effective rules:",
       ""
     ] ++
       reachable ++
       blocked ++
       ["" | verdict])
    |> Enum.join("\n")
  end

  # Pull the "## The task" section out of the challenge's markdown
  # description; fall back to the intro paragraph if it isn't there.
  defp task_section(description) do
    lines = String.split(description, "\n")

    case Enum.find_index(lines, &(String.trim(&1) == "## The task")) do
      nil ->
        intro_paragraph(description)

      idx ->
        lines
        |> Enum.drop(idx + 1)
        |> Enum.take_while(&(not String.starts_with?(String.trim(&1), "## ")))
        |> Enum.join("\n")
        |> String.trim()
    end
  end

  defp intro_paragraph(description) do
    description
    |> String.split("\n")
    |> Enum.drop_while(&(String.starts_with?(String.trim(&1), "#") or String.trim(&1) == ""))
    |> Enum.take_while(&(String.trim(&1) != ""))
    |> Enum.join("\n")
    |> String.trim()
  end
end
