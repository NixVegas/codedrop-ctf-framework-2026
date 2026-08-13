defmodule CtfServerWeb.AdminVmsLiveTest do
  use CtfServerWeb.ConnCase, async: true
  use Oban.Testing, repo: CtfServer.Repo

  import Phoenix.LiveViewTest
  import CtfServer.AccountsFixtures
  import CtfServer.ChallengesFixtures

  alias CtfServer.Challenges
  alias CtfServer.StubVMBackend

  setup %{conn: conn} do
    admin = admin_team_fixture()
    team = team_fixture()
    %{conn: log_in_team(conn, admin), admin: admin, team: team}
  end

  describe "access control" do
    test "redirects non-admin teams", %{team: team} do
      conn = build_conn() |> log_in_team(team) |> get(~p"/admin/vms")

      assert redirected_to(conn) == ~p"/dashboard"
    end
  end

  describe "inventory" do
    test "groups an attempt's node domains and shows its network", %{conn: conn, team: team} do
      attempt = challenge_attempt_fixture(%{team_id: team.id, status: :started, port: 2222})

      StubVMBackend.set_domains([
        {"ctf-vm-#{attempt.id}-web", "running"},
        {"ctf-vm-#{attempt.id}-ingress", "running"}
      ])

      StubVMBackend.set_networks([{"ctf-#{attempt.id}", "active"}])

      {:ok, _lv, html} = live(conn, ~p"/admin/vms")

      assert html =~ team.name
      assert html =~ "#{attempt.group} / #{attempt.level}"
      assert html =~ "ingress"
      assert html =~ "web"
      # no orphans or strays: everything is claimed
      assert html =~ "None — every ctf domain belongs to an in-flight attempt."
    end

    test "flags an attempt with no domains as a ghost", %{conn: conn, team: team} do
      challenge_attempt_fixture(%{team_id: team.id, status: :started})

      {:ok, _lv, html} = live(conn, ~p"/admin/vms")

      assert html =~ "ghost attempt"
    end
  end

  describe "lifecycle actions" do
    test "pausing an attempt transitions it and enqueues the worker", %{conn: conn, team: team} do
      attempt = challenge_attempt_fixture(%{team_id: team.id, status: :started, port: 2222})
      StubVMBackend.set_domains([{"ctf-vm-#{attempt.id}-vm", "running"}])

      {:ok, lv, _html} = live(conn, ~p"/admin/vms")

      html = lv |> element("a", "Pause") |> render_click()

      assert html =~ "Pausing #{attempt.group}/#{attempt.level}."
      assert Challenges.get_challenge_attempt!(attempt.id).status == :paused
    end

    test "force shutdown marks the attempt deprovisioning", %{conn: conn, team: team} do
      attempt = challenge_attempt_fixture(%{team_id: team.id, status: :started, port: 2222})
      StubVMBackend.set_domains([{"ctf-vm-#{attempt.id}-vm", "running"}])

      {:ok, lv, _html} = live(conn, ~p"/admin/vms")

      html = lv |> element("a", "Force shutdown") |> render_click()

      assert html =~ "Shutting down"
      assert Challenges.get_challenge_attempt!(attempt.id).status == :deprovisioning
    end
  end

  describe "reaping" do
    test "destroys an orphaned domain", %{conn: conn} do
      StubVMBackend.set_domains([{"ctf-vm-dead-0000-web", "shut off"}])

      {:ok, lv, html} = live(conn, ~p"/admin/vms")
      assert html =~ "ctf-vm-dead-0000-web"

      html = lv |> element("a", "Destroy") |> render_click()

      assert html =~ "Destroyed orphaned domain ctf-vm-dead-0000-web."
      assert StubVMBackend.destroyed() == [{:domain, "ctf-vm-dead-0000-web"}]
    end

    test "reports a libvirt refusal instead of claiming success", %{conn: conn} do
      StubVMBackend.set_domains([{"ctf-vm-dead-0000-web", "shut off"}])

      StubVMBackend.fail_next_destroy(
        "Refusing to undefine while domain managed save image exists"
      )

      {:ok, lv, _html} = live(conn, ~p"/admin/vms")

      html = lv |> element("a", "Destroy") |> render_click()

      assert html =~ "libvirt refused to undefine"
      assert html =~ "managed save image exists"
      # the domain is still listed, and nothing was audited as destroyed
      assert html =~ "ctf-vm-dead-0000-web"
      assert CtfServer.Audit.list_events(topic: "vm").total == 0
    end

    test "refuses to destroy a domain a live attempt has since claimed", %{
      conn: conn,
      team: team
    } do
      # Rendered while orphaned...
      StubVMBackend.set_domains([{"ctf-vm-dead-0000-web", "shut off"}])
      {:ok, lv, _html} = live(conn, ~p"/admin/vms")

      # ...then an attempt claims that exact domain before the click lands.
      attempt = challenge_attempt_fixture(%{team_id: team.id, status: :started})
      StubVMBackend.set_domains([{"ctf-vm-#{attempt.id}-web", "running"}])

      html =
        lv
        |> render_click("destroy_orphan_domain", %{"name" => "ctf-vm-#{attempt.id}-web"})

      assert html =~ "no longer orphaned"
      assert StubVMBackend.destroyed() == []
    end
  end
end
