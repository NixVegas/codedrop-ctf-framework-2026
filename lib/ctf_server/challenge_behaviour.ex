defmodule CtfServer.ChallengeBehavior do
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
  @callback name() :: String.t()

  @doc """
  Gets the group for the challenge.
  """
  @callback group() :: String.t()

  @doc """
  Gets the max score possible for a challenge.
  """
  @callback max_score() :: score()

  @doc """
  Gets the level for the challenge.
  """
  @callback level() :: non_neg_integer()

  @doc """
  Returns the Nix expression string for building this challenge's base VM image.

  Return `nil` if the challenge does not require a VM.
  """
  @callback vm_base_config() :: String.t() | nil

  @doc """
  Optional per-team "answer key" recorded on the attempt for staff.

  Returns a JSON-encodable map stored in `challenge_attempt.flag` and shown only
  on the admin team page — never read for scoring (which stays stateless). A
  challenge with several flags/values (e.g. a base and a bonus flag, a planted
  password) lists them here so staff can verify submissions at a glance. If a
  challenge does not implement this, the attempt records `%{"flag" => "Nix{...}"}`
  from `create_flag/2`.
  """
  @callback reference_values(team :: CtfServer.Accounts.Team.t()) :: map()

  @optional_callbacks [vm_base_config: 0, reference_values: 1]

  # The optional per-capture completion message is the `CtfServer.CompletionMessage`
  # protocol (dispatched on the challenge struct, with an `Any` default) rather
  # than a callback here.
end
