defmodule Ogol.PlaywrightDriverStudioTest do
  use Ogol.ConnCase, async: false

  @moduletag :integration

  setup do
    case Integration.Playwright.available?() do
      :ok -> :ok
      {:error, reason} -> {:ok, skip: reason}
    end
  end

  test "driver studio supports visual build/apply and source fallback in the browser" do
    Integration.Playwright.run!(~S"""
      await page.goto('/studio/drivers', { waitUntil: 'networkidle' });

      await expect(page.getByRole('heading', { name: 'Packaging Outputs' })).toBeVisible();
      await expect(page.getByRole('button', { name: 'Build' })).toBeVisible();
      await expect(page.getByRole('button', { name: 'Apply' })).toHaveCount(0);

      await page.locator('input[name="driver[label]"]').fill('Browser Driver');
      await expect(page.getByRole('heading', { name: 'Browser Driver' })).toBeVisible();
      await expect(page.getByText('Source changed and needs a build')).toBeVisible();

      await page.getByRole('button', { name: 'Build' }).click();
      await expect(page.getByText('Build ready to apply')).toBeVisible();
      await expect(page.getByRole('button', { name: 'Apply' })).toBeVisible();

      await page.getByRole('button', { name: 'Apply' }).click();
      await expect(page.getByText('Current source is applied')).toBeVisible();

      await page.getByRole('button', { name: 'Source' }).click();
      await page.locator('textarea[name="draft[source]"]').fill(`
        defmodule FreehandDriver do
          def hello, do: :world
        end
      `);
      await page.locator('textarea[name="draft[source]"]').blur();

      await expect(page.getByText('Visual editor unavailable')).toBeVisible();
      await expect(page.getByText('Current source can no longer be represented')).toBeVisible();
    """)
  end
end
