defmodule CtfServer.Challenges.CaptureThePoll do
  @behaviour CtfServer.ChallengeBehavior
  defstruct []

  def group, do: "capture-the-poll"
  def level, do: 1
  def max_score, do: 100
  def name, do: "Capture the Poll"

  # Cluster challenge: the per-role images are built by the flake from
  # priv/challenges/capture_the_poll_1/nodes/{web,poller,ingress}.nix and named
  # capture-the-poll_1_{role}.qcow2. This returns the shared base so
  # `Challenges.needs_vm?/1` (which reads nil-ness) sees a VM challenge and a
  # port is checked out for the ingress node; the string itself is not built.
  def vm_base_config do
    :ctf_server
    |> :code.priv_dir()
    |> Path.join("challenges/capture_the_poll_1/vm.nix")
    |> File.read!()
  end

  def description,
    do: """
    # Capture the Poll

    Your attempt is a small **cluster**: a `web` box serves a page, a `poller`
    box fetches it over plain HTTP on a loop, and the box you SSH into sits on
    the same network with packet-capture tools.

    ## The task

    The flag is never shown to you directly — it only crosses the wire between
    the other two machines. Sniff it.

    ## Hints

    * You land on the capture box. `tcpdump`/`tshark` are installed.
    * The poller fetches the flag from the web box every few seconds; watch the
      HTTP traffic on your primary interface.
    * `tshark -i eth0 -Y http -T fields -e http.file_data` will print response
      bodies as they fly past.
    """

  defimpl CtfServer.Challenge do
    alias CtfServer.Accounts.Team
    alias CtfUtils.VMUtils

    def name(_challenge), do: @for.name()
    def description(_challenge), do: @for.description()
    def group(_challenge), do: @for.group()
    def level(_challenge), do: @for.level()
    def max_score(_challenge), do: @for.max_score()

    def create_flag(_challenge, %Team{} = team) do
      {:ok, @for.expected_flag(team)}
    end

    def instantiate_challenge_attempt(challenge, attempt, pubkey) do
      flag = @for.expected_flag(attempt.team)

      # web is node 0 (`.2`); the poller fetches it by that pinned IP.
      web_url = "http://#{VMUtils.guest_ip(attempt.id, 0)}/flag.txt"

      priv = fn file ->
        :ctf_server
        |> :code.priv_dir()
        |> Path.join("challenges/capture_the_poll_1/#{file}")
      end

      VMUtils.start_cluster(
        attempt,
        [
          %{
            role: "web",
            ingress?: false,
            base_image: "capture-the-poll_1_web.qcow2",
            domain_template: priv.("nodes/peer.domain.xml.eex"),
            files: [{"/var/www/flag.txt", flag <> "\n"}]
          },
          %{
            role: "poller",
            ingress?: false,
            base_image: "capture-the-poll_1_poller.qcow2",
            domain_template: priv.("nodes/peer.domain.xml.eex"),
            files: [{"/etc/ctf/poll-url", web_url <> "\n"}]
          },
          %{
            role: "ingress",
            ingress?: true,
            base_image: "capture-the-poll_1_ingress.qcow2",
            domain_template: priv.("nodes/ingress.domain.xml.eex"),
            files:
              [{"/home/ctf/.ssh/authorized_keys", pubkey}] ++
                CtfServer.ChallengeBanner.login_files(challenge)
          }
        ],
        hub_mode: true
      )
    end

    def cleanup_challenge_attempt(_challenge, attempt) do
      VMUtils.teardown_cluster(attempt)
    end

    def score_challenge_attempt(challenge, %Team{} = team, flag) do
      if flag == @for.expected_flag(team) do
        {:ok, max_score(challenge)}
      else
        {:error, "Wrong flag."}
      end
    end
  end

  @doc false
  def generate_seed(%CtfServer.Accounts.Team{} = team) do
    CtfServer.Flag.seed("capture-the-poll-1", team)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc false
  def expected_flag(%CtfServer.Accounts.Team{} = team) do
    :crypto.hash(:sha256, generate_seed(team)) |> Base.encode16(case: :lower)
  end
end
