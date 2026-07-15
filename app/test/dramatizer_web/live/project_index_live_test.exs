defmodule DramatizerWeb.ProjectIndexLiveTest do
  use DramatizerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dramatizer.Projects

  test "creates, opens, and archives a project without a login surface", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "短剧制作台"
    assert html =~ "还没有项目"
    refute html =~ "登录"
    assert has_element?(view, "[data-project-launcher]")
    assert has_element?(view, "[data-workflow-promise]")

    view
    |> form("#new-project-form", project: %{name: "雨夜来信"})
    |> render_submit()

    {redirect_path, _flash} = assert_redirect(view)
    ["", "projects", project_id, "source"] = String.split(redirect_path, "/")
    project = Projects.get_project!(project_id)
    assert project.name == "雨夜来信"

    {:ok, index, html} = live(conn, ~p"/")
    assert html =~ "雨夜来信"
    assert has_element?(index, "a[href='/projects/#{project.id}/source']", "打开项目")

    index |> element("#archive-#{project.id}") |> render_click()
    refute has_element?(index, "#project-#{project.id}")
    assert Projects.get_project!(project.id).status == :archived
  end
end
