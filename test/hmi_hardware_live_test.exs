defmodule Ogol.HMI.HardwareLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.TestSupport.EthercatHmiFixture

  setup do
    EthercatHmiFixture.stop_all!()

    on_exit(fn ->
      EthercatHmiFixture.stop_all!()
    end)

    :ok
  end

  test "renders the hardware page without an active ethercat session" do
    {:ok, _view, html} = live(build_conn(), "/studio/hardware")

    assert html =~ "Hardware Studio"
    assert html =~ "Simulation Configs"
    assert html =~ "No EtherCAT session detected"
    assert html =~ "EtherCAT"
  end

  test "saves a hardware config and starts an ethercat simulation from it" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    view
    |> form("[data-test='simulation-config-form']", %{
      "simulation_config" => %{
        "id" => "packaging_line",
        "label" => "Packaging Line",
        "bind_ip" => "127.0.0.1",
        "simulator_ip" => "127.0.0.2",
        "scan_stable_ms" => "20",
        "scan_poll_ms" => "10",
        "frame_timeout_ms" => "20",
        "domains" => %{
          "0" => %{
            "id" => "main",
            "cycle_time_us" => "1000",
            "miss_threshold" => "1000",
            "recovery_threshold" => "3"
          }
        },
        "slaves" => %{
          "0" => %{
            "name" => "coupler",
            "driver" => "EtherCAT.Driver.EK1100",
            "target_state" => "preop",
            "process_data_mode" => "none",
            "process_data_domain" => "",
            "health_poll_ms" => ""
          },
          "1" => %{
            "name" => "inputs",
            "driver" => "EtherCAT.Driver.EL1809",
            "target_state" => "preop",
            "process_data_mode" => "none",
            "process_data_domain" => "",
            "health_poll_ms" => ""
          },
          "2" => %{
            "name" => "outputs",
            "driver" => "EtherCAT.Driver.EL2809",
            "target_state" => "preop",
            "process_data_mode" => "none",
            "process_data_domain" => "",
            "health_poll_ms" => ""
          }
        }
      }
    })
    |> render_submit()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "saved hardware config packaging_line"
      assert rendered =~ "Packaging Line"
      assert rendered =~ "Start simulation"
    end)

    view
    |> element("[data-test='start-simulation-packaging_line']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "starting simulation from packaging_line"

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "simulation started from packaging_line"
      assert rendered =~ "preop_ready"
      assert rendered =~ "coupler"
      assert rendered =~ "inputs"
      assert rendered =~ "outputs"

      assert {:ok, :preop_ready} = EtherCAT.state()
      assert {:ok, slaves} = EtherCAT.slaves()
      assert Enum.sort(slaves) == [:coupler, :inputs, :outputs]
    end)
  end

  test "configures an ethercat slave from the hardware page" do
    EthercatHmiFixture.boot_preop_ring!()

    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "EtherCAT session control"
      assert rendered =~ "outputs"
      assert rendered =~ "preop_ready"
    end)

    view
    |> form("[data-test='slave-config-outputs']", %{
      "slave_config" => %{
        "slave" => "outputs",
        "driver" => "EtherCAT.Driver.EL2809",
        "process_data_mode" => "all",
        "process_data_domain" => "main",
        "process_data_signals" => "",
        "target_state" => "preop",
        "health_poll_ms" => "123"
      }
    })
    |> render_submit()

    assert_eventually(fn ->
      rendered = render(view)

      assert rendered =~ "hardware configuration applied for outputs" or
               rendered =~ "applying EtherCAT configuration for outputs"

      assert {:ok, %{signals: signals}} = EtherCAT.Diagnostics.slave_info(:outputs)
      assert length(signals) == 16
      assert Enum.any?(signals, &(&1.name == :ch1 and &1.domain == :main))
    end)
  end

  test "preop simulation stays stable when activate is clicked" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    view
    |> form("[data-test='simulation-config-form']", %{
      "simulation_config" => %{
        "id" => "preop_only",
        "label" => "PREOP Only",
        "bind_ip" => "127.0.0.1",
        "simulator_ip" => "127.0.0.2",
        "scan_stable_ms" => "20",
        "scan_poll_ms" => "10",
        "frame_timeout_ms" => "20",
        "domains" => %{
          "0" => %{
            "id" => "main",
            "cycle_time_us" => "1000",
            "miss_threshold" => "1000",
            "recovery_threshold" => "3"
          }
        },
        "slaves" => %{
          "0" => %{
            "name" => "coupler",
            "driver" => "EtherCAT.Driver.EK1100",
            "target_state" => "preop",
            "process_data_mode" => "none",
            "process_data_domain" => "",
            "health_poll_ms" => ""
          },
          "1" => %{
            "name" => "inputs",
            "driver" => "EtherCAT.Driver.EL1809",
            "target_state" => "preop",
            "process_data_mode" => "none",
            "process_data_domain" => "",
            "health_poll_ms" => ""
          },
          "2" => %{
            "name" => "outputs",
            "driver" => "EtherCAT.Driver.EL2809",
            "target_state" => "preop",
            "process_data_mode" => "none",
            "process_data_domain" => "",
            "health_poll_ms" => ""
          }
        }
      }
    })
    |> render_submit()

    view
    |> element("[data-test='start-simulation-preop_only']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "simulation started from preop_only"
      assert {:ok, :preop_ready} = EtherCAT.state()
    end)

    Process.sleep(350)

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "preop_ready"
      assert {:ok, :preop_ready} = EtherCAT.state()
      refute rendered =~ "EtherCAT activate failed"
    end)

    view
    |> element("[data-test='ethercat-activate']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "EtherCAT activate sent"
      assert rendered =~ "preop_ready"
      assert {:ok, :preop_ready} = EtherCAT.state()
      refute rendered =~ "EtherCAT activate failed"
      refute rendered =~ ":recovery_in_progress"
    end)
  end

  defp assert_eventually(fun, attempts \\ 30)

  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    _error in [ExUnit.AssertionError] ->
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
  end
end
