defmodule Ogol.HMI.DeviceProfiles do
  @moduledoc false

  alias Ogol.HMI.DeviceProfile

  @profiles [
    %DeviceProfile{
      id: :panel_1024x768,
      width: 1024,
      height: 768,
      touch: true,
      orientation: :landscape,
      density_class: :compact,
      panel_class: :operator_panel,
      interaction_mode: :touch,
      kiosk: true,
      distance_class: :near
    },
    %DeviceProfile{
      id: :panel_1280x800,
      width: 1280,
      height: 800,
      touch: true,
      orientation: :landscape,
      density_class: :normal,
      panel_class: :operator_panel,
      interaction_mode: :touch,
      kiosk: true,
      distance_class: :near
    },
    %DeviceProfile{
      id: :panel_1920x1080,
      width: 1920,
      height: 1080,
      touch: true,
      orientation: :landscape,
      density_class: :comfortable,
      panel_class: :operator_panel,
      interaction_mode: :touch,
      kiosk: true,
      distance_class: :near
    }
  ]

  @profiles_by_id Map.new(@profiles, &{&1.id, &1})

  def list, do: @profiles
  def ids, do: Map.keys(@profiles_by_id)
  def fetch(id), do: Map.get(@profiles_by_id, id)
end
