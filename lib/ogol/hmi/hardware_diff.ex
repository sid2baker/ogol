defmodule Ogol.HMI.HardwareDiff do
  @moduledoc false

  alias Ogol.HMI.{HardwareConfig, HardwareGateway}

  @type t :: %{
          status: :aligned | :different | :unavailable,
          summary: binary(),
          draft_only_domains: [binary()],
          live_only_domains: [binary()],
          domain_mismatches: [binary()],
          draft_only_slaves: [binary()],
          live_only_slaves: [binary()],
          slave_mismatches: [binary()]
        }

  @spec compare_draft_to_live(map(), HardwareConfig.t() | nil) :: t()
  def compare_draft_to_live(_draft_form, nil) do
    %{
      status: :unavailable,
      summary: "No live hardware preview is available.",
      draft_only_domains: [],
      live_only_domains: [],
      domain_mismatches: [],
      draft_only_slaves: [],
      live_only_slaves: [],
      slave_mismatches: []
    }
  end

  def compare_draft_to_live(draft_form, %HardwareConfig{} = live_config) do
    draft = normalize_draft_form(draft_form)
    live = normalize_form(live_config.meta[:form] || %{})

    domain_diff =
      compare_rows(
        draft["domains"],
        live["domains"],
        "id",
        ~w(cycle_time_us miss_threshold recovery_threshold)
      )

    slave_diff =
      compare_rows(
        draft["slaves"],
        live["slaves"],
        "name",
        ~w(driver target_state process_data_mode process_data_domain health_poll_ms)
      )

    differences = domain_diff.mismatches ++ slave_diff.mismatches

    extras =
      domain_diff.draft_only ++
        domain_diff.live_only ++ slave_diff.draft_only ++ slave_diff.live_only

    %{
      status: if(differences == [] and extras == [], do: :aligned, else: :different),
      summary: diff_summary(differences, extras),
      draft_only_domains: domain_diff.draft_only,
      live_only_domains: domain_diff.live_only,
      domain_mismatches: domain_diff.mismatches,
      draft_only_slaves: slave_diff.draft_only,
      live_only_slaves: slave_diff.live_only,
      slave_mismatches: slave_diff.mismatches
    }
  end

  defp normalize_form(form) when is_map(form) do
    stringified =
      Enum.reduce(form, %{}, fn {key, value}, acc ->
        Map.put(acc, to_string(key), value)
      end)

    %{
      "domains" =>
        stringified
        |> Map.get("domains", [])
        |> normalize_rows(),
      "slaves" =>
        stringified
        |> Map.get("slaves", [])
        |> normalize_rows()
    }
  end

  defp normalize_form(_other), do: %{"domains" => [], "slaves" => []}

  defp normalize_draft_form(form) do
    case HardwareGateway.preview_ethercat_simulation_config(form) do
      {:ok, %HardwareConfig{} = config} ->
        normalize_form(config.meta[:form] || %{})

      {:error, _reason} ->
        normalize_form(form)
    end
  end

  defp normalize_rows(rows) when is_list(rows) do
    Enum.map(rows, fn row ->
      Enum.reduce(row, %{}, fn {key, value}, acc ->
        Map.put(acc, to_string(key), to_string(value || ""))
      end)
    end)
  end

  defp normalize_rows(_rows), do: []

  defp compare_rows(draft_rows, live_rows, key_field, compare_fields) do
    draft_by_key = Map.new(draft_rows, &{Map.get(&1, key_field, ""), &1})
    live_by_key = Map.new(live_rows, &{Map.get(&1, key_field, ""), &1})
    draft_keys = Map.keys(draft_by_key) |> Enum.reject(&(&1 == "")) |> Enum.sort()
    live_keys = Map.keys(live_by_key) |> Enum.reject(&(&1 == "")) |> Enum.sort()

    mismatches =
      draft_keys
      |> Enum.filter(&Map.has_key?(live_by_key, &1))
      |> Enum.flat_map(fn key ->
        draft = Map.fetch!(draft_by_key, key)
        live = Map.fetch!(live_by_key, key)

        field_diffs =
          compare_fields
          |> Enum.flat_map(fn field ->
            draft_value = Map.get(draft, field, "")
            live_value = Map.get(live, field, "")

            if draft_value == live_value do
              []
            else
              ["#{field}: draft=#{draft_value} live=#{live_value}"]
            end
          end)

        if field_diffs == [], do: [], else: ["#{key}: " <> Enum.join(field_diffs, ", ")]
      end)

    %{
      draft_only: draft_keys -- live_keys,
      live_only: live_keys -- draft_keys,
      mismatches: mismatches
    }
  end

  defp diff_summary([], []), do: "Draft matches the live hardware preview."

  defp diff_summary(differences, extras) do
    "Draft differs from live hardware: #{length(differences)} field mismatch(es), #{length(extras)} added/removed item(s)."
  end
end
