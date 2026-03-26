# Ogol

Ogol is a BEAM-native machine language that targets real `:gen_statem`
controller processes.

The authoring DSL is intended to be implemented with Spark. The runtime target
remains direct generated OTP code, not an interpreter.

Start here:

- [SPEC.md](/home/n0gg1n/Development/Work/opencode/ogol/SPEC.md)
- [IMPLEMENTATION_PLAN.md](/home/n0gg1n/Development/Work/opencode/ogol/IMPLEMENTATION_PLAN.md)

## Simulator Example

A runnable EtherCAT simulator example built from the stock `EL1809` and
`EL2809` drivers lives in
[ethercat_simulator_demo.ex](/home/n0gg1n/Development/Work/opencode/ogol/lib/ogol/examples/ethercat_simulator_demo.ex).

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
