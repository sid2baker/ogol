defmodule OgolWeb.HMI.SurfaceLive do
  use OgolWeb, :surface_live_view

  alias Ogol.HMI.Surface
  alias Ogol.HMI.Surface.Catalog, as: SurfaceCatalog
  alias Ogol.HMI.Surface.Deployments, as: SurfaceDeployment
  alias Ogol.HMI.Surface.Template
  alias Ogol.Session
  alias OgolWeb.HMI.{OpsControl, OpsControlStrip, OverviewSurface}

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
     |> assign(:ops_control_feedback, nil)
     |> assign(:surface_error, nil)
     |> assign(:surface_context, %{})
     |> assign(:surface_runtime, nil)
     |> assign(:surface_screen, nil)
     |> assign(:surface_variant, nil)
     |> assign(:ops_control_status, OpsControl.status())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case resolve_surface(socket.assigns.live_action, params) do
      {:ok, runtime, screen, variant, deployment} ->
        {:noreply, assign_surface(socket, runtime, screen, variant, deployment)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:ops_control_feedback, nil)
         |> assign(:surface_error, reason)
         |> assign(:surface_context, %{})
         |> assign(:surface_runtime, nil)
         |> assign(:surface_screen, nil)
         |> assign(:surface_variant, nil)
         |> assign(:ops_control_status, OpsControl.status())}
    end
  end

  @impl true
  def handle_info({:machine_snapshot_updated, _snapshot}, socket) do
    {:noreply, reload_context(socket)}
  end

  def handle_info({:overview_updated, _operations}, socket) do
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

  def handle_event("procedure_control", %{"action" => action} = params, socket) do
    {feedback, socket} =
      case dispatch_procedure_action(action, params) do
        {:ok, target, detail} ->
          {procedure_feedback(:ok, target, action, detail), reload_context(socket)}

        {:error, target, reason} ->
          {procedure_feedback(:error, target, action, reason), reload_context(socket)}
      end

    {:noreply,
     socket
     |> assign(:operator_feedback_ref, nil)
     |> assign(:operator_feedback, feedback)}
  end

  def handle_event("ops_control", %{"action" => action}, socket) do
    {feedback, socket} =
      case OpsControl.dispatch(action) do
        {:ok, target, detail} ->
          {OpsControl.feedback(:ok, target, action, detail), reload_context(socket)}

        {:error, target, reason} ->
          {OpsControl.feedback(:error, target, action, reason), reload_context(socket)}
      end

    {:noreply, assign(socket, :ops_control_feedback, feedback)}
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
    <div class="flex h-full min-h-0 flex-col gap-4">
      <OpsControlStrip.strip status={@ops_control_status} feedback={@ops_control_feedback} />

      <div class="min-h-0 flex-1 overflow-hidden">
        <OverviewSurface.render
          surface={@surface_runtime}
          screen={@surface_screen}
          variant={@surface_variant}
          context={@surface_context}
          operator_feedback={@operator_feedback}
        />
      </div>
    </div>
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

  defp assign_surface(socket, runtime, screen, variant, _deployment) do
    socket
    |> assign(:surface_error, nil)
    |> assign(:surface_runtime, runtime)
    |> assign(:surface_screen, screen)
    |> assign(:surface_variant, variant)
    |> reload_context()
  end

  defp reload_context(%{assigns: %{surface_runtime: %Surface.Runtime{} = runtime}} = socket) do
    socket
    |> assign(:surface_context, Template.build_context(runtime, event_limit: @event_limit))
    |> assign(:ops_control_status, OpsControl.status())
  end

  defp reload_context(socket) do
    socket
    |> assign(:surface_context, %{})
    |> assign(:ops_control_status, OpsControl.status())
  end

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
    %{kind: :machine_skill, status: status, machine_id: machine_id, name: name, detail: detail}
  end

  defp procedure_feedback(status, target, action, detail) do
    %{kind: :procedure_control, status: status, target: target, action: action, detail: detail}
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

  defp dispatch_procedure_action("select", %{"sequence_id" => sequence_id}) do
    case Session.select_procedure(sequence_id) do
      :ok -> {:ok, sequence_id, :selected}
      _other -> {:error, sequence_id, :not_allowed}
    end
  end

  defp dispatch_procedure_action("arm_auto", _params) do
    case Session.set_control_mode(:auto) do
      :ok -> {:ok, "cell", :armed}
      _other -> {:error, "cell", :not_allowed}
    end
  end

  defp dispatch_procedure_action("switch_to_manual", _params) do
    case Session.set_control_mode(:manual) do
      :ok -> {:ok, "cell", :manual}
      _other -> {:error, "cell", :not_allowed}
    end
  end

  defp dispatch_procedure_action("set_cycle_policy", _params) do
    case Session.set_sequence_run_policy(:cycle) do
      :ok -> {:ok, "cell", :cycle}
      _other -> {:error, "cell", :not_allowed}
    end
  end

  defp dispatch_procedure_action("set_once_policy", _params) do
    case Session.set_sequence_run_policy(:once) do
      :ok -> {:ok, "cell", :once}
      _other -> {:error, "cell", :not_allowed}
    end
  end

  defp dispatch_procedure_action("run_selected", _params) do
    case Session.selected_procedure_id() do
      sequence_id when is_binary(sequence_id) ->
        case Session.start_sequence_run(sequence_id) do
          :ok -> {:ok, sequence_id, :started}
          _other -> {:error, sequence_id, :not_allowed}
        end

      _other ->
        {:error, "cell", :no_selected_procedure}
    end
  end

  defp dispatch_procedure_action("pause", _params) do
    case Session.pause_sequence_run() do
      :ok -> {:ok, active_procedure_target(), :pause_requested}
      _other -> {:error, active_procedure_target(), :not_allowed}
    end
  end

  defp dispatch_procedure_action("resume", _params) do
    case Session.resume_sequence_run() do
      :ok -> {:ok, active_procedure_target(), :resume_requested}
      _other -> {:error, active_procedure_target(), :not_allowed}
    end
  end

  defp dispatch_procedure_action("abort", _params) do
    case Session.cancel_sequence_run() do
      :ok -> {:ok, active_procedure_target(), :abort_requested}
      _other -> {:error, active_procedure_target(), :not_allowed}
    end
  end

  defp dispatch_procedure_action("acknowledge", _params) do
    case Session.acknowledge_sequence_run() do
      :ok -> {:ok, active_or_selected_target(), :acknowledged}
      _other -> {:error, active_or_selected_target(), :not_allowed}
    end
  end

  defp dispatch_procedure_action("clear_result", _params) do
    case Session.clear_sequence_run_result() do
      :ok -> {:ok, active_or_selected_target(), :cleared}
      _other -> {:error, active_or_selected_target(), :not_allowed}
    end
  end

  defp dispatch_procedure_action("request_manual_takeover", _params) do
    case Session.request_manual_takeover() do
      :ok -> {:ok, active_procedure_target(), :takeover_requested}
      _other -> {:error, active_procedure_target(), :not_allowed}
    end
  end

  defp dispatch_procedure_action(_action, _params), do: {:error, "cell", :unsupported}

  defp active_procedure_target do
    case Session.sequence_run_state() do
      %{sequence_id: sequence_id} when is_binary(sequence_id) -> sequence_id
      _other -> "cell"
    end
  end

  defp active_or_selected_target do
    case active_procedure_target() do
      "cell" ->
        case Session.selected_procedure_id() do
          sequence_id when is_binary(sequence_id) -> sequence_id
          _other -> "cell"
        end

      target ->
        target
    end
  end
end
