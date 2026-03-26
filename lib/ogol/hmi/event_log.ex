defmodule Ogol.HMI.EventLog do
  @moduledoc false

  use GenServer

  @default_max_events 500

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def append(notification) do
    GenServer.cast(__MODULE__, {:append, notification})
  end

  def recent(limit \\ 100) do
    GenServer.call(__MODULE__, {:recent, limit})
  end

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(opts) do
    {:ok, %{events: [], max_events: Keyword.get(opts, :max_events, @default_max_events)}}
  end

  @impl true
  def handle_cast({:append, notification}, state) do
    events =
      [notification | state.events]
      |> Enum.take(state.max_events)

    {:noreply, %{state | events: events}}
  end

  @impl true
  def handle_call({:recent, limit}, _from, state) do
    {:reply, state.events |> Enum.take(limit) |> Enum.reverse(), state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | events: []}}
  end
end
