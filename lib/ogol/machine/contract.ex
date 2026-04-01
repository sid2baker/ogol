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
end
