defmodule Ogol.Studio.Cell do
  @moduledoc """
  Shared Studio Cell derivation contract.

  A Studio Cell is the UI for one bounded, source-backed artifact.

  This module owns the shared state and derivation model behind that idea. It
  is intentionally small. It is not a universal transition engine or a giant
  enum framework.

  The first-principles model is:

  - source is authoritative
  - the user has intent
  - the outside world has observed reality
  - the UI should show the most honest projection it can

  ## Facts vs Derived UI

  The shared contract is split into two layers:

  - `Facts`
    - truth-facing input
  - `Derived`
    - presentation-facing output

  `Facts` contains the small set of shared core facts:

  - `artifact_id`
  - `source`
  - `model`
  - `lifecycle_state`
  - `desired_state`
  - `observed_state`
  - `requested_view`
  - `issues`

  `Derived` contains the shared UI output:

  - `selected_view`
  - `notice`
  - `controls`
  - `views`

  Supporting shared structs are:

  - `Model`
  - `Issue`
  - `Control`
  - `View`
  - `Notice`

  ## Meaning of the Facts

  `source` is the durable authority for the artifact. Visual editing must never
  become a second truth.

  `model` is a parsed or recovered representation of source, when available.
  It exists to support visual editing and honest degradation.

  `desired_state` describes what the source or accepted user transition
  intends.

  `observed_state` describes what the external world reports now.

  `issues` are explicit facts that explain mismatch, degradation, or failure.
  They are not UI labels.

  `lifecycle_state` is optional and cell-defined. For source-backed code cells,
  this module provides a small shared lifecycle helper built around source and
  compiled digests:

  - `:uncompiled`
  - `:compiled`
  - `:stale`
  - `:compile_error`

  ## Views vs Presentation

  A view is a user-selectable representation such as `:source`, `:visual`, or
  `:runtime`.

  A presentation is the concrete rendering inside the selected view for the
  current state.

  For example, a simulator cell may expose two views:

  - `:visual`
  - `:source`

  while still having multiple presentations:

  - stopped visual editor
  - running visual runtime summary
  - source

  ## Shared Invariants

  The shared contract enforces a small set of hard rules:

  - `:source` is always a valid view
  - `:source` is always available
  - `selected_view` must always be one of the returned views
  - if `requested_view` is unavailable, selection falls back to `:source`

  Callers should use `derive/2`, not the raw callback directly. `derive/2`
  finalizes the result and enforces those invariants.

  ## Boundary

  This module is responsible for:

  - defining the shared fact shape
  - defining the shared derived UI shape
  - normalizing view selection
  - enforcing source-first view invariants

  Concrete cell modules are responsible for:

  - deciding which desired states matter
  - deciding which observed states matter
  - deciding which issues can arise
  - deriving controls, notices, and views for their artifact

  That keeps the framework small while still preventing local UI improvisation.
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

  @type source_lifecycle :: :uncompiled | :compiled | :stale | :compile_error

  defmodule Control do
    @moduledoc false

    @type action :: Ogol.Session.Data.action() | nil

    @type t :: %__MODULE__{
            id: atom(),
            label: String.t(),
            variant: :primary | :secondary | :danger,
            enabled?: boolean(),
            disabled_reason: String.t() | nil,
            action: action()
          }

    defstruct [:id, :label, :disabled_reason, :action, variant: :secondary, enabled?: true]
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
            controls: [Control.t()],
            views: [View.t()]
          }

    defstruct selected_view: :source, notice: nil, controls: [], views: []
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

  @spec control_for_transition(Derived.t() | [Control.t()], atom() | String.t()) ::
          Control.t() | nil
  def control_for_transition(%Derived{controls: controls}, transition) do
    control_for_transition(controls, transition)
  end

  def control_for_transition(controls, transition) when is_list(controls) do
    Enum.find(controls, &control_matches_transition?(&1, transition))
  end

  defp control_matches_transition?(%Control{id: id}, transition) when is_atom(transition) do
    id == transition
  end

  defp control_matches_transition?(%Control{id: id}, transition) when is_binary(transition) do
    to_string(id) == transition
  end

  defp control_matches_transition?(_control, _transition), do: false

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

  @spec source_lifecycle(String.t(), String.t() | nil, boolean() | [term()]) :: source_lifecycle()
  def source_lifecycle(current_source_digest, compiled_source_digest, compile_error?)

  def source_lifecycle(current_source_digest, compiled_source_digest, diagnostics)
      when is_list(diagnostics) do
    source_lifecycle(current_source_digest, compiled_source_digest, diagnostics != [])
  end

  def source_lifecycle(_current_source_digest, _compiled_source_digest, true), do: :compile_error

  def source_lifecycle(current_source_digest, compiled_source_digest, false)
      when is_binary(current_source_digest) and is_binary(compiled_source_digest) do
    if current_source_digest == compiled_source_digest do
      :compiled
    else
      :stale
    end
  end

  def source_lifecycle(_current_source_digest, _compiled_source_digest, false), do: :uncompiled

  @spec source_stale?(String.t(), String.t() | nil) :: boolean()
  def source_stale?(current_source_digest, compiled_source_digest)
      when is_binary(current_source_digest) and is_binary(compiled_source_digest) do
    current_source_digest != compiled_source_digest
  end

  def source_stale?(_current_source_digest, _compiled_source_digest), do: false

  @callback derive(Facts.t()) :: Derived.t()
end
