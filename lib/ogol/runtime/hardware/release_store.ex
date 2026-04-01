defmodule Ogol.Runtime.Hardware.ReleaseDiff do
  @moduledoc false

  alias Ogol.Runtime.Hardware.Diff, as: HardwareDiff

  @type t :: %{
          status: :initial | :aligned | :different | :unavailable,
          bump: :patch | :minor | :major | nil,
          summary: String.t(),
          hardware: HardwareDiff.t(),
          candidate_only_machines: [String.t()],
          armed_only_machines: [String.t()],
          machine_mismatches: [String.t()],
          candidate_only_topologies: [String.t()],
          armed_only_topologies: [String.t()],
          topology_mismatches: [String.t()],
          candidate_only_panels: [String.t()],
          armed_only_panels: [String.t()],
          panel_mismatches: [String.t()]
        }

  @spec compare(map() | nil, map() | nil) :: t()
  def compare(nil, _armed) do
    %{
      status: :unavailable,
      bump: nil,
      summary: "No candidate release is available.",
      hardware: HardwareDiff.compare_draft_to_live(%{}, nil),
      candidate_only_machines: [],
      armed_only_machines: [],
      machine_mismatches: [],
      candidate_only_topologies: [],
      armed_only_topologies: [],
      topology_mismatches: [],
      candidate_only_panels: [],
      armed_only_panels: [],
      panel_mismatches: []
    }
  end

  def compare(%{config: config, deployment_snapshot: deployment_snapshot}, nil) do
    %{
      status: :initial,
      bump: :minor,
      summary:
        "No armed release exists. Arming this candidate will create the initial runtime deployment baseline.",
      hardware: HardwareDiff.compare_draft_to_live(config.meta[:form] || %{}, nil),
      candidate_only_machines: snapshot_ids(deployment_snapshot.machines, :machine_id),
      armed_only_machines: [],
      machine_mismatches: [],
      candidate_only_topologies: snapshot_ids(deployment_snapshot.topologies, :topology_id),
      armed_only_topologies: [],
      topology_mismatches: [],
      candidate_only_panels: snapshot_ids(deployment_snapshot.panels, :panel_id),
      armed_only_panels: [],
      panel_mismatches: []
    }
  end

  def compare(%{config: candidate_config, deployment_snapshot: candidate_snapshot}, %{
        config: armed_config,
        deployment_snapshot: armed_snapshot
      }) do
    hardware =
      HardwareDiff.compare_draft_to_live(
        candidate_config.meta[:form] || %{},
        armed_config
      )

    machine_diff =
      compare_items(
        candidate_snapshot.machines,
        armed_snapshot.machines,
        & &1.machine_id,
        fn candidate, armed ->
          changed =
            changed_fields(candidate, armed, [:module], fn _field, value ->
              value || "unknown"
            end)

          if changed == [], do: nil, else: "#{candidate.machine_id}: #{Enum.join(changed, ", ")}"
        end
      )

    topology_diff =
      compare_items(
        candidate_snapshot.topologies,
        armed_snapshot.topologies,
        & &1.topology_id,
        fn _candidate, _armed -> nil end
      )

    panel_diff =
      compare_items(
        candidate_snapshot.panels,
        armed_snapshot.panels,
        & &1.panel_id,
        fn candidate, armed ->
          changed =
            changed_fields(
              candidate,
              armed,
              [:surface_id, :surface_version, :default_screen, :viewport_profile],
              fn _field, value -> value || "none" end
            )

          if changed == [], do: nil, else: "#{candidate.panel_id}: #{Enum.join(changed, ", ")}"
        end
      )

    deployment_change_count =
      diff_count(machine_diff) + diff_count(topology_diff) + diff_count(panel_diff)

    hardware_change_count =
      length(hardware.domain_mismatches) +
        length(hardware.slave_mismatches) +
        length(hardware.draft_only_domains) +
        length(hardware.live_only_domains) +
        length(hardware.draft_only_slaves) +
        length(hardware.live_only_slaves)

    bump = classify_bump(hardware, machine_diff, topology_diff, panel_diff)

    %{
      status:
        if(hardware_change_count == 0 and deployment_change_count == 0,
          do: :aligned,
          else: :different
        ),
      bump: bump,
      summary: diff_summary(hardware_change_count, deployment_change_count, bump),
      hardware: hardware,
      candidate_only_machines: machine_diff.candidate_only,
      armed_only_machines: machine_diff.armed_only,
      machine_mismatches: machine_diff.mismatches,
      candidate_only_topologies: topology_diff.candidate_only,
      armed_only_topologies: topology_diff.armed_only,
      topology_mismatches: topology_diff.mismatches,
      candidate_only_panels: panel_diff.candidate_only,
      armed_only_panels: panel_diff.armed_only,
      panel_mismatches: panel_diff.mismatches
    }
  end

  defp compare_items(candidate_items, armed_items, key_fun, mismatch_fun) do
    candidate_map = Map.new(candidate_items, &{key_fun.(&1), &1})
    armed_map = Map.new(armed_items, &{key_fun.(&1), &1})
    candidate_keys = candidate_map |> Map.keys() |> Enum.sort()
    armed_keys = armed_map |> Map.keys() |> Enum.sort()

    mismatches =
      candidate_keys
      |> Enum.filter(&Map.has_key?(armed_map, &1))
      |> Enum.reduce([], fn key, acc ->
        candidate = Map.fetch!(candidate_map, key)
        armed = Map.fetch!(armed_map, key)

        case mismatch_fun.(candidate, armed) do
          nil -> acc
          mismatch -> [mismatch | acc]
        end
      end)
      |> Enum.reverse()

    %{
      candidate_only: candidate_keys -- armed_keys,
      armed_only: armed_keys -- candidate_keys,
      mismatches: mismatches
    }
  end

  defp changed_fields(candidate, armed, fields, formatter) do
    Enum.reduce(fields, [], fn field, acc ->
      candidate_value = Map.get(candidate, field)
      armed_value = Map.get(armed, field)

      if candidate_value == armed_value do
        acc
      else
        formatted_candidate = formatter.(field, candidate_value)
        formatted_armed = formatter.(field, armed_value)
        ["#{field}: candidate=#{formatted_candidate} armed=#{formatted_armed}" | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp classify_bump(hardware, machine_diff, topology_diff, panel_diff) do
    cond do
      structural_add_remove?(machine_diff) or
        structural_add_remove?(topology_diff) or
          structural_add_remove?(panel_diff) ->
        :major

      machine_diff.mismatches != [] or topology_diff.mismatches != [] ->
        :major

      Enum.any?(panel_diff.mismatches, fn mismatch ->
        String.contains?(mismatch, "surface_id:") or
          String.contains?(mismatch, "default_screen:") or
            String.contains?(mismatch, "viewport_profile:")
      end) ->
        :major

      hardware.status == :aligned and panel_diff.mismatches == [] ->
        :patch

      hardware.draft_only_domains != [] or
        hardware.live_only_domains != [] or
        hardware.draft_only_slaves != [] or
          hardware.live_only_slaves != [] ->
        :major

      Enum.any?(hardware.slave_mismatches, &String.contains?(&1, "driver:")) ->
        :major

      true ->
        :minor
    end
  end

  defp structural_add_remove?(diff) do
    diff.candidate_only != [] or diff.armed_only != []
  end

  defp diff_count(diff) do
    length(diff.candidate_only) + length(diff.armed_only) + length(diff.mismatches)
  end

  defp diff_summary(0, 0, :patch) do
    "Candidate matches the armed runtime deployment."
  end

  defp diff_summary(hardware_change_count, deployment_change_count, bump) do
    "Candidate differs from armed runtime deployment: #{hardware_change_count} hardware change(s), #{deployment_change_count} runtime deployment change(s), classified as #{bump}."
  end

  defp snapshot_ids(items, field) do
    Enum.map(items, &Map.get(&1, field))
  end
end

defmodule Ogol.Runtime.Hardware.ReleaseStore do
  @moduledoc false

  use GenServer

  alias Ogol.Hardware.Config, as: HardwareConfig
  alias Ogol.HMI.Surface.Deployments, as: SurfaceDeployment
  alias Ogol.Runtime.SnapshotStore
  alias Ogol.Runtime.Hardware.ReleaseDiff, as: HardwareReleaseDiff

  @table :ogol_hmi_hardware_releases
  @candidate_key :candidate
  @armed_key :armed_release
  @history_key :release_history

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reset do
    :ets.delete_all_objects(@table)
    seed_defaults()
    :ok
  end

  def current_candidate do
    fetch(@candidate_key)
  end

  def current_armed_release do
    fetch(@armed_key)
  end

  def release_history do
    fetch(@history_key) || []
  end

  def fetch_release(version) when is_binary(version) do
    release_history()
    |> Enum.find(&(&1.version == version))
  end

  def candidate_vs_armed_diff do
    HardwareReleaseDiff.compare(current_candidate(), current_armed_release())
  end

  def promote_candidate(%HardwareConfig{} = config) do
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
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  defp put(key, value) do
    :ets.insert(@table, {key, value})
    :ok
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
      topology_id: to_string(snapshot.topology_id)
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
