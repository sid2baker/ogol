defmodule Ogol.HMI.RuntimeNotifier do
  @moduledoc false

  alias Ogol.HMI.Notification

  def emit(type, opts \\ []) when is_atom(type) and is_list(opts) do
    Notification.new(type, opts)
    |> Ogol.HMI.Projector.project()

    :ok
  end
end
