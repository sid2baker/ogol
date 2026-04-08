defmodule Ogol.TestSupport.EthercatFilteredFeedbackMachine do
  use Ogol.Machine
  require Ogol.Machine.Helpers

  defmodule Driver do
    @moduledoc false

    @behaviour EtherCAT.Driver

    @output_signals [:lamp]
    @input_signals [:sensor1, :sensor2]

    @impl true
    def identity do
      %{vendor_id: 0x0000_0ACE, product_code: 0x0000_CAFE, revision: 1}
    end

    @impl true
    def signal_model(_config, _sii_pdo_configs) do
      [
        lamp: 0x1600,
        sensor1: 0x1A00,
        sensor2: 0x1A01
      ]
    end

    @impl true
    def encode_signal(_signal, _config, value) when value in [true, 1], do: <<1>>
    def encode_signal(_signal, _config, _value), do: <<0>>

    @impl true
    def decode_signal(_signal, _config, <<_::7, bit::1>>), do: bit == 1
    def decode_signal(_signal, _config, _raw), do: false

    @impl true
    def describe(_config) do
      %{
        device_type: :digital_io,
        endpoints: [
          %{signal: :lamp, name: :lamp, direction: :output, type: :boolean},
          %{signal: :sensor1, name: :sensor1, direction: :input, type: :boolean},
          %{signal: :sensor2, name: :sensor2, direction: :input, type: :boolean}
        ],
        commands: [:set_output]
      }
    end

    @impl true
    def init(_config), do: {:ok, %{}}

    @impl true
    def project_state(decoded_inputs, prev_state, driver_state, _config) do
      previous = prev_state || %{}

      next_state =
        previous
        |> Map.take(@output_signals ++ @input_signals)
        |> Map.put(:sensor1, Map.get(decoded_inputs, :sensor1, false))
        |> Map.put(:sensor2, Map.get(decoded_inputs, :sensor2, false))

      {:ok, next_state, driver_state, [], []}
    end

    @impl true
    def command(
          %{name: :set_output, args: %{signal: signal, value: value}},
          _state,
          driver_state,
          _config
        )
        when signal in @output_signals and is_boolean(value) do
      {:ok, [{:write, signal, value}], driver_state, []}
    end

    def command(%{name: :set_output}, _state, _driver_state, _config),
      do: {:error, :invalid_output_value}

    def command(command, _state, _driver_state, _config),
      do: EtherCAT.Driver.unsupported_command(command)
  end

  defmodule Driver.Simulator do
    @moduledoc false

    @behaviour EtherCAT.Simulator.Adapter

    @impl true
    def definition_options(_config) do
      [
        profile: :digital_io,
        mode: :channels,
        direction: :io,
        mirror_output_to_input?: false,
        output_names: [:lamp],
        input_names: [:sensor1, :sensor2]
      ]
    end
  end

  boundary do
    fact(:sensor1?, :boolean, default: false)
    fact(:sensor2?, :boolean, default: false)
    request(:start)
    output(:lamp?, :boolean, default: false)
    signal(:advanced)
  end

  states do
    state :idle do
      initial?(true)
    end

    state(:waiting)
    state(:running)
  end

  transitions do
    transition :idle, :waiting do
      on({:request, :start})
      set_output(:lamp?, true)
      reply(:ok)
    end

    transition :waiting, :running do
      on({:hardware, :process_image})
      guard(Ogol.Machine.Helpers.callback(:sensor_active?))
      signal(:advanced)
    end
  end

  def sensor_active?(_delivered, data) do
    Ogol.Runtime.Observation.value(data, :sensor1?, false) or
      Ogol.Runtime.Observation.value(data, :sensor2?, false)
  end
end
