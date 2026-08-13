defmodule CtfServerWeb.ChallengeAttemptLiveTest do
  use CtfServerWeb.ConnCase

  import Phoenix.LiveViewTest
  import CtfServer.ChallengesFixtures
  import CtfServer.AccountsFixtures

  @update_attrs %{group: "nix-ecosystem", level: 3, status: :provisioning}
  @invalid_attrs %{group: nil, level: nil, status: nil}

  defp create_challenge_attempt(_) do
    team = admin_team_fixture()
    challenge_attempt = challenge_attempt_fixture(%{team_id: team.id})

    %{challenge_attempt: challenge_attempt, team: team}
  end

  describe "Index" do
    setup [:create_challenge_attempt]

    test "lists all challenge_attempt", %{
      conn: conn,
      challenge_attempt: challenge_attempt,
      team: team
    } do
      {:ok, _index_live, html} = conn |> log_in_team(team) |> live(~p"/challenge_attempt")

      assert html =~ "Listing Challenge attempt"
      assert html =~ challenge_attempt.group
      assert html =~ "#{challenge_attempt.level}"
    end

    test "saves new challenge_attempt", %{conn: conn, team: team} do
      {:ok, index_live, _html} = conn |> log_in_team(team) |> live(~p"/challenge_attempt")

      assert index_live |> element("a", "New Challenge attempt") |> render_click() =~
               "New Challenge attempt"

      assert_patch(index_live, ~p"/challenge_attempt/new")

      assert index_live
             |> form("#challenge_attempt-form", challenge_attempt: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#challenge_attempt-form",
               challenge_attempt: %{
                 group: "basic-nix",
                 level: 1,
                 status: :untouched,
                 team_id: team.id
               }
             )
             |> render_submit()

      assert_patch(index_live, ~p"/challenge_attempt")

      html = render(index_live)
      assert html =~ "Challenge attempt created successfully"
      assert html =~ "basic-nix"
      assert html =~ "1"
    end

    test "updates challenge_attempt in listing", %{
      conn: conn,
      challenge_attempt: challenge_attempt,
      team: team
    } do
      {:ok, index_live, _html} = conn |> log_in_team(team) |> live(~p"/challenge_attempt")

      assert index_live
             |> element("#challenge_attempt_collection-#{challenge_attempt.id} a", "Edit")
             |> render_click() =~
               "Edit Challenge attempt"

      assert_patch(index_live, ~p"/challenge_attempt/#{challenge_attempt}/edit")

      assert index_live
             |> form("#challenge_attempt-form", challenge_attempt: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#challenge_attempt-form",
               challenge_attempt: %{
                 group: "capture-the-poll",
                 level: 1,
                 status: :untouched,
                 team_id: team.id
               }
             )
             |> render_submit()

      assert_patch(index_live, ~p"/challenge_attempt")

      html = render(index_live)
      assert html =~ "Challenge attempt updated successfully"
      assert html =~ "capture-the-poll"
      assert html =~ "1"
    end

    test "deletes challenge_attempt in listing", %{
      conn: conn,
      challenge_attempt: challenge_attempt,
      team: team
    } do
      {:ok, index_live, _html} = conn |> log_in_team(team) |> live(~p"/challenge_attempt")

      assert index_live
             |> element("#challenge_attempt_collection-#{challenge_attempt.id} a", "Delete")
             |> render_click()

      refute has_element?(index_live, "#challenge_attempt-#{challenge_attempt.id}")
    end
  end

  describe "Show" do
    setup [:create_challenge_attempt]

    test "displays challenge_attempt", %{
      conn: conn,
      challenge_attempt: challenge_attempt,
      team: team
    } do
      {:ok, _show_live, html} =
        conn |> log_in_team(team) |> live(~p"/challenge_attempt/#{challenge_attempt}")

      assert html =~ "Show Challenge attempt"
      assert html =~ challenge_attempt.group
      assert html =~ "#{challenge_attempt.level}"
    end

    test "updates challenge_attempt within modal", %{
      conn: conn,
      challenge_attempt: challenge_attempt,
      team: team
    } do
      {:ok, show_live, _html} =
        conn
        |> log_in_team(team)
        |> live(~p"/challenge_attempt/#{challenge_attempt}")

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Challenge attempt"

      assert_patch(show_live, ~p"/challenge_attempt/#{challenge_attempt}/show/edit")

      assert show_live
             |> form("#challenge_attempt-form", challenge_attempt: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert show_live
             |> form("#challenge_attempt-form", challenge_attempt: @update_attrs)
             |> render_submit()

      assert_patch(show_live, ~p"/challenge_attempt/#{challenge_attempt}")

      html = render(show_live)
      assert html =~ "Challenge attempt updated successfully"
      assert html =~ "nix-ecosystem"
      assert html =~ "3"
    end
  end
end
