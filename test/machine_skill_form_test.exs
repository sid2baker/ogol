defmodule Ogol.Machine.SkillFormTest do
  use ExUnit.Case, async: true

  alias Ogol.Machine.SkillForm
  alias Ogol.Machine.Skill

  test "skills without args cast to an empty payload" do
    skill = %Skill{name: :start, kind: :request}

    assert {:ok, %{}} = SkillForm.cast(skill, %{})
    assert SkillForm.fields(skill) == []
  end

  test "typed skill fields cast through Zoi" do
    skill = %Skill{
      name: :configure,
      kind: :request,
      args: [
        %{name: :setpoint, type: :float, summary: "Desired target", default: 1.5},
        %{name: :enabled, type: :boolean, default: false},
        %{name: :mode, type: {:enum, ["auto", "manual"]}, default: "auto"}
      ]
    }

    assert [%{name: :setpoint}, %{name: :enabled}, %{name: :mode}] = SkillForm.fields(skill)

    assert {:ok, %{setpoint: 2.75, enabled: true, mode: "manual"}} =
             SkillForm.cast(skill, %{
               "setpoint" => "2.75",
               "enabled" => "true",
               "mode" => "manual"
             })
  end
end
