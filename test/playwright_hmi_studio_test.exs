defmodule Ogol.PlaywrightHmiStudioTest do
  use Ogol.ConnCase, async: false

  alias Ogol.HMI.{SurfaceDeploymentStore, SurfaceDraftStore}
  alias Ogol.TestSupport.HmiStudioTopology
  alias Ogol.Topology.Runtime

  @moduletag :integration

  setup do
    SurfaceDraftStore.reset()
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

  test "hmi studio publishes and assigns runtime versions in the browser for the active topology" do
    Integration.Playwright.run!(~S"""
      await page.goto('/studio/hmis', { waitUntil: 'networkidle' });

      const overviewCell = page.locator('#hmi-cell-topology_simple_hmi_line_overview');

      await expect(overviewCell.getByText('Simple HMI Studio Line Overview')).toBeVisible();
      await expect(overviewCell.getByRole('button', { name: 'Visual' })).toBeVisible();
      await expect(overviewCell.getByRole('button', { name: 'Source' })).toBeVisible();

      await overviewCell.getByRole('button', { name: 'Source' }).click();
      await expect(overviewCell.locator('textarea[name="draft[source]"]')).toBeVisible();
      await overviewCell.getByRole('button', { name: 'Visual' }).click();

      await overviewCell.locator('input[name="surface[title]"]').fill('Browser Topology Runtime One');
      await overviewCell.locator('textarea[name="surface[summary]"]').fill('First topology-scoped browser runtime surface.');

      await overviewCell.getByRole('button', { name: 'Compile' }).click();
      await overviewCell.getByRole('button', { name: 'Deploy' }).click();
      await overviewCell.getByRole('button', { name: 'Assign Panel' }).click();

      await page.goto('/ops', { waitUntil: 'networkidle' });
      await expect(page.getByText('Browser Topology Runtime One')).toBeVisible();

      await page.goto('/studio/hmis', { waitUntil: 'networkidle' });
      const updatedOverviewCell = page.locator('#hmi-cell-topology_simple_hmi_line_overview');

      await updatedOverviewCell.locator('input[name="surface[title]"]').fill('Browser Topology Runtime Two');
      await updatedOverviewCell.locator('textarea[name="surface[summary]"]').fill('Second topology-scoped browser runtime surface.');

      await updatedOverviewCell.getByRole('button', { name: 'Compile' }).click();
      await updatedOverviewCell.getByRole('button', { name: 'Deploy' }).click();
      await updatedOverviewCell.getByRole('button', { name: 'Assign Panel' }).click();

      await page.goto('/ops', { waitUntil: 'networkidle' });
      await expect(page.getByText('Browser Topology Runtime Two')).toBeVisible();
    """)
  end
end
