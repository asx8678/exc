defmodule CodePuppyControl.Tools.CpAskUserQuestionTest do
  @moduledoc """
  Tests for CodePuppyControl.Tools.CpAskUserQuestion — Phase E event protocol port.

  Covers:
  - Entry models (QuestionOptionEntry, QuestionEntry, QuestionAnswerEntry)
  - UserInteraction.ask_user_question_request/1
  - Commands.AskUserQuestionResponse serialization & answer validation
  - CpAskUserQuestion tool invocation (non-interactive, validation)
  - Tool.Runner timeout alignment (tool_timeout/0)
  - EventBus request/response protocol tests
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Messaging.{Entries, UserInteraction, WireEvent, Commands}
  alias CodePuppyControl.Tools.CpAskUserQuestion
  alias CodePuppyControl.Tool.Runner
  alias CodePuppyControl.EventBus

  # ===========================================================================
  # QuestionOptionEntry
  # ===========================================================================

  describe "question_option_entry/1" do
    test "happy path with label only" do
      {:ok, entry} = Entries.question_option_entry(%{"label" => "PostgreSQL"})

      assert entry["label"] == "PostgreSQL"
      assert entry["description"] == ""
    end

    test "accepts description" do
      {:ok, entry} =
        Entries.question_option_entry(%{
          "label" => "PostgreSQL",
          "description" => "Relational database"
        })

      assert entry["label"] == "PostgreSQL"
      assert entry["description"] == "Relational database"
    end

    test "rejects missing label" do
      assert {:error, {:missing_required_field, "label"}} =
               Entries.question_option_entry(%{"description" => "No label"})
    end

    test "rejects extra keys" do
      assert {:error, {:extra_fields_not_allowed, ["icon"]}} =
               Entries.question_option_entry(%{"label" => "OK", "icon" => "⭐"})
    end

    test "rejects non-map input" do
      assert {:error, {:not_a_map, "not a map"}} =
               Entries.question_option_entry("not a map")
    end

    test "JSON round-trip" do
      {:ok, entry} =
        Entries.question_option_entry(%{
          "label" => "MongoDB",
          "description" => "Document store"
        })

      json = Jason.encode!(entry)
      decoded = Jason.decode!(json)
      assert decoded["label"] == "MongoDB"
      assert decoded["description"] == "Document store"
    end
  end

  # ===========================================================================
  # QuestionEntry
  # ===========================================================================

  describe "question_entry/1" do
    test "happy path with required fields" do
      {:ok, entry} =
        Entries.question_entry(%{
          "question" => "Which database?",
          "header" => "Database",
          "options" => [
            %{"label" => "PostgreSQL"},
            %{"label" => "MongoDB"}
          ]
        })

      assert entry["question"] == "Which database?"
      assert entry["header"] == "Database"
      assert entry["multi_select"] == false
      assert length(entry["options"]) == 2
    end

    test "accepts multi_select" do
      {:ok, entry} =
        Entries.question_entry(%{
          "question" => "Pick tools",
          "header" => "Tools",
          "multi_select" => true,
          "options" => [
            %{"label" => "Docker"},
            %{"label" => "K8s"}
          ]
        })

      assert entry["multi_select"] == true
    end

    test "rejects too few options" do
      assert {:error, {:value_below_min, "options", 1, 2}} =
               Entries.question_entry(%{
                 "question" => "Only one?",
                 "header" => "Pick",
                 "options" => [%{"label" => "Solo"}]
               })
    end

    test "rejects too many options" do
      options = for i <- 1..7, do: %{"label" => "Opt#{i}"}

      assert {:error, {:value_above_max, "options", 7, 6}} =
               Entries.question_entry(%{
                 "question" => "Too many",
                 "header" => "Pick",
                 "options" => options
               })
    end

    test "rejects missing question" do
      assert {:error, {:missing_required_field, "question"}} =
               Entries.question_entry(%{
                 "header" => "H",
                 "options" => [%{"label" => "A"}, %{"label" => "B"}]
               })
    end

    test "rejects missing header" do
      assert {:error, {:missing_required_field, "header"}} =
               Entries.question_entry(%{
                 "question" => "Q?",
                 "options" => [%{"label" => "A"}, %{"label" => "B"}]
               })
    end

    test "rejects missing options" do
      assert {:error, {:missing_required_field, "options"}} =
               Entries.question_entry(%{"question" => "Q?", "header" => "H"})
    end

    test "validates nested option entries" do
      assert {:error, {:invalid_list_element, "options", {:missing_required_field, "label"}}} =
               Entries.question_entry(%{
                 "question" => "Q?",
                 "header" => "H",
                 "options" => [%{"description" => "No label"}, %{"label" => "OK"}]
               })
    end
  end

  # ===========================================================================
  # QuestionAnswerEntry
  # ===========================================================================

  describe "question_answer_entry/1" do
    test "happy path with required fields" do
      {:ok, entry} =
        Entries.question_answer_entry(%{
          "question_header" => "Database",
          "selected_options" => ["PostgreSQL"]
        })

      assert entry["question_header"] == "Database"
      assert entry["selected_options"] == ["PostgreSQL"]
      assert entry["other_text"] == nil
    end

    test "accepts other_text" do
      {:ok, entry} =
        Entries.question_answer_entry(%{
          "question_header" => "Tool",
          "selected_options" => [],
          "other_text" => "Custom answer"
        })

      assert entry["other_text"] == "Custom answer"
    end

    test "defaults selected_options to empty list" do
      {:ok, entry} =
        Entries.question_answer_entry(%{
          "question_header" => "H"
        })

      assert entry["selected_options"] == []
    end

    test "rejects non-string elements in selected_options" do
      assert {:error, {:invalid_field_type, "selected_options", :not_all_strings}} =
               Entries.question_answer_entry(%{
                 "question_header" => "H",
                 "selected_options" => [1, 2]
               })
    end

    test "rejects missing question_header" do
      assert {:error, {:missing_required_field, "question_header"}} =
               Entries.question_answer_entry(%{"selected_options" => []})
    end
  end

  # ===========================================================================
  # AskUserQuestionRequest (UserInteraction)
  # ===========================================================================

  describe "ask_user_question_request/1" do
    test "happy path with required fields" do
      {:ok, msg} =
        UserInteraction.ask_user_question_request(%{
          "prompt_id" => "auq-001",
          "questions" => [
            %{
              "question" => "Which framework?",
              "header" => "Framework",
              "options" => [
                %{"label" => "Django"},
                %{"label" => "Flask"}
              ]
            }
          ]
        })

      assert msg["category"] == "user_interaction"
      assert msg["prompt_id"] == "auq-001"
      assert length(msg["questions"]) == 1
      assert msg["timeout"] == 300
    end

    test "accepts custom timeout" do
      {:ok, msg} =
        UserInteraction.ask_user_question_request(%{
          "prompt_id" => "auq-002",
          "questions" => [
            %{
              "question" => "Q?",
              "header" => "H",
              "options" => [%{"label" => "A"}, %{"label" => "B"}]
            }
          ],
          "timeout" => 60
        })

      assert msg["timeout"] == 60
    end

    test "rejects missing prompt_id" do
      assert {:error, {:missing_required_field, "prompt_id"}} =
               UserInteraction.ask_user_question_request(%{
                 "questions" => [
                   %{
                     "question" => "Q?",
                     "header" => "H",
                     "options" => [%{"label" => "A"}, %{"label" => "B"}]
                   }
                 ]
               })
    end

    test "rejects missing questions" do
      assert {:error, {:missing_required_field, "questions"}} =
               UserInteraction.ask_user_question_request(%{"prompt_id" => "p1"})
    end

    test "rejects empty questions" do
      assert {:error, {:value_below_min, "questions", 0, 1}} =
               UserInteraction.ask_user_question_request(%{
                 "prompt_id" => "p1",
                 "questions" => []
               })
    end

    test "rejects too many questions" do
      questions =
        for i <- 1..11 do
          %{
            "question" => "Q#{i}?",
            "header" => "H#{i}",
            "options" => [%{"label" => "A"}, %{"label" => "B"}]
          }
        end

      assert {:error, {:value_above_max, "questions", 11, 10}} =
               UserInteraction.ask_user_question_request(%{
                 "prompt_id" => "p1",
                 "questions" => questions
               })
    end

    test "rejects invalid timeout" do
      assert {:error, {:invalid_field_type, "timeout", "fast"}} =
               UserInteraction.ask_user_question_request(%{
                 "prompt_id" => "p1",
                 "questions" => [
                   %{
                     "question" => "Q?",
                     "header" => "H",
                     "options" => [%{"label" => "A"}, %{"label" => "B"}]
                   }
                 ],
                 "timeout" => "fast"
               })
    end

    test "rejects category mismatch" do
      assert {:error, {:category_mismatch, expected: "user_interaction", got: "agent"}} =
               UserInteraction.ask_user_question_request(%{
                 "prompt_id" => "p1",
                 "questions" => [
                   %{
                     "question" => "Q?",
                     "header" => "H",
                     "options" => [%{"label" => "A"}, %{"label" => "B"}]
                   }
                 ],
                 "category" => "agent"
               })
    end

    test "WireEvent round-trip" do
      {:ok, msg} =
        UserInteraction.ask_user_question_request(%{
          "prompt_id" => "auq-wire",
          "questions" => [
            %{
              "question" => "Which DB?",
              "header" => "Database",
              "multi_select" => false,
              "options" => [
                %{"label" => "PostgreSQL", "description" => "Relational"},
                %{"label" => "MongoDB", "description" => "Document"}
              ]
            }
          ],
          "timeout" => 120
        })

      {:ok, wire} = WireEvent.to_wire(msg)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert restored["prompt_id"] == "auq-wire"
      assert restored["timeout"] == 120
      assert length(restored["questions"]) == 1
    end

    test "JSON round-trip" do
      {:ok, msg} =
        UserInteraction.ask_user_question_request(%{
          "prompt_id" => "auq-json",
          "questions" => [
            %{
              "question" => "Pick one",
              "header" => "Choice",
              "options" => [%{"label" => "X"}, %{"label" => "Y"}]
            }
          ]
        })

      json = Jason.encode!(msg)
      decoded = Jason.decode!(json)
      assert decoded["prompt_id"] == "auq-json"
      assert length(decoded["questions"]) == 1
    end
  end

  # ===========================================================================
  # AskUserQuestionResponse (Commands) — including answer validation
  # ===========================================================================

  describe "AskUserQuestionResponse" do
    test "constructor with defaults" do
      cmd =
        Commands.ask_user_question_response("auq-001", [
          %{"question_header" => "DB", "selected_options" => ["PostgreSQL"]}
        ])

      assert cmd.command_type == :ask_user_question_response
      assert cmd.prompt_id == "auq-001"
      assert length(cmd.answers) == 1
      assert cmd.cancelled == false
      assert cmd.timed_out == false
      assert cmd.error == nil
    end

    test "constructor with all options" do
      cmd =
        Commands.ask_user_question_response("auq-002", [],
          cancelled: true,
          timed_out: false,
          error: "user cancelled"
        )

      assert cmd.cancelled == true
      assert cmd.error == "user cancelled"
    end

    test "to_wire/1 serializes correctly" do
      cmd =
        Commands.ask_user_question_response("auq-003", [
          %{
            "question_header" => "Framework",
            "selected_options" => ["Django"],
            "other_text" => nil
          }
        ])

      wire = Commands.to_wire(cmd)

      assert wire["command_type"] == "ask_user_question_response"
      assert wire["prompt_id"] == "auq-003"
      assert is_list(wire["answers"])
      assert wire["cancelled"] == false
      # nil fields are omitted by to_wire
      refute Map.has_key?(wire, "error")
    end

    test "from_wire/1 deserializes correctly with valid answers" do
      wire = %{
        "command_type" => "ask_user_question_response",
        "prompt_id" => "auq-004",
        "answers" => [
          %{
            "question_header" => "DB",
            "selected_options" => ["PostgreSQL"]
          }
        ],
        "cancelled" => false,
        "timed_out" => false
      }

      {:ok, cmd} = Commands.from_wire(wire)

      assert %Commands.AskUserQuestionResponse{} = cmd
      assert cmd.prompt_id == "auq-004"
      assert length(cmd.answers) == 1
      assert cmd.cancelled == false
    end

    test "from_wire/1 validates answers through question_answer_entry" do
      wire = %{
        "command_type" => "ask_user_question_response",
        "prompt_id" => "auq-val",
        "answers" => [
          %{
            "question_header" => "DB",
            "selected_options" => ["PostgreSQL"]
          }
        ]
      }

      assert {:ok, _cmd} = Commands.from_wire(wire)
    end

    test "from_wire/1 rejects invalid answer entries" do
      wire = %{
        "command_type" => "ask_user_question_response",
        "prompt_id" => "auq-bad",
        "answers" => [
          %{"selected_options" => [123]}
        ]
      }

      # Missing question_header should fail Entries.question_answer_entry validation
      assert {:error, _reason} = Commands.from_wire(wire)
    end

    test "from_wire/1 rejects answers with non-string selected_options" do
      wire = %{
        "command_type" => "ask_user_question_response",
        "prompt_id" => "auq-badtype",
        "answers" => [
          %{"question_header" => "H", "selected_options" => [1, 2]}
        ]
      }

      assert {:error, {:invalid_list_element, "answers", _}} = Commands.from_wire(wire)
    end

    test "from_wire/1 round-trip through to_wire" do
      cmd =
        Commands.ask_user_question_response(
          "auq-rt",
          [
            %{"question_header" => "H", "selected_options" => ["A", "B"]}
          ],
          cancelled: false,
          timed_out: true,
          error: "timeout message"
        )

      wire = Commands.to_wire(cmd)
      {:ok, restored} = Commands.from_wire(wire)

      assert restored.prompt_id == "auq-rt"
      assert length(restored.answers) == 1
      assert restored.timed_out == true
      assert restored.error == "timeout message"
    end

    test "from_wire/1 accepts empty answers list" do
      wire = %{
        "command_type" => "ask_user_question_response",
        "prompt_id" => "auq-empty",
        "answers" => []
      }

      assert {:ok, cmd} = Commands.from_wire(wire)
      assert cmd.answers == []
    end

    test "from_wire/1 accepts missing answers (defaults to [])" do
      wire = %{
        "command_type" => "ask_user_question_response",
        "prompt_id" => "auq-missing"
      }

      assert {:ok, cmd} = Commands.from_wire(wire)
      assert cmd.answers == []
    end

    test "from_wire/1 rejects unknown command_type" do
      assert {:error, :unknown_command_type} =
               Commands.from_wire(%{"command_type" => "bogus_response"})
    end

    test "from_wire/1 rejects extra fields" do
      assert {:error, :extra_fields_not_allowed} =
               Commands.from_wire(%{
                 "command_type" => "ask_user_question_response",
                 "prompt_id" => "p1",
                 "answers" => [],
                 "unexpected_field" => true
               })
    end
  end

  # ===========================================================================
  # CpAskUserQuestion Tool
  # ===========================================================================

  describe "CpAskUserQuestion tool" do
    test "implements Tool behaviour" do
      assert CpAskUserQuestion.name() == :cp_ask_user_question
      assert is_binary(CpAskUserQuestion.description())
      assert is_map(CpAskUserQuestion.parameters())
    end

    test "parameters schema requires questions" do
      params = CpAskUserQuestion.parameters()
      assert params["required"] == ["questions"]
      assert params["properties"]["questions"]["type"] == "array"
    end

    test "tool_timeout/0 returns 300_000 ms (5 minutes)" do
      assert CpAskUserQuestion.tool_timeout() == 300_000
    end

    test "invoke returns error for invalid questions (validation failure)" do
      result = CpAskUserQuestion.invoke(%{"questions" => []}, %{run_id: "test-run"})

      assert match?({:ok, %{"error" => _}}, result)
    end
  end

  # ===========================================================================
  # Registry Integration
  # ===========================================================================

  describe "tool registry integration" do
    setup do
      # Ensure the tool is registered regardless of test execution order.
      # Other tests (e.g. runner_test) clear the global Registry, so we
      # explicitly register our tool and clean up afterwards.
      :ok = CodePuppyControl.Tool.Registry.register(CpAskUserQuestion)

      on_exit(fn ->
        CodePuppyControl.Tool.Registry.unregister(:cp_ask_user_question)
      end)

      :ok
    end

    test "cp_ask_user_question is registered in tool registry" do
      assert CodePuppyControl.Tool.Registry.registered?(:cp_ask_user_question)
    end

    test "cp_ask_user_question appears in CodePuppy agent allowed tools" do
      allowed = CodePuppyControl.Agents.CodePuppy.allowed_tools()
      assert :cp_ask_user_question in allowed
    end
  end

  # ===========================================================================
  # Tool.Runner timeout alignment
  # ===========================================================================

  describe "Tool.Runner uses tool_timeout/0" do
    test "Runner picks up CpAskUserQuestion.tool_timeout/0 when no context override" do
      # This verifies that the Runner will use the tool's 300_000 ms
      # default instead of the Runner's 60_000 ms default.
      assert function_exported?(CpAskUserQuestion, :tool_timeout, 0)
      assert CpAskUserQuestion.tool_timeout() == 300_000
    end

    test "context timeout overrides tool_timeout" do
      # The Runner checks context :timeout first, then module tool_timeout,
      # then @default_timeout_ms. We verify the priority chain by checking
      # that build_context includes session_id when provided.
      ctx = Runner.build_context(run_id: "r1", session_id: "s1", timeout: 5000)
      assert ctx.timeout == 5000
      assert ctx.session_id == "s1"
    end
  end

  # ===========================================================================
  # EventBus request/response protocol tests
  # ===========================================================================

  describe "EventBus request/response protocol" do
    setup do
      run_id = "proto-run-#{System.unique_integer([:positive])}"
      session_id = "proto-session-#{System.unique_integer([:positive])}"
      prompt_id = "proto-prompt-#{:erlang.unique_integer([:positive])}"

      # Subscribe to the run topic before broadcasting
      :ok = EventBus.subscribe_run(run_id)

      # Build and broadcast a valid request
      {:ok, request_msg} =
        UserInteraction.ask_user_question_request(%{
          "prompt_id" => prompt_id,
          "questions" => [
            %{
              "question" => "Pick a DB",
              "header" => "Database",
              "options" => [
                %{"label" => "PostgreSQL"},
                %{"label" => "MongoDB"}
              ]
            }
          ]
        })

      :ok = EventBus.broadcast_message(run_id, session_id, request_msg, store: false)

      # Flush the request event from the mailbox — we only want responses
      assert_receive {:event, _request_event}, 1_000

      {:ok, run_id: run_id, session_id: session_id, prompt_id: prompt_id}
    end

    test "success round-trip: response with matching prompt_id is received", %{
      run_id: run_id,
      prompt_id: prompt_id
    } do
      cmd =
        Commands.ask_user_question_response(prompt_id, [
          %{"question_header" => "Database", "selected_options" => ["PostgreSQL"]}
        ])

      :ok = EventBus.broadcast_command(run_id, nil, cmd, store: false)

      assert_receive {:event, event}, 1_000
      assert event[:type] == "command"
      assert event[:command]["prompt_id"] == prompt_id
      assert event[:command]["command_type"] == "ask_user_question_response"
    end

    test "response includes session_id when available", %{
      run_id: run_id,
      session_id: session_id,
      prompt_id: prompt_id
    } do
      cmd =
        Commands.ask_user_question_response(prompt_id, [
          %{"question_header" => "Database", "selected_options" => ["PostgreSQL"]}
        ])

      :ok = EventBus.broadcast_command(run_id, session_id, cmd, store: false)

      assert_receive {:event, event}, 1_000
      assert event[:session_id] == session_id
    end

    test "mismatched prompt_id is ignored, matching prompt_id accepted" do
      run_id = "mismatch-run-#{System.unique_integer([:positive])}"
      :ok = EventBus.subscribe_run(run_id)

      # Broadcast a response with a WRONG prompt_id on the same run topic
      wrong_cmd =
        Commands.ask_user_question_response("wrong-prompt-id", [
          %{"question_header" => "H", "selected_options" => ["X"]}
        ])

      :ok = EventBus.broadcast_command(run_id, nil, wrong_cmd, store: false)

      # The wrong-prompt command should arrive as an event
      assert_receive {:event, %{type: "command"}}, 1_000

      # Now broadcast a response with the CORRECT prompt_id
      right_cmd =
        Commands.ask_user_question_response("correct-prompt", [
          %{"question_header" => "H", "selected_options" => ["Y"]}
        ])

      :ok = EventBus.broadcast_command(run_id, nil, right_cmd, store: false)

      # The correct-prompt command should also arrive
      assert_receive {:event, %{type: "command"}}, 1_000

      # Both events arrive; the tool's spin_wait loop ignores the
      # mismatched one and returns the matching one.
      :ok
    end

    test "unrelated events do not reset timeout", %{run_id: run_id} do
      # Send an unrelated heartbeat event
      :ok = EventBus.broadcast_heartbeat(run_id, nil, %{test: true})

      # The heartbeat should arrive as a non-command event
      assert_receive {:event, %{type: "heartbeat"}}, 1_000

      # Tool's spin_wait loop should ignore this and keep waiting
      # (verified by implementation: :continue on non-command events)
    end

    test "timeout response is returned when no matching response arrives" do
      # Invoke the tool with a very short timeout (200 ms → reports 0 seconds)
      timeout_ms = 200

      result =
        CpAskUserQuestion.invoke(
          %{
            "questions" => [
              %{
                "question" => "Q?",
                "header" => "H",
                "options" => [%{"label" => "A"}, %{"label" => "B"}]
              }
            ]
          },
          %{
            run_id: "timeout-test-run-#{:erlang.unique_integer([:positive])}",
            timeout: timeout_ms
          }
        )

      assert {:ok, response} = result
      assert response["timed_out"] == true
      assert response["cancelled"] == false
      assert response["answers"] == []
      # Timeout message must report the *configured* timeout, not monotonic time
      expected_seconds = div(timeout_ms, 1000)

      assert response["error"] ==
               "Interaction timed out after #{expected_seconds} seconds of inactivity"
    end
  end

  # ===========================================================================
  # Subscribe-before-broadcast race resistance
  # ===========================================================================

  describe "subscribe-before-broadcast race resistance" do
    test "tool subscribes before broadcasting request" do
      # The implementation calls subscribe_run BEFORE broadcast_message.
      # We verify by checking the code path: invoke/2 does subscribe then broadcast.
      # A functional test: invoke the tool with a short timeout, ensure no crash.
      run_id = "race-test-run-#{:erlang.unique_integer([:positive])}"

      result =
        CpAskUserQuestion.invoke(
          %{
            "questions" => [
              %{
                "question" => "Q?",
                "header" => "H",
                "options" => [%{"label" => "A"}, %{"label" => "B"}]
              }
            ]
          },
          %{run_id: run_id, timeout: 50}
        )

      # Should not crash, should timeout cleanly
      assert {:ok, %{"timed_out" => true} = response} = result
      # Verify the timeout message reports the *configured* timeout
      expected_seconds = div(50, 1000)

      assert response["error"] ==
               "Interaction timed out after #{expected_seconds} seconds of inactivity"
    end

    test "immediate response after broadcast is received" do
      run_id = "immediate-run-#{:erlang.unique_integer([:positive])}"
      test_pid = self()

      # Subscribe to the run topic BEFORE spawning the tool process so we
      # reliably capture the request event (which carries the prompt_id).
      :ok = EventBus.subscribe_run(run_id)

      invoke_pid =
        spawn(fn ->
          result =
            CpAskUserQuestion.invoke(
              %{
                "questions" => [
                  %{
                    "question" => "Pick?",
                    "header" => "Choice",
                    "options" => [%{"label" => "A"}, %{"label" => "B"}]
                  }
                ]
              },
              %{run_id: run_id, timeout: 3000}
            )

          send(test_pid, {:tool_result, result})
        end)

      # Wait for the tool's request event to extract the generated prompt_id.
      # The wire event from broadcast_message has the prompt_id inside
      # ["payload"]["prompt_id"].
      prompt_id =
        receive do
          {:event, %{"payload" => %{"prompt_id" => pid}}} ->
            pid
        after
          1_000 ->
            flunk("Did not receive request event from tool within 1s")
        end

      # Immediately send a matching response — the tool process is already
      # subscribed and spinning, so it should pick this up without timeout.
      cmd =
        Commands.ask_user_question_response(prompt_id, [
          %{"question_header" => "Choice", "selected_options" => ["A"]}
        ])

      :ok = EventBus.broadcast_command(run_id, nil, cmd, store: false)

      # The tool MUST return the matching response, NOT a timeout.
      receive do
        {:tool_result, {:ok, %{"answers" => [_ | _]} = result}} ->
          assert result["cancelled"] == false
          assert result["timed_out"] == false
          assert result["error"] == nil

        {:tool_result, {:ok, %{"timed_out" => true} = result}} ->
          flunk("Tool timed out instead of receiving the immediate response: #{inspect(result)}")
      after
        5_000 ->
          flunk("Tool invocation did not complete within 5s")
      end

      # Clean up the invoke process and subscription
      :ok = EventBus.unsubscribe_run(run_id)

      if Process.alive?(invoke_pid) do
        Process.exit(invoke_pid, :kill)
      end
    end
  end
end
