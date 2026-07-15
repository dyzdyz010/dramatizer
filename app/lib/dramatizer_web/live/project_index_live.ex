defmodule DramatizerWeb.ProjectIndexLive do
  use DramatizerWeb, :live_view

  alias Dramatizer.Projects

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, load(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("create-project", %{"project" => %{"name" => name}}, socket) do
    case Projects.create_project(%{name: String.trim(name)}) do
      {:ok, project} ->
        {:noreply, push_navigate(socket, to: ~p"/projects/#{project.id}/source")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, error_message(changeset))}
    end
  end

  def handle_event("archive-project", %{"id" => id}, socket) do
    id |> Projects.get_project!() |> Projects.archive_project()
    {:noreply, load(socket)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="index-shell">
        <section class="hero-panel">
          <div>
            <p class="eyebrow">AI DRAMA WORKBENCH</p>
            <h1>短剧制作台</h1>
            <p class="hero-copy">从小说全文到可追溯的竖屏样片，每一步都由你确认。</p>
          </div>

          <.form
            for={@form}
            id="new-project-form"
            phx-submit="create-project"
            class="new-project-form"
          >
            <.input
              field={@form[:name]}
              label="项目名称"
              placeholder="例如：雨夜来信"
              required
            />
            <.button variant="primary">创建项目</.button>
          </.form>
        </section>

        <section aria-labelledby="project-list-title" class="project-section">
          <div class="section-heading">
            <div>
              <p class="eyebrow">PROJECTS</p>
              <h2 id="project-list-title">进行中的项目</h2>
            </div>
            <span class="count-pill">{length(@projects)}</span>
          </div>

          <div :if={@projects == []} class="empty-panel">
            <.icon name="hero-film" class="size-10" />
            <h3>还没有项目</h3>
            <p>先给这部作品起个名字，随后导入 TXT、Markdown 或文本型 PDF。</p>
          </div>

          <div :if={@projects != []} class="project-grid">
            <article :for={project <- @projects} id={"project-#{project.id}"} class="project-card">
              <div class="project-card__mark">
                {project.name |> String.first() |> String.upcase()}
              </div>
              <div class="project-card__body">
                <p class="eyebrow">ACTIVE PROJECT</p>
                <h3>{project.name}</h3>
                <p>更新于 {Calendar.strftime(project.updated_at, "%m月%d日 %H:%M")}</p>
              </div>
              <div class="project-card__actions">
                <.link navigate={~p"/projects/#{project.id}/source"} class="btn btn-primary">
                  打开项目
                </.link>
                <button
                  id={"archive-#{project.id}"}
                  type="button"
                  class="btn btn-ghost"
                  phx-click="archive-project"
                  phx-value-id={project.id}
                  data-confirm="确认归档这个项目？"
                >
                  归档
                </button>
              </div>
            </article>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp load(socket) do
    projects = Enum.reject(Projects.list_projects(), &(&1.status == :archived))

    socket
    |> assign(:page_title, "短剧制作台")
    |> assign(:projects, projects)
    |> assign(:form, to_form(%{"name" => ""}, as: :project))
  end

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map_join("；", fn {field, {message, _}} -> "#{field} #{message}" end)
  end

  defp error_message(reason), do: inspect(reason)
end
