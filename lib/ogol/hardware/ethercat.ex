defmodule Ogol.Hardware.EtherCAT do
  @moduledoc false

  alias EtherCAT.Slave.Config, as: SlaveConfig
  alias Ogol.Hardware.EtherCAT.Driver.{EK1100, EL1809, EL2809}

  @artifact_id "ethercat"
  @default_label "EtherCAT"
  @default_bind_ip {127, 0, 0, 1}
  @default_domain_id :main
  @default_cycle_time_us 1_000
  @default_scan_stable_ms 20
  @default_scan_poll_ms 10
  @default_frame_timeout_ms 20

  @type signal_ref :: {atom(), atom()}
  @type command_binding_ref :: {atom(), atom(), map()}

  defmodule Transport do
    @moduledoc false

    @enforce_keys [:mode]
    defstruct [:mode, :bind_ip, :primary_interface, :secondary_interface]

    @type mode_t :: :udp | :raw | :redundant

    @type t :: %__MODULE__{
            mode: mode_t(),
            bind_ip: :inet.ip_address() | nil,
            primary_interface: String.t() | nil,
            secondary_interface: String.t() | nil
          }
  end

  defmodule Timing do
    @moduledoc false

    @enforce_keys [:scan_stable_ms, :scan_poll_ms, :frame_timeout_ms]
    defstruct [:scan_stable_ms, :scan_poll_ms, :frame_timeout_ms]

    @type t :: %__MODULE__{
            scan_stable_ms: pos_integer(),
            scan_poll_ms: pos_integer(),
            frame_timeout_ms: pos_integer()
          }
  end

  defmodule Domain do
    @moduledoc false

    @enforce_keys [:id, :cycle_time_us, :miss_threshold, :recovery_threshold]
    defstruct [:id, :cycle_time_us, :miss_threshold, :recovery_threshold]

    @type t :: %__MODULE__{
            id: atom(),
            cycle_time_us: pos_integer(),
            miss_threshold: pos_integer(),
            recovery_threshold: pos_integer()
          }

    @spec to_runtime(t()) :: keyword()
    def to_runtime(%__MODULE__{} = domain) do
      [
        id: domain.id,
        cycle_time_us: domain.cycle_time_us,
        miss_threshold: domain.miss_threshold,
        recovery_threshold: domain.recovery_threshold
      ]
    end
  end

  @enforce_keys [:transport, :timing]
  defstruct [
    :transport,
    :timing,
    id: @artifact_id,
    label: @default_label,
    domains: [],
    slaves: [],
    inserted_at: nil,
    updated_at: nil,
    meta: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          transport: Transport.t(),
          timing: Timing.t(),
          domains: [Domain.t()],
          slaves: [SlaveConfig.t()],
          inserted_at: integer() | nil,
          updated_at: integer() | nil,
          meta: map()
        }

  @spec artifact_id() :: String.t()
  def artifact_id, do: @artifact_id

  @spec id(t()) :: String.t()
  def id(%__MODULE__{id: id}) when is_binary(id) and id != "", do: id
  def id(%__MODULE__{}), do: @artifact_id

  @spec default_label() :: String.t()
  def default_label, do: @default_label

  @spec label(t()) :: String.t()
  def label(%__MODULE__{label: label}) when is_binary(label) and label != "", do: label
  def label(%__MODULE__{}), do: @default_label

  @spec default() :: t()
  def default do
    %__MODULE__{
      transport: %Transport{
        mode: :udp,
        bind_ip: @default_bind_ip
      },
      timing: %Timing{
        scan_stable_ms: @default_scan_stable_ms,
        scan_poll_ms: @default_scan_poll_ms,
        frame_timeout_ms: @default_frame_timeout_ms
      },
      domains: [
        %Domain{
          id: @default_domain_id,
          cycle_time_us: @default_cycle_time_us,
          miss_threshold: 1_000,
          recovery_threshold: 3
        }
      ],
      slaves: [
        default_slave(:coupler, EK1100),
        default_slave(:inputs, EL1809),
        default_slave(:outputs, EL2809)
      ]
    }
  end

  @spec transport_mode(t()) :: Transport.mode_t()
  def transport_mode(%__MODULE__{transport: %Transport{mode: mode}}), do: mode

  @spec bind_ip(t()) :: :inet.ip_address() | nil
  def bind_ip(%__MODULE__{transport: %Transport{bind_ip: bind_ip}}), do: bind_ip

  @spec primary_interface(t()) :: String.t() | nil
  def primary_interface(%__MODULE__{transport: %Transport{primary_interface: primary_interface}}),
    do: primary_interface

  @spec secondary_interface(t()) :: String.t() | nil
  def secondary_interface(%__MODULE__{
        transport: %Transport{secondary_interface: secondary_interface}
      }),
      do: secondary_interface

  @spec scan_stable_ms(t()) :: pos_integer()
  def scan_stable_ms(%__MODULE__{timing: %Timing{scan_stable_ms: value}}), do: value

  @spec scan_poll_ms(t()) :: pos_integer()
  def scan_poll_ms(%__MODULE__{timing: %Timing{scan_poll_ms: value}}), do: value

  @spec frame_timeout_ms(t()) :: pos_integer()
  def frame_timeout_ms(%__MODULE__{timing: %Timing{frame_timeout_ms: value}}), do: value

  @spec runtime_domains(t()) :: [keyword()]
  def runtime_domains(%__MODULE__{domains: domains}) do
    Enum.map(domains, &Domain.to_runtime/1)
  end

  defp default_slave(name, driver) do
    domain_id = @default_domain_id

    %SlaveConfig{
      name: name,
      driver: driver,
      target_state: :op,
      process_data: default_process_data(driver, domain_id),
      health_poll_ms: SlaveConfig.default_health_poll_ms(),
      config: %{},
      sync: nil
    }
  end

  defp default_process_data(driver, domain_id) do
    if signal_model_directions(%SlaveConfig{name: :default, driver: driver}) == %{} do
      :none
    else
      {:all, domain_id}
    end
  end

  defp signal_model_directions(%SlaveConfig{driver: driver}) when is_atom(driver) do
    if Code.ensure_loaded?(driver) and function_exported?(driver, :signal_model, 2) do
      driver
      |> apply(:signal_model, [%{}, []])
      |> Keyword.keys()
      |> Map.new(&{&1, :unknown})
    else
      %{}
    end
  rescue
    _error -> %{}
  end
end
