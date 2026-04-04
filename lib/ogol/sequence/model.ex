defmodule Ogol.Sequence.Model do
  @moduledoc false

  @type t :: %__MODULE__{
          module: module() | nil,
          sequence: struct() | nil
        }

  defstruct [
    :module,
    :sequence
  ]

  defmodule SequenceDefinition do
    @moduledoc false

    defstruct [
      :id,
      :name,
      :topology,
      :meaning,
      root: [],
      invariants: [],
      procedures: []
    ]
  end

  defmodule ProcedureDefinition do
    @moduledoc false

    defstruct [
      :id,
      :name,
      :meaning,
      body: []
    ]
  end

  defmodule Invariant do
    @moduledoc false

    defstruct [
      :id,
      :condition,
      :meaning
    ]
  end

  defmodule Step do
    @moduledoc false

    defstruct [
      :id,
      :kind,
      :duration_ms,
      :target,
      :condition,
      :procedure,
      :message,
      :guard,
      :timeout,
      :on_timeout,
      :body,
      :then_body,
      :else_body,
      projection: %{}
    ]
  end

  defmodule TimeoutSpec do
    @moduledoc false

    defstruct [
      :kind,
      :duration_ms
    ]
  end

  defmodule Failure do
    @moduledoc false

    defstruct [
      :kind,
      :message
    ]
  end

  defmodule SkillRef do
    @moduledoc false

    defstruct [:machine, :skill]
  end

  defmodule StatusRef do
    @moduledoc false

    defstruct [:machine, :item]
  end

  defmodule SignalRef do
    @moduledoc false

    defstruct [:machine, :item]
  end

  defmodule TopologyRef do
    @moduledoc false

    defstruct [:scope, :item]
  end

  defmodule Expr.Not do
    @moduledoc false

    defstruct [:expr]
  end

  defmodule Expr.And do
    @moduledoc false

    defstruct [:left, :right]
  end

  defmodule Expr.Or do
    @moduledoc false

    defstruct [:left, :right]
  end

  defmodule Expr.Compare do
    @moduledoc false

    defstruct [:op, :left, :right]
  end
end
