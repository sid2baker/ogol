defmodule Ogol.Machine.Contract do
  @moduledoc false

  @type item_t :: %{
          name: String.t(),
          kind: atom() | nil,
          summary: String.t() | nil
        }

  @type t :: %{
          machine_id: String.t(),
          module_name: String.t() | nil,
          meaning: String.t() | nil,
          skills: [item_t()],
          status: [item_t()],
          signals: [item_t()]
        }

  @spec from_module(module()) :: {:ok, t()} | {:error, :missing_interface}
  def from_module(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__ogol_interface__, 0) do
      {:ok, from_interface(module.__ogol_interface__())}
    else
      {:error, :missing_interface}
    end
  end

  defp from_interface(interface) do
    status_spec = interface.status_spec

    %{
      machine_id: to_string(interface.machine_id),
      module_name: normalized_module_name(interface.module),
      meaning: interface.summary,
      skills: normalize_skills(interface.skills),
      status:
        normalize_status(status_spec.facts, :fact) ++
          normalize_status(status_spec.outputs, :output) ++
          normalize_status(status_spec.fields, :field),
      signals: normalize_signals(interface.signals)
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
