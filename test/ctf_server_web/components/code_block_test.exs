defmodule CtfServerWeb.CodeBlockTest do
  use CtfServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  defp render_code_block(assigns) do
    render_component(&CtfServerWeb.CoreComponents.code_block/1, assigns)
  end

  test "renders the code and a copy button, wired to the CodeBlock hook" do
    html = render_code_block(%{id: "box", code: "echo hi"})

    assert html =~ ~s(phx-hook="CodeBlock")
    assert html =~ "data-copy"
    assert html =~ "echo hi"
  end

  test "omits the download button when the box is not a file" do
    html = render_code_block(%{id: "box", code: "echo hi"})

    refute html =~ "data-download"
  end

  test "shows a download button carrying the filename when given one" do
    html = render_code_block(%{id: "box", code: "PRIVATE KEY", filename: "ctf.key"})

    assert html =~ "data-download"
    assert html =~ ~s(data-filename="ctf.key")
  end

  test "html-escapes the code so it can't inject markup" do
    html = render_code_block(%{id: "box", code: "<script>alert(1)</script>"})

    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;"
  end
end
