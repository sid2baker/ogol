defmodule Ogol.HMI.HardwareReleaseStore do
  @moduledoc false

  use GenServer

  alias Ogol.HardwareConfig
  alias Ogol.HMI.{HardwareReleaseDiff, SnapshotStore, SurfaceDeployment}

  @table :ogol_hmi_hardware_releases
  @candidate_key :candidate
  @armed_key :armed_release
  @history_key :release_history

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reset do
    ensure_started()

    if table_ready?() do
      :ets.delete_all_objects(@table)
    end

    seed_defaults()
    :ok
  end

  def current_candidate do
    ensure_started()
    fetch(@candidate_key)
  end

  def current_armed_release do
    ensure_started()
    fetch(@armed_key)
  end

  def release_history do
    ensure_started()
    fetch(@history_key) || []
  end

  def fetch_release(version) when is_binary(version) do
    ensure_started()

    release_history()
    |> Enum.find(&(&1.version == version))
  end

  def candidate_vs_armed_diff do
    HardwareReleaseDiff.compare(current_candidate(), current_armed_release())
  end

  def promote_candidate(%HardwareConfig{} = config) do
    ensure_started()

    candidate = %{
      build_id: next_build_id(current_candidate()),
      promoted_at: System.system_time(:millisecond),
      config: config,
      deployment_snapshot: build_release_snapshot(config)
    }

    put(@candidate_key, candidate)
    candidate
  end

  def arm_candidate do
    ensure_started()

    case current_candidate() do
      nil ->
        {:error, :missing_candidate}

      candidate ->
        armed = current_armed_release()
        diff = HardwareReleaseDiff.compare(candidate, armed)
        bump = diff.bump || :minor
        version = next_semver(armed && armed.version, bump)

        release = %{
          version: version,
          bump: bump,
          released_at: System.system_time(:millisecond),
          candidate_build_id: candidate.build_id,
          config: candidate.config,
          deployment_snapshot: candidate.deployment_snapshot,
          diff: diff
        }

        put(@armed_key, release)
        put(@history_key, [release | release_history()])
        {:ok, release}
    end
  end

  def rollback_to_release(version) when is_binary(version) do
    ensure_started()

    case fetch_release(version) do
      nil ->
        {:error, :unknown_release}

      release ->
        put(@armed_key, release)
        {:ok, release}
    end
  end

  defp next_build_id(nil), do: "c1"

  defp next_build_id(%{build_id: "c" <> rest}) do
    case Integer.parse(rest) do
      {value, ""} -> "c#{value + 1}"
      _ -> "c1"
    end
  end

  defp next_build_id(_other), do: "c1"

  defp next_semver(nil, _bump), do: "0.1.0"

  defp next_semver(version, bump) when is_binary(version) do
    {major, minor, patch} = parse_semver(version)

    case bump do
      :major -> "#{major + 1}.0.0"
      :minor -> "#{major}.#{minor + 1}.0"
      :patch -> "#{major}.#{minor}.#{patch + 1}"
    end
  end

  defp parse_semver(version) do
    case String.split(version, ".", parts: 3) do
      [major, minor, patch] ->
        {parse_int(major), parse_int(minor), parse_int(patch)}

      _other ->
        {0, 1, 0}
    end
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> 0
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    seed_defaults()
    {:ok, %{}}
  end

  defp seed_defaults do
    :ets.insert(@table, [{@candidate_key, nil}, {@armed_key, nil}, {@history_key, []}])
  end

  defp fetch(key) do
    if table_ready?() do
      case :ets.lookup(@table, key) do
        [{^key, value}] -> value
        [] -> nil
      end
    else
      nil
    end
  end

  defp put(key, value) do
    ensure_started()
    :ets.insert(@table, {key, value})
    :ok
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to start #{inspect(__MODULE__)}: #{inspect(reason)}"
        end

      _pid ->
        :ok
    end
  end

  defp table_ready? do
    :ets.whereis(@table) != :undefined
  end

  defp build_release_snapshot(%HardwareConfig{} = config) do
    %{
      captured_at: System.system_time(:millisecond),
      config_id: config.id,
      machines:
        SnapshotStore.list_machines()
        |> Enum.map(&normalize_machine/1),
      topologies:
        SnapshotStore.list_topologies()
        |> Enum.map(&normalize_topology/1),
      panels:
        SurfaceDeployment.list()
        |> Enum.map(&normalize_panel/1)
    }
  end

  defp normalize_machine(snapshot) do
    %{
      machine_id: to_string(snapshot.machine_id),
      module:
        case snapshot.module do
          nil -> nil
          module -> inspect(module)
        end
    }
  end

  defp normalize_topology(snapshot) do
    %{
      topology_id: to_string(snapshot.topology_id),
      root_machine_id:
        case snapshot.root_machine_id do
          nil -> nil
          machine_id -> to_string(machine_id)
        end
    }
  end

  defp normalize_panel(panel) do
    %{
      panel_id: to_string(panel.panel_id),
      surface_id: to_string(panel.surface_id),
      surface_version: panel.surface_version,
      default_screen:
        case panel.default_screen do
          nil -> nil
          screen -> to_string(screen)
        end,
      viewport_profile:
        case panel.viewport_profile do
          nil -> nil
          profile -> to_string(profile)
        end
    }
  end
end
