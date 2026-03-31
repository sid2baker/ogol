defmodule Ogol.HMI.CommandGateway do
  @moduledoc false

  alias Ogol.HMI.RuntimeNotifier
  alias Ogol.Runtime.Delivery
  alias Ogol.Runtime.Target

  @default_timeout 5_000

  @spec invoke(atom(), atom(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def invoke(machine_id, name, data \\ %{}, opts \\ [])
      when is_atom(machine_id) and is_atom(name) and is_map(data) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    meta = Keyword.get(opts, :meta, %{})
    operator_meta = operator_meta(meta)

    with {:ok, runtime} <- Target.resolve_machine_runtime(machine_id),
         {:ok, skill} <- find_skill(runtime.module, name),
         {:ok, reply} <- dispatch(runtime.pid, skill, name, data, operator_meta, timeout) do
      RuntimeNotifier.emit(:operator_skill_invoked,
        machine_id: machine_id,
        source: __MODULE__,
        payload: %{name: name, kind: skill.kind, data: data, reply: reply},
        meta: operator_meta
      )

      {:ok, reply}
    else
      {:error, reason} = error ->
        emit_failure(machine_id, name, data, operator_meta, reason)
        error
    end
  end

  defp find_skill(target_module, name) do
    case Enum.find(target_module.skills(), &(&1.name == name)) do
      %Ogol.Skill{} = skill -> {:ok, skill}
      nil -> {:error, {:unknown_skill, name}}
    end
  end

  defp dispatch(pid, %Ogol.Skill{kind: :request}, name, data, meta, timeout) do
    {:ok, Delivery.request(pid, name, data, meta, timeout)}
  catch
    :exit, reason -> {:error, {:target_runtime_failure, reason}}
  end

  defp dispatch(pid, %Ogol.Skill{kind: :event}, name, data, meta, _timeout) do
    :ok = Delivery.event(pid, name, data, meta)
    {:ok, :accepted}
  end

  defp emit_failure(machine_id, name, data, meta, reason) do
    RuntimeNotifier.emit(:operator_skill_failed,
      machine_id: machine_id,
      source: __MODULE__,
      payload: %{name: name, data: data, reason: reason},
      meta: meta
    )

    {:error, reason}
  end

  defp operator_meta(meta) do
    meta
    |> Map.put_new(:origin, :operator)
    |> Map.put_new(:gateway, __MODULE__)
  end
end
