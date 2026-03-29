defmodule Ogol.PlaywrightHmiStudioTest do
  use Ogol.ConnCase, async: false

  alias Ogol.HMI.{SurfaceDeploymentStore, SurfaceDraftStore}

  @moduletag :integration

  setup do
    SurfaceDraftStore.reset()
    SurfaceDeploymentStore.reset()

    case Integration.Playwright.available?() do
      :ok -> :ok
      {:error, reason} -> {:ok, skip: reason}
    end
  end

  test "hmi studio publishes and assigns runtime versions in the browser" do
    Integration.Playwright.run!(~S"""
      await page.goto('/studio/hmis', { waitUntil: 'networkidle' });

      await expect(page.locator('input[name="surface[title]"]')).toHaveValue('Operations Triage');
      await expect(page.locator('textarea[name="surface[summary]"]')).toContainText('Assigned runtime surface');

      await page.getByRole('button', { name: 'Source' }).click();
      await expect(page.locator('textarea[name="draft[source]"]')).toBeVisible();
      await page.getByRole('button', { name: 'Visual' }).click();
      await expect(page.locator('input[name="surface[title]"]')).toBeVisible();

      await page.locator('input[name="surface[title]"]').fill('Browser Runtime Version One');
      await page.locator('textarea[name="surface[summary]"]').fill('First browser-published HMI runtime surface.');

      await page.getByRole('button', { name: 'Compile' }).click();
      await page.getByRole('button', { name: 'Deploy' }).click();
      await page.getByRole('button', { name: 'Assign Panel' }).click();

      await page.goto('/ops', { waitUntil: 'networkidle' });
      await expect(page.getByText('Browser Runtime Version One')).toBeVisible();

      await page.goto('/studio/hmis', { waitUntil: 'networkidle' });
      await page.locator('input[name="surface[title]"]').fill('Browser Runtime Version Two');
      await page.locator('textarea[name="surface[summary]"]').fill('Second browser-published HMI runtime surface.');

      await page.getByRole('button', { name: 'Compile' }).click();
      await page.getByRole('button', { name: 'Deploy' }).click();
      await page.getByRole('button', { name: 'Assign Panel' }).click();

      await page.goto('/ops', { waitUntil: 'networkidle' });
      await expect(page.getByText('Browser Runtime Version Two')).toBeVisible();
    """)
  end
end
