defmodule Ogol.Machine.SkillFormTest do
  use ExUnit.Case, async: true

  alias Ogol.Machine.SkillForm
  alias Ogol.Machine.Skill

  defmodule TypedSkillMachine do
    use Ogol.Machine

    boundary do
      request(:configure_schedule,
        args: [
          interval_ms: :integer,
          duration_ms: [type: :integer, summary: "Watering duration"]
        ]
      )
    end

    states do
      state :idle do
        initial?(true)
      end
    end
  end

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

  test "required numeric args stay required instead of silently defaulting to zero" do
    skill = %Skill{
      name: :configure_schedule,
      kind: :request,
      args: [%{name: :interval_ms, type: :integer}]
    }

    assert {:error, errors} = SkillForm.cast(skill, %{})
    assert Enum.any?(errors, &String.contains?(&1, "interval ms"))
  end

  test "compiled request skills expose typed args declared in the DSL" do
    assert [
             %Skill{
               name: :configure_schedule,
               kind: :request,
               args: [
                 %{name: :interval_ms, type: :integer},
                 %{name: :duration_ms, type: :integer, summary: "Watering duration"}
               ]
             }
           ] = TypedSkillMachine.skills()
  end
end
