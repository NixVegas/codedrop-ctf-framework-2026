defmodule CtfServer.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias CtfServer.Audit
  alias CtfServer.Repo

  alias CtfServer.Accounts.{Team, TeamToken, TeamNotifier, InviteCode}
  alias CtfServer.Competition
  alias CtfServer.WordList

  ## Database getters

  @doc """
  Gets a team by email.

  ## Examples

      iex> get_team_by_email("foo@example.com")
      %Team{}

      iex> get_team_by_email("unknown@example.com")
      nil

  """
  def get_team_by_email(email) when is_binary(email) do
    Repo.get_by(Team, email: email)
  end

  @doc """
  Gets a team by email and password.

  ## Examples

      iex> get_team_by_email_and_password("foo@example.com", "correct_password")
      %Team{}

      iex> get_team_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_team_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    team = Repo.get_by(Team, email: email)
    if Team.valid_password?(team, password) and is_nil(team.disabled_at), do: team
  end

  @doc """
  Gets a single team.

  Raises `Ecto.NoResultsError` if the Team does not exist.

  ## Examples

      iex> get_team!(123)
      %Team{}

      iex> get_team!(456)
      ** (Ecto.NoResultsError)

  """
  def get_team!(id), do: Repo.get!(Team, id)

  @doc """
  Lists all teams, newest first.
  """
  def list_teams do
    Repo.all(from t in Team, order_by: [desc: t.inserted_at])
  end

  ## Team registration

  @doc """
  Whether newly registered teams should be confirmed immediately, skipping
  the confirmation email. Configured via `:skip_account_confirmation` and
  the `CTF_SERVER_SKIP_ACCOUNT_CONFIRMATION` environment variable.
  """
  def skip_account_confirmation? do
    Application.get_env(:ctf_server, :skip_account_confirmation, true)
  end

  @doc """
  Whether registration requires an invite code for remote clients. Off by
  default (dev/test); prod enables it via `CTF_SERVER_REQUIRE_INVITE_CODES`.
  """
  def require_invite_codes? do
    Application.get_env(:ctf_server, :require_invite_codes, false)
  end

  @doc """
  Registers a team. `opts[:local?]` (default true) and `opts[:client_ip]`
  describe the client. When invite codes are required and the client is remote,
  `attrs["invite_code"]` must redeem an unused code.

  ## Examples

      iex> register_team(%{field: value})
      {:ok, %Team{}}

      iex> register_team(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_team(attrs, opts \\ []) do
    if not Competition.registration_open?() do
      {:error, :registration_closed}
    else
      local? = Keyword.get(opts, :local?, true)
      client_ip = Keyword.get(opts, :client_ip)
      remote? = not local?

      changeset =
        %Team{}
        |> Team.registration_changeset(normalize_attrs(attrs))
        |> Ecto.Changeset.change(registered_remote: remote?, registration_ip: client_ip)

      changeset =
        if skip_account_confirmation?() do
          Team.confirm_changeset(changeset)
        else
          changeset
        end

      if require_invite_codes?() and remote? do
        register_team_with_code(changeset, fetch_invite_code(attrs))
      else
        insert_team(changeset)
      end
    end
  end

  # Accepts string- or atom-keyed attrs; drops the invite_code key so it never
  # reaches the changeset cast.
  defp normalize_attrs(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.delete("invite_code")
  end

  defp fetch_invite_code(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.get("invite_code")
  end

  defp insert_team(changeset) do
    with {:ok, team} <- Repo.insert(changeset) do
      Audit.create_account(team)
      {:ok, team}
    end
  end

  defp register_team_with_code(_changeset, code) when code in [nil, ""] do
    {:error, :invalid_invite_code}
  end

  defp register_team_with_code(changeset, code) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:team, changeset)
    |> Ecto.Multi.run(:code, fn repo, %{team: team} ->
      {count, _} =
        repo.update_all(
          from(c in InviteCode, where: c.code == ^code and is_nil(c.redeemed_at)),
          set: [redeemed_at: now, redeemed_by_team_id: team.id]
        )

      if count == 1, do: {:ok, team}, else: {:error, :invalid_invite_code}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{team: team}} ->
        Audit.create_account(team)
        {:ok, team}

      {:error, :code, :invalid_invite_code, _} ->
        {:error, :invalid_invite_code}

      {:error, _, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Registers a team on behalf of an admin.

  The team is confirmed immediately regardless of the
  `:skip_account_confirmation` setting, since no confirmation email reaches
  admin-created accounts.
  """
  def admin_register_team(attrs, actor \\ nil) do
    with {:ok, team} <-
           %Team{}
           |> Team.registration_changeset(attrs)
           |> Team.confirm_changeset()
           |> Repo.insert() do
      Audit.create_account(team, actor)
      {:ok, team}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking team changes.

  ## Examples

      iex> change_team_registration(team)
      %Ecto.Changeset{data: %Team{}}

  """
  def change_team_registration(%Team{} = team, attrs \\ %{}) do
    Team.registration_changeset(team, attrs, hash_password: false, validate_email: false)
  end

  ## Settings

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the team email.

  ## Examples

      iex> change_team_email(team)
      %Ecto.Changeset{data: %Team{}}

  """
  def change_team_email(team, attrs \\ %{}) do
    Team.email_changeset(team, attrs, validate_email: false)
  end

  @doc """
  Emulates that the email will change without actually changing
  it in the database.

  ## Examples

      iex> apply_team_email(team, "valid password", %{email: ...})
      {:ok, %Team{}}

      iex> apply_team_email(team, "invalid password", %{email: ...})
      {:error, %Ecto.Changeset{}}

  """
  def apply_team_email(team, password, attrs) do
    team
    |> Team.email_changeset(attrs)
    |> Team.validate_current_password(password)
    |> Ecto.Changeset.apply_action(:update)
  end

  @doc """
  Updates the team email using the given token.

  If the token matches, the team email is updated and the token is deleted.
  The confirmed_at date is also updated to the current time.
  """
  def update_team_email(team, token) do
    context = "change:#{team.email}"

    with {:ok, query} <- TeamToken.verify_change_email_token_query(token, context),
         %TeamToken{sent_to: email} <- Repo.one(query),
         {:ok, _} <- Repo.transaction(team_email_multi(team, email, context)) do
      :ok
    else
      _ -> :error
    end
  end

  defp team_email_multi(team, email, context) do
    changeset =
      team
      |> Team.email_changeset(%{email: email})
      |> Team.confirm_changeset()

    Ecto.Multi.new()
    |> Ecto.Multi.update(:team, changeset)
    |> Ecto.Multi.delete_all(:tokens, TeamToken.by_team_and_contexts_query(team, [context]))
  end

  @doc ~S"""
  Delivers the update email instructions to the given team.

  ## Examples

      iex> deliver_team_update_email_instructions(team, current_email, &url(~p"/teams/settings/confirm_email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_team_update_email_instructions(%Team{} = team, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, team_token} = TeamToken.build_email_token(team, "change:#{current_email}")

    Repo.insert!(team_token)
    TeamNotifier.deliver_update_email_instructions(team, update_email_url_fun.(encoded_token))
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the team password.

  ## Examples

      iex> change_team_password(team)
      %Ecto.Changeset{data: %Team{}}

  """
  def change_team_password(team, attrs \\ %{}) do
    Team.password_changeset(team, attrs, hash_password: false)
  end

  @doc """
  Updates the team password.

  ## Examples

      iex> update_team_password(team, "valid password", %{password: ...})
      {:ok, %Team{}}

      iex> update_team_password(team, "invalid password", %{password: ...})
      {:error, %Ecto.Changeset{}}

  """
  def update_team_password(team, password, attrs) do
    changeset =
      team
      |> Team.password_changeset(attrs)
      |> Team.validate_current_password(password)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:team, changeset)
    |> Ecto.Multi.delete_all(:tokens, TeamToken.by_team_and_contexts_query(team, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{team: team}} -> {:ok, team}
      {:error, :team, changeset, _} -> {:error, changeset}
    end
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_team_session_token(team) do
    {token, team_token} = TeamToken.build_session_token(team)
    Repo.insert!(team_token)
    token
  end

  @doc """
  Gets the team with the given signed token.
  """
  def get_team_by_session_token(token) do
    {:ok, query} = TeamToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_team_session_token(token) do
    Repo.delete_all(TeamToken.by_token_and_context_query(token, "session"))
    :ok
  end

  ## Confirmation

  @doc ~S"""
  Delivers the confirmation email instructions to the given team.

  ## Examples

      iex> deliver_team_confirmation_instructions(team, &url(~p"/teams/confirm/#{&1}"))
      {:ok, %{to: ..., body: ...}}

      iex> deliver_team_confirmation_instructions(confirmed_team, &url(~p"/teams/confirm/#{&1}"))
      {:error, :already_confirmed}

  """
  def deliver_team_confirmation_instructions(%Team{} = team, confirmation_url_fun)
      when is_function(confirmation_url_fun, 1) do
    if team.confirmed_at do
      {:error, :already_confirmed}
    else
      {encoded_token, team_token} = TeamToken.build_email_token(team, "confirm")
      Repo.insert!(team_token)
      TeamNotifier.deliver_confirmation_instructions(team, confirmation_url_fun.(encoded_token))
    end
  end

  @doc """
  Confirms a team by the given token.

  If the token matches, the team account is marked as confirmed
  and the token is deleted.
  """
  def confirm_team(token) do
    with {:ok, query} <- TeamToken.verify_email_token_query(token, "confirm"),
         %Team{} = team <- Repo.one(query),
         {:ok, %{team: team}} <- Repo.transaction(confirm_team_multi(team)) do
      Audit.confirm_account(team)
      {:ok, team}
    else
      _ -> :error
    end
  end

  defp confirm_team_multi(team) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:team, Team.confirm_changeset(team))
    |> Ecto.Multi.delete_all(:tokens, TeamToken.by_team_and_contexts_query(team, ["confirm"]))
  end

  @doc """
  Confirms a team directly, without a confirmation token.

  Intended for admins confirming accounts by hand.
  """
  def admin_confirm_team(%Team{} = team, actor \\ nil) do
    case Repo.transaction(confirm_team_multi(team)) do
      {:ok, %{team: team}} ->
        Audit.confirm_account(team, actor)
        {:ok, team}

      {:error, :team, changeset, _} ->
        {:error, changeset}
    end
  end

  ## Reset password

  @doc ~S"""
  Delivers the reset password email to the given team.

  ## Examples

      iex> deliver_team_reset_password_instructions(team, &url(~p"/teams/reset_password/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_team_reset_password_instructions(%Team{} = team, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    {encoded_token, team_token} = TeamToken.build_email_token(team, "reset_password")
    Repo.insert!(team_token)
    TeamNotifier.deliver_reset_password_instructions(team, reset_password_url_fun.(encoded_token))
  end

  @doc """
  Generates a one-time password reset code for the given team.

  Intended for admins handing a reset code to a team out of band. The code
  is the same token used by the email reset flow: it is redeemed at
  `/teams/reset_password/:code`, expires after one day, and is deleted
  (along with all other tokens for the team) once the password is reset.
  """
  def generate_team_reset_password_code(%Team{} = team, actor \\ nil) do
    {encoded_token, team_token} = TeamToken.build_email_token(team, "reset_password")
    Repo.insert!(team_token)
    Audit.create_reset_code(team, actor)
    encoded_token
  end

  @doc """
  Gets the team by reset password token.

  ## Examples

      iex> get_team_by_reset_password_token("validtoken")
      %Team{}

      iex> get_team_by_reset_password_token("invalidtoken")
      nil

  """
  def get_team_by_reset_password_token(token) do
    with {:ok, query} <- TeamToken.verify_email_token_query(token, "reset_password"),
         %Team{} = team <- Repo.one(query) do
      team
    else
      _ -> nil
    end
  end

  @doc """
  Resets the team password.

  ## Examples

      iex> reset_team_password(team, %{password: "new long password", password_confirmation: "new long password"})
      {:ok, %Team{}}

      iex> reset_team_password(team, %{password: "valid", password_confirmation: "not the same"})
      {:error, %Ecto.Changeset{}}

  """
  def reset_team_password(team, attrs) do
    Audit.reset_password_attempted(team)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:team, Team.password_changeset(team, attrs))
    |> Ecto.Multi.delete_all(:tokens, TeamToken.by_team_and_contexts_query(team, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{team: team}} ->
        Audit.reset_password(team)
        {:ok, team}

      {:error, :team, changeset, _} ->
        Audit.reset_password_failed(team, %{
          fields: changeset.errors |> Keyword.keys() |> Enum.uniq()
        })

        {:error, changeset}
    end
  end

  ## Login enable/disable

  @doc """
  Disables login for a team and revokes its active sessions.

  Setting `disabled_at` rejects new logins and invalidates existing session
  tokens (the session lookup filters disabled teams), and all session tokens
  are deleted. Returns the raw deleted session tokens so callers in the web
  layer can broadcast disconnects to live sessions.
  """
  def disable_team_login(%Team{} = team, actor \\ nil) do
    session_tokens =
      Repo.all(
        from t in TeamToken,
          where: t.team_id == ^team.id and t.context == "session",
          select: t.token
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, %{team: team}} =
      Ecto.Multi.new()
      |> Ecto.Multi.update(:team, Ecto.Changeset.change(team, disabled_at: now))
      |> Ecto.Multi.delete_all(:tokens, TeamToken.by_team_and_contexts_query(team, ["session"]))
      |> Repo.transaction()

    Audit.disable_login(team, actor, %{sessions_revoked: length(session_tokens)})

    {:ok, team, session_tokens}
  end

  @doc """
  Re-enables login for a disabled team.
  """
  def enable_team_login(%Team{} = team, actor \\ nil) do
    {:ok, team} =
      team
      |> Ecto.Changeset.change(disabled_at: nil)
      |> Repo.update()

    Audit.enable_login(team, actor)
    {:ok, team}
  end

  ## Invite codes

  @doc """
  Generates `count` unique one-time invite codes and inserts them.

  Returns `{:ok, codes}` with the plaintext codes in insertion order. Retries a
  code on the rare unique-index collision. `opts[:words]` sets the word count
  (default 3); `opts[:actor]` is the admin for the audit event.
  """
  def generate_invite_codes(count, opts \\ []) when is_integer(count) and count > 0 do
    words = Keyword.get(opts, :words, 3)

    codes =
      Enum.map(1..count, fn _ -> insert_unique_code(words) end)

    Audit.generate_invite_codes(count, opts[:actor])
    {:ok, codes}
  end

  defp insert_unique_code(words) do
    code = WordList.code(words)

    case Repo.insert(InviteCode.insert_changeset(code)) do
      {:ok, _} ->
        code

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :code) do
          insert_unique_code(words)
        else
          raise "unexpected invite_code insert error: #{inspect(errors)}"
        end
    end
  end

  @doc "All invite codes, newest first, with the redeeming team preloaded."
  def list_invite_codes do
    Repo.all(from c in InviteCode, order_by: [desc: c.inserted_at], preload: [:redeemed_by_team])
  end

  @doc "Counts of total / redeemed / unused invite codes."
  def count_invite_codes do
    total = Repo.aggregate(InviteCode, :count)
    redeemed = Repo.aggregate(from(c in InviteCode, where: not is_nil(c.redeemed_at)), :count)
    %{total: total, redeemed: redeemed, unused: total - redeemed}
  end
end
