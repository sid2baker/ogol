defmodule Ogol.Hardware.EtherCAT.Ref do
  @moduledoc """
  Endpoint-first machine binding for one configured EtherCAT slave.

  EtherCAT drivers and slave aliases now define the public endpoint names.
  Ogol keeps only the machine-to-slave subset selection here:

  - `:slave` - configured EtherCAT slave name
  - `:outputs` - machine outputs this slave should handle directly via matching endpoint names
  - `:facts` - machine facts this slave should update from matching endpoint names
  - `:commands` - optional explicit command bindings using endpoint-aware EtherCAT commands
  - `:event_name` - optional machine event name for forwarded public slave events
  - `:meta` - default metadata merged into outgoing and incoming EtherCAT events
  """

  @type command_binding :: {:command, atom(), map()}
  @type input :: t() | map() | keyword()

  @type t :: %__MODULE__{
          slave: atom(),
          outputs: [atom()],
          facts: [atom()],
          commands: %{optional(atom()) => command_binding()},
          event_name: atom() | nil,
          meta: map()
        }

  @enforce_keys [:slave]
  defstruct slave: nil,
            outputs: [],
            facts: [],
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
  def normalize(%__MODULE__{} = ref), do: validate(ref)

  def normalize(ref) when is_list(ref) do
    if Keyword.keyword?(ref) do
      ref
      |> Map.new()
      |> normalize()
    else
      {:error, {:invalid_ethercat_ref, ref}}
    end
  end

  def normalize(%{} = ref) do
    with :ok <- validate_allowed_keys(ref),
         {:ok, slave} <- fetch_required_atom(ref, :slave),
         {:ok, outputs} <- fetch_atom_list(ref, :outputs, []),
         {:ok, facts} <- fetch_atom_list(ref, :facts, []),
         {:ok, commands} <- fetch_commands(ref),
         {:ok, event_name} <- fetch_optional_atom(ref, :event_name),
         {:ok, meta} <- fetch_meta(ref) do
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

  def normalize(ref), do: {:error, {:invalid_ethercat_ref, ref}}

  @spec fact_endpoints(t()) :: [atom()]
  def fact_endpoints(%__MODULE__{} = ref) do
    ref.facts
    |> List.wrap()
    |> Enum.uniq()
  end

  @spec handles_output?(t(), atom()) :: boolean()
  def handles_output?(%__MODULE__{} = ref, output) when is_atom(output) do
    output in List.wrap(ref.outputs)
  end

  @spec handles_command?(t(), atom()) :: boolean()
  def handles_command?(%__MODULE__{} = ref, command) when is_atom(command) do
    Map.has_key?(ref.commands, command)
  end

  @spec observes_fact?(t(), atom()) :: boolean()
  def observes_fact?(%__MODULE__{} = ref, fact) when is_atom(fact) do
    fact in fact_endpoints(ref)
  end

  @spec event_name(t()) :: atom() | nil
  def event_name(%__MODULE__{event_name: event_name}), do: event_name

  @spec observes_events?(t()) :: boolean()
  def observes_events?(%__MODULE__{} = ref),
    do: not is_nil(event_name(ref)) and is_atom(event_name(ref))

  @spec observes_anything?(t()) :: boolean()
  def observes_anything?(%__MODULE__{} = ref) do
    observes_events?(ref) or fact_endpoints(ref) != []
  end

  defp validate(
         %__MODULE__{
           slave: slave,
           outputs: outputs,
           facts: facts,
           commands: commands,
           event_name: event_name,
           meta: meta
         } = ref
       )
       when is_atom(slave) and is_list(outputs) and is_list(facts) and is_map(commands) and
              (is_nil(event_name) or is_atom(event_name)) and is_map(meta) do
    if Enum.all?(outputs, &is_atom/1) and Enum.all?(facts, &is_atom/1) do
      {:ok,
       %{
         ref
         | outputs: Enum.uniq(outputs),
           facts: Enum.uniq(facts),
           commands: Map.new(commands)
       }}
    else
      {:error, {:invalid_ethercat_ref, ref}}
    end
  end

  defp validate(ref), do: {:error, {:invalid_ethercat_ref, ref}}

  defp validate_allowed_keys(ref) do
    case Map.keys(ref) -- @allowed_keys do
      [] -> :ok
      unknown -> {:error, {:invalid_ethercat_ref_keys, unknown}}
    end
  end

  defp fetch_required_atom(ref, key) do
    case Map.fetch(ref, key) do
      {:ok, value} when is_atom(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_ethercat_ref_value, key, value}}
      :error -> {:error, {:missing_ethercat_ref_key, key}}
    end
  end

  defp fetch_optional_atom(ref, key) do
    case Map.get(ref, key) do
      nil -> {:ok, nil}
      value when is_atom(value) -> {:ok, value}
      value -> {:error, {:invalid_ethercat_ref_value, key, value}}
    end
  end

  defp fetch_atom_list(ref, key, default) do
    value = Map.get(ref, key, default)

    if is_list(value) and Enum.all?(value, &is_atom/1) do
      {:ok, value}
    else
      {:error, {:invalid_ethercat_ref_value, key, value}}
    end
  end

  defp fetch_commands(ref) do
    ref
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

  defp fetch_meta(ref) do
    case Map.get(ref, :meta, %{}) do
      meta when is_map(meta) ->
        {:ok, meta}

      meta when is_list(meta) ->
        if Keyword.keyword?(meta) do
          {:ok, Map.new(meta)}
        else
          {:error, {:invalid_ethercat_ref_value, :meta, meta}}
        end

      value ->
        {:error, {:invalid_ethercat_ref_value, :meta, value}}
    end
  end
end
