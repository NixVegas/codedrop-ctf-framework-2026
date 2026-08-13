defmodule CtfServer.LogRedactor do
  @moduledoc """
  A `:logger` primary filter that redacts secrets from structured log events.

  `Phoenix`'s `:filter_parameters` only scrubs the HTTP request logger. When a
  LiveView channel (or any gen_server) crashes, OTP logs a crash report whose
  "Last message" is the raw event payload, e.g.
  `%{"team" => %{"password" => "..."}}` (a plain map that no schema redaction
  touches). This filter walks each log event and replaces the value of any key
  whose name matches a sensitive token, so a crash can't leak a plaintext
  password (CWE-532 / CWE-209).

  The token list is `config :ctf_server, :filter_parameters`, which
  `config/config.exs` sets from the same literal as
  `config :phoenix, :filter_parameters`, so the HTTP and crash-report paths
  stay in sync. Do not read the `:phoenix` key here: since Phoenix 1.8 it is
  rewritten at boot into an opaque `{:compiled, ...}` matcher rather than the
  list that was configured. Installed by `CtfServer.Application` via
  `:logger.add_primary_filter/2`.
  """

  @redacted "[REDACTED]"

  @doc "Adds this module as a logger primary filter (idempotent)."
  def install do
    # Returns {:error, {:already_exist, _}} if it is already installed (e.g. an
    # app restart); either way there is nothing to do.
    case :logger.add_primary_filter(:ctf_redact_secrets, {&__MODULE__.filter/2, []}) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  rescue
    _ -> :ok
  end

  @doc """
  Logger primary filter. Returns the event with sensitive values redacted. It
  must never raise (a raising filter is removed by `:logger`), so on any error
  it returns the event unchanged rather than crash the logging pipeline.
  """
  def filter(%{msg: msg} = event, _opts) do
    %{event | msg: redact_msg(msg)}
  rescue
    _ -> event
  end

  def filter(event, _opts), do: event

  defp redact_msg({:report, report}), do: {:report, redact(report)}
  defp redact_msg({:string, chardata}), do: {:string, chardata}
  defp redact_msg({format, args}) when is_list(args), do: {format, redact(args)}
  defp redact_msg(other), do: other

  # Structs: redact each field but keep the struct type and untouched fields.
  defp redact(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Enum.reduce(struct, fn {k, v}, acc -> Map.put(acc, k, redact_value(k, v)) end)
  rescue
    _ -> struct
  end

  defp redact(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, redact_value(k, v)} end)
  end

  defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)

  # A 2-tuple is treated as a possible key/value pair (keyword-list entry);
  # larger tuples are recursed element by element.
  defp redact({k, v}), do: {k, redact_value(k, v)}

  defp redact(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&redact/1) |> List.to_tuple()
  end

  defp redact(other), do: other

  defp redact_value(key, value) do
    if sensitive?(key), do: @redacted, else: redact(value)
  end

  defp sensitive?(key) when is_atom(key), do: sensitive?(Atom.to_string(key))

  defp sensitive?(key) when is_binary(key) do
    Enum.any?(tokens(), &String.contains?(key, &1))
  end

  defp sensitive?(_), do: false

  # The fallback is only reachable if the config above is missing or malformed;
  # it deliberately still covers every token rather than degrading quietly to a
  # narrower list, since under-redacting is the dangerous direction.
  @default_tokens ["password", "invite_code"]

  defp tokens do
    case Application.get_env(:ctf_server, :filter_parameters, @default_tokens) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> @default_tokens
    end
  end
end
