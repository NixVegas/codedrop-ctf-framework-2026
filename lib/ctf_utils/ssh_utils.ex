defmodule CtfUtils.SSHUtils do
  @moduledoc """
  Various utilities for handling SSH stuff.
  """

  @doc """
  Generates an ed25519 keypair, returning the public and private keys as binaries.
  """
  @spec gen_keypair() :: {:ok, String.t(), String.t()}
  def gen_keypair() do
    {:ok, private_key_path} = Temp.path()
    public_key_path = "#{private_key_path}.pub"

    args = [
      "-t",
      "ed25519",
      "-f",
      private_key_path,
      "-N",
      ""
    ]

    case System.cmd("ssh-keygen", args, stderr_to_stdout: true) do
      {_output, 0} ->
        pubkey = File.read!(public_key_path)
        File.rm(public_key_path)
        privkey = File.read!(private_key_path)
        File.rm(private_key_path)
        {:ok, pubkey, privkey}

      {error_output, exit_code} ->
        {:error, {exit_code, error_output}}
    end
  end
end
