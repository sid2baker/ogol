defmodule OgolTest do
  use ExUnit.Case, async: true

  test "internal delivery helpers use gen_statem delivery shapes" do
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
      _ = Ogol.Runtime.Delivery.request(pid, :start, %{id: 1}, %{source: :test}, 1_000)
    end)

    assert_receive {:request_received, from}, 1_000
    GenServer.reply(from, :ok)

    :ok = Ogol.Runtime.Delivery.event(pid, :sensor_changed, %{value: 42}, %{source: :adapter})
    assert_receive :event_received, 1_000
  end

  test "public interface exposes skills and invoke without exposing raw delivery as the main story" do
    alias Ogol.TestSupport.SimpleHmiDemo
    alias Ogol.TestSupport.SimpleHmiDemo.LineMachine

    {:ok, pid} = SimpleHmiDemo.boot!()

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)

    skills = LineMachine.skills()

    assert Enum.map(skills, & &1.name) == [:part_seen, :start, :stop]
    assert {:ok, :ok} = Ogol.Runtime.Delivery.invoke(pid, :start)
    assert {:ok, :accepted} = Ogol.Runtime.Delivery.invoke(pid, :part_seen)

    assert %Ogol.Machine.Status{
             machine_id: :simple_hmi_line,
             outputs: %{running?: true},
             fields: %{part_count: 1}
           } = LineMachine.status(pid)
  end
end
