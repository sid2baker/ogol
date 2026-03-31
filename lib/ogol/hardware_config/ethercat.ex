defmodule Ogol.HardwareConfig.EtherCAT do
  @moduledoc false

  alias EtherCAT.Slave.Config, as: SlaveConfig

  defmodule Transport do
    @moduledoc false

    @enforce_keys [:mode]
    defstruct [:mode, :bind_ip, :simulator_ip, :primary_interface, :secondary_interface]

    @type mode_t :: :udp | :raw | :redundant

    @type t :: %__MODULE__{
            mode: mode_t(),
            bind_ip: :inet.ip_address() | nil,
            simulator_ip: :inet.ip_address() | nil,
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

  @enforce_keys [:transport, :timing, :domains, :slaves]
  defstruct [:transport, :timing, domains: [], slaves: []]

  @type t :: %__MODULE__{
          transport: Transport.t(),
          timing: Timing.t(),
          domains: [Domain.t()],
          slaves: [SlaveConfig.t()]
        }

  @spec transport_mode(t()) :: Transport.mode_t()
  def transport_mode(%__MODULE__{transport: %Transport{mode: mode}}), do: mode

  @spec bind_ip(t()) :: :inet.ip_address() | nil
  def bind_ip(%__MODULE__{transport: %Transport{bind_ip: bind_ip}}), do: bind_ip

  @spec simulator_ip(t()) :: :inet.ip_address() | nil
  def simulator_ip(%__MODULE__{transport: %Transport{simulator_ip: simulator_ip}}),
    do: simulator_ip

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
end
