defmodule OgolTest do
  use ExUnit.Case, async: true

  test "public request and event helpers use gen_statem delivery shapes" do
    parent = self()

    pid =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:request, :start, %{id: 1}, %{source: :test}}} ->
            send(parent, {:request_received, from})
        end

        receive do
          {:"$gen_cast", {:event, :sensor_changed, %{value: 42}, %{source: :adapter}}} ->
            send(parent, :event_received)
        end
      end)

    spawn(fn ->
      _ = Ogol.request(pid, :start, %{id: 1}, %{source: :test}, 1_000)
    end)

    assert_receive {:request_received, from}
    GenServer.reply(from, :ok)

    :ok = Ogol.event(pid, :sensor_changed, %{value: 42}, %{source: :adapter})
    assert_receive :event_received
  end
end
