defmodule CtfServer.Challenges.BasicNix1 do
  @behaviour CtfServer.ChallengeBehavior
  defstruct do
  end

  def group, do: "basic-nix"
  def level, do: 1
  def max_score, do: 100
  def name, do: "Your First Nix Expression"

  def vm_base_config do
    :ctf_server
    |> :code.priv_dir()
    |> Path.join("challenges/basic_nix_1/vm.nix")
    |> File.read!()
  end

  def description,
    do: """
    # Your First Nix Expression

    This challenge will get you familiar with logging into a CTF machine, running a basic nix expression, and capturing a flag.

    ## The task

    On your challenge VM, you'll find a file at `~/challenge.txt`. Your goal is to compute the SHA-256 hash of its contents using Nix builtins, and submit the result as your flag.

    ## Hints

    * You can start an interactive Nix REPL with `nix repl`. Type `:?` for help once inside.
    * Check out [builtins.hashString](https://nix.dev/manual/nix/2.28/language/builtins.html#builtins-hashString) and [builtins.readFile](https://nix.dev/manual/nix/2.28/language/builtins.html#builtins-readFile).
    * You can also evaluate expressions directly from the command line: `nix eval --expr '<expression>'`
    * The flag format is `Nix{<hash>}`.
    """

  defimpl CtfServer.Challenge do
    alias CtfServer.Accounts.Team

    def name(_challenge), do: @for.name()
    def description(_challenge), do: @for.description()
    def group(_challenge), do: @for.group()
    def level(_challenge), do: @for.level()
    def max_score(_challenge), do: @for.max_score()

    def create_flag(_challenge, %Team{} = team) do
      seed = @for.generate_seed(team)
      hash = :crypto.hash(:sha256, seed) |> Base.encode16(case: :lower)
      {:ok, hash}
    end

    def instantiate_challenge_attempt(challenge, attempt, pubkey) do
      seed = @for.generate_seed(attempt.team)

      CtfUtils.VMUtils.start_cluster(attempt, [
        %{
          role: "main",
          ingress?: true,
          base_image: "basic-nix_1.qcow2",
          domain_template:
            :ctf_server
            |> :code.priv_dir()
            |> Path.join("challenges/basic_nix_1/domain.xml.eex"),
          files:
            [
              {"/home/ctf/.ssh/authorized_keys", pubkey},
              {"/home/ctf/challenge.txt", seed}
            ] ++ CtfServer.ChallengeBanner.login_files(challenge)
        }
      ])
    end

    def cleanup_challenge_attempt(_challenge, attempt) do
      CtfUtils.VMUtils.teardown_cluster(attempt)
    end

    def score_challenge_attempt(challenge, %Team{} = team, flag) do
      expected_hash =
        :crypto.hash(:sha256, @for.generate_seed(team)) |> Base.encode16(case: :lower)

      if flag == expected_hash do
        {:ok, max_score(challenge)}
      else
        {:error, "Wrong flag."}
      end
    end
  end

  @doc false
  def generate_seed(%CtfServer.Accounts.Team{} = team) do
    CtfServer.Flag.seed("basic-nix-1", team)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
