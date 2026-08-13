defmodule CtfServer.Accounts.InviteCode do
  use Ecto.Schema
  import Ecto.Changeset
  alias CtfServer.Accounts.Team

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "invite_codes" do
    field :code, :string
    field :redeemed_at, :utc_datetime_usec
    belongs_to :redeemed_by_team, Team

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Changeset for inserting a freshly generated (unredeemed) code."
  def insert_changeset(code) when is_binary(code) do
    %__MODULE__{}
    |> cast(%{code: code}, [:code])
    |> validate_required([:code])
    |> unique_constraint(:code)
  end
end
