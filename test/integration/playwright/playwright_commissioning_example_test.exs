defmodule Ogol.PlaywrightCommissioningExampleTest do
  use Ogol.ConnCase, async: false

  alias Ogol.TestSupport.EthercatHmiFixture
  alias Ogol.Topology.Registry

  @moduletag :browser_integration

  setup do
    EthercatHmiFixture.stop_all!()

    on_exit(fn ->
      stop_active_topology()
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

  test "commissioning example keeps raw simulator transport selections across source and reload" do
    Integration.Playwright.run!(
      ~S"""
        await page.goto('/studio', { waitUntil: 'networkidle' });

        await expect(page.locator('[data-test="load-example-pump_skid_commissioning_bench"]')).toBeVisible();
        await page.locator('[data-test="load-example-pump_skid_commissioning_bench"]').click();
        await expect(page.getByText('Example loaded')).toBeVisible({ timeout: 15000 });

        await page.goto('/studio/simulator/ethercat', { waitUntil: 'networkidle' });

        const transport = page.locator('select[name="simulator_config[transport]"]');
        await expect(transport).toHaveValue('udp');

        await transport.selectOption('raw');
        await expect(transport).toHaveValue('raw');

        const primaryInterface = page.locator('select[name="simulator_config[primary_interface]"]');
        await expect(primaryInterface).toBeVisible({ timeout: 15000 });
        await expect(page.locator('input[name="simulator_config[host]"]')).toHaveCount(0);
        await expect(page.locator('input[name="simulator_config[port]"]')).toHaveCount(0);

        const rawInterfaces = await primaryInterface.locator('option').evaluateAll((options) =>
          options.map((option) => option.value).filter((value) => value !== '')
        );

        if (rawInterfaces.length === 0) {
          throw new Error('No raw interfaces available for the simulator raw transport regression');
        }

        const selectedInterface = rawInterfaces[0];

        await primaryInterface.selectOption(selectedInterface);
        await expect(primaryInterface).toHaveValue(selectedInterface);

        await page.getByRole('button', { name: 'Source' }).click();
        await expect(page.locator('[data-test="simulator-config-source"] textarea[name="draft[source]"]'))
          .toContainText(`backend: {:raw, %{interface: "${selectedInterface}"}}`);

        await page.getByRole('button', { name: 'Config' }).click();
        await expect(transport).toHaveValue('raw');
        await expect(primaryInterface).toBeVisible({ timeout: 15000 });
        await expect(primaryInterface).toHaveValue(selectedInterface);
        await expect(page.locator('input[name="simulator_config[host]"]')).toHaveCount(0);
        await expect(page.locator('input[name="simulator_config[port]"]')).toHaveCount(0);

        await page.reload({ waitUntil: 'networkidle' });

        await expect(transport).toHaveValue('raw');
        await expect(primaryInterface).toBeVisible({ timeout: 15000 });
        await expect(primaryInterface).toHaveValue(selectedInterface);
        await expect(page.locator('input[name="simulator_config[host]"]')).toHaveCount(0);
        await expect(page.locator('input[name="simulator_config[port]"]')).toHaveCount(0);
      """,
      %{timeout_ms: 60_000}
    )
  end

  test "commissioning example boots end to end after switching hardware to udp" do
    Integration.Playwright.run!(
      ~S"""
        await page.goto('/studio', { waitUntil: 'networkidle' });

        await expect(page.locator('[data-test="load-example-pump_skid_commissioning_bench"]')).toBeVisible();
        await page.locator('[data-test="load-example-pump_skid_commissioning_bench"]').click();
        await expect(page.getByText('Example loaded')).toBeVisible({ timeout: 15000 });

        await page.goto('/studio/hardware/ethercat', { waitUntil: 'networkidle' });

        const hardwareTransport = page.locator('select[name="hardware_config[transport]"]');
        await expect(hardwareTransport).toHaveValue('raw');
        await hardwareTransport.selectOption('udp');
        await expect(hardwareTransport).toHaveValue('udp');
        await expect(page.locator('input[name="hardware_config[bind_ip]"]')).toBeVisible({ timeout: 15000 });
        await expect(page.locator('select[name="hardware_config[primary_interface]"]')).toHaveCount(0);

        await page.goto('/studio/simulator/ethercat', { waitUntil: 'networkidle' });
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
          throw new Error('commissioning example topology never reached the running state');
        }

        await expect(page.getByRole('button', { name: 'Stop' })).toBeVisible({ timeout: 15000 });
        await expect(page.getByText('Start failed')).toHaveCount(0);

        await page.goto('/studio/simulator/ethercat', { waitUntil: 'networkidle' });
        await expect(page.locator('[data-test="simulator-runtime-status"]')).toContainText('Simulator running');
        await expect(page.locator('[data-test="simulation-stop-current"]')).toBeVisible();

        await page.goto('/studio/topology', { waitUntil: 'networkidle' });
        await page.getByRole('button', { name: 'Stop' }).click();
        await expect(page.getByRole('button', { name: 'Start' })).toBeVisible({ timeout: 15000 });
      """,
      %{timeout_ms: 90_000}
    )
  end

  test "commissioning example sequence runs end to end from the sequence page" do
    Integration.Playwright.run!(
      ~S"""
        await page.goto('/studio', { waitUntil: 'networkidle' });

        await expect(page.locator('[data-test="load-example-pump_skid_commissioning_bench"]')).toBeVisible();
        await page.locator('[data-test="load-example-pump_skid_commissioning_bench"]').click();
        await expect(page.getByText('Example loaded')).toBeVisible({ timeout: 15000 });

        await page.goto('/studio/hardware/ethercat', { waitUntil: 'networkidle' });

        const hardwareTransport = page.locator('select[name="hardware_config[transport]"]');
        await expect(hardwareTransport).toHaveValue('raw');
        await hardwareTransport.selectOption('udp');
        await expect(hardwareTransport).toHaveValue('udp');

        await page.goto('/studio/simulator/ethercat', { waitUntil: 'networkidle' });
        await expect(page.locator('[data-test="start-simulation"]')).toBeVisible();
        await page.locator('[data-test="start-simulation"]').click();
        await expect(page.locator('[data-test="simulation-stop-current"]')).toBeVisible({ timeout: 15000 });

        await page.goto('/studio/topology', { waitUntil: 'networkidle' });

        const topologyCompileButton = page.getByRole('button', { name: /Compile|Recompile/ });
        const topologyStartButton = page.getByRole('button', { name: 'Start' });
        let started = false;

        for (let attempt = 0; attempt < 10; attempt++) {
          if (await topologyCompileButton.isEnabled()) {
            await topologyCompileButton.click();
          }

          await page.waitForTimeout(250);
          await topologyStartButton.click();

          if (await page.getByRole('button', { name: 'Stop' }).isVisible().catch(() => false)) {
            started = true;
            break;
          }
        }

        if (!started) {
          throw new Error('commissioning example topology never reached the running state');
        }

        await page.goto('/studio/sequences/pump_skid_commissioning', { waitUntil: 'networkidle' });

        const runButton = page.getByRole('button', { name: 'Run' });
        await expect(runButton).toBeVisible({ timeout: 15000 });
        await runButton.click();

        await expect(page.getByText('The latest sequence run finished successfully.')).toBeVisible({ timeout: 15000 });

        await page.getByRole('button', { name: 'Live' }).click();
        await expect(page.getByText('Live Run')).toBeVisible({ timeout: 15000 });
        await expect(page.getByText('Run Status')).toBeVisible({ timeout: 15000 });
        await expect(page.getByText('Current Procedure', { exact: true })).toBeVisible({ timeout: 15000 });
      """,
      %{timeout_ms: 90_000}
    )
  end

  defp stop_active_topology do
    case Registry.active_topology() do
      %{pid: pid} when is_pid(pid) ->
        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _reason -> :ok
        end

      _other ->
        :ok
    end
  end
end
