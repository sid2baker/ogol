defmodule Ogol.PlaywrightTopologyStudioLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.TestSupport.EthercatHmiFixture
  alias Ogol.Topology.Registry

  @moduletag :browser_integration

  setup do
    EthercatHmiFixture.stop_all!()

    on_exit(fn ->
      stop_active_topology()
      EthercatHmiFixture.stop_all!()
    end)

    case Integration.Playwright.available?() do
      :ok -> :ok
      {:error, reason} -> {:ok, skip: reason}
    end
  end

  test "topology live keeps the mermaid diagram visible while invoking machine skills" do
    Integration.Playwright.run!(~S"""
      await page.goto('/studio/simulator/ethercat', { waitUntil: 'networkidle' });
      await page.locator('[data-test="start-simulation"]').click();
      await expect(page.locator('[data-test="simulation-stop-current"]')).toBeVisible({ timeout: 15000 });

      await page.goto('/studio/topology', { waitUntil: 'networkidle' });
      const compileButton = page.getByRole('button', { name: /Compile|Recompile/ });
      const startButton = page.getByRole('button', { name: 'Start' });
      let started = false;

      for (let attempt = 0; attempt < 10; attempt++) {
        if (await compileButton.isEnabled()) {
          await compileButton.click();
        }

        await page.waitForTimeout(250);
        await startButton.click();

        if (await page.getByRole('button', { name: 'Stop' }).isVisible().catch(() => false)) {
          started = true;
          break;
        }
      }

      if (!started) {
        throw new Error('topology never reached the running state');
      }

      await expect(page.getByRole('button', { name: 'Stop' })).toBeVisible({ timeout: 15000 });
      await page.getByRole('button', { name: 'Live' }).click();

      const diagram = page.locator('#topology-live-machine-mermaid-packaging_line svg');
      await expect(diagram).toBeVisible({ timeout: 15000 });

      await page.locator("[data-test='topology-live-skill-packaging_line-start']").click();
      await expect(page.getByText('packaging_line :: skill start')).toBeVisible({ timeout: 15000 });
      await expect(diagram).toBeVisible({ timeout: 15000 });
    """)
  end

  defp stop_active_topology do
    case Registry.active_topology() do
      %{pid: pid} when is_pid(pid) ->
        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _reason -> :ok
        end

      _ ->
        :ok
    end
  end
end
