defmodule OgolWeb.HMI.SurfaceLive do
  use OgolWeb, :surface_live_view

  alias Ogol.HMI.Surface
  alias Ogol.HMI.Surface.Catalog, as: SurfaceCatalog
  alias Ogol.HMI.Surface.Deployments, as: SurfaceDeployment
  alias Ogol.HMI.Surface.Template
  alias Ogol.Session
  alias OgolWeb.HMI.OverviewSurface

  @event_limit 6

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Session.subscribe(:overview)
      :ok = Session.subscribe(:events)
    end

    {:ok,
     socket
     |> assign(:operator_feedback, nil)
     |> assign(:operator_feedback_ref, nil)
     |> assign(:surface_error, nil)
     |> assign(:surface_context, %{})
     |> assign(:surface_runtime, nil)
     |> assign(:surface_screen, nil)
     |> assign(:surface_variant, nil)
     |> assign(:surface_panel, nil)
     |> assign(:surface_version, nil)
     |> assign(:surface_viewport, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case resolve_surface(socket.assigns.live_action, params) do
      {:ok, runtime, screen, variant, deployment} ->
        {:noreply, assign_surface(socket, runtime, screen, variant, deployment)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:surface_error, reason)
         |> assign(:surface_context, %{})
         |> assign(:surface_runtime, nil)
         |> assign(:surface_screen, nil)
         |> assign(:surface_variant, nil)}
    end
  end

  @impl true
  def handle_info({:machine_snapshot_updated, _snapshot}, socket) do
    {:noreply, reload_context(socket)}
  end

  def handle_info({:event_logged, _notification}, socket) do
    {:noreply, reload_context(socket)}
  end

  def handle_info({:operator_control_result, ref, feedback}, socket) do
    if socket.assigns.operator_feedback_ref == ref do
      {:noreply,
       socket
       |> assign(:operator_feedback_ref, nil)
       |> assign(:operator_feedback, feedback)
       |> reload_context()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("dispatch_control", %{"machine_id" => machine_id, "name" => name}, socket) do
    case Template.resolve_skill(
           socket.assigns.surface_runtime,
           socket.assigns.surface_context,
           machine_id,
           name
         ) do
      {:ok, machine, skill_name} ->
        ref = make_ref()
        dispatch_control_async(self(), ref, machine.machine_id, skill_name)

        {:noreply,
         socket
         |> assign(:operator_feedback_ref, ref)
         |> assign(
           :operator_feedback,
           operator_feedback(:pending, machine.machine_id, skill_name, :dispatching)
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:operator_feedback_ref, nil)
         |> assign(:operator_feedback, operator_feedback(:error, machine_id, name, reason))}
    end
  end

  @impl true
  def render(%{surface_runtime: nil, surface_error: reason} = assigns) do
    assigns = assign(assigns, :reason, inspect(reason))

    ~H"""
    <section class="app-panel mx-auto max-w-4xl px-6 py-8">
      <p class="app-kicker">Runtime Surface</p>
      <h2 class="mt-2 text-2xl font-semibold text-[var(--app-text)]">Surface unavailable</h2>
      <p class="mt-3 text-sm leading-6 text-[var(--app-text-muted)]">
        The requested runtime surface could not be resolved.
      </p>
      <p class="mt-4 font-mono text-[11px] text-[var(--app-text-dim)]">{@reason}</p>
      <.link
        navigate={~p"/ops/hmis"}
        class="mt-5 inline-flex border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text)]"
      >
        Open surface launcher
      </.link>
    </section>
    """
  end

  def render(assigns) do
    ~H"""
    <OverviewSurface.render
      surface={@surface_runtime}
      screen={@surface_screen}
      variant={@surface_variant}
      context={@surface_context}
      operator_feedback={@operator_feedback}
    />
    """
  end

  defp resolve_surface(:assigned, _params) do
    deployment = SurfaceDeployment.default_assignment()

    with {:ok, %{runtime: runtime, version: version}} <-
           SurfaceCatalog.fetch_resolved(deployment.surface_id, deployment.surface_version),
         screen when not is_nil(screen) <- Surface.find_screen(runtime, deployment.default_screen),
         variant when not is_nil(variant) <-
           Surface.select_variant(screen, deployment.viewport_profile) do
      {:ok, runtime, screen, variant, %{deployment | surface_version: version}}
    else
      _ -> {:error, {:surface_not_assigned, deployment.surface_id}}
    end
  end

  defp resolve_surface(_action, %{"surface_id" => surface_id} = params) do
    requested_screen = params["screen_id"]

    with {:ok, %{runtime: runtime, version: version}} <- SurfaceCatalog.fetch_resolved(surface_id),
         deployment <-
           SurfaceDeployment.fetch_surface_assignment(surface_id) ||
             fallback_deployment(runtime, version, requested_screen),
         screen when not is_nil(screen) <-
           Surface.find_screen(runtime, requested_screen || deployment.default_screen),
         variant when not is_nil(variant) <-
           Surface.select_variant(screen, deployment.viewport_profile) do
      {:ok, runtime, screen, variant, %{deployment | surface_version: version}}
    else
      :error -> {:error, {:unknown_surface, surface_id}}
      nil -> {:error, {:unknown_screen, requested_screen}}
    end
  end

  defp assign_surface(socket, runtime, screen, variant, deployment) do
    socket
    |> assign(:surface_error, nil)
    |> assign(:surface_runtime, runtime)
    |> assign(:surface_screen, screen)
    |> assign(:surface_variant, variant)
    |> assign(:surface_title, runtime.title)
    |> assign(:surface_summary, runtime.summary)
    |> assign(:surface_role, runtime.role)
    |> assign(:surface_panel, deployment && deployment.panel_id)
    |> assign(:surface_version, deployment && deployment.surface_version)
    |> assign(:surface_viewport, deployment && deployment.viewport_profile)
    |> reload_context()
  end

  defp reload_context(%{assigns: %{surface_runtime: %Surface.Runtime{} = runtime}} = socket) do
    assign(socket, :surface_context, Template.build_context(runtime, event_limit: @event_limit))
  end

  defp reload_context(socket), do: assign(socket, :surface_context, %{})

  defp fallback_deployment(%Surface.Runtime{} = runtime, version, requested_screen) do
    default_assignment = SurfaceDeployment.default_assignment()

    %Surface.Deployment{
      panel_id: default_assignment.panel_id,
      surface_id: runtime.id,
      surface_module: runtime.module,
      surface_version: version,
      default_screen: requested_screen || runtime.default_screen,
      viewport_profile: default_assignment.viewport_profile
    }
  end

  defp operator_feedback(status, machine_id, name, detail) do
    %{status: status, machine_id: machine_id, name: name, detail: detail}
  end

  defp dispatch_control_async(owner, ref, machine_id, skill_name) do
    Task.start(fn ->
      feedback =
        case Session.invoke_machine(machine_id, skill_name) do
          {:ok, reply} -> operator_feedback(:ok, machine_id, skill_name, reply)
          {:error, reason} -> operator_feedback(:error, machine_id, skill_name, reason)
        end

      send(owner, {:operator_control_result, ref, feedback})
    end)
  end
end
