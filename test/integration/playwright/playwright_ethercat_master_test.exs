defmodule Ogol.PlaywrightEthercatMasterTest do
  use Ogol.ConnCase, async: false

  alias Ogol.TestSupport.EthercatHmiFixture

  @moduletag :browser_integration

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
      await page.goto('/studio/simulator/ethercat', { waitUntil: 'networkidle' });

      await expect(page.locator('[data-test="simulator-runtime-status"]')).toBeVisible();
      await expect(page.getByRole('heading', { name: 'EtherCAT simulator runtime' })).toBeVisible();
      await expect(page.locator('[data-test="start-simulation"]')).toBeVisible();
      await page.locator('[data-test="start-simulation"]').click();
      await expect(page.locator('[data-test="simulation-stop-current"]')).toBeVisible({ timeout: 15000 });
      await expect(page.locator('[data-test="simulator-runtime-status"]')).toContainText('Simulator running');

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
      await page.getByRole('button', { name: 'Stop' }).click();

      await expect(startButton).toBeVisible({ timeout: 15000 });

      await page.goto('/studio/simulator/ethercat', { waitUntil: 'networkidle' });
      await expect(page.locator('[data-test="simulator-runtime-status"]')).toContainText('Simulator running');
      await expect(page.locator('[data-test="simulation-stop-current"]')).toBeVisible();
    """)
  end
end
