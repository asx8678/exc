defmodule CodePuppyControl.CLI.ParserTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.CLI.Parser

  describe "parse/1 — help flag" do
    test "--help returns {:help, _}" do
      assert {:help, opts} = Parser.parse(["--help"])
      assert opts[:help] == true
    end

    test "-h returns {:help, _}" do
      assert {:help, opts} = Parser.parse(["-h"])
      assert opts[:help] == true
    end
  end

  describe "parse/1 — version flag" do
    test "--version returns {:version, _}" do
      assert {:version, opts} = Parser.parse(["--version"])
      assert opts[:version] == true
    end

    test "-v returns {:version, _}" do
      assert {:version, opts} = Parser.parse(["-v"])
      assert opts[:version] == true
    end

    test "-V returns {:version, _}" do
      assert {:version, opts} = Parser.parse(["-V"])
      assert opts[:version] == true
    end
  end

  describe "parse/1 — model flag" do
    test "--model with value" do
      assert {:ok, opts} = Parser.parse(["--model", "claude-sonnet"])
      assert opts[:model] == "claude-sonnet"
    end

    test "-m with value" do
      assert {:ok, opts} = Parser.parse(["-m", "gpt-4"])
      assert opts[:model] == "gpt-4"
    end
  end

  describe "parse/1 — agent flag" do
    test "--agent with value" do
      assert {:ok, opts} = Parser.parse(["--agent", "qa-kitten"])
      assert opts[:agent] == "qa-kitten"
    end

    test "-a with value" do
      assert {:ok, opts} = Parser.parse(["-a", "pack-leader"])
      assert opts[:agent] == "pack-leader"
    end
  end

  describe "parse/1 — continue flag" do
    test "--continue is parsed" do
      assert {:ok, opts} = Parser.parse(["--continue"])
      assert opts[:continue] == true
    end

    test "-c is parsed" do
      assert {:ok, opts} = Parser.parse(["-c"])
      assert opts[:continue] == true
    end
  end

  describe "parse/1 — prompt flag" do
    test "--prompt with value" do
      assert {:ok, opts} = Parser.parse(["--prompt", "explain this code"])
      assert opts[:prompt] == "explain this code"
    end

    test "-p with value" do
      assert {:ok, opts} = Parser.parse(["-p", "fix the bug"])
      assert opts[:prompt] == "fix the bug"
    end
  end

  describe "parse/1 — interactive flag" do
    test "--interactive is parsed" do
      assert {:ok, opts} = Parser.parse(["--interactive"])
      assert opts[:interactive] == true
    end

    test "-i is parsed" do
      assert {:ok, opts} = Parser.parse(["-i"])
      assert opts[:interactive] == true
    end
  end

  describe "parse/1 — positional prompt" do
    test "positional arg becomes prompt when -p not given" do
      assert {:ok, opts} = Parser.parse(["explain this code"])
      assert opts[:prompt] == "explain this code"
    end

    test "-p takes precedence over positional" do
      assert {:ok, opts} = Parser.parse(["-p", "explicit", "positional"])
      assert opts[:prompt] == "explicit"
    end
  end

  describe "parse/1 — combined flags" do
    test "-m and -c together" do
      assert {:ok, opts} = Parser.parse(["-m", "claude-sonnet", "-c"])
      assert opts[:model] == "claude-sonnet"
      assert opts[:continue] == true
    end

    test "full set of flags" do
      assert {:ok, opts} =
               Parser.parse([
                 "-m",
                 "gpt-4",
                 "-a",
                 "code-puppy",
                 "-c",
                 "-i"
               ])

      assert opts[:model] == "gpt-4"
      assert opts[:agent] == "code-puppy"
      assert opts[:continue] == true
      assert opts[:interactive] == true
    end
  end

  describe "parse/1 — error handling" do
    test "unknown flag returns error" do
      assert {:error, msg} = Parser.parse(["--nonexistent"])
      assert msg =~ "nonexistent"
      refute msg =~ "----", "error message should not have duplicated '--' prefix"
    end

    test "unknown flag error message preserves single '--' prefix" do
      assert {:error, msg} = Parser.parse(["--nonsense"])
      assert msg =~ "--nonsense"
      refute msg =~ "----nonsense"
    end
  end

  describe "parse/1 — default values" do
    test "no args defaults to empty opts with booleans false" do
      assert {:ok, opts} = Parser.parse([])
      assert opts[:help] == false
      assert opts[:version] == false
      assert opts[:continue] == false
      assert opts[:interactive] == false
      assert opts[:model] == nil
      assert opts[:agent] == nil
      assert opts[:prompt] == nil
    end
  end

  describe "parse/1 — worker flags" do
    test "--worker is parsed" do
      assert {:ok, opts} = Parser.parse(["--worker"])
      assert opts[:worker] == true
    end

    test "-w is parsed as worker alias" do
      assert {:ok, opts} = Parser.parse(["-w"])
      assert opts[:worker] == true
    end

    test "--sname with value" do
      assert {:ok, opts} = Parser.parse(["--sname", "pup_worker_01"])
      assert opts[:sname] == "pup_worker_01"
    end

    test "--name with value" do
      assert {:ok, opts} = Parser.parse(["--name", "pup_worker@host.example.com"])
      assert opts[:name] == "pup_worker@host.example.com"
    end

    test "--cookie with value" do
      assert {:ok, opts} = Parser.parse(["--cookie", "secret"])
      assert opts[:cookie] == "secret"
    end

    test "--sname + --cookie together" do
      assert {:ok, opts} = Parser.parse(["--worker", "--sname", "pup_w1", "--cookie", "abc"])
      assert opts[:worker] == true
      assert opts[:sname] == "pup_w1"
      assert opts[:cookie] == "abc"
    end

    test "--name + --cookie together" do
      assert {:ok, opts} = Parser.parse(["--worker", "--name", "pup@host.com", "--cookie", "xyz"])
      assert opts[:worker] == true
      assert opts[:name] == "pup@host.com"
      assert opts[:cookie] == "xyz"
    end

    test "worker defaults to false" do
      assert {:ok, opts} = Parser.parse([])
      assert opts[:worker] == false
    end

    test "sname/name/cookie default to nil" do
      assert {:ok, opts} = Parser.parse([])
      assert opts[:sname] == nil
      assert opts[:name] == nil
      assert opts[:cookie] == nil
    end
  end
end
