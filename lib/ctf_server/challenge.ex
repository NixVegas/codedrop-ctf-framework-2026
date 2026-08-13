defprotocol CtfServer.Challenge do
  alias CtfServer.Accounts.Team

  @type t :: t()

  @typedoc """
  Flag for use with a challenge.

  Should be of the form `NIX{<whatever}`.
  """
  @type flag :: String.t()

  @typedoc """
  Score given for a challenge.
  """
  @type score :: non_neg_integer()

  @doc """
  Gets the friendly name of a challenge.
  """
  @spec group(t) :: String.t()
  def name(challenge)

  @doc """
  Gets the group for the challenge.
  """
  @spec group(t) :: String.t()
  def group(challenge)

  @doc """
  Gets the max score possible for a challenge.
  """
  @spec max_score(t()) :: score()
  def max_score(challenge)

  @doc """
  Gets the level for the challenge.
  """
  @spec level(t) :: non_neg_integer()
  def level(challenge)

  @doc """
  Gets the description (usually markdown) of the challenge.
  """
  @spec description(t) :: String.t()
  def description(challenge)

  @doc """
  Generates the flag for the challenge.
  """
  @spec create_flag(t(), Team.t()) :: {:ok, flag()} | {:error, any}
  def create_flag(challenge, team)

  @doc """
  Does whatever setup is required to instantiate a challenge for a team.

  After running, we expect there to be an active challenge attempt with associated resources
  (e.g., VMs on a private network, SSH access configured).

  * `attempt` is the ChallengeAttempt (preloaded with :team), which carries the id, flag, port, etc.
  * `pubkey` is the SSH public key to authorize for the team
  """
  @spec instantiate_challenge_attempt(t(), CtfServer.ChallengeAttempt.t(), String.t()) ::
          :ok | {:error, any()}
  def instantiate_challenge_attempt(challenge, attempt, pubkey)

  @doc """
  Cleans up the resources associated with a challenge attempt, e.g., destroying VMs, tearing down networks, etc.
  """
  @spec cleanup_challenge_attempt(t(), CtfServer.ChallengeAttempt.t()) :: :ok | {:error, any()}
  def cleanup_challenge_attempt(challenge, attempt)

  @doc """
  Scores a challenge attempt, returning a score.
  """
  @spec score_challenge_attempt(t(), Team.t(), flag()) :: {:error, any} | {:ok, score()}
  def score_challenge_attempt(challenge, team, flag)
end
