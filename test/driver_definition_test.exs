defmodule Ogol.Studio.DriverDefinitionTest do
  use ExUnit.Case, async: false

  alias Ogol.Studio.DriverDefinition

  test "cast_model validates a constrained digital output driver" do
    assert {:ok, model} =
             DriverDefinition.cast_model(%{
               "id" => "packaging_outputs",
               "module_name" => "Ogol.Generated.Drivers.PackagingOutputs",
               "label" => "Packaging Outputs",
               "device_kind" => "digital_output",
               "vendor_id" => "2",
               "product_code" => "184103122",
               "revision" => "any",
               "channel_count" => "2",
               "channels" => %{
                 "0" => %{"name" => "outfeed_ready", "invert?" => "false", "default" => "true"},
                 "1" => %{"name" => "pusher_extend", "invert?" => "true", "default" => "false"}
               }
             })

    assert model.id == "packaging_outputs"
    assert model.device_kind == :digital_output
    assert Enum.map(model.channels, & &1.name) == ["outfeed_ready", "pusher_extend"]
  end

  test "generated source round-trips through the supported parser" do
    model = DriverDefinition.default_model("packaging_outputs")
    module = DriverDefinition.module_from_name!(model.module_name)
    source = DriverDefinition.to_source(module, model)

    assert {:ok, parsed} = DriverDefinition.from_source(source)
    assert parsed == model
  end

  test "source with extra handwritten code falls back to partial" do
    model = DriverDefinition.default_model("packaging_outputs")
    module = DriverDefinition.module_from_name!(model.module_name)

    source =
      DriverDefinition.to_source(module, model)
      |> String.replace("\nend\n", "\n\n  def extra, do: :ok\nend\n")

    assert {:partial, parsed, diagnostics} = DriverDefinition.from_source(source)
    assert parsed.id == model.id
    assert diagnostics != []
  end

  test "unsupported source reports unsupported" do
    assert :unsupported =
             DriverDefinition.from_source("""
             defmodule PlainOldElixir do
               def hello, do: :world
             end
             """)
  end
end
