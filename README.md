# Ogol

Ogol is a BEAM-native machine language that targets real `:gen_statem`
controller processes.

The intended public machine model is:

- `skills`
- `status`
- `signals`

with `invoke/4` as the canonical composition primitive.

Low-level request/event delivery remains internal runtime plumbing rather than
the long-term public API story.

## Public Machine Interface

Publicly, a machine exposes:

- `skills`
- `status`
- `signals`

Use:

- `Ogol.skills(target)`
- `Ogol.skill(target, name)`
- `Ogol.invoke(target, name, args \\ %{}, opts \\ [])`
- `Ogol.status(target)`

Signals remain observable runtime notifications and are not invokable.

### Migration Note

This is an intentional abstraction cleanup.

- replace request-first and event-first public usage with `invoke/4`
- treat `Ogol.request/5`, `Ogol.event/4`, and `Ogol.hardware_event/4` as
  internal runtime plumbing
- stop describing composition publicly in terms of child-centered delivery
  primitives

The authoring DSL is intended to be implemented with Spark. The runtime target
remains direct generated OTP code, not an interpreter.

Long-term authoring direction:

- canonical source remains the persisted artifact
- visual editors act as structured authoring surfaces over that source
- machines, hardware configs, and later EtherCAT driver definitions should all
  support source/visual toggling

Start here:

- [SPEC.md](/home/n0gg1n/Development/Work/opencode/ogol/SPEC.md)
- [HMI_ROADMAP.md](/home/n0gg1n/Development/Work/opencode/ogol/HMI_ROADMAP.md)
- [STUDIO_GENERATED_MODULES_PLAN.md](/home/n0gg1n/Development/Work/opencode/ogol/STUDIO_GENERATED_MODULES_PLAN.md)
- [BUNDLE_FORMAT.md](/home/n0gg1n/Development/Work/opencode/ogol/BUNDLE_FORMAT.md)
- [HARDWARE_CONTEXT_MODEL.md](/home/n0gg1n/Development/Work/opencode/ogol/HARDWARE_CONTEXT_MODEL.md)
- [HARDWARE_WORKFLOWS.md](/home/n0gg1n/Development/Work/opencode/ogol/HARDWARE_WORKFLOWS.md)

## HMI

The first Phoenix LiveView HMI slice is implemented. It currently provides:

- a runtime notification pipeline
- ETS-backed machine/topology/hardware snapshots
- an assigned runtime surface at `/ops`
- a supervisor/fallback surface launcher at `/ops/hmis`
- a machine detail page at `/ops/machines/:machine_id`
- a `Studio` area rooted at `/studio`
- a real HMI Studio workspace at `/studio/hmis`
  - canonical HMI DSL
  - visual / DSL / split editing
  - save draft / compile / deploy / assign panel flow
  - multiple runtime surface artifacts
- a first Studio artifact at `/studio/hardware`

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
Three compiled examples are available out of the box:

```elixir
{:ok, pid} = Ogol.Examples.SimpleHmiDemo.boot!()
demo = Ogol.Examples.EthercatSimulatorDemo.boot!()
line = Ogol.Examples.CompositeLineDemo.boot!()
deep = Ogol.Examples.DeepDependencyLineDemo.boot!()

Ogol.skills(pid)
Ogol.status(pid)
{:ok, :ok} = Ogol.invoke(pid, :start)
```

## Simulator Example

A runnable EtherCAT simulator example built from the stock `EL1809` and
`EL2809` drivers lives in
[ethercat_simulator_demo.ex](/home/n0gg1n/Development/Work/opencode/ogol/examples/ethercat_simulator_demo.ex).

Try it in IEx:

```elixir
iex -S mix
demo = Ogol.Examples.EthercatSimulatorDemo.boot!()
{:ok, :ok} = Ogol.invoke(demo.machine, :start_cycle)
Ogol.status(demo.machine)
Ogol.Examples.EthercatSimulatorDemo.set_closed(true)
flush()
Ogol.Examples.EthercatSimulatorDemo.snapshot()
Ogol.Examples.EthercatSimulatorDemo.stop()
```

A minimal non-hardware demo for testing the HMI lives in
[simple_hmi_demo.ex](/home/n0gg1n/Development/Work/opencode/ogol/examples/simple_hmi_demo.ex).

A composite in-memory topology example with feeder, clamp, and inspector
machine processes lives in
[composite_line_demo.ex](/home/n0gg1n/Development/Work/opencode/ogol/examples/composite_line_demo.ex).
It starts an explicit topology module that deploys several machine brains and
wires their observations:

```elixir
iex -S mix phx.server
line = Ogol.Examples.CompositeLineDemo.boot!(signal_sink: self())
{:ok, :ok} = Ogol.Examples.CompositeLineDemo.invoke(line, :start_cycle)
flush()
Ogol.status(line.topology)
{:ok, :ok} = Ogol.Examples.CompositeLineDemo.invoke(line, :release_line)
Ogol.Examples.CompositeLineDemo.stop(line)
```

A deeper dependency-graph example with repeated machine modules lives in
[deep_dependency_line_demo.ex](/home/n0gg1n/Development/Work/opencode/ogol/examples/deep_dependency_line_demo.ex).
It keeps topology flat while the semantic dependency graph is deeper:

```elixir
iex -S mix phx.server
demo = Ogol.Examples.DeepDependencyLineDemo.boot!(signal_sink: self())
{:ok, :ok} = Ogol.Examples.DeepDependencyLineDemo.invoke(demo, :start_cycle)
Ogol.status(:deep_dependency_line)
Ogol.status(:pair_station)
Ogol.status(:left_clamp)
Ogol.status(:right_clamp)
Ogol.Examples.DeepDependencyLineDemo.stop(demo)
```

That example also shows explicit status observation with
`observe_status(:pair_station, :paired?, as: :station_ready)`.

Topology is intentionally flat on a node:

- one active topology per node
- no nested/deep topology modules
- multiple named instances of the same machine module are allowed inside that
  topology

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
