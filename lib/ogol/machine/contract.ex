defmodule Ogol.Machine.Contract do
  @moduledoc false

  alias Ogol.Machine.Skill

  @type item_t :: %{name: atom(), summary: String.t() | nil}

  @type t :: %__MODULE__{
          machine_id: atom(),
          module: module(),
          summary: String.t() | nil,
          skills: [Skill.t()],
          signals: [item_t()],
          facts: [item_t()],
          outputs: [item_t()],
          fields: [item_t()]
        }

  @type descriptor_item_t :: %{
          name: String.t(),
          kind: atom() | nil,
          summary: String.t() | nil
        }

  @type descriptor_t :: %{
          machine_id: String.t(),
          module_name: String.t() | nil,
          meaning: String.t() | nil,
          skills: [descriptor_item_t()],
          status: [descriptor_item_t()],
          signals: [descriptor_item_t()]
        }

  @enforce_keys [:machine_id, :module]
  defstruct [
    :machine_id,
    :module,
    :summary,
    skills: [],
    signals: [],
    facts: [],
    outputs: [],
    fields: []
  ]

  @spec fetch(module()) :: {:ok, t()} | {:error, :missing_contract}
  def fetch(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__ogol_contract__, 0) do
      {:ok, module.__ogol_contract__()}
    else
      {:error, :missing_contract}
    end
  end

  @spec from_module(module()) :: {:ok, descriptor_t()} | {:error, :missing_contract}
  def from_module(module) when is_atom(module) do
    with {:ok, %__MODULE__{} = contract} <- fetch(module) do
      {:ok, describe(contract)}
    end
  end

  @spec from_projection(map()) :: descriptor_t()
  def from_projection(%{} = projection) do
    %{
      machine_id: projection_machine_id(projection),
      module_name: Map.get(projection, :module_name),
      meaning: Map.get(projection, :meaning),
      skills:
        normalize_skills(
          projection_skill_items(Map.get(projection, :requests, []), :request) ++
            projection_skill_items(Map.get(projection, :events, []), :event)
        ),
      status:
        normalize_status(projection_public_items(Map.get(projection, :facts, [])), :fact) ++
          normalize_status(projection_public_items(Map.get(projection, :outputs, [])), :output) ++
          normalize_status(
            projection_public_items(Map.get(projection, :memory_fields, [])),
            :field
          ),
      signals: normalize_signals(Map.get(projection, :signals, []))
    }
  end

  @spec describe(t()) :: descriptor_t()
  def describe(%__MODULE__{} = contract) do
    %{
      machine_id: to_string(contract.machine_id),
      module_name: normalized_module_name(contract.module),
      meaning: contract.summary,
      skills: normalize_skills(contract.skills),
      status:
        normalize_status(contract.facts, :fact) ++
          normalize_status(contract.outputs, :output) ++
          normalize_status(contract.fields, :field),
      signals: normalize_signals(contract.signals)
    }
  end

  defp normalize_skills(skills) do
    skills
    |> Enum.map(fn skill ->
      %{
        name: to_string(skill.name),
        kind: skill.kind,
        summary: skill.summary
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp normalize_status(items, kind) do
    items
    |> Enum.map(fn item ->
      %{
        name: to_string(item.name),
        kind: kind,
        summary: Map.get(item, :summary)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp normalize_signals(signals) do
    signals
    |> Enum.map(fn signal ->
      %{
        name: to_string(signal.name),
        kind: nil,
        summary: Map.get(signal, :summary)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp normalized_module_name(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
  end

  defp normalized_module_name(_module), do: nil

  defp projection_machine_id(%{machine_id: machine_id}) when is_binary(machine_id), do: machine_id
  defp projection_machine_id(%{machine_id: machine_id}), do: to_string(machine_id)
  defp projection_machine_id(_projection), do: ""

  defp projection_skill_items(rows, kind) when is_list(rows) do
    Enum.flat_map(rows, fn row ->
      if Map.get(row, :skill?, false) do
        [
          %{
            name: Map.get(row, :name),
            kind: kind,
            summary: Map.get(row, :meaning)
          }
        ]
      else
        []
      end
    end)
  end

  defp projection_public_items(rows) when is_list(rows) do
    Enum.flat_map(rows, fn row ->
      if Map.get(row, :public?, false) do
        [%{name: Map.get(row, :name), summary: Map.get(row, :meaning)}]
      else
        []
      end
    end)
  end
end
