defmodule Ogol.Studio.Cell do
  @moduledoc """
  Shared Studio Cell derivation contract.

  A Studio Cell implementation derives UI presentation from a small set of
  source-backed facts. The facts are the truth-facing inputs. The derived value
  is the presentation-facing output.

  Invariants:

  - `:source` is always a valid view
  - `:source` is always available
  - `selected_view` must always be one of the returned views
  - if `requested_view` is unavailable, selection falls back to `:source`
  - `lifecycle_state` is optional and cell-defined; it is not a universal
    Studio taxonomy
  """

  defmodule Model do
    @moduledoc false

    @typedoc """
    Recovery state for the visual model.

    `:unavailable` means no recovered model is currently available. It does not
    promise why.
    """
    @type recovery :: :full | :partial | :unsupported | :unavailable

    @type t :: %__MODULE__{
            value: map() | nil,
            recovery: recovery(),
            diagnostics: [String.t()]
          }

    defstruct [:value, recovery: :unavailable, diagnostics: []]
  end

  defmodule Issue do
    @moduledoc false

    @typedoc """
    A structured fact about mismatch, degradation, or failure.

    `detail` is opaque payload for the cell implementation. It is not the UI
    notice itself.
    """
    @type t :: %__MODULE__{
            id: atom(),
            detail: String.t() | map() | nil
          }

    defstruct [:id, :detail]
  end

  defmodule Facts do
    @moduledoc false

    @type t :: %__MODULE__{
            artifact_id: String.t() | nil,
            source: String.t(),
            model: Model.t(),
            lifecycle_state: atom() | nil,
            desired_state: atom() | nil,
            observed_state: atom() | nil,
            requested_view: atom(),
            issues: [Issue.t()]
          }

    defstruct [
      :artifact_id,
      :source,
      :lifecycle_state,
      :desired_state,
      :observed_state,
      requested_view: :source,
      model: %Model{},
      issues: []
    ]
  end

  defmodule Action do
    @moduledoc false

    @type t :: %__MODULE__{
            id: atom(),
            label: String.t(),
            variant: :primary | :secondary | :danger,
            enabled?: boolean(),
            disabled_reason: String.t() | nil
          }

    defstruct [:id, :label, :disabled_reason, variant: :secondary, enabled?: true]
  end

  defmodule View do
    @moduledoc false

    @type t :: %__MODULE__{
            id: atom(),
            label: String.t(),
            available?: boolean()
          }

    defstruct [:id, :label, available?: true]
  end

  defmodule Notice do
    @moduledoc false

    @type tone :: :info | :warning | :error

    @type t :: %__MODULE__{
            tone: tone(),
            title: String.t(),
            message: String.t() | nil
          }

    defstruct [:title, :message, tone: :info]
  end

  defmodule Derived do
    @moduledoc false

    @type t :: %__MODULE__{
            selected_view: atom(),
            notice: Notice.t() | nil,
            actions: [Action.t()],
            views: [View.t()]
          }

    defstruct selected_view: :source, notice: nil, actions: [], views: []
  end

  @spec derive(module(), Facts.t()) :: Derived.t()
  def derive(module, %Facts{} = facts) when is_atom(module) do
    module.derive(facts)
    |> finalize(facts)
  end

  @spec finalize(Derived.t(), Facts.t()) :: Derived.t()
  def finalize(%Derived{} = derived, %Facts{} = facts) do
    {selected_view, views} =
      resolve_views(facts.requested_view || derived.selected_view, derived.views)

    %Derived{derived | selected_view: selected_view, views: views}
  end

  @spec resolve_views(atom(), [View.t()]) :: {atom(), [View.t()]}
  def resolve_views(requested_view, views) do
    views = ensure_source_view(views)

    selected_view =
      if Enum.any?(views, &(&1.id == requested_view and &1.available?)) do
        requested_view
      else
        :source
      end

    {selected_view, views}
  end

  defp ensure_source_view(views) do
    if Enum.any?(views, &(&1.id == :source)) do
      Enum.map(views, fn
        %View{id: :source} = view -> %View{view | available?: true}
        view -> view
      end)
    else
      views ++ [%View{id: :source, label: "Source", available?: true}]
    end
  end

  @callback derive(Facts.t()) :: Derived.t()
end
