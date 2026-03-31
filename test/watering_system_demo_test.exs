defmodule Ogol.Examples.WateringSystemDemoTest do
  use ExUnit.Case, async: false

  alias Ogol.Examples.WateringSystemDemo
  alias Ogol.Status

  setup do
    _ = WateringSystemDemo.stop()

    on_exit(fn ->
      _ = WateringSystemDemo.stop()
    end)

    :ok
  end

  test "rotates automatic watering, enforces manual limits, and resumes the schedule" do
    demo = WateringSystemDemo.boot!(signal_sink: self())

    on_exit(fn ->
      WateringSystemDemo.stop(demo)
    end)

    assert_eventually(fn ->
      WateringSystemDemo.snapshot() == %{
        valve_1: false,
        valve_2: false,
        valve_3: false,
        valve_4: false
      }
    end)

    assert {:ok, :ok} = WateringSystemDemo.configure_schedule(demo, 80, 25)
    assert {:ok, :ok} = WateringSystemDemo.enable_schedule(demo)
    assert_receive {:ogol_signal, :watering_controller, :schedule_enabled, %{}, %{}}, 500

    assert_eventually(fn ->
      match?(
        %Status{current_state: :auto_waiting, fields: %{schedule_interval_ms: 80}},
        Ogol.Examples.WateringSystemDemo.Controller.status(demo.machine)
      )
    end)

    assert_receive {:ogol_signal, :watering_controller, :watering_started, %{zones: [1]}, %{}},
                   500

    assert_eventually(fn ->
      WateringSystemDemo.snapshot() == %{
        valve_1: true,
        valve_2: false,
        valve_3: false,
        valve_4: false
      }
    end)

    assert_at_most_two_open(WateringSystemDemo.snapshot())

    assert_receive {:ogol_signal, :watering_controller, :watering_completed,
                    %{zones: [1], next_group_index: 1}, %{}},
                   500

    assert {:ok, :ok} = WateringSystemDemo.disable_schedule(demo)
    assert_receive {:ogol_signal, :watering_controller, :schedule_disabled, %{}, %{}}, 500

    assert_eventually(fn ->
      match?(
        %Status{
          machine_id: :watering_controller,
          current_state: :disabled,
          outputs: %{
            valve_1_open?: false,
            valve_2_open?: false,
            valve_3_open?: false,
            valve_4_open?: false
          },
          fields: %{
            active_zones: [],
            next_group_index: 1,
            schedule_interval_ms: 80,
            watering_duration_ms: 25
          }
        },
        Ogol.Examples.WateringSystemDemo.Controller.status(demo.machine)
      )
    end)

    assert_eventually(fn ->
      WateringSystemDemo.snapshot() == %{
        valve_1: false,
        valve_2: false,
        valve_3: false,
        valve_4: false
      }
    end)

    assert {:ok, :ok} = WateringSystemDemo.set_manual_zones(demo, [3, 4])

    assert_receive {:ogol_signal, :watering_controller, :manual_override_enabled,
                    %{zones: [3, 4]}, %{}},
                   500

    assert_eventually(fn ->
      match?(
        %Status{
          current_state: :manual,
          fields: %{active_zones: [3, 4], next_group_index: 1},
          outputs: %{
            valve_1_open?: false,
            valve_2_open?: false,
            valve_3_open?: true,
            valve_4_open?: true
          }
        },
        Ogol.Examples.WateringSystemDemo.Controller.status(demo.machine)
      )
    end)

    assert_eventually(fn ->
      WateringSystemDemo.snapshot() == %{
        valve_1: false,
        valve_2: false,
        valve_3: true,
        valve_4: true
      }
    end)

    assert_at_most_two_open(WateringSystemDemo.snapshot())

    assert {:ok, {:error, :too_many_manual_zones}} =
             WateringSystemDemo.set_manual_zones(demo, [1, 2, 3])

    assert WateringSystemDemo.snapshot() == %{
             valve_1: false,
             valve_2: false,
             valve_3: true,
             valve_4: true
           }

    assert {:ok, :ok} = WateringSystemDemo.enable_schedule(demo)
    assert_receive {:ogol_signal, :watering_controller, :schedule_enabled, %{}, %{}}, 500

    assert_receive {:ogol_signal, :watering_controller, :watering_started, %{zones: [2]}, %{}},
                   500

    assert_eventually(fn ->
      WateringSystemDemo.snapshot() == %{
        valve_1: false,
        valve_2: true,
        valve_3: false,
        valve_4: false
      }
    end)

    assert_at_most_two_open(WateringSystemDemo.snapshot())
  end

  defp assert_at_most_two_open(snapshot) do
    open_count =
      snapshot
      |> Map.values()
      |> Enum.count(& &1)

    assert open_count <= 2
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, 0) do
    assert fun.()
  end

  defp assert_eventually(fun, attempts) do
    case fun.() do
      true ->
        :ok

      false ->
        Process.sleep(10)
        assert_eventually(fun, attempts - 1)
    end
  end
end
