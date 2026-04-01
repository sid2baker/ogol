defmodule Ogol.Runtime.Notifier do
  @moduledoc false

  alias Ogol.Runtime.Notification

  def emit(type, opts \\ []) when is_atom(type) and is_list(opts) do
    Notification.new(type, opts)
    |> Ogol.Runtime.Projector.project()

    :ok
  end
end
