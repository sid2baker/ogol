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
      await expect(page.getByText('Runtime render plan prepared as r1.')).toBeVisible();

      await page.getByRole('button', { name: 'Deploy' }).click();
      await expect(page.getByText('Compiled surface r1 is now published for runtime assignment.')).toBeVisible();
      await expect(page.locator('select[name="assignment[version]"]')).toHaveValue('r1');

      await page.getByRole('button', { name: 'Assign Panel' }).click();
      await expect(page.getByText('now opens operations_overview@r1 by default.')).toBeVisible();

      await page.goto('/ops', { waitUntil: 'networkidle' });
      await expect(page.getByText('Browser Runtime Version One')).toBeVisible();

      await page.goto('/studio/hmis', { waitUntil: 'networkidle' });
      await page.locator('input[name="surface[title]"]').fill('Browser Runtime Version Two');
      await page.locator('textarea[name="surface[summary]"]').fill('Second browser-published HMI runtime surface.');

      await page.getByRole('button', { name: 'Compile' }).click();
      await expect(page.getByText('Runtime render plan prepared as r2.')).toBeVisible();

      await page.getByRole('button', { name: 'Deploy' }).click();
      await expect(page.getByText('Compiled surface r2 is now published for runtime assignment.')).toBeVisible();
      await expect(page.locator('select[name="assignment[version]"]')).toHaveValue('r2');

      await page.goto('/ops', { waitUntil: 'networkidle' });
      await expect(page.getByText('Browser Runtime Version One')).toBeVisible();
      await expect(page.getByText('Browser Runtime Version Two')).toHaveCount(0);

      await page.goto('/studio/hmis', { waitUntil: 'networkidle' });
      await page.locator('select[name="assignment[version]"]').selectOption('r1');
      await page.getByRole('button', { name: 'Assign Panel' }).click();
      await expect(page.getByText('now opens operations_overview@r1 by default.')).toBeVisible();

      await page.goto('/ops', { waitUntil: 'networkidle' });
      await expect(page.getByText('Browser Runtime Version One')).toBeVisible();
      await expect(page.getByText('Browser Runtime Version Two')).toHaveCount(0);

      await page.goto('/studio/hmis', { waitUntil: 'networkidle' });
      await page.locator('select[name="assignment[version]"]').selectOption('r2');
      await page.getByRole('button', { name: 'Assign Panel' }).click();
      await expect(page.getByText('now opens operations_overview@r2 by default.')).toBeVisible();

      await page.goto('/ops', { waitUntil: 'networkidle' });
      await expect(page.getByText('Browser Runtime Version Two')).toBeVisible();
    """)
  end
end
