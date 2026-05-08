defmodule CodePuppyControl.Tools.CommandRunner.OutputProcessorTest do
  @moduledoc """
  Tests for CommandRunner.OutputProcessor.

  Covers:
  - Line truncation (short and long lines)
  - Output processing (splitting, truncating, bounding)
  - Chunk processing (streaming pattern)
  - ANSI stripping
  - Result formatting
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.Tools.CommandRunner.OutputProcessor

  describe "truncate_line/2" do
    test "does not truncate short lines" do
      assert "hello world" = OutputProcessor.truncate_line("hello world")
    end

    test "does not truncate lines at exactly max length" do
      exact_line = String.duplicate("a", 256)
      assert exact_line == OutputProcessor.truncate_line(exact_line)
    end

    test "truncates lines exceeding max length" do
      long_line = String.duplicate("a", 300)
      truncated = OutputProcessor.truncate_line(long_line)

      assert String.length(truncated) <=
               256 + String.length(OutputProcessor.line_truncation_hint())

      assert truncated =~ "truncated"
      assert truncated =~ "try filtering with grep"
    end

    test "uses custom max length" do
      long_line = String.duplicate("b", 100)
      truncated = OutputProcessor.truncate_line(long_line, 50)

      assert String.starts_with?(truncated, String.duplicate("b", 50))
      assert truncated =~ "truncated"
    end

    test "handles empty string" do
      assert "" = OutputProcessor.truncate_line("")
    end
  end

  describe "process_output/1" do
    test "splits output into lines" do
      result = OutputProcessor.process_output("line1\nline2\nline3\n")

      assert result.lines == ["line1", "line2", "line3"]
      assert result.text == "line1\nline2\nline3"
    end

    test "truncates long lines in output" do
      long_line = String.duplicate("x", 300)
      result = OutputProcessor.process_output("#{long_line}\n")

      assert length(result.lines) == 1
      assert result.lines |> hd() =~ "truncated"
    end

    test "bounds output to max_output_lines" do
      # Create more than 256 lines
      lines = for i <- 1..300, do: "line#{i}"
      output = Enum.join(lines, "\n") <> "\n"

      result = OutputProcessor.process_output(output)

      assert length(result.lines) == 256
      # Should keep the tail (last 256 lines)
      assert List.last(result.lines) == "line300"
    end

    test "handles empty output" do
      result = OutputProcessor.process_output("")

      assert result.lines == []
      assert result.text == ""
    end

    test "handles single line without trailing newline" do
      result = OutputProcessor.process_output("hello")

      # No trailing newline means the split doesn't produce a trailing empty
      assert "hello" in result.lines
    end
  end

  describe "process_chunks/1" do
    test "processes multiple output chunks" do
      chunks = ["line1\n", "line2\nline3\n", "line4\n"]

      result = OutputProcessor.process_chunks(chunks)

      assert "line1" in result.lines
      assert "line2" in result.lines
      assert "line3" in result.lines
      assert "line4" in result.lines
    end

    test "truncates long lines in chunks" do
      long_chunk = String.duplicate("z", 300) <> "\n"
      result = OutputProcessor.process_chunks([long_chunk])

      assert length(result.lines) == 1
      assert hd(result.lines) =~ "truncated"
    end

    test "bounds chunks to max_output_lines" do
      chunks = for i <- 1..300, do: "line#{i}\n"

      result = OutputProcessor.process_chunks(chunks)

      assert length(result.lines) == 256
    end

    test "handles empty chunks list" do
      result = OutputProcessor.process_chunks([])

      assert result.lines == []
      assert result.text == ""
    end

    test "filters empty lines from chunks" do
      result = OutputProcessor.process_chunks(["\n\nhello\n\n"])

      assert result.lines == ["hello"]
    end
  end

  describe "format_result/1" do
    test "processes stdout and stderr in result map" do
      result =
        %{
          stdout: "line1\nline2\n",
          stderr: "error1\n",
          exit_code: 0
        }
        |> OutputProcessor.format_result()

      assert result.stdout == "line1\nline2"
      assert result.stderr == "error1"
      assert result.exit_code == 0
    end

    test "handles missing stdout/stderr" do
      result = OutputProcessor.format_result(%{exit_code: 0})

      assert result.stdout == ""
      assert result.stderr == ""
    end
  end

  describe "strip_ansi/1" do
    test "removes color escape sequences" do
      colored = "\e[31mRed Text\e[0m"
      assert OutputProcessor.strip_ansi(colored) == "Red Text"
    end

    test "removes multiple color codes" do
      colored = "\e[1;32mBold Green\e[0m and \e[33mYellow\e[0m"
      assert OutputProcessor.strip_ansi(colored) == "Bold Green and Yellow"
    end

    test "preserves plain text" do
      plain = "Hello, world!"
      assert OutputProcessor.strip_ansi(plain) == "Hello, world!"
    end

    test "handles empty string" do
      assert OutputProcessor.strip_ansi("") == ""
    end
  end

  describe "config accessors" do
    test "max_line_length returns 256" do
      assert OutputProcessor.max_line_length() == 256
    end

    test "shell_batch_size returns 10" do
      assert OutputProcessor.shell_batch_size() == 10
    end

    test "max_output_lines returns 256" do
      assert OutputProcessor.max_output_lines() == 256
    end

    test "line_truncation_hint is non-empty" do
      hint = OutputProcessor.line_truncation_hint()
      assert is_binary(hint)
      assert hint =~ "truncated"
    end
  end
end
