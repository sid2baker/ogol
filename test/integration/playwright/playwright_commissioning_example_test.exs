defmodule Ogol.PlaywrightCommissioningExampleTest do
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

  test "commissioning example loads and exposes the simulator cell in the browser" do
    Integration.Playwright.run!(
      ~S"""
        await page.goto('/studio', { waitUntil: 'networkidle' });

        await expect(page.locator('[data-test="load-example-pump_skid_commissioning_bench"]')).toBeVisible();
        await page.locator('[data-test="load-example-pump_skid_commissioning_bench"]').click();
        await expect(page.getByText('Example loaded')).toBeVisible({ timeout: 15000 });
        await expect(page.getByRole('heading', { name: 'Pump Skid Commissioning Bench' })).toBeVisible({ timeout: 15000 });

        await page.goto('/studio/simulator/ethercat', { waitUntil: 'networkidle' });

        await expect(page.getByText('Connections')).toBeVisible();
        await expect(page.locator('[data-test="start-simulation"]')).toBeVisible();
        await page.locator('[data-test="start-simulation"]').click();
        await expect(page.locator('[data-test="simulation-stop-current"]')).toBeVisible({ timeout: 15000 });
        await expect(page.locator('[data-test="simulator-runtime-status"]')).toContainText('Simulator running');
      """,
      %{timeout_ms: 60_000}
    )
  end
end
