defmodule CtfServerWeb.PageControllerTest do
  use CtfServerWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Escape your fate at DEF CON 34."
  end
end
