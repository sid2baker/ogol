defmodule Ogol.Studio.Definition do
  @moduledoc false

  @callback schema() :: map()
  @callback cast_model(map()) :: {:ok, map()} | {:error, term()}
  @callback to_source(module(), map()) :: String.t()
  @callback from_source(String.t()) ::
              {:ok, map()} | {:partial, map(), [term()]} | :unsupported
end
