defmodule CodePuppyControl.FileOps.PathClassifierTest do
  @moduledoc """
  Tests for path classification.

  Ported from Rust: `code_puppy_core/src/path_classify/tests.rs`
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.FileOps.PathClassifier

  # ===== Ignore pattern tests =====

  describe "should_ignore/2" do
    setup do
      %{classifier: PathClassifier.new()}
    end

    test "ignores git directory", %{classifier: c} do
      assert PathClassifier.should_ignore(c, ".git")
      assert PathClassifier.should_ignore(c, ".git/config")
      assert PathClassifier.should_ignore(c, "./.git")
      assert PathClassifier.should_ignore(c, "./.git/HEAD")
      assert PathClassifier.should_ignore(c, "project/.git")
      assert PathClassifier.should_ignore(c, "project/.git/hooks/pre-commit")
    end

    test "ignores node_modules", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "node_modules")
      assert PathClassifier.should_ignore(c, "node_modules/lodash")
      assert PathClassifier.should_ignore(c, "node_modules/lodash/index.js")
      assert PathClassifier.should_ignore(c, "./node_modules")
      assert PathClassifier.should_ignore(c, "project/node_modules")
    end

    test "ignores pycache", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "__pycache__")
      assert PathClassifier.should_ignore(c, "__pycache__/foo.cpython-311.pyc")
      assert PathClassifier.should_ignore(c, "./__pycache__")
      assert PathClassifier.should_ignore(c, "project/__pycache__")
    end

    test "ignores compiled Python", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "foo.pyc")
      assert PathClassifier.should_ignore(c, "foo.pyo")
      assert PathClassifier.should_ignore(c, "./foo.pyc")
      assert PathClassifier.should_ignore(c, "project/foo.pyc")
    end

    test "ignores binary files", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "image.png")
      assert PathClassifier.should_ignore(c, "doc.pdf")
      assert PathClassifier.should_ignore(c, "archive.zip")
      assert PathClassifier.should_ignore(c, "video.mp4")
      assert PathClassifier.should_ignore(c, "font.ttf")
    end

    test "does not ignore regular files", %{classifier: c} do
      refute PathClassifier.should_ignore(c, "main.rs")
      refute PathClassifier.should_ignore(c, "src/main.rs")
      refute PathClassifier.should_ignore(c, "README.md")
      refute PathClassifier.should_ignore(c, "./src/lib.rs")
    end

    test "ignores npm logs", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "npm-debug.log")
      assert PathClassifier.should_ignore(c, "npm-debug.log.123456789")
    end

    test "ignores hidden files", %{classifier: c} do
      # "**/.*" pattern added for parity with Python
      # This catches generic dotfiles/dotdirs
      assert PathClassifier.should_ignore(c, ".hidden_file")
      assert PathClassifier.should_ignore(c, "./.hidden_file")
      assert PathClassifier.should_ignore(c, "project/.hidden_file")

      # Common hidden files still work
      assert PathClassifier.should_ignore(c, ".DS_Store")
      assert PathClassifier.should_ignore(c, "./.DS_Store")
      assert PathClassifier.should_ignore(c, "project/.DS_Store")
    end

    test "ignores hidden directories", %{classifier: c} do
      # Hidden directories should be ignored via "**/.*" pattern
      assert PathClassifier.should_ignore(c, ".hidden_dir")
      assert PathClassifier.should_ignore(c, "./.hidden_dir")
      assert PathClassifier.should_ignore(c, "project/.hidden_dir")
      assert PathClassifier.should_ignore(c, "path/to/.hidden_dir/file")
      assert PathClassifier.should_ignore(c, "path/to/.hidden_dir/nested/path/file")
    end

    test "ignores swap files", %{classifier: c} do
      assert PathClassifier.should_ignore(c, ".file.swp")
      assert PathClassifier.should_ignore(c, ".file.swo")
      assert PathClassifier.should_ignore(c, "file~")
    end

    test "ignores coverage file", %{classifier: c} do
      # .coverage file pattern added for parity with Python
      assert PathClassifier.should_ignore(c, ".coverage")
      assert PathClassifier.should_ignore(c, "./.coverage")
      assert PathClassifier.should_ignore(c, "project/.coverage")
    end

    test "ignores lein files", %{classifier: c} do
      # .lein-* pattern using double asterisk (like Python "**/.lein-**")
      assert PathClassifier.should_ignore(c, ".lein-repl-history")
      assert PathClassifier.should_ignore(c, ".lein-failures")
      assert PathClassifier.should_ignore(c, "project/.lein-deps-sum")
    end

    test "ignores gradle app setting", %{classifier: c} do
      # gradle-app.setting pattern added for parity with Python
      assert PathClassifier.should_ignore(c, "gradle-app.setting")
      assert PathClassifier.should_ignore(c, "./gradle-app.setting")
      assert PathClassifier.should_ignore(c, "project/gradle-app.setting")
    end
  end

  # ===== Sensitive path tests =====

  describe "is_sensitive/2" do
    setup do
      %{classifier: PathClassifier.new()}
    end

    test "detects sensitive SSH directory", %{classifier: c} do
      # Test that ~username/.ssh paths are detected as sensitive
      # (other users' SSH directories should always be sensitive)
      assert PathClassifier.is_sensitive(c, "~other/.ssh/id_rsa")
      assert PathClassifier.is_sensitive(c, "~alice/.ssh")
      assert PathClassifier.is_sensitive(c, "~root/.ssh")
      assert PathClassifier.is_sensitive(c, "~root/.ssh/authorized_keys")
    end

    test "detects sensitive /etc paths", %{classifier: c} do
      assert PathClassifier.is_sensitive(c, "/etc/shadow")
      assert PathClassifier.is_sensitive(c, "/etc/passwd")
      assert PathClassifier.is_sensitive(c, "/etc/sudoers")
    end

    test "detects sensitive /private/etc paths", %{classifier: c} do
      assert PathClassifier.is_sensitive(c, "/private/etc/shadow")
      assert PathClassifier.is_sensitive(c, "/private/etc/passwd")
      assert PathClassifier.is_sensitive(c, "/private/etc/sudoers")
      assert PathClassifier.is_sensitive(c, "/private/etc")
    end

    test "detects sensitive /dev paths", %{classifier: c} do
      assert PathClassifier.is_sensitive(c, "/dev/sda1")
      assert PathClassifier.is_sensitive(c, "/dev/null")
      assert PathClassifier.is_sensitive(c, "/dev")
    end

    test "does not detect /proc as sensitive", %{classifier: c} do
      # /proc paths should NOT be detected as sensitive in file operations
      # (Python is_sensitive_path does NOT have /proc check)
      refute PathClassifier.is_sensitive(c, "/proc/1/cmdline")
      refute PathClassifier.is_sensitive(c, "/proc")
    end

    test "does not detect /var/log as sensitive", %{classifier: c} do
      # /var/log paths should NOT be detected as sensitive in file operations
      # (Python is_sensitive_path does NOT have /var/log check)
      refute PathClassifier.is_sensitive(c, "/var/log/syslog")
      refute PathClassifier.is_sensitive(c, "/var/log/auth.log")
    end

    test "does not detect /root as sensitive", %{classifier: c} do
      # /root paths should NOT be detected as sensitive in file operations
      # (Python is_sensitive_path does NOT check /root as a prefix)
      # ~root paths ARE detected via ~username handling
      refute PathClassifier.is_sensitive(c, "/root")
      refute PathClassifier.is_sensitive(c, "/root/.bashrc")
      assert PathClassifier.is_sensitive(c, "~root/.ssh/id_rsa")
    end

    test "detects sensitive .env files", %{classifier: c} do
      # Regular .env is sensitive
      assert PathClassifier.is_sensitive(c, ".env")
      assert PathClassifier.is_sensitive(c, "project/.env")
      assert PathClassifier.is_sensitive(c, "/path/to/.env")

      # Allowed variants are NOT sensitive
      refute PathClassifier.is_sensitive(c, ".env.example")
      refute PathClassifier.is_sensitive(c, ".env.sample")
      refute PathClassifier.is_sensitive(c, ".env.template")
      refute PathClassifier.is_sensitive(c, "project/.env.example")
    end

    test "detects sensitive extensions", %{classifier: c} do
      assert PathClassifier.is_sensitive(c, "id_rsa.pem")
      assert PathClassifier.is_sensitive(c, "server.key")
      assert PathClassifier.is_sensitive(c, "cert.p12")
      assert PathClassifier.is_sensitive(c, "keystore.pfx")
      assert PathClassifier.is_sensitive(c, "android.keystore")
    end

    test "does not detect regular files as sensitive", %{classifier: c} do
      refute PathClassifier.is_sensitive(c, "main.rs")
      refute PathClassifier.is_sensitive(c, "README.md")
      refute PathClassifier.is_sensitive(c, "src/lib.rs")
    end

    test "empty path is not sensitive", %{classifier: c} do
      refute PathClassifier.is_sensitive(c, "")
    end

    test "symlinked sensitive targets are still classified as sensitive", %{classifier: c} do
      tmp = Path.join(System.tmp_dir!(), "path-classifier-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      secret = Path.join(tmp, "secret.pem")
      link = Path.join(tmp, "innocent.txt")
      File.write!(secret, "PRIVATE KEY DATA")
      File.ln_s!(secret, link)

      assert PathClassifier.is_sensitive(c, link)
    end

    test "non-allowlisted env variants remain sensitive", %{classifier: c} do
      assert PathClassifier.is_sensitive(c, ".env.local")
      assert PathClassifier.is_sensitive(c, "config/.env.production")
    end
  end

  # ===== Combined classifier tests =====

  describe "classify_path/2" do
    setup do
      %{classifier: PathClassifier.new()}
    end

    test "classifies regular file", %{classifier: c} do
      assert PathClassifier.classify_path(c, "main.rs") == %{ignored: false, sensitive: false}
    end

    test "classifies node_modules", %{classifier: c} do
      # node_modules: IS ignored, not sensitive
      assert PathClassifier.classify_path(c, "node_modules") == %{ignored: true, sensitive: false}
    end

    test "classifies .env file", %{classifier: c} do
      # .env: IS ignored (hidden file), IS sensitive
      assert PathClassifier.classify_path(c, ".env") == %{ignored: true, sensitive: true}
    end
  end

  describe "should_ignore_dir/2" do
    setup do
      %{classifier: PathClassifier.new()}
    end

    test "directory patterns match both should_ignore and should_ignore_dir", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "node_modules")
      assert PathClassifier.should_ignore_dir(c, "node_modules")
    end

    test "file patterns match only should_ignore", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "image.png")
      refute PathClassifier.should_ignore_dir(c, "image.png")
    end

    test "regular files don't match either", %{classifier: c} do
      refute PathClassifier.should_ignore(c, "main.rs")
      refute PathClassifier.should_ignore_dir(c, "main.rs")
    end
  end

  describe "hidden check edge cases" do
    setup do
      %{classifier: PathClassifier.new()}
    end

    test "parent directory is NOT treated as hidden", %{classifier: c} do
      refute PathClassifier.should_ignore(c, "..")
      refute PathClassifier.should_ignore(c, "foo/..")
    end

    test "double-dot prefix names ARE hidden", %{classifier: c} do
      # Parity with Python **/.* pattern
      assert PathClassifier.should_ignore(c, "..hidden")
      assert PathClassifier.should_ignore(c, "...hidden")
      assert PathClassifier.should_ignore(c, "project/..hidden")
      assert PathClassifier.should_ignore(c, "project/...hidden")
    end
  end

  # ===== Additional pattern category tests =====

  describe "additional ignore patterns" do
    setup do
      %{classifier: PathClassifier.new()}
    end

    test "version control patterns", %{classifier: c} do
      assert PathClassifier.should_ignore(c, ".svn")
      assert PathClassifier.should_ignore(c, ".hg")
      assert PathClassifier.should_ignore(c, ".bzr")
    end

    test "build directories", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "target")
      assert PathClassifier.should_ignore(c, "build")
      assert PathClassifier.should_ignore(c, "dist")
      assert PathClassifier.should_ignore(c, "_build")
    end

    test "IDE and editor patterns", %{classifier: c} do
      assert PathClassifier.should_ignore(c, ".idea")
      assert PathClassifier.should_ignore(c, ".vscode")
      assert PathClassifier.should_ignore(c, ".elixir_ls")
    end

    test "OS-specific patterns", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "Thumbs.db")
      assert PathClassifier.should_ignore(c, "Desktop.ini")
    end

    test "archive formats", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "archive.zip")
      assert PathClassifier.should_ignore(c, "backup.tar.gz")
      assert PathClassifier.should_ignore(c, "data.7z")
    end

    test "media files", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "song.mp3")
      assert PathClassifier.should_ignore(c, "movie.mp4")
      assert PathClassifier.should_ignore(c, "clip.avi")
    end

    test "font files", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "font.ttf")
      assert PathClassifier.should_ignore(c, "icons.woff2")
    end

    test "database files", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "data.db")
      assert PathClassifier.should_ignore(c, "app.sqlite")
      assert PathClassifier.should_ignore(c, "cache.sqlite3")
    end

    test "Rust artifacts", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "Cargo.lock")
      assert PathClassifier.should_ignore(c, "program.o")
      assert PathClassifier.should_ignore(c, "lib.so")
    end

    test "Elixir artifacts", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "erl_crash.dump")
      assert PathClassifier.should_ignore(c, "package.ez")
    end

    test "compiled binaries", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "program.exe")
      assert PathClassifier.should_ignore(c, "lib.dll")
      assert PathClassifier.should_ignore(c, "lib.dylib")
    end

    test "Java artifacts", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "App.class")
      assert PathClassifier.should_ignore(c, "library.jar")
      assert PathClassifier.should_ignore(c, "app.war")
    end

    test "Node.js related", %{classifier: c} do
      assert PathClassifier.should_ignore(c, ".next")
      assert PathClassifier.should_ignore(c, ".nuxt")
      assert PathClassifier.should_ignore(c, ".parcel-cache")
    end

    test "Python virtual environments", %{classifier: c} do
      assert PathClassifier.should_ignore(c, ".venv")
      assert PathClassifier.should_ignore(c, "venv")
      assert PathClassifier.should_ignore(c, "env")
      assert PathClassifier.should_ignore(c, "ENV")
    end

    test "Ruby related", %{classifier: c} do
      assert PathClassifier.should_ignore(c, ".bundle")
      assert PathClassifier.should_ignore(c, "Gemfile.lock")
      assert PathClassifier.should_ignore(c, "app.gem")
    end

    test "Go related", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "program.test")
      assert PathClassifier.should_ignore(c, "go.work")
      assert PathClassifier.should_ignore(c, "go.work.sum")
    end

    test "Swift/Xcode related", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "App.xcodeproj")
      assert PathClassifier.should_ignore(c, "App.xcworkspace")
      assert PathClassifier.should_ignore(c, "DerivedData")
      assert PathClassifier.should_ignore(c, "xcuserdata")
    end

    test "Haskell related", %{classifier: c} do
      assert PathClassifier.should_ignore(c, "dist-newstyle")
      assert PathClassifier.should_ignore(c, ".stack-work")
      assert PathClassifier.should_ignore(c, "Main.hi")
      assert PathClassifier.should_ignore(c, "app.prof")
    end
  end

  describe "home directory sensitive paths" do
    setup do
      %{classifier: PathClassifier.new()}
    end

    test "detects sensitive files in home directory", %{classifier: c} do
      home = System.user_home!()

      assert PathClassifier.is_sensitive(c, "#{home}/.ssh/id_rsa")
      assert PathClassifier.is_sensitive(c, "#{home}/.aws/credentials")
      assert PathClassifier.is_sensitive(c, "#{home}/.gnupg/secring.gpg")
      assert PathClassifier.is_sensitive(c, "#{home}/.kube/config")
      assert PathClassifier.is_sensitive(c, "#{home}/.docker/config.json")
    end

    test "detects sensitive home config files", %{classifier: c} do
      home = System.user_home!()

      assert PathClassifier.is_sensitive(c, "#{home}/.netrc")
      assert PathClassifier.is_sensitive(c, "#{home}/.pgpass")
      assert PathClassifier.is_sensitive(c, "#{home}/.my.cnf")
      assert PathClassifier.is_sensitive(c, "#{home}/.bash_history")
      assert PathClassifier.is_sensitive(c, "#{home}/.npmrc")
      assert PathClassifier.is_sensitive(c, "#{home}/.pypirc")
      assert PathClassifier.is_sensitive(c, "#{home}/.gitconfig")
    end

    test "handles tilde expansion", %{classifier: c} do
      assert PathClassifier.is_sensitive(c, "~/.ssh/id_rsa")
      assert PathClassifier.is_sensitive(c, "~/.aws/credentials")
      assert PathClassifier.is_sensitive(c, "~/.env")
    end
  end

  describe "case sensitivity" do
    setup do
      %{classifier: PathClassifier.new()}
    end

    test "extensions are case-insensitive for sensitivity", %{classifier: c} do
      assert PathClassifier.is_sensitive(c, "key.PEM")
      assert PathClassifier.is_sensitive(c, "key.Pem")
      assert PathClassifier.is_sensitive(c, "server.KEY")
      assert PathClassifier.is_sensitive(c, "cert.P12")
      assert PathClassifier.is_sensitive(c, "keystore.PFX")
    end
  end
end
