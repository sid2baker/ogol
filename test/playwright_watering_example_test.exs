defmodule Ogol.PlaywrightWateringExampleTest do
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

  test "watering example survives simulator start and still starts topology in the browser" do
    Integration.Playwright.run!(
      ~S"""
        await page.goto('/studio', { waitUntil: 'networkidle' });

        await expect(page.locator('[data-test="load-example-watering_valves"]')).toBeVisible();
        await page.locator('[data-test="load-example-watering_valves"]').click();
        await expect(page.getByText('Example loaded')).toBeVisible({ timeout: 15000 });

        await page.goto('/studio/simulator', { waitUntil: 'networkidle' });

        await expect(page.locator('[data-test="start-simulation"]')).toBeVisible();
        await page.locator('[data-test="start-simulation"]').click();
        await expect(page.locator('[data-test="simulation-stop-current"]')).toBeVisible({ timeout: 15000 });

        await page.goto('/studio/topology/watering_system', { waitUntil: 'networkidle' });

        await expect(page.getByRole('button', { name: /Compile|Recompile/ })).toBeVisible();
        const compileButton = page.getByRole('button', { name: /Compile|Recompile/ });
        if (await compileButton.isEnabled()) {
          await compileButton.click();
        }
        await expect(page.getByRole('button', { name: 'Start' })).toBeVisible({ timeout: 15000 });
        await page.getByRole('button', { name: 'Start' }).click();

        await page.waitForTimeout(1000);
        await expect(page.getByText('Start failed')).toHaveCount(0);
        await expect(page.getByText('Machine watering_controller tried to drive a hardware output')).toHaveCount(0);
      """,
      %{timeout_ms: 60_000}
    )
  end
end
