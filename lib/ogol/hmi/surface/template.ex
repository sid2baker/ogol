defmodule Ogol.HMI.Surface.Template do
  @moduledoc false

  alias Ogol.HMI.Surface
  alias Ogol.HMI.Surface.Templates.{Overview, Station}

  def build_context(runtime, opts \\ [])

  def build_context(nil, _opts), do: %{}

  def build_context(%Surface.Runtime{template: :overview}, opts) do
    Overview.build_context(opts)
  end

  def build_context(%Surface.Runtime{template: :station} = runtime, opts) do
    Station.build_context(runtime, opts)
  end

  def build_context(%Surface.Runtime{}, _opts), do: %{}

  def resolve_skill(%Surface.Runtime{template: :overview}, context, machine_id, name) do
    Overview.resolve_skill(context, machine_id, name)
  end

  def resolve_skill(%Surface.Runtime{template: :station}, context, machine_id, name) do
    Station.resolve_skill(context, machine_id, name)
  end

  def resolve_skill(%Surface.Runtime{}, _context, _machine_id, _name), do: {:error, :unsupported}
  def resolve_skill(nil, _context, _machine_id, _name), do: {:error, :unavailable}
end
