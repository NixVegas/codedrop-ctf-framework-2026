defmodule CtfServerWeb.PageController do
  use CtfServerWeb, :controller

  def home(conn, _params) do
    # The generator skipped the app layout here on the assumption that a home
    # page is custom made. It isn't anymore — it's a heading and three
    # links — so it takes the same chrome, padding, and content column as every
    # other page instead of hand-rolling its own.
    render(conn, :home)
  end
end
