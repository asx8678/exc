defmodule CodePuppyControl.Agent.ResponseValidatorTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Agent.ResponseValidator

  defmodule SimpleSchema do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:summary, :string)
      field(:confidence, :float)
    end

    def changeset(struct, params) do
      struct
      |> cast(params, [:summary, :confidence])
      |> validate_required([:summary])
      |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    end
  end

  defmodule NestedSchema do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:plan_name, :string)

      embeds_many :steps, Step do
        field(:action, :string)
        field(:file_path, :string)
      end
    end

    def changeset(struct, params) do
      struct
      |> cast(params, [:plan_name])
      |> cast_embed(:steps, with: &step_changeset/2)
      |> validate_required([:plan_name])
    end

    defp step_changeset(step, params) do
      step
      |> cast(params, [:action, :file_path])
      |> validate_required([:action])
    end
  end

  describe "validate/2 with nil schema" do
    test "returns response unchanged" do
      response = %{text: "Just some text", tool_calls: []}
      assert {:ok, ^response} = ResponseValidator.validate(response, nil)
    end
  end

  describe "validate/2 with schema — success" do
    test "validates pure JSON text" do
      response = %{text: ~s({"summary": "Refactor", "confidence": 0.85}), tool_calls: []}
      assert {:ok, struct} = ResponseValidator.validate(response, SimpleSchema)
      assert %SimpleSchema{summary: "Refactor", confidence: 0.85} = struct
    end

    test "validates JSON in code fence" do
      text = "```json\n{\"summary\": \"Test\", \"confidence\": 0.5}\n```"
      response = %{text: text, tool_calls: []}

      assert {:ok, %SimpleSchema{summary: "Test"}} =
               ResponseValidator.validate(response, SimpleSchema)
    end

    test "validates JSON in prose" do
      text = "Result is {\"summary\": \"Debug\"} here."
      response = %{text: text, tool_calls: []}

      assert {:ok, %SimpleSchema{summary: "Debug"}} =
               ResponseValidator.validate(response, SimpleSchema)
    end

    test "validates nested schema" do
      json =
        ~s({"plan_name": "Migrate", "steps": [{"action": "Create", "file_path": "lib/a.ex"}]})

      response = %{text: json, tool_calls: []}
      assert {:ok, struct} = ResponseValidator.validate(response, NestedSchema)
      assert struct.plan_name == "Migrate"
      assert length(struct.steps) == 1
    end
  end

  describe "validate/2 — validation errors" do
    test "returns errors when required field missing" do
      response = %{text: ~s({"confidence": 0.5}), tool_calls: []}
      assert {:error, errors} = ResponseValidator.validate(response, SimpleSchema)
      assert errors[:summary] == ["can't be blank"]
    end

    test "returns errors for invalid number" do
      response = %{text: ~s({"summary": "X", "confidence": 2.5}), tool_calls: []}
      assert {:error, errors} = ResponseValidator.validate(response, SimpleSchema)
      assert errors[:confidence] != nil
    end
  end

  describe "validate/2 — malformed JSON" do
    test "returns error for invalid JSON" do
      response = %{text: "not json", tool_calls: []}
      assert {:error, %{json: _}} = ResponseValidator.validate(response, SimpleSchema)
    end

    test "returns error for array JSON" do
      response = %{text: "[1,2,3]", tool_calls: []}
      assert {:error, %{json: _}} = ResponseValidator.validate(response, SimpleSchema)
    end

    test "returns error for nil text" do
      response = %{text: nil, tool_calls: []}
      assert {:error, %{json: _}} = ResponseValidator.validate(response, SimpleSchema)
    end
  end

  describe "extract_json/1" do
    test "parses valid JSON" do
      assert {:ok, %{"a" => 1}} = ResponseValidator.extract_json(~s({"a": 1}))
    end

    test "returns error for array" do
      assert {:error, %{json: _}} = ResponseValidator.extract_json("[1]")
    end
  end

  describe "collect_errors/1" do
    test "returns empty map for valid changeset" do
      changeset = SimpleSchema.changeset(%SimpleSchema{}, %{"summary" => "OK"})
      assert ResponseValidator.collect_errors(changeset) == %{}
    end

    test "returns errors for invalid changeset" do
      changeset = SimpleSchema.changeset(%SimpleSchema{}, %{})
      assert %{summary: ["can't be blank"]} = ResponseValidator.collect_errors(changeset)
    end
  end
end
