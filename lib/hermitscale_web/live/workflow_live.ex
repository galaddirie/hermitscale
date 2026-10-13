defmodule HermitscaleWeb.WorkflowLive do
  use HermitscaleWeb, :live_view
  alias Ecto.Changeset
  alias Hermitscale.{Authorization, Workflows}
  alias Hermitscale.Workflows.{Catalog, ExternalOperations}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    catalog =
      Catalog.index()
      |> Enum.map(fn {{type, version}, module} ->
        {type <> " · v" <> to_string(version), type <> "@" <> to_string(version), module.spec()}
      end)
      |> Enum.reject(fn {_label, _value, spec} ->
        String.starts_with?(spec.id, "test.") or spec.deprecated
      end)
      |> Enum.sort()

    {:ok,
     socket
     |> assign(
       page_title: "Workflows",
       graph: nil,
       definition: nil,
       selected: nil,
       dirty?: false,
       run: nil,
       issues: [],
       parameter_help: [],
       canvas_height: 200,
       run_timer: nil
     )
     |> assign(
       :catalog_options,
       Enum.map(catalog, fn {label, value, _spec} -> {label, value} end)
     )
     |> assign(:can_edit?, Authorization.authorize(scope, "workflows:edit") == :ok)
     |> assign(:can_run?, Authorization.authorize(scope, "workflows:run") == :ok)
     |> assign(:can_activate?, Authorization.authorize(scope, "workflows:activate") == :ok)
     |> assign(:new_form, editor_form(:workflow, %{name: :string}, %{}))
     |> assign(:graph_form, editor_form(:graph, %{name: :string, status: :string}, %{}))
     |> assign(:add_form, editor_form(:node, %{catalog: :string, id: :string}, %{}))
     |> assign(
       :node_form,
       editor_form(:node_config, %{params: :string, connection: :string, policy: :string}, %{})
     )
     |> assign(
       :edge_form,
       editor_form(:edge, %{from: :string, to: :string, to_input: :integer}, %{})
     )
     |> assign(:run_form, editor_form(:run_input, %{input: :string}, %{"input" => "{}"}))
     |> assign(:node_options, [])
     |> stream(:workflows, [])
     |> stream(:nodes, [])
     |> stream(:edges, [])
     |> stream(:connection_rows, [])
     |> stream(:issues, [])
     |> stream_configure(:runs, dom_id: &run_dom_id/1)
     |> stream(:runs, [])
     |> stream(:operations, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    readable? = socket.assigns.can_edit? or socket.assigns.can_run?

    if readable? do
      graphs = Workflows.list_graphs(socket.assigns.current_scope)

      case socket.assigns.live_action do
        :index ->
          {:noreply,
           socket
           |> clear_run()
           |> assign(:graph, nil)
           |> stream(:workflows, Enum.take(graphs, 100), reset: true)}

        :show ->
          case Enum.find(graphs, &(&1.id == params["id"])) do
            nil ->
              {:noreply,
               socket
               |> put_flash(:error, "Workflow is unavailable.")
               |> push_navigate(to: ~p"/workflows")}

            graph ->
              socket =
                socket
                |> assign(
                  graph: graph,
                  definition: graph.definition,
                  dirty?: false,
                  selected: nil,
                  run: nil
                )
                |> assign(
                  :graph_form,
                  editor_form(:graph, %{name: :string, status: :string}, %{
                    "name" => graph.name,
                    "status" => Atom.to_string(graph.status)
                  })
                )
                |> refresh_canvas()
                |> stream(:runs, Workflows.list_runs(socket.assigns.current_scope, graph.id),
                  reset: true
                )
                |> load_recorded_run(params["run_id"])

              {:noreply, socket}
          end
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Your role does not allow viewing workflows.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("create_workflow", %{"workflow" => attrs}, socket) do
    name = Map.get(attrs, "name", "") |> String.trim()
    id = "wf_" <> (Ecto.UUID.generate() |> String.replace("-", "_"))

    definition = %{
      "schema_version" => 1,
      "id" => id,
      "name" => name,
      "nodes" => [%{"id" => "start", "type" => "debug", "version" => 1, "params" => %{}}],
      "connections" => []
    }

    case Workflows.create_graph(socket.assigns.current_scope, %{
           id: id,
           name: name,
           definition: definition,
           status: :draft
         }) do
      {:ok, graph} ->
        {:noreply, push_navigate(socket, to: ~p"/workflows/#{graph.id}")}

      {:error, %Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Enter a workflow name.")
         |> assign(:new_form, editor_form(:workflow, %{name: :string}, attrs))
         |> show_changeset(changeset)}

      {:error, reason} ->
        {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("add_node", %{"node" => attrs}, socket) do
    with :ok <- edit_permission(socket),
         true <- length(socket.assigns.definition["nodes"]) < 100,
         {:ok, type, version} <- catalog_choice(attrs["catalog"]),
         {:ok, module} <- Catalog.fetch(type, version),
         {:ok, id} <- node_id(attrs["id"]),
         false <- Enum.any?(socket.assigns.definition["nodes"], &(&1["id"] == id)) do
      node = %{
        "id" => id,
        "type" => type,
        "version" => version,
        "params" => defaults(module.spec())
      }

      definition = Map.update!(socket.assigns.definition, "nodes", &(&1 ++ [node]))

      {:noreply,
       socket
       |> assign(definition: definition, dirty?: true)
       |> select_node(id)
       |> refresh_canvas()}
    else
      true -> {:noreply, fail(socket, :duplicate_node)}
      false -> {:noreply, fail(socket, :node_limit)}
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("select_node", %{"id" => id}, socket) do
    case Enum.any?(socket.assigns.definition["nodes"], &(&1["id"] == id)) do
      true -> {:noreply, socket |> select_node(id) |> refresh_canvas()}
      false -> {:noreply, fail(socket, :node_not_found)}
    end
  end

  def handle_event("save_node", %{"node_config" => attrs}, socket) do
    with :ok <- edit_permission(socket),
         {:ok, params} <- json_object(attrs["params"]),
         {:ok, connection} <- json_object(attrs["connection"]),
         {:ok, policy} <- json_object(attrs["policy"]) do
      id = socket.assigns.selected

      nodes =
        Enum.map(socket.assigns.definition["nodes"], fn
          %{"id" => ^id} = node ->
            node
            |> Map.put("params", params)
            |> put_optional("connection", connection)
            |> put_optional("policy", policy)

          node ->
            node
        end)

      {:noreply,
       socket
       |> assign(definition: Map.put(socket.assigns.definition, "nodes", nodes), dirty?: true)
       |> refresh_canvas()
       |> put_flash(:info, "Node updated. Save the workflow to publish this definition.")}
    else
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("delete_node", %{"id" => id}, socket) do
    with :ok <- edit_permission(socket) do
      definition =
        socket.assigns.definition
        |> Map.update!("nodes", &Enum.reject(&1, fn n -> n["id"] == id end))
        |> Map.update!(
          "connections",
          &Enum.reject(&1, fn e -> e["from"] == id or e["to"] == id end)
        )

      {:noreply,
       socket
       |> assign(definition: definition, selected: nil, dirty?: true, parameter_help: [])
       |> refresh_canvas()}
    else
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("connect_nodes", %{"edge" => attrs}, socket) do
    with :ok <- edit_permission(socket),
         true <- attrs["from"] != attrs["to"],
         true <-
           Enum.all?(
             [attrs["from"], attrs["to"]],
             &Enum.member?(Enum.map(socket.assigns.definition["nodes"], fn n -> n["id"] end), &1)
           ),
         {:ok, edge} <- edge_params(attrs),
         false <- Enum.member?(socket.assigns.definition["connections"], edge) do
      definition = Map.update!(socket.assigns.definition, "connections", &(&1 ++ [edge]))
      {:noreply, socket |> assign(definition: definition, dirty?: true) |> refresh_canvas()}
    else
      value when is_boolean(value) -> {:noreply, fail(socket, :invalid_or_duplicate_connection)}
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("delete_edge", %{"id" => id}, socket) do
    with :ok <- edit_permission(socket) do
      definition =
        Map.update!(
          socket.assigns.definition,
          "connections",
          &Enum.reject(&1, fn edge -> edge_id(edge) == id end)
        )

      {:noreply, socket |> assign(definition: definition, dirty?: true) |> refresh_canvas()}
    else
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("validate_workflow", _params, socket),
    do: {:noreply, validate_definition(socket)}

  def handle_event("save_workflow", %{"graph" => attrs}, socket) do
    definition = Map.put(socket.assigns.definition, "name", attrs["name"])
    status = attrs["status"]

    with :ok <- edit_permission(socket),
         :ok <- activate_permission(socket, status),
         :ok <- Workflows.validate_graph(definition),
         {:ok, graph} <-
           Workflows.update_graph(socket.assigns.current_scope, socket.assigns.graph, %{
             name: attrs["name"],
             definition: definition,
             status: status
           }) do
      {:noreply,
       socket
       |> assign(graph: graph, definition: graph.definition, dirty?: false)
       |> refresh_canvas()
       |> put_flash(:info, "Workflow saved and validated.")}
    else
      {:error, issues} when is_list(issues) -> {:noreply, show_issues(socket, issues)}
      {:error, %Changeset{} = changeset} -> {:noreply, show_changeset(socket, changeset)}
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("start_run", %{"run_input" => attrs}, socket) do
    with :ok <- Authorization.authorize(socket.assigns.current_scope, "workflows:run"),
         true <- socket.assigns.graph.definition == socket.assigns.definition,
         {:ok, input} <- json_value(attrs["input"]),
         {:ok, run} <-
           Workflows.start_run(socket.assigns.current_scope, socket.assigns.graph, input,
             run_id: Ecto.UUID.generate(),
             executor: :queued
           ) do
      {:noreply,
       socket
       |> push_patch(to: ~p"/workflows/#{socket.assigns.graph.id}?run_id=#{run.id}")
       |> put_flash(:info, "Workflow run admitted.")}
    else
      false -> {:noreply, fail(socket, :save_before_running)}
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("refresh_run", _params, socket), do: {:noreply, refresh_run(socket)}

  def handle_event("resume_run", _params, socket) do
    case Workflows.resume_run(socket.assigns.current_scope, socket.assigns.run) do
      {:ok, run} -> {:noreply, socket |> assign(:run, run) |> refresh_run()}
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  @impl true
  def handle_info(:refresh_run, socket) do
    socket = refresh_run(socket)

    timer =
      if socket.assigns.run && socket.assigns.run.status in [:created, :running],
        do: Process.send_after(self(), :refresh_run, 3000),
        else: nil

    {:noreply, assign(socket, :run_timer, timer)}
  end

  def handle_info({event, id}, socket) when event in [:run_complete, :run_failed] do
    if socket.assigns.run && socket.assigns.run.id == id,
      do: {:noreply, refresh_run(socket)},
      else: {:noreply, socket}
  end

  defp refresh_run(%{assigns: %{run: nil}} = socket), do: socket

  defp refresh_run(socket) do
    run = Workflows.get_run!(socket.assigns.current_scope, socket.assigns.run.id)

    socket
    |> assign(:run, run)
    |> stream_insert(:runs, run)
    |> stream(:operations, ExternalOperations.list(socket.assigns.current_scope, run.id),
      reset: true
    )
  end

  defp load_recorded_run(socket, nil), do: clear_run(socket)

  defp load_recorded_run(socket, id) do
    run = Workflows.get_run!(socket.assigns.current_scope, id)

    if run.workflow_graph_id == socket.assigns.graph.id do
      socket = clear_run(socket) |> assign(:run, run) |> refresh_run()

      if connected?(socket) do
        Workflows.subscribe_run(socket.assigns.current_scope, run.id)

        if run.status in [:created, :running],
          do: assign(socket, :run_timer, Process.send_after(self(), :refresh_run, 3000)),
          else: socket
      else
        socket
      end
    else
      socket |> clear_run() |> put_flash(:error, "Run is unavailable for this workflow.")
    end
  rescue
    Ecto.NoResultsError ->
      socket |> clear_run() |> put_flash(:error, "Run is unavailable for this workflow.")
  end

  defp clear_run(socket) do
    if socket.assigns.run_timer, do: Process.cancel_timer(socket.assigns.run_timer)
    socket |> assign(run: nil, run_timer: nil) |> stream(:operations, [], reset: true)
  end

  defp run_dom_id(run), do: "runs-" <> Base.url_encode64(run.id, padding: false)

  defp select_node(socket, id) do
    node = Enum.find(socket.assigns.definition["nodes"], &(&1["id"] == id))

    {socket, help} =
      case Catalog.fetch(node["type"], node["version"]) do
        {:ok, module} ->
          {socket, parameter_help(module)}

        {:error, :not_found} ->
          {put_flash(
             socket,
             :error,
             "This action is unavailable. Remove it and select a catalog action."
           ), []}
      end

    attrs = %{
      "params" => Jason.encode!(node["params"], pretty: true),
      "connection" => Jason.encode!(Map.get(node, "connection", %{}), pretty: true),
      "policy" => Jason.encode!(Map.get(node, "policy", %{}), pretty: true)
    }

    socket
    |> assign(selected: id, parameter_help: help)
    |> assign(
      :node_form,
      editor_form(:node_config, %{params: :string, connection: :string, policy: :string}, attrs)
    )
  end

  defp parameter_help(module) do
    Enum.map(module.spec().params_schema, fn {key, opts} ->
      %{
        name: Atom.to_string(key),
        required: Keyword.get(opts, :required, false),
        doc: Keyword.get(opts, :doc, ""),
        type: inspect(Keyword.fetch!(opts, :type))
      }
    end)
  end

  defp refresh_canvas(socket) do
    nodes = socket.assigns.definition["nodes"]

    positions =
      nodes
      |> Enum.with_index()
      |> Map.new(fn {node, index} ->
        {node["id"], {rem(index, 3) * 280 + 24, div(index, 3) * 155 + 24}}
      end)

    rendered =
      Enum.map(nodes, fn node ->
        {x, y} = Map.fetch!(positions, node["id"])
        %{id: node["id"], type: node["type"], version: node["version"], left: x, top: y}
      end)

    edges =
      Enum.map(socket.assigns.definition["connections"], fn edge ->
        {x1, y1} = Map.fetch!(positions, edge["from"])
        {x2, y2} = Map.fetch!(positions, edge["to"])

        %{
          id: edge_id(edge),
          from: edge["from"],
          to: edge["to"],
          input: Map.get(edge, "to_input"),
          path:
            "M #{x1 + 240} #{y1 + 47} C #{x1 + 270} #{y1 + 47}, #{x2 - 30} #{y2 + 47}, #{x2} #{y2 + 47}"
        }
      end)

    socket
    |> assign(:node_options, Enum.map(nodes, &{&1["id"], &1["id"]}))
    |> assign(:canvas_height, max(190, (div(max(length(nodes) - 1, 0), 3) + 1) * 155 + 40))
    |> stream(:nodes, rendered, reset: true)
    |> stream(:edges, edges, reset: true)
    |> stream(:connection_rows, edges, reset: true)
    |> validate_definition()
  end

  defp validate_definition(socket),
    do: show_issues(socket, Workflows.graph_issues(socket.assigns.definition))

  defp show_issues(socket, issues) do
    rows =
      Enum.with_index(issues, fn issue, index ->
        Map.put(Map.from_struct(issue), :id, to_string(index))
      end)

    socket |> assign(:issues, issues) |> stream(:issues, rows, reset: true)
  end

  defp show_changeset(socket, changeset),
    do:
      put_flash(
        socket,
        :error,
        inspect(Changeset.traverse_errors(changeset, fn {message, _opts} -> message end),
          limit: 10
        )
      )

  defp editor_form(name, types, attrs),
    do: {%{}, types} |> Changeset.cast(attrs, Map.keys(types)) |> to_form(as: name)

  defp edit_permission(socket),
    do: Authorization.authorize(socket.assigns.current_scope, "workflows:edit")

  defp activate_permission(%{assigns: %{can_activate?: true}}, "active"), do: :ok
  defp activate_permission(_socket, "active"), do: {:error, :forbidden}
  defp activate_permission(_socket, status) when status in ["draft", "archived"], do: :ok
  defp activate_permission(_socket, _invalid), do: {:error, :invalid_status}
  defp put_optional(node, key, value) when map_size(value) == 0, do: Map.delete(node, key)
  defp put_optional(node, key, value), do: Map.put(node, key, value)

  defp defaults(spec),
    do:
      Map.new(spec.params_schema, fn {name, options} ->
        {Atom.to_string(name),
         Keyword.get(options, :default, default_type(Keyword.fetch!(options, :type)))}
      end)

  defp default_type({:in, [first | _rest]}), do: first
  defp default_type(:string), do: ""
  defp default_type(type) when type in [:integer, :pos_integer, :number], do: 1
  defp default_type(:boolean), do: false
  defp default_type(:map), do: %{}
  defp default_type({:list, _type}), do: []
  defp default_type(_type), do: nil

  defp node_id(id) when is_binary(id) do
    if Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_:-]{0,79}\z/, id),
      do: {:ok, id},
      else: {:error, :invalid_node_id}
  end

  defp node_id(_id), do: {:error, :invalid_node_id}

  defp catalog_choice(choice) when is_binary(choice) do
    case String.split(choice, "@") do
      [type, version] ->
        case Integer.parse(version) do
          {version, ""} -> {:ok, type, version}
          _invalid -> {:error, :invalid_catalog_node}
        end

      _invalid ->
        {:error, :invalid_catalog_node}
    end
  end

  defp catalog_choice(_choice), do: {:error, :invalid_catalog_node}

  defp json_value(value) when is_binary(value) and byte_size(value) <= 65_536,
    do: Jason.decode(value)

  defp json_value(_value), do: {:error, :invalid_or_oversized_json}

  defp json_object(value) do
    case json_value(value) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, :json_object_required}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp edge_params(%{"from" => from, "to" => to} = attrs) do
    case Map.get(attrs, "to_input", "") do
      "" ->
        {:ok, %{"from" => from, "to" => to}}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {index, ""} when index in 0..99 ->
            {:ok, %{"from" => from, "to" => to, "to_input" => index}}

          _invalid ->
            {:error, :invalid_input_port}
        end
    end
  end

  defp edge_id(edge),
    do: edge["from"] <> "-" <> edge["to"] <> "-" <> to_string(Map.get(edge, "to_input", "main"))

  defp fail(socket, :save_before_running),
    do: put_flash(socket, :error, "Save the current definition before running.")

  defp fail(socket, :forbidden),
    do: put_flash(socket, :error, "Your role does not allow this action.")

  defp fail(socket, reason),
    do:
      put_flash(
        socket,
        :error,
        "Unable to complete this action: " <> inspect(reason, limit: 5, printable_limit: 200)
      )

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-7xl px-4 py-10 sm:px-8">
        <%= if @live_action == :index do %>
          <header class="mb-10">
            <p class="mb-3 text-xs uppercase tracking-[0.2em] text-base-content/50">
              Automate the work
            </p><h1 class="text-4xl font-semibold tracking-tight">Workflows</h1><p class="mt-3 max-w-xl text-base-content/60">
              Connect agents, apps, and the services your team uses.
            </p>
          </header>
          <div class="grid gap-8 lg:grid-cols-[1fr_340px]">
            <section id="workflows" phx-update="stream" class="space-y-4">
              <p
                id="no-workflows"
                class="hidden rounded-2xl border border-dashed border-base-300 p-8 text-base-content/60 only:block"
              >
                Create a workflow to open the visual editor.
              </p><.link
                :for={{id, workflow} <- @streams.workflows}
                id={id}
                navigate={~p"/workflows/#{workflow.id}"}
                class="flex items-center justify-between gap-4 rounded-2xl border border-base-300 p-6 transition hover:border-primary/40 hover:shadow-sm"
              ><div>
                <h2 class="text-lg font-semibold">{workflow.name}</h2><p class="mt-2 text-xs text-base-content/50">
                  {workflow.id}
                </p>
              </div><span class="badge badge-outline">{workflow.status}</span></.link>
            </section>
            <.form
              :if={@can_edit?}
              for={@new_form}
              id="new-workflow-form"
              phx-submit="create_workflow"
              class="h-fit rounded-2xl border border-base-300 p-6"
            >
              <h2 class="mb-5 text-lg font-semibold">Create a workflow</h2><.input
                field={@new_form[:name]}
                label="Workflow name"
                required
                maxlength="120"
              /><p class="mb-5 text-xs leading-6 text-base-content/55">
                Start with one node, then connect the actions you need. Every saved definition passes validation.
              </p><button
                id="create-workflow"
                class="btn btn-primary w-full"
                phx-disable-with="Creating…"
              >Open editor <.icon name="hero-arrow-right" class="size-4" /></button>
            </.form>
          </div>
        <% else %>
          <%= if @graph do %>
            <.link
              navigate={~p"/workflows"}
              class="mb-6 inline-flex items-center gap-2 text-sm text-base-content/60"
            ><.icon name="hero-arrow-left" class="size-4" />Workflows</.link>
            <header class="mb-6 flex flex-wrap items-start justify-between gap-4">
              <div>
                <h1 id="workflow-title" class="text-3xl font-semibold tracking-tight">
                  {@graph.name}
                </h1><p
                  id="workflow-save-state"
                  class="mt-2 text-xs text-base-content/50"
                  role="status"
                >
                  {if(@dirty?, do: "Unsaved changes", else: "Saved definition")} · {@graph.status}
                </p>
              </div><button
                id="validate-workflow"
                phx-click="validate_workflow"
                class="btn btn-outline btn-sm"
              >Validate definition <.icon name="hero-check-badge" class="size-4" /></button>
            </header>
            <div class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_330px]">
              <div class="min-w-0 space-y-6">
                <section
                  class="overflow-auto rounded-2xl border border-base-300 bg-base-200/30"
                  aria-labelledby="canvas-heading"
                >
                  <h2 id="canvas-heading" class="sr-only">Workflow graph</h2><div
                    id="workflow-canvas"
                    class="relative min-w-[860px]"
                    style={"height: #{@canvas_height}px"}
                  >
                    <svg
                      id="workflow-edges"
                      phx-update="stream"
                      class="pointer-events-none absolute inset-0 h-full w-full"
                      aria-hidden="true"
                    ><path
                      :for={{id, edge} <- @streams.edges}
                      id={id}
                      d={edge.path}
                      fill="none"
                      stroke="currentColor"
                      stroke-width="2"
                      class="text-primary/40"
                    /></svg><div id="workflow-nodes" phx-update="stream">
                      <button
                        :for={{id, node} <- @streams.nodes}
                        id={id}
                        type="button"
                        phx-click="select_node"
                        phx-value-id={node.id}
                        aria-pressed={@selected == node.id}
                        style={"left: #{node.left}px; top: #{node.top}px"}
                        class={[
                          "absolute w-[240px] rounded-xl border bg-base-100 p-5 text-left shadow-sm transition hover:-translate-y-0.5 hover:shadow-md",
                          if(@selected == node.id,
                            do: "border-primary ring-2 ring-primary/20",
                            else: "border-base-300"
                          )
                        ]}
                      ><span class="text-xs font-semibold uppercase tracking-wider text-primary">{node.type}</span><span class="mt-3 block text-sm font-semibold">{node.id}</span><span class="mt-2 block text-xs text-base-content/40">Version {node.version}</span></button>
                    </div>
                  </div>
                </section>
                <section :if={@can_edit?} class="grid gap-6 lg:grid-cols-2">
                  <.form
                    for={@add_form}
                    id="add-workflow-node-form"
                    phx-submit="add_node"
                    class="rounded-2xl border border-base-300 p-5"
                  >
                    <h2 class="mb-4 font-semibold">Add an action</h2><.input
                      field={@add_form[:catalog]}
                      type="select"
                      label="Catalog action"
                      options={@catalog_options}
                      required
                    /><.input
                      field={@add_form[:id]}
                      label="Node name"
                      placeholder="prepare_fix"
                      required
                      maxlength="80"
                    /><button id="add-workflow-node" class="btn btn-outline btn-sm w-full">Add node
                    <.icon name="hero-plus" class="size-4" /></button>
                  </.form>
                  <.form
                    for={@edge_form}
                    id="connect-workflow-nodes-form"
                    phx-submit="connect_nodes"
                    class="rounded-2xl border border-base-300 p-5"
                  >
                    <h2 class="mb-4 font-semibold">Connect actions</h2><div class="grid grid-cols-2 gap-3">
                      <.input
                        field={@edge_form[:from]}
                        type="select"
                        label="From"
                        options={@node_options}
                        required
                      /><.input
                        field={@edge_form[:to]}
                        type="select"
                        label="To"
                        options={@node_options}
                        required
                      />
                    </div><.input
                      field={@edge_form[:to_input]}
                      type="number"
                      label="Join input index (optional)"
                      min="0"
                      max="99"
                    /><button id="connect-workflow-nodes" class="btn btn-outline btn-sm w-full">Connect
                    <.icon name="hero-arrow-right" class="size-4" /></button>
                  </.form>
                </section>
                <section class="rounded-2xl border border-base-300 p-5">
                  <h2 class="mb-4 font-semibold">Connections</h2><div
                    id="workflow-connection-list"
                    phx-update="stream"
                    class="space-y-2"
                  >
                    <p
                      id="no-workflow-connections"
                      class="hidden text-sm text-base-content/50 only:block"
                    >
                      Connect two actions to pass results forward.
                    </p><div
                      :for={{id, edge} <- @streams.connection_rows}
                      id={id}
                      class="flex items-center justify-between gap-3 rounded-lg bg-base-200/60 p-3 text-xs"
                    >
                      <span class="min-w-0 break-all">{edge.from}
                      <.icon name="hero-arrow-right" class="mx-2 size-3" />{edge.to}{if(
                        is_integer(edge.input),
                        do: " · input #{edge.input}",
                        else: ""
                      )}</span><button
                        :if={@can_edit?}
                        id={"remove-edge-" <> edge.id}
                        phx-click="delete_edge"
                        phx-value-id={edge.id}
                        aria-label={"Remove connection from #{edge.from} to #{edge.to}"}
                        class="btn btn-ghost btn-xs"
                      ><.icon name="hero-x-mark" class="size-4" /></button>
                    </div>
                  </div>
                </section>
                <section aria-labelledby="validation-heading">
                  <h2 id="validation-heading" class="mb-3 text-sm font-semibold">Validation</h2><div
                    id="workflow-validation"
                    phx-update="stream"
                    class="space-y-2"
                  >
                    <p
                      id="workflow-valid"
                      class="hidden rounded-xl border border-success/30 bg-success/5 p-4 text-xs text-success only:block"
                    >
                      Definition is valid.
                    </p><p
                      :for={{id, issue} <- @streams.issues}
                      id={id}
                      class="rounded-xl border border-error/25 bg-error/5 p-4 text-xs"
                    >
                      <span class="font-mono">{issue.path}</span> · {issue.message}
                    </p>
                  </div>
                </section>
              </div>
              <aside class="space-y-6">
                <.form
                  :if={@can_edit?}
                  for={@graph_form}
                  id="save-workflow-form"
                  phx-submit="save_workflow"
                  class="rounded-2xl border border-base-300 p-5"
                >
                  <h2 class="mb-4 font-semibold">Definition settings</h2><.input
                    field={@graph_form[:name]}
                    label="Name"
                    required
                    maxlength="120"
                  /><.input
                    field={@graph_form[:status]}
                    type="select"
                    label="Status"
                    options={
                      if(@can_activate?,
                        do: [{"Draft", "draft"}, {"Active", "active"}, {"Archived", "archived"}],
                        else: [{"Draft", "draft"}, {"Archived", "archived"}]
                      )
                    }
                  /><button
                    id="save-workflow"
                    class="btn btn-primary btn-sm w-full"
                    phx-disable-with="Validating & saving…"
                  >Save workflow</button>
                </.form>
                <.form
                  :if={is_binary(@selected) and @can_edit?}
                  for={@node_form}
                  id="workflow-node-config-form"
                  phx-submit="save_node"
                  class="rounded-2xl border border-primary/30 p-5"
                >
                  <div class="mb-4 flex items-center justify-between gap-3">
                    <h2 class="font-semibold">{@selected}</h2><button
                      id="delete-workflow-node"
                      type="button"
                      phx-click="delete_node"
                      phx-value-id={@selected}
                      aria-label="Delete selected node"
                      class="btn btn-ghost btn-xs"
                    ><.icon name="hero-trash" class="size-4" /></button>
                  </div><.input
                    field={@node_form[:params]}
                    type="textarea"
                    label="Parameters (JSON)"
                    rows="9"
                    class="w-full rounded-xl border border-base-300 bg-base-100 p-3 font-mono text-xs leading-6 focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/20"
                  /><details class="my-4 text-xs text-base-content/60">
                    <summary class="cursor-pointer">Parameters & expressions</summary><dl class="mt-3 space-y-3">
                      <div :for={field <- @parameter_help}>
                        <dt class="font-mono font-semibold">
                          {field.name}{if(field.required, do: " · required", else: "")}
                        </dt><dd class="mt-1 leading-5">
                          {field.doc}<span class="block font-mono text-base-content/40">{field.type}</span>
                        </dd>
                      </div>
                    </dl><p class="mt-3 leading-5" phx-no-curly-interpolation>
                      Use {{ $json.field }} to read the previous action's result.
                    </p>
                  </details><.input
                    field={@node_form[:connection]}
                    type="textarea"
                    label="Connected account (JSON, optional)"
                    rows="3"
                  /><.input
                    field={@node_form[:policy]}
                    type="textarea"
                    label="Retry policy (JSON, optional)"
                    rows="3"
                  /><button id="save-workflow-node" class="btn btn-outline btn-sm w-full">Apply node settings</button>
                </.form>
                <.form
                  :if={@can_run?}
                  for={@run_form}
                  id="workflow-run-form"
                  phx-submit="start_run"
                  class="rounded-2xl border border-base-300 p-5"
                >
                  <h2 class="mb-4 font-semibold">Run this workflow</h2><.input
                    field={@run_form[:input]}
                    type="textarea"
                    label="Input (JSON)"
                    rows="4"
                  /><p class="mb-4 text-xs leading-6 text-base-content/55">
                    Runs use the saved definition. Coding, publication and deployment follow their configured budgets and actor permissions.
                  </p><button
                    id="start-workflow-run"
                    class="btn btn-primary btn-sm w-full"
                    phx-disable-with="Starting…"
                  >Start run <.icon name="hero-play" class="size-4" /></button>
                </.form>
              </aside>
            </div>
            <section class="mt-8 rounded-2xl border border-base-300 p-6">
              <h2 class="text-lg font-semibold">Recorded runs</h2>
              <p class="mt-2 text-sm text-base-content/55">
                Open a run to inspect its saved status, results and external operations.
              </p>
              <div id="workflow-runs" phx-update="stream" class="mt-5 space-y-2">
                <p id="workflow-runs-empty" class="hidden text-sm text-base-content/50 only:block">
                  No runs yet.
                </p>
                <.link
                  :for={{id, run} <- @streams.runs}
                  id={id}
                  data-run-id={run.id}
                  patch={~p"/workflows/#{@graph.id}?run_id=#{run.id}"}
                  class="flex items-center justify-between gap-4 rounded-xl bg-base-200/50 px-4 py-3 transition hover:bg-base-200"
                >
                  <span class="truncate font-mono text-xs">{run.id}</span>
                  <span class="badge badge-outline">{run.status}</span>
                </.link>
              </div>
            </section>
            <section
              :if={@run}
              id="workflow-run-detail"
              class="mt-8 rounded-2xl border border-base-300 p-6"
            >
              <div class="flex items-center justify-between gap-4">
                <h2 class="text-lg font-semibold">Run</h2><span
                  id="workflow-run-status"
                  class="badge badge-outline"
                  role="status"
                >{@run.status}</span>
              </div><p class="mt-3 break-all font-mono text-xs text-base-content/50">{@run.id}</p><div class="mt-4 flex gap-2">
                <button id="refresh-workflow-run" phx-click="refresh_run" class="btn btn-ghost btn-xs">Refresh recorded status</button><button
                  :if={@can_run? and @run.status in [:created, :running]}
                  id="resume-workflow-run"
                  phx-click="resume_run"
                  class="btn btn-outline btn-xs"
                >Reconcile run</button>
              </div><div id="workflow-run-operations" phx-update="stream" class="mt-5 space-y-3">
                <article
                  :for={{id, operation} <- @streams.operations}
                  id={id}
                  class="rounded-xl bg-base-200/60 p-4"
                >
                  <div class="flex items-center justify-between text-xs">
                    <span class="font-semibold">{operation.node_id} · {operation.node_type}</span><span>{operation.status}</span>
                  </div><pre
                    :if={operation.resource != %{}}
                    class="mt-3 overflow-auto whitespace-pre-wrap text-xs"
                  >{Jason.encode!(operation.resource, pretty: true)}</pre>
                </article>
              </div><pre
                :if={@run.output}
                id="workflow-run-output"
                class="mt-5 overflow-auto whitespace-pre-wrap rounded-xl bg-base-200/60 p-4 text-xs"
              >{Jason.encode!(@run.output, pretty: true)}</pre><pre
                :if={@run.error}
                id="workflow-run-error"
                class="mt-5 overflow-auto whitespace-pre-wrap text-xs text-error"
              >{Jason.encode!(@run.error, pretty: true)}</pre>
            </section>
          <% end %>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
