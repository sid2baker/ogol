defmodule Ogol.PlaywrightMachineHmiE2ETest do
  use Ogol.ConnCase, async: false

  alias Ogol.HMI.Surface.DeploymentStore, as: SurfaceDeploymentStore
  alias Ogol.HMI.Surface.RuntimeStore, as: SurfaceRuntimeStore
  alias Ogol.TestSupport.EthercatHmiFixture
  alias Ogol.Topology.Registry

  @moduletag :integration

  setup do
    EthercatHmiFixture.stop_all!()
    SurfaceRuntimeStore.reset()
    SurfaceDeploymentStore.reset()

    on_exit(fn ->
      stop_active_topology()
      EthercatHmiFixture.stop_all!()
    end)

    case Integration.Playwright.available?() do
      :ok -> :ok
      {:error, reason} -> {:ok, skip: reason}
    end
  end

  test "the browser flow can bring a machine online and visualize it through topology-scoped HMI cells" do
    Integration.Playwright.run!(
      ~S"""
        await page.goto('/studio/simulator', { waitUntil: 'networkidle' });

        await expect(page.locator('[data-test="start-simulation"]')).toBeVisible();
        await page.locator('[data-test="start-simulation"]').click();
        await expect(page.locator('[data-test="simulation-stop-current"]')).toBeVisible({ timeout: 15000 });

        await page.goto('/studio/topology/packaging_line', { waitUntil: 'networkidle' });

        await expect(page.getByRole('button', { name: /Compile|Recompile/ })).toBeVisible();
        const compileButton = page.getByRole('button', { name: /Compile|Recompile/ });
        if (await compileButton.isEnabled()) {
          await compileButton.click();
        }
        await expect(page.getByRole('button', { name: 'Start' })).toBeVisible();
        await page.getByRole('button', { name: 'Start' }).click();
        await page.waitForTimeout(1000);
        await expect(page.getByText('Start failed')).toHaveCount(0);

        await page.goto('/studio/hmis', { waitUntil: 'networkidle' });

        await expect(page.getByRole('link', { name: /Packaging Line coordinator Station/i })).toBeVisible({ timeout: 15000 });
        await page.goto('/studio/hmis/topology_packaging_line_packaging_line_station', { waitUntil: 'networkidle' });

        const stationCell = page.locator('#hmi-cell-topology_packaging_line_packaging_line_station');

        await expect(stationCell).toBeVisible({ timeout: 15000 });

        await stationCell.locator('input[name="surface[title]"]').fill('Browser Packaging Station');
        await stationCell.locator('textarea[name="surface[summary]"]').fill(
          'Topology-scoped station surface for the browser machine startup flow.'
        );
        await stationCell.locator('textarea[name="surface[summary]"]').blur();
        await expect(page.getByRole('heading', { name: 'Browser Packaging Station' })).toBeVisible();

        await stationCell.getByRole('button', { name: /Compile|Recompile/ }).click();
        await expect(stationCell.getByRole('button', { name: 'Deploy' })).toBeEnabled();
        await stationCell.getByRole('button', { name: 'Deploy' }).click();
        await expect(stationCell.getByRole('button', { name: 'Assign Panel' })).toBeEnabled({ timeout: 15000 });
        await stationCell.getByRole('button', { name: 'Assign Panel' }).click();

        await page.goto('/ops', { waitUntil: 'networkidle' });

        await expect(page.getByText('Browser Packaging Station')).toBeVisible({ timeout: 15000 });
        await expect(page.locator("[data-test='control-packaging_line-skill-start']")).toBeVisible({ timeout: 15000 });

        await page.locator("[data-test='control-packaging_line-skill-start']").click();

        await expect(page.getByText('operator skill invoked')).toBeVisible({ timeout: 15000 });
        await expect(page.getByText('reply=ok')).toBeVisible({ timeout: 15000 });
        await expect(page.getByText('state=running')).toBeVisible({ timeout: 15000 });
      """,
      timeout_ms: 60_000
    )
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
