defmodule Ogol.PlaywrightHmiStudioTest do
  use Ogol.ConnCase, async: false

  alias Ogol.HMI.Surface.DeploymentStore, as: SurfaceDeploymentStore
  alias Ogol.HMI.Surface.RuntimeStore, as: SurfaceRuntimeStore
  alias Ogol.TestSupport.HmiStudioTopology
  alias Ogol.Topology.Runtime

  @moduletag :browser_integration

  setup do
    SurfaceRuntimeStore.reset()
    SurfaceDeploymentStore.reset()

    {:ok, pid} = Runtime.start(HmiStudioTopology.__ogol_topology__())

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
    end)

    case Integration.Playwright.available?() do
      :ok -> :ok
      {:error, reason} -> {:ok, skip: reason}
    end
  end

  test "hmi studio publishes and assigns runtime versions in the browser for the current workspace topology" do
    Integration.Playwright.run!(
      ~S"""
        await page.goto('/studio/hmis/topology_packaging_line_overview', { waitUntil: 'networkidle' });

        const overviewCell = page.locator('#hmi-cell-topology_packaging_line_overview');

        await expect(page.getByRole('heading', { name: 'Packaging Line topology Overview' })).toBeVisible();
        await expect(overviewCell.getByRole('button', { name: 'Configuration' })).toBeVisible();
        await expect(overviewCell.getByRole('button', { name: 'Preview' })).toBeVisible();
        await expect(overviewCell.getByRole('button', { name: 'Source' })).toBeVisible();

        await overviewCell.getByRole('button', { name: 'Source' }).click();
        await expect(overviewCell.locator('textarea[name="draft[source]"]')).toBeVisible();
        await overviewCell.getByRole('button', { name: 'Configuration' }).click();

      await overviewCell.locator('input[name="surface[title]"]').fill('Browser Topology Runtime One');
      await overviewCell.locator('textarea[name="surface[summary]"]').fill('First topology-scoped browser runtime surface.');
      await overviewCell.locator('textarea[name="surface[summary]"]').blur();
      await expect(page.getByRole('heading', { name: 'Browser Topology Runtime One' })).toBeVisible();

      await overviewCell.getByRole('button', { name: /Compile|Recompile/ }).click();
      await expect(overviewCell.getByRole('button', { name: 'Deploy' })).toBeEnabled();
      await overviewCell.getByRole('button', { name: 'Deploy' }).click();
        await overviewCell.getByRole('button', { name: 'Assign Panel' }).click();

        await page.goto('/ops', { waitUntil: 'networkidle' });
        await expect(page.getByText('Browser Topology Runtime One')).toBeVisible();

        await page.goto('/studio/hmis/topology_packaging_line_overview', { waitUntil: 'networkidle' });
        const updatedOverviewCell = page.locator('#hmi-cell-topology_packaging_line_overview');

      await updatedOverviewCell.locator('input[name="surface[title]"]').fill('Browser Topology Runtime Two');
      await updatedOverviewCell.locator('textarea[name="surface[summary]"]').fill('Second topology-scoped browser runtime surface.');
      await updatedOverviewCell.locator('textarea[name="surface[summary]"]').blur();
      await expect(page.getByRole('heading', { name: 'Browser Topology Runtime Two' })).toBeVisible();

      await updatedOverviewCell.getByRole('button', { name: /Compile|Recompile/ }).click();
      await expect(updatedOverviewCell.getByRole('button', { name: 'Deploy' })).toBeEnabled();
      await updatedOverviewCell.getByRole('button', { name: 'Deploy' }).click();
        await updatedOverviewCell.getByRole('button', { name: 'Assign Panel' }).click();

        await page.goto('/ops', { waitUntil: 'networkidle' });
        await expect(page.getByText('Browser Topology Runtime Two')).toBeVisible();
      """,
      timeout_ms: 60_000
    )
  end
end
