"""Comprehensive tests for staged_changes module.

Tests the StagedChangesSandbox, StagedChange, and related functions
for staging, saving, loading, applying, and rejecting file changes.
"""

import json
import threading

import pytest

from code_puppy.staged_changes import (
    ChangeType,
    StagedChange,
    StagedChangesSandbox,
    get_sandbox,
    reset_sandbox,
)


class TestStagedChange:
    """Tests for StagedChange dataclass."""

    def test_create_change(self):
        """Test creating a CREATE change."""
        change = StagedChange(
            change_id="test123",
            change_type=ChangeType.CREATE,
            file_path="/tmp/test.txt",
            content="hello world",
        )
        assert change.change_id == "test123"
        assert change.change_type == ChangeType.CREATE
        assert change.content == "hello world"
        assert change.applied is False
        assert change.rejected is False

    def test_replace_change(self):
        """Test creating a REPLACE change."""
        change = StagedChange(
            change_id="test456",
            change_type=ChangeType.REPLACE,
            file_path="/tmp/test.txt",
            old_str="hello",
            new_str="goodbye",
        )
        assert change.old_str == "hello"
        assert change.new_str == "goodbye"

    def test_delete_snippet_change(self):
        """Test creating a DELETE_SNIPPET change."""
        change = StagedChange(
            change_id="test789",
            change_type=ChangeType.DELETE_SNIPPET,
            file_path="/tmp/test.txt",
            snippet="unwanted code",
        )
        assert change.snippet == "unwanted code"

    def test_change_cannot_be_both_applied_and_rejected(self):
        """Test that a change cannot be both applied and rejected."""
        with pytest.raises(ValueError, match="cannot be both applied and rejected"):
            StagedChange(
                change_id="test_invalid",
                change_type=ChangeType.CREATE,
                file_path="/tmp/test.txt",
                content="test",
                applied=True,
                rejected=True,
            )

    def test_to_dict(self):
        """Test serializing change to dictionary."""
        change = StagedChange(
            change_id="test_dict",
            change_type=ChangeType.REPLACE,
            file_path="/tmp/test.txt",
            old_str="old",
            new_str="new",
            description="Test replacement",
        )
        d = change.to_dict()
        assert d["change_id"] == "test_dict"
        assert d["change_type"] == "REPLACE"
        assert d["old_str"] == "old"
        assert d["new_str"] == "new"
        assert d["description"] == "Test replacement"

    def test_from_dict(self):
        """Test creating change from dictionary."""
        data = {
            "change_id": "from_dict",
            "change_type": "DELETE_SNIPPET",
            "file_path": "/tmp/test.txt",
            "snippet": "to delete",
            "created_at": 1234567890.0,
            "description": "Delete test",
            "applied": False,
            "rejected": False,
        }
        change = StagedChange.from_dict(data)
        assert change.change_id == "from_dict"
        assert change.change_type == ChangeType.DELETE_SNIPPET
        assert change.snippet == "to delete"
        assert change.created_at == 1234567890.0

    def test_from_dict_defaults(self):
        """Test that from_dict handles missing optional fields."""
        data = {
            "change_id": "minimal",
            "change_type": "CREATE",
            "file_path": "/tmp/test.txt",
        }
        change = StagedChange.from_dict(data)
        assert change.content is None
        assert change.old_str is None
        assert change.new_str is None
        assert change.snippet is None
        assert change.applied is False
        assert change.rejected is False

    def test_round_trip(self):
        """Test to_dict -> from_dict round-trip."""
        original = StagedChange(
            change_id="round_trip",
            change_type=ChangeType.CREATE,
            file_path="/tmp/test.txt",
            content="content",
            description="Round trip test",
        )
        d = original.to_dict()
        restored = StagedChange.from_dict(d)
        assert original.change_id == restored.change_id
        assert original.change_type == restored.change_type
        assert original.content == restored.content


class TestStagedChangesSandbox:
    """Tests for StagedChangesSandbox."""

    def setup_method(self):
        """Reset sandbox before each test."""
        self.sandbox = reset_sandbox()

    def test_initial_state(self):
        """Test initial sandbox state."""
        assert self.sandbox.enabled is False
        assert self.sandbox.is_empty() is True
        assert self.sandbox.count() == 0

    def test_enable_disable(self):
        """Test enabling and disabling staging mode."""
        self.sandbox.enable()
        assert self.sandbox.enabled is True
        self.sandbox.disable()
        assert self.sandbox.enabled is False

    def test_toggle(self):
        """Test toggling staging mode."""
        initial = self.sandbox.enabled
        result = self.sandbox.toggle()
        assert result == (not initial)
        assert self.sandbox.enabled == (not initial)

    def test_add_create(self):
        """Test staging a file creation."""
        change = self.sandbox.add_create(
            "/tmp/new_file.txt", "new content", "Create test file"
        )
        assert change.change_type == ChangeType.CREATE
        assert change.content == "new content"
        assert self.sandbox.count() == 1

    def test_add_replace(self):
        """Test staging a text replacement."""
        change = self.sandbox.add_replace(
            "/tmp/file.txt", "old text", "new text", "Replace in file"
        )
        assert change.change_type == ChangeType.REPLACE
        assert change.old_str == "old text"
        assert change.new_str == "new text"
        assert self.sandbox.count() == 1

    def test_add_delete_snippet(self):
        """Test staging a snippet deletion."""
        change = self.sandbox.add_delete_snippet(
            "/tmp/file.txt", "unwanted code", "Delete snippet"
        )
        assert change.change_type == ChangeType.DELETE_SNIPPET
        assert change.snippet == "unwanted code"
        assert self.sandbox.count() == 1

    def test_get_staged_changes(self):
        """Test getting staged changes."""
        self.sandbox.add_create("/tmp/test1.txt", "content1")
        self.sandbox.add_create("/tmp/test2.txt", "content2")
        changes = self.sandbox.get_staged_changes()
        assert len(changes) == 2

    def test_get_staged_changes_excludes_applied(self):
        """Test that applied changes are excluded by default."""
        change = self.sandbox.add_create("/tmp/test.txt", "content")
        change.applied = True
        changes = self.sandbox.get_staged_changes()
        assert len(changes) == 0
        changes_incl = self.sandbox.get_staged_changes(include_applied=True)
        assert len(changes_incl) == 1

    def test_get_staged_changes_excludes_rejected(self):
        """Test that rejected changes are excluded by default."""
        change = self.sandbox.add_create("/tmp/test.txt", "content")
        change.rejected = True
        changes = self.sandbox.get_staged_changes()
        assert len(changes) == 0

    def test_get_changes_for_file(self):
        """Test getting changes for a specific file."""
        self.sandbox.add_create("/tmp/file1.txt", "content1")
        self.sandbox.add_create("/tmp/file1.txt", "content1_updated")
        self.sandbox.add_create("/tmp/file2.txt", "content2")
        changes = self.sandbox.get_changes_for_file("/tmp/file1.txt")
        assert len(changes) == 2

    def test_clear(self):
        """Test clearing all staged changes."""
        self.sandbox.add_create("/tmp/test1.txt", "content1")
        self.sandbox.add_create("/tmp/test2.txt", "content2")
        self.sandbox.clear()
        assert self.sandbox.count() == 0

    def test_remove_change(self):
        """Test removing a specific change."""
        change = self.sandbox.add_create("/tmp/test.txt", "content")
        change_id = change.change_id
        result = self.sandbox.remove_change(change_id)
        assert result is True
        assert self.sandbox.count() == 0

    def test_remove_nonexistent_change(self):
        """Test removing a change that doesn't exist."""
        result = self.sandbox.remove_change("nonexistent")
        assert result is False

    def test_count(self):
        """Test counting changes."""
        assert self.sandbox.count() == 0
        self.sandbox.add_create("/tmp/test1.txt", "content1")
        assert self.sandbox.count() == 1
        self.sandbox.add_create("/tmp/test2.txt", "content2")
        assert self.sandbox.count() == 2

    def test_is_empty(self):
        """Test is_empty check."""
        assert self.sandbox.is_empty() is True
        self.sandbox.add_create("/tmp/test.txt", "content")
        assert self.sandbox.is_empty() is False


class TestDiffGeneration:
    """Tests for diff generation."""

    def setup_method(self):
        """Reset sandbox before each test."""
        self.sandbox = reset_sandbox()

    def test_diff_for_create(self):
        """Test generating diff for file creation."""
        change = self.sandbox.add_create(
            "/tmp/new_file.txt", "line1\nline2\n", "Create file"
        )
        diff = self.sandbox.generate_diff(change)
        assert "/dev/null" in diff
        assert "b/new_file.txt" in diff
        assert "+line1" in diff
        assert "+line2" in diff

    def test_diff_for_replace(self, tmp_path):
        """Test generating diff for text replacement."""
        test_file = tmp_path / "test.txt"
        test_file.write_text("hello world\n")
        change = self.sandbox.add_replace(
            str(test_file), "hello", "goodbye", "Replace hello"
        )
        diff = self.sandbox.generate_diff(change)
        assert "-hello world" in diff
        assert "+goodbye world" in diff

    def test_diff_for_replace_with_cache(self, tmp_path):
        """Test that file cache is used for replacements."""
        test_file = tmp_path / "test.txt"
        test_file.write_text("original content\n")
        change = self.sandbox.add_replace(
            str(test_file), "cached", "modified", "Replace"
        )
        # Cache has "cached" so replacement should apply to cache, not file
        cache = {str(test_file): "cached content\n"}
        diff = self.sandbox.generate_diff(change, file_cache=cache)
        # Should use cached content, not file content
        assert "-cached content" in diff
        assert "+modified content" in diff
        assert "original" not in diff

    def test_diff_for_delete_snippet(self, tmp_path):
        """Test generating diff for snippet deletion."""
        test_file = tmp_path / "test.txt"
        test_file.write_text("keep this\nunwanted\nkeep that\n")
        change = self.sandbox.add_delete_snippet(
            str(test_file), "unwanted\n", "Delete unwanted"
        )
        diff = self.sandbox.generate_diff(change)
        assert "-unwanted" in diff

    def test_combined_diff(self, tmp_path):
        """Test generating combined diff for all changes."""
        test_file1 = tmp_path / "file1.txt"
        test_file1.write_text("file1 content\n")
        test_file2 = tmp_path / "file2.txt"
        test_file2.write_text("file2 content\n")

        self.sandbox.add_create(
            str(tmp_path / "new.txt"), "new content\n", "Create new"
        )
        self.sandbox.add_replace(str(test_file1), "content", "modified", "Modify file1")
        self.sandbox.add_delete_snippet(str(test_file2), "file2", "Delete from file2")

        combined = self.sandbox.generate_combined_diff()
        assert "Create new" in combined
        assert "Modify file1" in combined
        assert "Delete from file2" in combined

    def test_combined_diff_empty(self):
        """Test combined diff with no changes."""
        diff = self.sandbox.generate_combined_diff()
        assert diff == ""

    def test_preview_changes(self, tmp_path):
        """Test preview changes grouped by file."""
        test_file = tmp_path / "test.txt"
        test_file.write_text("content\n")

        self.sandbox.add_replace(str(test_file), "content", "modified", "Replace")
        self.sandbox.add_replace(str(test_file), "modified", "final", "Replace again")

        preview = self.sandbox.preview_changes()
        assert str(test_file) in preview
        # preview_changes returns raw diffs (no descriptions), grouped by file
        diff_text = preview[str(test_file)]
        assert "-content" in diff_text
        assert "+modified" in diff_text


class TestSaveLoadDisk:
    """Tests for save_to_disk and load_from_disk."""

    def setup_method(self):
        """Reset sandbox before each test."""
        self.sandbox = reset_sandbox()

    def test_save_to_disk(self, tmp_path):
        """Test saving changes to disk."""
        # Patch STAGE_DIR to use tmp_path
        import code_puppy.staged_changes as sc

        original_stage_dir = sc.STAGE_DIR
        sc.STAGE_DIR = tmp_path

        try:
            self.sandbox.add_create("/tmp/test.txt", "content")
            save_path = self.sandbox.save_to_disk()
            assert save_path.exists()

            # Verify file contains valid JSON
            with open(save_path, "r") as f:
                data = json.load(f)
            assert "session_id" in data
            assert "changes" in data
            assert len(data["changes"]) == 1
        finally:
            sc.STAGE_DIR = original_stage_dir

    def test_load_from_disk(self, tmp_path):
        """Test loading changes from disk."""
        import code_puppy.staged_changes as sc

        original_stage_dir = sc.STAGE_DIR
        sc.STAGE_DIR = tmp_path

        try:
            # Create and save changes
            self.sandbox.add_create("/tmp/test.txt", "content")
            self.sandbox.save_to_disk()

            # Create new sandbox and load
            new_sandbox = StagedChangesSandbox()
            loaded = new_sandbox.load_from_disk(self.sandbox._session_id)

            assert loaded is True
            assert new_sandbox.count() == 1
            changes = new_sandbox.get_staged_changes()
            assert changes[0].content == "content"
        finally:
            sc.STAGE_DIR = original_stage_dir

    def test_load_from_disk_nonexistent(self, tmp_path):
        """Test loading from nonexistent file."""
        import code_puppy.staged_changes as sc

        original_stage_dir = sc.STAGE_DIR
        sc.STAGE_DIR = tmp_path

        try:
            loaded = self.sandbox.load_from_disk("nonexistent")
            assert loaded is False
        finally:
            sc.STAGE_DIR = original_stage_dir

    def test_save_load_round_trip(self, tmp_path):
        """Test complete save/load round-trip."""
        import code_puppy.staged_changes as sc

        original_stage_dir = sc.STAGE_DIR
        sc.STAGE_DIR = tmp_path

        try:
            # Add various change types
            self.sandbox.add_create("/tmp/create.txt", "new file")
            self.sandbox.add_replace("/tmp/replace.txt", "old", "new")
            self.sandbox.add_delete_snippet("/tmp/delete.txt", "snippet")

            # Save
            self.sandbox.save_to_disk()

            # Load into new sandbox
            new_sandbox = StagedChangesSandbox()
            loaded = new_sandbox.load_from_disk(self.sandbox._session_id)

            assert loaded is True
            assert new_sandbox.count() == 3

            # Verify change types
            changes = new_sandbox.get_staged_changes()
            types = {c.change_type for c in changes}
            assert ChangeType.CREATE in types
            assert ChangeType.REPLACE in types
            assert ChangeType.DELETE_SNIPPET in types
        finally:
            sc.STAGE_DIR = original_stage_dir

    def test_save_load_preserves_enabled_state(self, tmp_path):
        """Test that enabled state is preserved across save/load."""
        import code_puppy.staged_changes as sc

        original_stage_dir = sc.STAGE_DIR
        sc.STAGE_DIR = tmp_path

        try:
            self.sandbox.enable()
            self.sandbox.save_to_disk()

            new_sandbox = StagedChangesSandbox()
            new_sandbox.load_from_disk(self.sandbox._session_id)

            assert new_sandbox.enabled is True
        finally:
            sc.STAGE_DIR = original_stage_dir


class TestApplyReject:
    """Tests for apply and reject operations."""

    def setup_method(self):
        """Reset sandbox before each test."""
        self.sandbox = reset_sandbox()

    def test_apply_create(self, tmp_path):
        """Test applying a CREATE change."""
        test_file = tmp_path / "new_file.txt"
        change = self.sandbox.add_create(str(test_file), "new content")

        # Apply the change
        from code_puppy.command_line.staged_commands import _apply_single_change

        result = _apply_single_change(change)

        assert result is True
        assert test_file.exists()
        assert test_file.read_text() == "new content"

    def test_apply_replace(self, tmp_path):
        """Test applying a REPLACE change."""
        test_file = tmp_path / "test.txt"
        test_file.write_text("hello world\n")

        change = self.sandbox.add_replace(str(test_file), "hello", "goodbye")

        from code_puppy.command_line.staged_commands import _apply_single_change

        result = _apply_single_change(change)

        assert result is True
        assert test_file.read_text() == "goodbye world\n"

    def test_apply_delete_snippet(self, tmp_path):
        """Test applying a DELETE_SNIPPET change."""
        test_file = tmp_path / "test.txt"
        test_file.write_text("keep this\nunwanted\nkeep that\n")

        change = self.sandbox.add_delete_snippet(str(test_file), "unwanted\n")

        from code_puppy.command_line.staged_commands import _apply_single_change

        result = _apply_single_change(change)

        assert result is True
        assert test_file.read_text() == "keep this\nkeep that\n"

    def test_reject_changes(self):
        """Test rejecting changes."""
        self.sandbox.add_create("/tmp/test1.txt", "content1")
        self.sandbox.add_create("/tmp/test2.txt", "content2")

        # Mark as rejected (simulating _reject_staged_changes)
        for change in self.sandbox.get_staged_changes():
            change.rejected = True

        # Clear
        self.sandbox.clear()

        assert self.sandbox.count() == 0

    def test_apply_missing_file_fails(self):
        """Test that applying REPLACE to nonexistent file fails."""
        change = self.sandbox.add_replace("/nonexistent/file.txt", "old", "new")

        from code_puppy.command_line.staged_commands import _apply_single_change

        result = _apply_single_change(change)

        assert result is False
        assert change.applied is False


class TestConcurrency:
    """Tests for concurrent access."""

    def test_concurrent_adds(self):
        """Test adding changes from multiple threads."""
        sandbox = StagedChangesSandbox()
        results = []

        def add_change(idx):
            change = sandbox.add_create(f"/tmp/thread_{idx}.txt", f"content_{idx}")
            results.append(change.change_id)

        threads = [threading.Thread(target=add_change, args=(i,)) for i in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert sandbox.count() == 10
        assert len(set(results)) == 10  # All IDs unique


class TestEdgeCases:
    """Tests for edge cases."""

    def test_empty_content_create(self):
        """Test creating file with empty content."""
        sandbox = StagedChangesSandbox()
        change = sandbox.add_create("/tmp/empty.txt", "")
        assert change.content == ""
        assert sandbox.count() == 1

    def test_empty_old_str_replace(self):
        """Test replacement with empty old string."""
        sandbox = StagedChangesSandbox()
        change = sandbox.add_replace("/tmp/test.txt", "", "new")
        assert change.old_str == ""
        assert sandbox.count() == 1

    def test_special_characters_in_content(self):
        """Test handling special characters."""
        sandbox = StagedChangesSandbox()
        content = "line1\nline2\n\ttab\n\"quotes\"\n'single quotes'"
        change = sandbox.add_create("/tmp/special.txt", content)
        assert change.content == content

    def test_large_content(self):
        """Test handling large content."""
        sandbox = StagedChangesSandbox()
        large_content = "x" * 100000
        change = sandbox.add_create("/tmp/large.txt", large_content)
        assert len(change.content) == 100000

    def test_unicode_content(self):
        """Test handling unicode content."""
        sandbox = StagedChangesSandbox()
        content = "Hello 世界 🌍 café"
        change = sandbox.add_create("/tmp/unicode.txt", content)
        assert change.content == content

    def test_get_summary(self):
        """Test summary generation."""
        sandbox = StagedChangesSandbox()
        sandbox.add_create("/tmp/create.txt", "content")
        sandbox.add_replace("/tmp/replace.txt", "old", "new")
        sandbox.enable()

        summary = sandbox.get_summary()
        assert summary["total"] == 2
        assert "CREATE" in summary["by_type"]
        assert "REPLACE" in summary["by_type"]
        assert summary["by_file"] == 2
        assert summary["enabled"] is True
        assert "session_id" in summary


class TestGlobalFunctions:
    """Tests for module-level convenience functions."""

    def test_get_sandbox_singleton(self):
        """Test that get_sandbox returns same instance."""
        sandbox1 = get_sandbox()
        sandbox2 = get_sandbox()
        assert sandbox1 is sandbox2

    def test_reset_sandbox(self):
        """Test that reset_sandbox creates new instance."""
        sandbox1 = get_sandbox()
        sandbox2 = reset_sandbox()
        assert sandbox1 is not sandbox2
        assert sandbox2.count() == 0

    def test_convenience_functions(self, tmp_path):
        """Test module-level convenience functions."""
        from code_puppy.staged_changes import (
            clear_staged,
            get_staged_count,
            stage_create,
            stage_delete_snippet,
            stage_replace,
        )

        stage_create(str(tmp_path / "test.txt"), "content")
        stage_replace(str(tmp_path / "test2.txt"), "old", "new")
        stage_delete_snippet(str(tmp_path / "test3.txt"), "snippet")

        assert get_staged_count() == 3

        clear_staged()
        assert get_staged_count() == 0
