defmodule CodePuppyControl.Indexer.Constants do
  @moduledoc """
  Constants for directory indexing.
  """

  @ignored_dirs MapSet.new([
                  ".git",
                  ".hg",
                  ".svn",
                  "__pycache__",
                  ".pytest_cache",
                  ".mypy_cache",
                  ".ruff_cache",
                  "node_modules",
                  "dist",
                  "build",
                  ".venv",
                  "venv",
                  "target",
                  ".tox",
                  "htmlcov",
                  ".idea",
                  ".vscode",
                  ".DS_Store",
                  "_build",
                  "deps"
                ])

  @important_files MapSet.new([
                     "README.md",
                     "README.rst",
                     "pyproject.toml",
                     "setup.py",
                     "package.json",
                     "Cargo.toml",
                     "Cargo.lock",
                     "Makefile",
                     "justfile",
                     "Dockerfile",
                     ".gitignore",
                     "LICENSE",
                     "requirements.txt",
                     "Pipfile",
                     "poetry.lock",
                     "mix.exs"
                   ])

  # Extension -> {kind, extract_symbols?}
  @extension_map %{
    "py" => {"python", true},
    "rs" => {"rust", true},
    "js" => {"javascript", true},
    "ts" => {"typescript", true},
    "tsx" => {"tsx", true},
    "ex" => {"elixir", true},
    "exs" => {"elixir", true},
    "md" => {"docs", false},
    "rst" => {"docs", false},
    "txt" => {"docs", false},
    "json" => {"json", false},
    "toml" => {"toml", false},
    "yaml" => {"yaml", false},
    "yml" => {"yaml", false},
    "html" => {"html", false},
    "htm" => {"html", false},
    "css" => {"css", false},
    "scss" => {"scss", false},
    "sh" => {"shell", false},
    "bash" => {"shell", false},
    "zsh" => {"shell", false}
  }

  @doc "Returns the set of directory names to ignore during indexing."
  @spec ignored_dirs() :: MapSet.t(String.t())
  def ignored_dirs, do: @ignored_dirs

  @doc "Returns the set of important file names that get special categorization."
  @spec important_files() :: MapSet.t(String.t())
  def important_files, do: @important_files

  @doc "Returns the map of file extensions to {kind, extract_symbols?} tuples."
  @spec extension_map() :: %{String.t() => {String.t(), boolean()}}
  def extension_map, do: @extension_map
end
