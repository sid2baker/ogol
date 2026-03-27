defmodule Ogol.HMI.CommandGateway do
  @moduledoc false

  alias Ogol.HMI.RuntimeNotifier

  @default_timeout 5_000

  @spec invoke(atom(), atom(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def invoke(machine_id, name, data \\ %{}, opts \\ [])
      when is_atom(machine_id) and is_atom(name) and is_map(data) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    meta = Keyword.get(opts, :meta, %{})
    operator_meta = operator_meta(meta)

    with %Ogol.Skill{} = skill <- Ogol.skill(machine_id, name),
         {:ok, reply} <-
           Ogol.invoke(machine_id, name, data, meta: operator_meta, timeout: timeout) do
      RuntimeNotifier.emit(:operator_skill_invoked,
        machine_id: machine_id,
        source: __MODULE__,
        payload: %{name: name, kind: skill.kind, data: data, reply: reply},
        meta: operator_meta
      )

      {:ok, reply}
    else
      nil ->
        emit_failure(machine_id, name, data, operator_meta, {:unknown_skill, name})

      {:error, reason} = error ->
        emit_failure(machine_id, name, data, operator_meta, reason)
        error
    end
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
