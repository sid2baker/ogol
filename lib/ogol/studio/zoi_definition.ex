defmodule Ogol.Studio.ZoiDefinition do
  @moduledoc false

  @spec cast_model(map(), term()) :: {:ok, map()} | {:error, [term()]}
  def cast_model(params, schema) when is_map(params) do
    context = Zoi.Form.parse(schema, params, [])

    if context.valid? do
      {:ok, context.parsed}
    else
      {:error, context.errors}
    end
  end
end
