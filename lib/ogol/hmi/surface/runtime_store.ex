defmodule Ogol.HMI.Surface.RuntimeStore do
  @moduledoc false

  use GenServer

  alias Ogol.HMI.Surface

  @table :ogol_hmi_surface_runtimes

  defmodule Entry do
    @moduledoc false

    @type published_version :: %{definition: Surface.t(), runtime: Surface.Runtime.t()}

    @type t :: %__MODULE__{
            surface_id: String.t() | atom(),
            source_module: module() | nil,
            published_versions: %{optional(String.t()) => published_version()},
            compiled_definition: Surface.t() | nil,
            compiled_runtime: Surface.Runtime.t() | nil,
            compiled_version: String.t() | nil,
            compiled_source_digest: String.t() | nil,
            compiled_at: DateTime.t() | nil,
            deployed_definition: Surface.t() | nil,
            deployed_runtime: Surface.Runtime.t() | nil,
            deployed_version: String.t() | nil,
            deployed_source_digest: String.t() | nil,
            deployed_at: DateTime.t() | nil
          }

    defstruct [
      :surface_id,
      :source_module,
      :compiled_definition,
      :compiled_runtime,
      :compiled_version,
      :compiled_source_digest,
      :compiled_at,
      :deployed_definition,
      :deployed_runtime,
      :deployed_version,
      :deployed_source_digest,
      :deployed_at,
      published_versions: %{}
    ]
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  def list_entries do
    @table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(&to_string(&1.surface_id))
  end

  def fetch(surface_id) when is_atom(surface_id) or is_binary(surface_id) do
    @table
    |> :ets.tab2list()
    |> Enum.find_value(fn {stored_id, %Entry{} = entry} ->
      if to_string(stored_id) == to_string(surface_id), do: entry
    end)
  end

  def fetch_or_default(surface_id, opts \\ [])
      when is_atom(surface_id) or is_binary(surface_id) do
    fetch(surface_id) ||
      %Entry{
        surface_id: normalize_surface_id(surface_id),
        source_module: Keyword.get(opts, :source_module)
      }
  end

  def published_versions(%Entry{} = entry) do
    entry.published_versions
    |> Map.keys()
    |> Enum.sort_by(&version_sort_key/1, :desc)
  end

  def compile(surface_id, %Surface{} = definition, %Surface.Runtime{} = runtime, opts \\ []) do
    now = DateTime.utc_now()
    source_module = Keyword.get(opts, :source_module)
    source_digest = Keyword.get(opts, :source_digest)

    update(surface_id, fn entry ->
      version = next_version(entry.compiled_version)

      %{
        entry
        | source_module: source_module || entry.source_module,
          compiled_definition: definition,
          compiled_runtime: %{runtime | module: nil},
          compiled_version: version,
          compiled_source_digest: source_digest,
          compiled_at: now
      }
    end)
  end

  def deploy(surface_id) do
    now = DateTime.utc_now()

    update(surface_id, fn entry ->
      if entry.compiled_runtime do
        published_versions =
          Map.put(entry.published_versions || %{}, entry.compiled_version, %{
            definition: entry.compiled_definition,
            runtime: entry.compiled_runtime
          })

        %{
          entry
          | published_versions: published_versions,
            deployed_definition: entry.compiled_definition,
            deployed_runtime: entry.compiled_runtime,
            deployed_version: entry.compiled_version,
            deployed_source_digest: entry.compiled_source_digest,
            deployed_at: now
        }
      else
        entry
      end
    end)
  end

  def fetch_deployed(surface_id, version \\ nil)

  def fetch_deployed(surface_id, version) do
    case fetch(surface_id) do
      %Entry{} = entry ->
        version = version || entry.deployed_version

        case Map.get(entry.published_versions || %{}, version) do
          %{definition: %Surface{} = definition, runtime: %Surface.Runtime{} = runtime} ->
            {:ok,
             %{
               definition: definition,
               runtime: runtime,
               version: version,
               module: entry.source_module
             }}

          nil ->
            fallback_deployed(entry, version)
        end

      _ ->
        :error
    end
  end

  defp fallback_deployed(
         %Entry{
           deployed_definition: %Surface{} = definition,
           deployed_runtime: %Surface.Runtime{} = runtime,
           deployed_version: deployed_version,
           source_module: source_module
         },
         version
       )
       when is_nil(version) or version == deployed_version do
    {:ok,
     %{
       definition: definition,
       runtime: runtime,
       version: deployed_version,
       module: source_module
     }}
  end

  defp fallback_deployed(_entry, _version), do: :error

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  defp update(surface_id, fun) do
    entry = fetch_or_default(surface_id)
    updated = fun.(entry)
    :ets.insert(@table, {updated.surface_id, updated})
    updated
  end

  defp next_version(nil), do: "r1"
  defp next_version("current"), do: "r1"

  defp next_version("r" <> rest) do
    case Integer.parse(rest) do
      {value, ""} -> "r#{value + 1}"
      _ -> "r1"
    end
  end

  defp next_version(_other), do: "r1"

  defp version_sort_key("current"), do: {0, 0}
  defp version_sort_key(nil), do: {0, 0}

  defp version_sort_key("r" <> rest) do
    case Integer.parse(rest) do
      {value, ""} -> {1, value}
      _ -> {0, 0}
    end
  end

  defp version_sort_key(_other), do: {0, 0}

  defp normalize_surface_id(surface_id) when is_binary(surface_id), do: surface_id
  defp normalize_surface_id(surface_id) when is_atom(surface_id), do: surface_id
end
