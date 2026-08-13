defmodule CtfServer.Challenges.NixEcosystem1 do
  @moduledoc """
  Nix Ecosystem 1 — "navigating the source for answers".

  A no-VM challenge: players browse the nixpkgs checkout on the on-site forgejo,
  locate the start of the block in the nginx module where the actual gzip
  settings are defined, and submit `sha256("<path>:<line>")` as the flag.

  ## Finalizing before the event

  `@answer` is that location as `<path>:<line>`, path relative to the nixpkgs
  root. It **must** be verified against the exact nixpkgs revision served by the
  on-site forgejo and updated if it drifts (line numbers move between revisions).
  The target is the **first line of the `optionalString cfg.recommendedGzipSettings`
  block** — the block that emits the real `gzip on; gzip_types …;` directives —
  and the description must point players at that same line.
  """
  @behaviour CtfServer.ChallengeBehavior
  defstruct []

  # The location players must find: the first line of the
  # `optionalString cfg.recommendedGzipSettings` block (where the real gzip
  # directives are defined), as `<path>:<line>` relative to the nixpkgs root.
  # Pinned against nixos-26.05 (the branch the on-site forgejo mirrors); line
  # 237 is the `${optionalString cfg.recommendedGzipSettings` block opener, not
  # the line 627 `mkOption` declaration. RE-VERIFY against the deployed forgejo
  # revision before the event — the mirror tracks the branch tip, so a commit
  # that shifts this block moves the line.
  @answer "nixos/modules/services/web-servers/nginx/default.nix:237"

  def group, do: "nix-ecosystem"
  def level, do: 1
  def max_score, do: 100
  def name, do: "Reading the Source"

  # No VM — solved by browsing the nixpkgs checkout on the on-site forgejo.
  def vm_base_config, do: nil

  def description,
    do: """
    # Reading the Source

    Documentation only gets you so far. Sooner or later the real answer is in the
    source, and knowing how to read nixpkgs is a superpower.

    ## The task

    When you enable `services.nginx.recommendedGzipSettings`, where does the
    actual gzip configuration come from? Find the spot in the NixOS nginx module,
    in the nixpkgs tree on the CTF forgejo, where those settings are actually
    defined — the start of the block that emits the real `gzip on; gzip_types …;`
    directives (guarded by `optionalString cfg.recommendedGzipSettings`).

    Form the string `<path>:<line>`, where:

    * `<path>` is the file path **relative to the nixpkgs root**, using forward
      slashes and no leading `./` (e.g. `nixos/modules/services/web-servers/nginx/default.nix`).
    * `<line>` is the line number where that block **begins**, in decimal, with
      no padding.

    The flag is the SHA-256 of that exact string, in lowercase hex.

    ## Watch out

    Hash the string with **no trailing newline**. For example, for a made-up
    location `pkgs/foo/bar.nix:42`:

    ```
    printf '%s' 'pkgs/foo/bar.nix:42' | sha256sum
    ```

    (Note `printf`/`echo -n` — a stray newline will change the hash.)

    ## Submit

    Submit your flag as `Nix{<sha256hex>}`.
    """

  @doc false
  def answer, do: @answer

  @doc false
  def expected_flag, do: :crypto.hash(:sha256, @answer) |> Base.encode16(case: :lower)

  defimpl CtfServer.Challenge do
    alias CtfServer.Accounts.Team

    def name(_challenge), do: @for.name()
    def description(_challenge), do: @for.description()
    def group(_challenge), do: @for.group()
    def level(_challenge), do: @for.level()
    def max_score(_challenge), do: @for.max_score()

    # Universal flag — sharing is fine for this track, so it does not depend on
    # the team. It is the SHA-256 of the definition site players must find.
    def create_flag(_challenge, %Team{} = _team), do: {:ok, @for.expected_flag()}

    # No VM to stand up or tear down.
    def instantiate_challenge_attempt(_challenge, _attempt, _pubkey), do: :ok
    def cleanup_challenge_attempt(_challenge, _attempt), do: :ok

    def score_challenge_attempt(challenge, %Team{} = _team, flag) do
      if flag == @for.expected_flag() do
        {:ok, max_score(challenge)}
      else
        {:error, "Wrong flag."}
      end
    end
  end
end
