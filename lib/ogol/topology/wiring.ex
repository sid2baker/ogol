defmodule Ogol.Topology.Wiring do
  @moduledoc false

  @type command_binding :: {:command, atom(), map()}

  @type t :: %__MODULE__{
          facts: %{optional(atom()) => atom()},
          outputs: %{optional(atom()) => atom()},
          commands: %{optional(atom()) => command_binding()},
          event_name: atom() | nil
        }

  defstruct facts: %{}, outputs: %{}, commands: %{}, event_name: nil

  @allowed_keys [:facts, :outputs, :commands, :event_name]

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = wiring) do
    wiring.facts == %{} and wiring.outputs == %{} and wiring.commands == %{} and
      is_nil(wiring.event_name)
  end

  @spec normalize(term()) :: {:ok, t()} | {:error, term()}
  def normalize(nil), do: {:ok, %__MODULE__{}}
  def normalize(%__MODULE__{} = wiring), do: {:ok, wiring}

  def normalize(wiring) when wiring == [] or wiring == %{}, do: {:ok, %__MODULE__{}}

  def normalize(wiring) when is_list(wiring) do
    if Keyword.keyword?(wiring) do
      wiring
      |> Map.new()
      |> normalize()
    else
      {:error, {:invalid_topology_wiring, wiring}}
    end
  end

  def normalize(%{} = wiring) do
    with :ok <- validate_allowed_keys(wiring),
         {:ok, facts} <- normalize_port_map(Map.get(wiring, :facts, %{}), :facts),
         {:ok, outputs} <- normalize_port_map(Map.get(wiring, :outputs, %{}), :outputs),
         {:ok, commands} <- normalize_commands(Map.get(wiring, :commands, %{})),
         {:ok, event_name} <- normalize_event_name(Map.get(wiring, :event_name)) do
      {:ok,
       %__MODULE__{
         facts: facts,
         outputs: outputs,
         commands: commands,
         event_name: event_name
       }}
    end
  end

  def normalize(wiring), do: {:error, {:invalid_topology_wiring, wiring}}

  defp validate_allowed_keys(wiring) do
    case Map.keys(wiring) -- @allowed_keys do
      [] -> :ok
      unknown -> {:error, {:invalid_topology_wiring_keys, unknown}}
    end
  end

  defp normalize_port_map(value, _kind) when value == %{} or value == [], do: {:ok, %{}}

  defp normalize_port_map(value, kind) when is_list(value) do
    if Keyword.keyword?(value) do
      value
      |> Map.new()
      |> normalize_port_map(kind)
    else
      {:error, {:invalid_topology_wiring_value, kind, value}}
    end
  end

  defp normalize_port_map(value, _kind) when is_map(value) do
    if Enum.all?(value, fn {port, endpoint} -> is_atom(port) and is_atom(endpoint) end) do
      {:ok, Map.new(value)}
    else
      {:error, {:invalid_topology_wiring_mapping, value}}
    end
  end

  defp normalize_port_map(value, kind),
    do: {:error, {:invalid_topology_wiring_value, kind, value}}

  defp normalize_commands(value) when value == %{} or value == [], do: {:ok, %{}}

  defp normalize_commands(value) when is_list(value) do
    if Keyword.keyword?(value) do
      value
      |> Map.new()
      |> normalize_commands()
    else
      {:error, {:invalid_topology_wiring_value, :commands, value}}
    end
  end

  defp normalize_commands(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn
      {name, {:command, command, args}}, {:ok, acc} when is_atom(name) and is_atom(command) ->
        with {:ok, normalized_args} <- normalize_command_args(args) do
          {:cont, {:ok, Map.put(acc, name, {:command, command, normalized_args})}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {name, binding}, _acc ->
        {:halt, {:error, {:invalid_topology_command_binding, name, binding}}}
    end)
  end

  defp normalize_commands(value),
    do: {:error, {:invalid_topology_wiring_value, :commands, value}}

  defp normalize_command_args(args) when is_map(args), do: {:ok, args}

  defp normalize_command_args(args) when is_list(args) do
    if Keyword.keyword?(args) do
      {:ok, Map.new(args)}
    else
      {:error, {:invalid_topology_command_args, args}}
    end
  end

  defp normalize_command_args(args), do: {:error, {:invalid_topology_command_args, args}}

  defp normalize_event_name(nil), do: {:ok, nil}
  defp normalize_event_name(event_name) when is_atom(event_name), do: {:ok, event_name}

  defp normalize_event_name(value),
    do: {:error, {:invalid_topology_wiring_value, :event_name, value}}
end
