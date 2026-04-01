defmodule Ogol.Hardware.EtherCAT.Binding do
  @moduledoc """
  Runtime EtherCAT binding for one configured slave.

  The binding stores machine-port to hardware-endpoint mappings after topology
  wiring has been resolved against the active hardware configuration.
  """

  @type command_binding :: {:command, atom(), map()}
  @type input :: t() | map() | keyword()

  @type t :: %__MODULE__{
          slave: atom(),
          outputs: %{optional(atom()) => atom()},
          facts: %{optional(atom()) => atom()},
          commands: %{optional(atom()) => command_binding()},
          event_name: atom() | nil,
          meta: map()
        }

  @enforce_keys [:slave]
  defstruct slave: nil,
            outputs: %{},
            facts: %{},
            commands: %{},
            event_name: nil,
            meta: %{}

  @allowed_keys [:slave, :outputs, :facts, :commands, :event_name, :meta]

  @spec normalize_runtime(term()) :: {:ok, t() | [t()]} | {:error, term()}
  def normalize_runtime(refs) when is_list(refs) do
    if Keyword.keyword?(refs) do
      normalize(refs)
    else
      normalize_many(refs)
    end
  end

  def normalize_runtime(ref), do: normalize(ref)

  @spec normalize_many(term()) :: {:ok, [t()]} | {:error, term()}
  def normalize_many(refs) when is_list(refs) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      case normalize(ref) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_many(ref) do
    with {:ok, normalized} <- normalize(ref) do
      {:ok, [normalized]}
    end
  end

  @spec normalize(term()) :: {:ok, t()} | {:error, term()}
  def normalize(%__MODULE__{} = binding), do: validate(binding)

  def normalize(binding) when is_list(binding) do
    if Keyword.keyword?(binding) do
      binding
      |> Map.new()
      |> normalize()
    else
      {:error, {:invalid_ethercat_binding, binding}}
    end
  end

  def normalize(%{} = binding) do
    with :ok <- validate_allowed_keys(binding),
         {:ok, slave} <- fetch_required_atom(binding, :slave),
         {:ok, outputs} <- fetch_atom_map(binding, :outputs, %{}),
         {:ok, facts} <- fetch_atom_map(binding, :facts, %{}),
         {:ok, commands} <- fetch_commands(binding),
         {:ok, event_name} <- fetch_optional_atom(binding, :event_name),
         {:ok, meta} <- fetch_meta(binding) do
      validate(%__MODULE__{
        slave: slave,
        outputs: outputs,
        facts: facts,
        commands: commands,
        event_name: event_name,
        meta: meta
      })
    end
  end

  def normalize(binding), do: {:error, {:invalid_ethercat_binding, binding}}

  @spec fact_endpoints(t()) :: [atom()]
  def fact_endpoints(%__MODULE__{} = binding) do
    binding.facts
    |> Map.keys()
    |> Enum.uniq()
  end

  @spec machine_fact_for_endpoint(t(), atom()) :: atom() | nil
  def machine_fact_for_endpoint(%__MODULE__{} = binding, endpoint) when is_atom(endpoint) do
    Map.get(binding.facts, endpoint)
  end

  @spec output_endpoint(t(), atom()) :: atom() | nil
  def output_endpoint(%__MODULE__{} = binding, output) when is_atom(output) do
    Map.get(binding.outputs, output)
  end

  @spec handles_output?(t(), atom()) :: boolean()
  def handles_output?(%__MODULE__{} = binding, output) when is_atom(output) do
    Map.has_key?(binding.outputs, output)
  end

  @spec handles_command?(t(), atom()) :: boolean()
  def handles_command?(%__MODULE__{} = binding, command) when is_atom(command) do
    Map.has_key?(binding.commands, command)
  end

  @spec observes_fact?(t(), atom()) :: boolean()
  def observes_fact?(%__MODULE__{} = binding, endpoint) when is_atom(endpoint) do
    endpoint in fact_endpoints(binding)
  end

  @spec event_name(t()) :: atom() | nil
  def event_name(%__MODULE__{event_name: event_name}), do: event_name

  @spec observes_events?(t()) :: boolean()
  def observes_events?(%__MODULE__{} = binding),
    do: not is_nil(event_name(binding)) and is_atom(event_name(binding))

  @spec observes_anything?(t()) :: boolean()
  def observes_anything?(%__MODULE__{} = binding) do
    observes_events?(binding) or fact_endpoints(binding) != []
  end

  defp validate(
         %__MODULE__{
           slave: slave,
           outputs: outputs,
           facts: facts,
           commands: commands,
           event_name: event_name,
           meta: meta
         } = binding
       )
       when is_atom(slave) and is_map(outputs) and is_map(facts) and is_map(commands) and
              (is_nil(event_name) or is_atom(event_name)) and is_map(meta) do
    if valid_atom_mapping?(outputs) and valid_atom_mapping?(facts) do
      {:ok,
       %{binding | outputs: Map.new(outputs), facts: Map.new(facts), commands: Map.new(commands)}}
    else
      {:error, {:invalid_ethercat_binding, binding}}
    end
  end

  defp validate(binding), do: {:error, {:invalid_ethercat_binding, binding}}

  defp valid_atom_mapping?(mapping) when is_map(mapping) do
    Enum.all?(mapping, fn {left, right} -> is_atom(left) and is_atom(right) end)
  end

  defp validate_allowed_keys(binding) do
    case Map.keys(binding) -- @allowed_keys do
      [] -> :ok
      unknown -> {:error, {:invalid_ethercat_binding_keys, unknown}}
    end
  end

  defp fetch_required_atom(binding, key) do
    case Map.fetch(binding, key) do
      {:ok, value} when is_atom(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_ethercat_binding_value, key, value}}
      :error -> {:error, {:missing_ethercat_binding_key, key}}
    end
  end

  defp fetch_optional_atom(binding, key) do
    case Map.get(binding, key) do
      nil -> {:ok, nil}
      value when is_atom(value) -> {:ok, value}
      value -> {:error, {:invalid_ethercat_binding_value, key, value}}
    end
  end

  defp fetch_atom_map(binding, key, default) do
    value = Map.get(binding, key, default)

    cond do
      value == %{} or value == [] ->
        {:ok, %{}}

      is_list(value) and Keyword.keyword?(value) ->
        fetch_atom_map(%{key => Map.new(value)}, key, default)

      is_map(value) and valid_atom_mapping?(value) ->
        {:ok, Map.new(value)}

      true ->
        {:error, {:invalid_ethercat_binding_value, key, value}}
    end
  end

  defp fetch_commands(binding) do
    binding
    |> Map.get(:commands, %{})
    |> normalize_commands()
  end

  defp normalize_commands(commands) when commands == %{} or commands == [], do: {:ok, %{}}

  defp normalize_commands(commands) when is_list(commands) do
    if Keyword.keyword?(commands) do
      commands
      |> Map.new()
      |> normalize_commands()
    else
      {:error, {:invalid_ethercat_commands, commands}}
    end
  end

  defp normalize_commands(commands) when is_map(commands) do
    Enum.reduce_while(commands, {:ok, %{}}, fn
      {name, {:command, command, args}}, {:ok, acc} when is_atom(name) and is_atom(command) ->
        with {:ok, normalized_args} <- normalize_command_args(args) do
          {:cont, {:ok, Map.put(acc, name, {:command, command, normalized_args})}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {name, binding}, _acc ->
        {:halt, {:error, {:invalid_ethercat_command_mapping, name, binding}}}
    end)
  end

  defp normalize_commands(commands), do: {:error, {:invalid_ethercat_commands, commands}}

  defp normalize_command_args(args) when is_map(args), do: {:ok, args}

  defp normalize_command_args(args) when is_list(args) do
    if Keyword.keyword?(args) do
      {:ok, Map.new(args)}
    else
      {:error, {:invalid_ethercat_command_args, args}}
    end
  end

  defp normalize_command_args(args), do: {:error, {:invalid_ethercat_command_args, args}}

  defp fetch_meta(binding) do
    case Map.get(binding, :meta, %{}) do
      meta when is_map(meta) ->
        {:ok, meta}

      meta when is_list(meta) ->
        if Keyword.keyword?(meta) do
          {:ok, Map.new(meta)}
        else
          {:error, {:invalid_ethercat_binding_value, :meta, meta}}
        end

      value ->
        {:error, {:invalid_ethercat_binding_value, :meta, value}}
    end
  end
end
