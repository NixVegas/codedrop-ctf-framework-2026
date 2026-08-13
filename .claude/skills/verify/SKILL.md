---
name: verify
description: Build, run, and drive the CTF server locally to verify changes end-to-end.
---

# Verifying ctf-server changes

## Database

Postgres runs repo-locally via `PGHOST=$REPO/.nix-postgres` (unix socket; env
vars come from the nix shell). The personal TCP server on localhost:5432 is a
*different* instance — always use the socket (plain `psql -d ctf_server_dev`).

- Dev DB: `mix ecto.create && mix ecto.migrate && mix run priv/repo/seeds.exs`
- Seeds create the admin: `ctf_admin@localhost` / `adminadmin`
- If tests fail with missing columns, the test DB is stale:
  `MIX_ENV=test mix do ecto.drop, ecto.create, ecto.migrate`

## Run

`mix phx.server` → http://127.0.0.1:4000 (assets are prebuilt; watchers start on their own).
Swoosh dev mailbox: http://127.0.0.1:4000/dev/mailbox

## Drive

Most forms are LiveViews (websocket submits), so curl can't drive them.
`chromium` is on PATH — drive headless over CDP with Node 22's built-in
WebSocket (no npm deps needed):

- `chromium --headless=new --remote-debugging-port=9222 --user-data-dir=<tmp>`
- Fill inputs with `el.value = ...` + dispatch `input`/`change` events;
  `button.click()` triggers phx-submit; override `window.confirm` for
  `data-confirm` links; screenshot via `Page.captureScreenshot`.

Flows worth driving: register at `/teams/register` (lands on `/dashboard`),
log in at `/teams/log_in`, admin team management at `/admin/teams`
(admin-only), password reset at `/teams/reset_password/:token`.

Clean up any teams you create: `psql -d ctf_server_dev -c "delete from teams where email like '...'"`.
