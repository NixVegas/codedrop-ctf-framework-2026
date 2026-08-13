defmodule CtfServer.Audit.Event do
  use Ecto.Schema
  import Ecto.Changeset

  alias CtfServer.Accounts.Team

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "audit_events" do
    field :topic, :string
    field :event, :string
    field :details, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    belongs_to :principal, Team

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:topic, :event, :details, :occurred_at, :principal_id])
    |> validate_required([:topic, :event, :occurred_at])
  end
end
