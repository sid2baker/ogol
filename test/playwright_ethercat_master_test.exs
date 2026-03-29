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

  test "the browser flow can start the simulator, attach the master, and stop the master without stopping simulation" do
    Integration.Playwright.run!(~S"""
      await page.goto('/studio/simulator', { waitUntil: 'networkidle' });

      await expect(page.locator('[data-test="start-simulation"]')).toBeVisible();
      await expect(page.locator('[data-test="start-simulation"]')).toBeEnabled();
      await page.locator('[data-test="start-simulation"]').click();
      await expect(page.locator('[data-test="simulation-stop-current"]')).toBeVisible({ timeout: 15000 });
      await expect(page.getByText('Current simulator state')).toBeVisible({ timeout: 15000 });

      await page.goto('/studio/ethercat', { waitUntil: 'networkidle' });

      await expect(page.locator('[data-test="hardware-section-master"]')).toBeVisible();
      await expect(page.getByText('Simulator backend is still running')).toBeVisible({ timeout: 15000 });
      await expect(page.locator('[data-test="start-master"]')).toBeVisible({ timeout: 15000 });
      await page.locator('[data-test="start-master"]').click();
      await expect(page.locator('[data-test="stop-master"]')).toBeVisible({ timeout: 15000 });
      await expect(page.locator('[data-test="master-view-runtime"]')).toBeEnabled({ timeout: 15000 });
      await page.locator('[data-test="master-view-runtime"]').click();
      await expect(page.locator('[data-test="master-runtime-view"]')).toBeVisible({ timeout: 15000 });
      await page.locator('[data-test="stop-master"]').click();

      await expect(page.locator('[data-test="start-master"]')).toBeVisible({ timeout: 15000 });
      await expect(page.getByText('EtherCAT master stopped')).toBeVisible({ timeout: 15000 });
    """)
  end
end
