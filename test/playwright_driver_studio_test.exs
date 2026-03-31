defmodule Ogol.PlaywrightDriverStudioTest do
  use Ogol.ConnCase, async: false

  @moduletag :integration

  setup do
    case Integration.Playwright.available?() do
      :ok -> :ok
      {:error, reason} -> {:ok, skip: reason}
    end
  end

  test "driver studio supports visual compile and source fallback in the browser" do
    Integration.Playwright.run!(~S"""
      await page.goto('/studio/drivers', { waitUntil: 'networkidle' });

      await expect(page.locator('input[name="driver[label]"]')).toHaveValue('Packaging Outputs');
      await expect(page.getByRole('button', { name: 'Compile' })).toBeVisible();

      await page.locator('input[name="driver[label]"]').fill('Browser Driver');
      await expect(page.locator('input[name="driver[label]"]')).toHaveValue('Browser Driver');
      await expect(page.getByRole('button', { name: 'Compile' })).toBeEnabled();

      await page.getByRole('button', { name: 'Compile' }).click();
      await expect(page.locator('input[name="driver[label]"]')).toHaveValue('Browser Driver');

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
