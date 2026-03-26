defmodule Ogol.HMI.OverviewLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.TestSupport.SampleMachine

  test "renders machine snapshots and recent events" do
    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ "No machines running yet"

    {:ok, pid} = SampleMachine.start_link()

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "sample_machine"
      assert rendered =~ "idle"
    end)

    assert :ok = Ogol.request(pid, :start)

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "running"
      assert rendered =~ "started"
      assert rendered =~ "machine started"
      assert rendered =~ "state entered"
    end)
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    _error in [ExUnit.AssertionError] ->
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
  end
end
