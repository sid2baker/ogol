defmodule Ogol.PlaywrightEthercatMasterTest do
  use Ogol.ConnCase, async: false

  alias Ogol.TestSupport.EthercatHmiFixture

  @moduletag :integration

  setup do
    EthercatHmiFixture.stop_all!()

    on_exit(fn ->
      EthercatHmiFixture.stop_all!()
    end)

    case Integration.Playwright.available?() do
      :ok -> :ok
      {:error, reason} -> {:ok, skip: reason}
    end
  end

  test "the browser flow starts simulation on the simulator page and topology start leaves it running" do
    Integration.Playwright.run!(~S"""
      await page.goto('/studio/simulator', { waitUntil: 'networkidle' });

      await expect(page.getByText('Derived from current EtherCAT config')).toBeVisible();
      await expect(page.locator('[data-test="start-simulation"]')).toBeVisible();
      await page.locator('[data-test="start-simulation"]').click();
      await expect(page.locator('[data-test="simulation-stop-current"]')).toBeVisible({ timeout: 15000 });
      await expect(page.locator('[data-test="simulator-runtime-status"]')).toContainText('Simulator running');

      await page.goto('/studio/topology', { waitUntil: 'networkidle' });

      const compileButton = page.getByRole('button', { name: /Compile|Recompile/ });
      if (await compileButton.isEnabled()) {
        await compileButton.click();
      }
      await expect(page.getByRole('button', { name: 'Start' })).toBeVisible({ timeout: 15000 });
      await page.getByRole('button', { name: 'Start' }).click();
      await expect(page.getByRole('button', { name: 'Stop' })).toBeVisible({ timeout: 15000 });
      await page.getByRole('button', { name: 'Stop' }).click();

      await expect(page.getByRole('button', { name: 'Start' })).toBeVisible({ timeout: 15000 });

      await page.goto('/studio/simulator', { waitUntil: 'networkidle' });
      await expect(page.locator('[data-test="simulator-runtime-status"]')).toContainText('Simulator running');
      await expect(page.locator('[data-test="simulation-stop-current"]')).toBeVisible();
    """)
  end
end
