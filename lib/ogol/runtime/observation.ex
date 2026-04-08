defmodule Ogol.Runtime.Observation do
  @moduledoc false

  alias Ogol.Runtime.Data

  @spec merge(Data.t(), map(), map()) :: Data.t()
  def merge(%Data{} = data, patch, meta \\ %{}) when is_map(patch) and is_map(meta) do
    normalized = normalize_patch(patch, meta)

    if normalized == %{} do
      data
    else
      %{
        data
        | observations:
            Map.merge(data.observations, normalized, fn _name, existing, incoming ->
              merge_entry(existing, incoming)
            end)
      }
    end
  end

  @spec resolved_facts(Data.t()) :: map()
  def resolved_facts(%Data{} = data) do
    Enum.reduce(data.observations, data.facts, fn
      {name, %{value: value}}, acc -> Map.put(acc, name, value)
      {_name, _entry}, acc -> acc
    end)
  end

  @spec fetch(Data.t(), atom()) :: {:ok, term()} | :error
  def fetch(%Data{} = data, name) when is_atom(name) do
    case Map.fetch(data.observations, name) do
      {:ok, %{value: value}} ->
        {:ok, value}

      _other ->
        case Map.fetch(data.facts, name) do
          {:ok, value} -> {:ok, value}
          :error -> :error
        end
    end
  end

  @spec value(Data.t(), atom(), term()) :: term()
  def value(%Data{} = data, name, default \\ nil) when is_atom(name) do
    case fetch(data, name) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @spec entry(Data.t(), atom()) :: map() | nil
  def entry(%Data{} = data, name) when is_atom(name), do: Map.get(data.observations, name)

  defp merge_entry(existing, incoming) when is_map(existing) and is_map(incoming) do
    Map.merge(existing, incoming)
  end

  defp merge_entry(_existing, incoming), do: incoming

  defp normalize_patch(patch, meta) do
    Enum.reduce(patch, %{}, fn
      {name, value}, acc when is_atom(name) ->
        Map.put(acc, name, normalize_entry(value, meta))

      {_name, _value}, acc ->
        acc
    end)
  end

  defp normalize_entry(value, meta) when is_map(value) do
    %{}
    |> maybe_put(:value, Map.get(value, :value))
    |> maybe_put(
      :observed_at_us,
      Map.get(value, :observed_at_us) || Map.get(value, :updated_at_us) || meta[:updated_at_us]
    )
    |> maybe_put(:freshness, Map.get(value, :freshness) || inferred_freshness(value, meta))
    |> maybe_put(:stale_details, Map.get(value, :stale_details))
    |> maybe_put(:source, Map.get(value, :source) || meta[:source])
    |> maybe_put(:bus, Map.get(value, :bus) || meta[:bus])
    |> maybe_put(:slave, Map.get(value, :slave) || meta[:slave])
    |> maybe_put(:signal, Map.get(value, :signal) || meta[:signal])
    |> maybe_put(:channel, Map.get(value, :channel) || meta[:channel])
    |> maybe_put(:cycle, Map.get(value, :cycle) || meta[:cycle])
  end

  defp normalize_entry(value, meta) do
    normalize_entry(%{value: value}, meta)
  end

  defp inferred_freshness(value, _meta) when is_map(value) do
    cond do
      Map.has_key?(value, :freshness) -> Map.get(value, :freshness)
      Map.has_key?(value, :value) -> :fresh
      true -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
