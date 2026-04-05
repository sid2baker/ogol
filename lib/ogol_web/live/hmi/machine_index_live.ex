defmodule OgolWeb.HMI.MachineIndexLive do
  use OgolWeb, :live_view

  alias Ogol.Session
  alias OgolWeb.Components.StatusBadge
  alias OgolWeb.HMI.{MachineCard, OpsControl, OpsControlStrip}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Session.subscribe(:overview)
    end

    {:ok,
     socket
     |> assign(:hmi_mode, :ops)
     |> assign(:hmi_nav, :machines)
     |> assign(:operator_feedback, nil)
     |> assign(:operator_feedback_ref, nil)
     |> assign(:ops_control_feedback, nil)
     |> load_runtime_machines()}
  end

  @impl true
  def handle_info({:overview_updated, _operations}, socket) do
    {:noreply, load_runtime_machines(socket)}
  end

  def handle_info({:operator_control_result, ref, feedback}, socket) do
    if socket.assigns.operator_feedback_ref == ref do
      {:noreply,
       socket
       |> assign(:operator_feedback_ref, nil)
       |> assign(:operator_feedback, feedback)
       |> load_runtime_machines()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("dispatch_control", %{"machine_id" => machine_id, "name" => name}, socket) do
    case resolve_skill(socket.assigns.machine_instances, machine_id, name) do
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

  def handle_event("ops_control", %{"action" => action}, socket) do
    {feedback, socket} =
      case OpsControl.dispatch(action) do
        {:ok, target, detail} ->
          {OpsControl.feedback(:ok, target, action, detail), load_runtime_machines(socket)}

        {:error, target, reason} ->
          {OpsControl.feedback(:error, target, action, reason), load_runtime_machines(socket)}
      end

    {:noreply, assign(socket, :ops_control_feedback, feedback)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-4">
      <OpsControlStrip.strip status={@ops_control_status} feedback={@ops_control_feedback} />

      <div
        :if={@operator_feedback}
        class={[
          "app-panel inline-flex border px-4 py-3 font-mono text-[11px] uppercase tracking-[0.16em]",
          feedback_classes(@operator_feedback.status)
        ]}
      >
        {operator_feedback_summary(@operator_feedback)} :: {operator_feedback_detail(@operator_feedback)}
      </div>

      <div
        :if={@machine_groups == []}
        class="app-panel border-dashed px-6 py-14 text-center text-sm leading-6 text-[var(--app-text-muted)]"
      >
        No runtime machine instances are projected yet. Start a machine or topology and the instance index will populate automatically.
      </div>

      <section
        :for={group <- @machine_groups}
        data-test={"machine-group-#{group.id}"}
        class="app-panel overflow-hidden"
      >
        <div class="border-b border-[var(--app-border)] px-5 py-4">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="app-kicker">Machine Definition</p>
              <h2 class="mt-1 text-xl font-semibold text-[var(--app-text)]">{group.label}</h2>
              <p :if={group.summary} class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
                {group.summary}
              </p>
            </div>

            <div class="flex flex-wrap items-center gap-2">
              <span class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-1 font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-muted)]">
                {length(group.instances)} instances
              </span>
              <StatusBadge.badge status={group_health(group.instances)} />
            </div>
          </div>
        </div>

        <div class="grid gap-4 p-4 xl:grid-cols-2">
          <MachineCard.card
            :for={machine <- group.instances}
            machine={machine}
            status={status_for(machine)}
            skills={skills_for(machine)}
            controls_enabled?={machine.connected?}
          />
        </div>
      </section>
    </section>
    """
  end

  defp load_runtime_machines(socket) do
    machine_instances = Session.list_runtime_machines()

    socket
    |> assign(:machine_instances, machine_instances)
    |> assign(:machine_groups, machine_groups(machine_instances))
    |> assign(:ops_control_status, OpsControl.status())
  end

  defp machine_groups(machine_instances) do
    machine_instances
    |> Enum.sort_by(fn machine ->
      {module_label(machine), to_string(machine.machine_id)}
    end)
    |> Enum.group_by(&module_group_key/1)
    |> Enum.map(fn {key, instances} ->
      first = List.first(instances)

      %{
        id: slugify(module_label(first)),
        key: key,
        label: module_label(first),
        summary: machine_summary(first),
        instances: Enum.sort_by(instances, &to_string(&1.machine_id))
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  defp group_health(instances) do
    cond do
      Enum.any?(instances, &(&1.health in [:crashed, :faulted])) -> :crashed
      Enum.any?(instances, &(&1.health == :recovering)) -> :recovering
      Enum.any?(instances, &(&1.health == :running)) -> :running
      Enum.any?(instances, &(&1.health == :waiting)) -> :waiting
      Enum.any?(instances, &(&1.health == :healthy)) -> :healthy
      true -> :stopped
    end
  end

  defp module_group_key(%{module: module}) when is_atom(module), do: Atom.to_string(module)
  defp module_group_key(_machine), do: "module pending"

  defp module_label(%{module: module}) when is_atom(module) do
    module
    |> inspect()
    |> String.replace_prefix("Elixir.", "")
  end

  defp module_label(_machine), do: "module pending"

  defp machine_summary(%{module: module}) when is_atom(module) do
    if function_exported?(module, :__ogol_contract__, 0) do
      module.__ogol_contract__().summary
    end
  end

  defp machine_summary(_machine), do: nil

  defp status_for(machine) do
    %Ogol.Machine.Status{
      machine_id: machine.machine_id,
      module: machine.module,
      current_state: machine.current_state,
      health: machine.health,
      connected?: machine.connected?,
      facts: Map.get(machine, :facts, %{}),
      fields: Map.get(machine, :fields, %{}),
      outputs: Map.get(machine, :outputs, %{}),
      last_signal: machine.last_signal,
      last_transition_at: machine.last_transition_at
    }
  end

  defp skills_for(%{module: module}) when is_atom(module) do
    if function_exported?(module, :skills, 0), do: module.skills(), else: []
  end

  defp skills_for(_machine), do: []

  defp resolve_skill(machines, machine_id, name) do
    case Enum.find(machines, &(to_string(&1.machine_id) == machine_id)) do
      nil ->
        {:error, :machine_unavailable}

      machine ->
        case Enum.find(skills_for(machine), &(to_string(&1.name) == name)) do
          nil -> {:error, {:unknown_skill, name}}
          skill -> {:ok, machine, skill.name}
        end
    end
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

  defp operator_feedback(status, machine_id, name, detail) do
    %{status: status, machine_id: machine_id, name: name, detail: detail}
  end

  defp operator_feedback_summary(feedback) do
    "#{feedback.machine_id} :: skill #{feedback.name}"
  end

  defp operator_feedback_detail(%{status: :pending}), do: "invoking"

  defp operator_feedback_detail(%{status: :ok, detail: detail}),
    do: "reply=#{format_value(detail)}"

  defp operator_feedback_detail(%{status: :error, detail: detail}),
    do: "reason=#{format_value(detail)}"

  defp feedback_classes(:ok) do
    "border-[var(--app-good-border)] bg-[var(--app-good-surface)] text-[var(--app-good-text)]"
  end

  defp feedback_classes(:pending) do
    "border-[var(--app-info-border)] bg-[var(--app-info-surface)] text-[var(--app-info-text)]"
  end

  defp feedback_classes(:error) do
    "border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] text-[var(--app-danger-text)]"
  end

  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp format_value(value), do: inspect(value)

  defp slugify(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9]+/u, "-")
    |> String.trim("-")
    |> String.downcase()
  end
end
