defmodule Ogol.RevisionFile.Examples.SequenceStarterCell do
  @revision %{
    kind: :ogol_revision,
    format: 2,
    app_id: "examples",
    revision: "sequence_starter_cell",
    title: "Sequence Starter Cell Example",
    exported_at: "2026-03-30T00:00:00Z",
    sources: [
      %{
        kind: :machine,
        id: "clamp",
        module: Ogol.Generated.Machines.Clamp,
        digest: "59baffb919482a7d938e6fb709b185862c0e4957fa5f47395b541e76ffe162cd",
        title: "Clamp station"
      },
      %{
        kind: :machine,
        id: "feeder",
        module: Ogol.Generated.Machines.Feeder,
        digest: "130da68d774a9a6a604ff66de2c06e6f5daaabcc66d2d954ad9d2fca0ce74a22",
        title: "Part feeder"
      },
      %{
        kind: :machine,
        id: "inspector",
        module: Ogol.Generated.Machines.Inspector,
        digest: "132ae0ff7fca4216fccbcff4b08d4b8c3731b0fd5a5bdecc142078655c7c79dc",
        title: "Inspection station"
      },
      %{
        kind: :sequence,
        id: "sequence_starter_auto",
        module: Ogol.Generated.Sequences.SequenceStarterAuto,
        digest: "a59534c5c6c4043a4c5d6f2a67b160bcfd4f9a291a83291bd03efd55cd4fa273",
        title: "Starter sequence over feeder, clamp, and inspector contracts"
      },
      %{
        kind: :topology,
        id: "sequence_starter_cell",
        module: Ogol.Generated.Topologies.SequenceStarterCell,
        digest: "a8c02cfbdf5a693ef7d1319f7d6e0acc0d7b81a106295b7c8ae070f99ddb1f2c",
        title: "Sequence starter cell topology"
      }
    ]
  }
  def manifest do
    @revision
  end
end

defmodule Ogol.Generated.Machines.Clamp do
  use Ogol.Machine

  machine do
    name(:clamp)
    meaning("Clamp station")
  end

  boundary do
    request(:close)
    request(:open)
    fact(:closed?, :boolean, default: false, public?: true)
    signal(:closed)
  end

  states do
    state :open do
      initial?(true)
      set_fact(:closed?, false)
    end

    state :closed do
      set_fact(:closed?, true)
      signal(:closed)
    end
  end

  transitions do
    transition :open, :closed do
      on({:request, :close})
      reply(:ok)
    end

    transition :open, :open do
      on({:request, :open})
      reply(:ok)
    end

    transition :closed, :open do
      on({:request, :open})
      reply(:ok)
    end

    transition :closed, :closed do
      on({:request, :close})
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Machines.Feeder do
  use Ogol.Machine

  machine do
    name(:feeder)
    meaning("Part feeder")
  end

  boundary do
    request(:feed_part)
    request(:reset)
    fact(:part_staged?, :boolean, default: false, public?: true)
    signal(:part_staged)
  end

  states do
    state :idle do
      initial?(true)
      set_fact(:part_staged?, false)
    end

    state :staged do
      set_fact(:part_staged?, true)
      signal(:part_staged)
    end
  end

  transitions do
    transition :idle, :staged do
      on({:request, :feed_part})
      reply(:ok)
    end

    transition :idle, :idle do
      on({:request, :reset})
      reply(:ok)
    end

    transition :staged, :idle do
      on({:request, :reset})
      reply(:ok)
    end

    transition :staged, :staged do
      on({:request, :feed_part})
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Machines.Inspector do
  use Ogol.Machine

  machine do
    name(:inspector)
    meaning("Inspection station")
  end

  boundary do
    request(:inspect)
    request(:reject)
    request(:reset)
    fact(:ready?, :boolean, default: true, public?: true)
    fact(:passed?, :boolean, default: false, public?: true)
    fact(:rejected?, :boolean, default: false, public?: true)
    signal(:passed)
    signal(:rejected)
  end

  states do
    state :ready do
      initial?(true)
      set_fact(:ready?, true)
      set_fact(:passed?, false)
      set_fact(:rejected?, false)
    end

    state :passed do
      set_fact(:ready?, false)
      set_fact(:passed?, true)
      set_fact(:rejected?, false)
      signal(:passed)
    end

    state :rejected do
      set_fact(:ready?, false)
      set_fact(:passed?, false)
      set_fact(:rejected?, true)
      signal(:rejected)
    end
  end

  transitions do
    transition :ready, :passed do
      on({:request, :inspect})
      reply(:ok)
    end

    transition :ready, :rejected do
      on({:request, :reject})
      reply(:ok)
    end

    transition :ready, :ready do
      on({:request, :reset})
      reply(:ok)
    end

    transition :passed, :ready do
      on({:request, :reset})
      reply(:ok)
    end

    transition :rejected, :ready do
      on({:request, :reset})
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Sequences.SequenceStarterAuto do
  use Ogol.Sequence

  alias Ogol.Sequence.Expr
  alias Ogol.Sequence.Ref

  sequence do
    name(:sequence_starter_auto)
    topology(Ogol.Generated.Topologies.SequenceStarterCell)
    meaning("Starter sequence over feeder, clamp, and inspector contracts")

    proc :stage_part do
      do_skill(:feeder, :feed_part)
      wait(Ref.status(:feeder, :part_staged?), timeout: 2_000, fail: "feeder did not stage a part")
    end

    proc :secure_part do
      do_skill(:clamp, :close)
      wait(Ref.status(:clamp, :closed?), timeout: 2_000, fail: "clamp did not close")
    end

    proc :inspect_part do
      do_skill(:inspector, :inspect)
      wait(Ref.status(:inspector, :passed?), timeout: 2_000, fail: "inspection did not pass")
    end

    proc :reset_cell do
      do_skill(:inspector, :reset)
      wait(Ref.status(:inspector, :ready?), timeout: 2_000, fail: "inspection did not reset")
      do_skill(:clamp, :open)
      wait(Expr.not_expr(Ref.status(:clamp, :closed?)), timeout: 2_000, fail: "clamp did not open")
      do_skill(:feeder, :reset)
      wait(Expr.not_expr(Ref.status(:feeder, :part_staged?)), timeout: 2_000, fail: "feeder did not clear")
    end

    run(:stage_part)
    run(:secure_part)
    run(:inspect_part)
    run(:reset_cell)
  end
end

defmodule Ogol.Generated.Topologies.SequenceStarterCell do
  use Ogol.Topology

  topology do
    root(:feeder)
    strategy(:one_for_one)
    meaning("Sequence starter cell topology")
  end

  machines do
    machine(:feeder, Ogol.Generated.Machines.Feeder,
      restart: :permanent,
      meaning: "Part feeder"
    )

    machine(:clamp, Ogol.Generated.Machines.Clamp,
      restart: :permanent,
      meaning: "Clamp station"
    )

    machine(:inspector, Ogol.Generated.Machines.Inspector,
      restart: :permanent,
      meaning: "Inspection station"
    )
  end

  observations do
  end
end
