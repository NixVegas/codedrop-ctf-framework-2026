import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/ctf_server start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :ctf_server, CtfServerWeb.Endpoint, server: true
end

# Only the web server node should run Oban queues. One-off `ctf_server eval`
# invocations (migrations, admin tasks, the test harness) start the full app
# but exit as soon as their expression returns; if their Oban picked up a job
# first it would be orphaned mid-run as "executing". Insert-only there.
# Scoped to prod: releases run as prod, and only the release's `bin/server`
# sets PHX_SERVER — `mix phx.server` doesn't, and dev/test must keep their
# queues (test overrides with `testing: :manual` regardless).
if config_env() == :prod and !System.get_env("PHX_SERVER") do
  config :ctf_server, Oban, queues: false, plugins: false
end

parse_ip_address = fn env_name ->
  case System.get_env(env_name) do
    nil ->
      nil

    "" ->
      nil

    "localhost" ->
      {127, 0, 0, 1}

    value ->
      case value |> String.to_charlist() |> :inet.parse_address() do
        {:ok, address} ->
          address

        {:error, reason} ->
          raise "invalid #{env_name}=#{inspect(value)}: #{inspect(reason)}"
      end
  end
end

listen_ip = parse_ip_address.("CTF_SERVER_LISTEN_IP")

listen_port =
  case System.get_env("CTF_SERVER_LISTEN_PORT") || System.get_env("PORT") do
    nil -> nil
    "" -> nil
    port -> String.to_integer(port)
  end

http_runtime_config =
  []
  |> then(fn config ->
    if listen_ip, do: Keyword.put(config, :ip, listen_ip), else: config
  end)
  |> then(fn config ->
    if listen_port, do: Keyword.put(config, :port, listen_port), else: config
  end)

if http_runtime_config != [] do
  config :ctf_server, CtfServerWeb.Endpoint, http: http_runtime_config
end

parse_csv = fn env ->
  case System.get_env(env) do
    nil -> nil
    "" -> nil
    s -> String.split(s, ",", trim: true)
  end
end

vm_runtime_config =
  [
    vm_base_image_path: System.get_env("CTF_SERVER_VM_BASE_IMAGE_PATH"),
    vm_overlay_path: System.get_env("CTF_SERVER_VM_OVERLAY_PATH"),
    vm_libvirt_uri: System.get_env("CTF_SERVER_VM_LIBVIRT_URI"),
    vm_ssh_host: System.get_env("CTF_SERVER_VM_SSH_HOST"),
    vm_egress_interface: System.get_env("CTF_SERVER_VM_EGRESS_INTERFACE"),
    vm_overlay_size: System.get_env("CTF_SERVER_VM_OVERLAY_SIZE"),
    vm_egress_allow_subnets: parse_csv.("CTF_SERVER_VM_EGRESS_ALLOW_SUBNETS"),
    vm_internal_zones: parse_csv.("CTF_SERVER_VM_INTERNAL_ZONES")
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)

vm_runtime_config =
  case System.get_env("CTF_SERVER_VM_PORT_RANGE") do
    nil ->
      vm_runtime_config

    "" ->
      vm_runtime_config

    range ->
      [first, last] = String.split(range, ["..", "-"], parts: 2)

      Keyword.put(
        vm_runtime_config,
        :vm_port_range,
        String.to_integer(first)..String.to_integer(last)
      )
  end

if vm_runtime_config != [] do
  config :ctf_server, vm_runtime_config
end

case System.get_env("CTF_SERVER_MAX_VMS_PER_TEAM") do
  value when value in [nil, ""] ->
    :ok

  value ->
    case Integer.parse(value) do
      {n, ""} when n >= 0 ->
        config :ctf_server, :max_vms_per_team, n

      _ ->
        raise "invalid CTF_SERVER_MAX_VMS_PER_TEAM=#{inspect(value)}: expected a non-negative integer"
    end
end

# Home Assistant webhook the backend POSTs to on every flag capture (to flash the
# lights in the space). Unset/blank disables the notification.
case System.get_env("CTF_SERVER_HA_WEBHOOK_URL") do
  value when value in [nil, ""] ->
    :ok

  value ->
    config :ctf_server, :ha_webhook_url, value
end

case System.get_env("CTF_SERVER_SKIP_ACCOUNT_CONFIRMATION") do
  nil ->
    :ok

  "" ->
    :ok

  value when value in ~w(true 1 yes) ->
    config :ctf_server, :skip_account_confirmation, true

  value when value in ~w(false 0 no) ->
    config :ctf_server, :skip_account_confirmation, false

  value ->
    raise "invalid CTF_SERVER_SKIP_ACCOUNT_CONFIRMATION=#{inspect(value)}: expected true or false"
end

case System.get_env("CTF_SERVER_REQUIRE_INVITE_CODES") do
  value when value in [nil, ""] ->
    :ok

  value ->
    if String.downcase(value) in ~w(1 true yes) do
      config :ctf_server, :require_invite_codes, true
    end
end

case System.get_env("CTF_SERVER_LOCAL_NETWORKS") do
  value when value in [nil, ""] ->
    :ok

  value ->
    nets =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    config :ctf_server, :local_networks, nets
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :ctf_server, CtfServer.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = listen_port || 4000
  url_scheme = System.get_env("CTF_SERVER_URL_SCHEME") || "https"

  url_port =
    case System.get_env("CTF_SERVER_URL_PORT") do
      nil -> 443
      "" -> 443
      port -> String.to_integer(port)
    end

  config :ctf_server, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :ctf_server, CtfServerWeb.Endpoint,
    url: [host: host, port: url_port, scheme: url_scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: listen_ip || {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :ctf_server, CtfServerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :ctf_server, CtfServerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Also, you may need to configure the Swoosh API client of your choice if you
  # are not using SMTP. Here is an example of the configuration:
  #
  #     config :ctf_server, CtfServer.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # For this example you need include a HTTP client required by Swoosh API client.
  # Swoosh supports Hackney and Finch out of the box:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Hackney
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
