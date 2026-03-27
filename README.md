# Ogol

Ogol is a BEAM-native machine language that targets real `:gen_statem`
controller processes.

The authoring DSL is intended to be implemented with Spark. The runtime target
remains direct generated OTP code, not an interpreter.

Long-term authoring direction:

- canonical source remains the persisted artifact
- visual editors act as structured authoring surfaces over that source
- machines, hardware configs, and later EtherCAT driver definitions should all
  support source/visual toggling

Start here:

- [SPEC.md](/home/n0gg1n/Development/Work/opencode/ogol/SPEC.md)
- [MACHINE_AUTHORING_PLAN.md](/home/n0gg1n/Development/Work/opencode/ogol/MACHINE_AUTHORING_PLAN.md)

## HMI

The first Phoenix LiveView HMI slice is implemented. It currently provides:

- a runtime notification pipeline
- ETS-backed machine/topology/hardware snapshots
- a live overview page at `/`
- a machine detail page at `/machines/:machine_id`
- a hardware configuration page at `/hardware`

Run it with:

```bash
mix phx.server
```

Then open <http://localhost:4000>.

The hardware page is EtherCAT-first today. It reads runtime state and
diagnostics from the public `EtherCAT`, `EtherCAT.Diagnostics`, and
`EtherCAT.Provisioning` APIs, and lets you apply PREOP slave configuration from
the HMI without reaching into Ogol's machine-to-hardware mapping layer.

To add a machine to the HMI quickly in development, start one from `iex -S mix phx.server`.
Two compiled examples are available out of the box:

```elixir
{:ok, pid} = Ogol.Examples.SimpleHmiDemo.boot!()
demo = Ogol.Examples.EthercatSimulatorDemo.boot!()
line = Ogol.Examples.MultiChildLineDemo.boot!()
```

## Simulator Example

A runnable EtherCAT simulator example built from the stock `EL1809` and
`EL2809` drivers lives in
[ethercat_simulator_demo.ex](/home/n0gg1n/Development/Work/opencode/ogol/examples/ethercat_simulator_demo.ex).

Try it in IEx:

```elixir
iex -S mix
demo = Ogol.Examples.EthercatSimulatorDemo.boot!()
Ogol.request(demo.machine, :start_cycle)
Ogol.Examples.EthercatSimulatorDemo.snapshot()
Ogol.Examples.EthercatSimulatorDemo.set_closed(true)
flush()
:sys.get_state(demo.machine)
Ogol.Examples.EthercatSimulatorDemo.stop()
```

A minimal non-hardware demo for testing the HMI lives in
[simple_hmi_demo.ex](/home/n0gg1n/Development/Work/opencode/ogol/examples/simple_hmi_demo.ex).

A composite in-memory topology example with feeder, clamp, and inspector child
machines lives in
[multi_child_line_demo.ex](/home/n0gg1n/Development/Work/opencode/ogol/examples/multi_child_line_demo.ex).
It starts a generated parent `Topology` plus multiple child machine brains:

```elixir
iex -S mix phx.server
line = Ogol.Examples.MultiChildLineDemo.boot!(signal_sink: self())
Ogol.Examples.MultiChildLineDemo.request(line, :start_cycle)
flush()
:sys.get_state(line.brain)
Ogol.Examples.MultiChildLineDemo.request(line, :release_line)
Ogol.Examples.MultiChildLineDemo.stop(line)
```

`Ogol.Hardware.EtherCAT.Ref` derives observed input signals from `fact_map` by
default. You can also opt into extra observed signals with
`observe_signals: [...]` and public driver/runtime notices with
`observe_events?: true`.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `ogol` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ogol, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/ogol>.
