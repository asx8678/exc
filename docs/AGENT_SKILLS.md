# 🎯 Agent Skills Integration

> **Official Spec:** [https://agentskills.io](https://agentskills.io)

Agent Skills are reusable, modular capabilities that extend Code Puppy's functionality. Think of them as specialized training packets you can dynamically load when needed—like teaching your puppy new tricks on demand! 🐕

---

## 📋 Table of Contents

1. [What Are Agent Skills?](#what-are-agent-skills)
2. [Installing Skills](#installing-skills)
3. [Using the /skills TUI Menu](#using-the-skills-tui-menu)
4. [How Skills Work](#how-skills-work)
5. [Creating Your Own Skills](#creating-your-own-skills)
6. [Configuration Options](#configuration-options)
7. [Security Considerations](#security-considerations)

---

## What Are Agent Skills?

Agent Skills are pre-packaged capabilities that can be dynamically discovered, loaded, and used by agents. They consist of:

- **SKILL.md** - The main instruction file with YAML frontmatter metadata
- **Resources** - Optional supporting files (templates, examples, configs)
- **Metadata** - Name, description, version, author, and tags

Skills enable you to:

- 📦 Share reusable workflows and best practices
- 🎯 Give agents specialized knowledge for specific tasks
- 🔌 Extend functionality without modifying core code
- 🏗️ Build domain-specific expertise (DevOps, security, testing, etc.)

---

## Installing Skills

Skills are installed by placing them in designated skill directories. Code Puppy scans these directories at startup to discover available skills.

### Default Skill Directories

By default, Code Puppy looks for skills in:

1. **`~/.code_puppy/skills/`** - User-level skills (global)
2. **`./skills/`** - Project-level skills (local)

### Installation Steps

1. **Create the skills directory** (if it doesn't exist):

   ```bash
   mkdir -p ~/.code_puppy/skills
   ```

2. **Download or clone a skill** into the directory:

   ```bash
   # Example: Installing a python-testing skill
   cd ~/.code_puppy/skills
   git clone https://github.com/example/code-puppy-python-testing.git python-testing
   
   # Or manually create the skill directory
   mkdir my-custom-skill
   ```

3. **Verify the skill** has a `SKILL.md` file:

   ```bash
   ls ~/.code_puppy/skills/my-custom-skill/SKILL.md
   ```

4. **Refresh skill discovery**:

   ```
   /skills refresh
   ```

### Skill Directory Structure

```
~/.code_puppy/skills/
├── python-testing/
│   ├── SKILL.md          # Required: Skill instructions + metadata
│   ├── pytest.ini        # Optional: Supporting resource
│   └── conftest.py.template # Optional: Supporting resource
├── kubernetes/
│   ├── SKILL.md
│   └── k8s-templates/
└── security-audit/
    ├── SKILL.md
    └── audit-checklist.md
```

---

## Using the /skills TUI Menu

Code Puppy provides an interactive TUI (Text User Interface) for managing skills.

### Launching the Menu

```
/skills
```

This opens an interactive menu where you can browse, enable, disable, and configure skills.

### Quick Commands

| Command | Description |
|---------|-------------|
| `/skills` | Launch the interactive TUI menu |
| `/skills list` | List all discovered skills |
| `/skills enable <name>` | Enable a specific skill |
| `/skills disable <name>` | Disable a specific skill |
| `/skills toggle` | Toggle skills integration on/off |
| `/skills directories` | Manage skill directories |
| `/skills add <path>` | Add a skill directory |
| `/skills remove <num>` | Remove a skill directory by number |
| `/skills refresh` | Refresh skill cache |
| `/skills help` | Show help message |

### Interactive Menu Options

When you run `/skills`, you'll see:

```
┌─────────────────────────────────────────────────────────────┐
│                        Agent Skills                         │
├────────────┬─────────────────────┬──────────────────────────┤
│ Status     │ Name                │ Description              │
├────────────┼─────────────────────┼──────────────────────────┤
│ ✓ Enabled  │ python-testing      │ Python testing guides    │
│ ✓ Enabled  │ kubernetes          │ K8s deployment guides    │
│ ✗ Disabled │ security-audit      │ Security best practices  │
└────────────┴─────────────────────┴──────────────────────────┘

Total: 3 skills found

Commands:
  list              - List all skills
  enable <skill>    - Enable a specific skill
  disable <skill>   - Disable a specific skill
  toggle            - Toggle skills integration on/off
  directories       - Manage skill directories
  refresh           - Refresh skill cache
  help              - Show this help
  exit              - Exit skills menu
```

---

## How Skills Work

Skills integrate with agents through two mechanisms: **prompt injection** and **dedicated tools**.

### 1. Prompt Injection

When skills are enabled, Code Puppy automatically injects available skills into the system prompt:

```xml
<available_skills>
  <skill>
    <name>python-testing</name>
    <description>Expert guidance for Python testing with pytest, including fixtures, mocks, and coverage</description>
  </skill>
  <skill>
    <name>kubernetes</name>
    <description>Kubernetes deployment patterns, manifest generation, and cluster management</description>
  </skill>
</available_skills>
```

This tells the agent what skills are available without loading their full content.

### 2. Skill Tools

Agents have access to two dedicated tools for working with skills:

#### `list_or_search_skills`

Lists all available skills, optionally filtered by a search query.

**When to use:**
- At the start of a task to see what's available
- When you need to find a skill matching specific keywords

**Example:**
```python
# List all skills
list_or_search_skills()

# Search for testing-related skills
list_or_search_skills(query="testing")
```

**Returns:**
- `skills`: List of skill metadata (name, description, path, tags)
- `total_count`: Total number of skills found
- `query`: The search query (if provided)

#### `activate_skill`

Loads and activates a specific skill by name.

**When to use:**
- When a user's task matches a skill's description
- To load the full instructions for a specific capability

**Example:**
```python
activate_skill(skill_name="python-testing")
```

**Returns:**
- `skill_name`: Name of the activated skill
- `content`: Full SKILL.md content (including instructions)
- `resources`: List of available resource files
- `error`: Error message (if activation failed)

### Skill Activation Flow

1. **Discovery** → Code Puppy scans skill directories at startup
2. **Prompt Injection** → Available skills are listed in the system prompt
3. **User Request** → User asks for help with a specific domain
4. **Skill Selection** → Agent identifies the relevant skill
5. **Activation** → Agent calls `activate_skill(skill_name="...")`
6. **Execution** → Agent follows the loaded skill instructions

---

## Creating Your Own Skills

Creating a skill is straightforward. You need a directory with at least one file: `SKILL.md`.

### SKILL.md Format

The `SKILL.md` file uses **YAML frontmatter** for metadata followed by **Markdown content** for instructions.

```markdown
---
name: python-testing
description: Expert guidance for Python testing with pytest, including fixtures, mocks, and coverage
version: 1.0.0
author: Your Name
tags:
  - python
  - testing
  - pytest
  - quality
---

# Python Testing Expert Skill

## When to Use This Skill

Use this skill when the user needs help with:
- Writing or optimizing test suites
- Setting up pytest configurations
- Test best practices and patterns
- Mocking and fixtures

## Instructions

### 1. Test Best Practices

Always follow these principles:

- Use descriptive test names that explain the behavior
- Follow the Arrange-Act-Assert pattern
- Keep tests independent and isolated
- Use fixtures for shared setup

### 2. Test Organization

- Group related tests in classes
- Use markers to categorize tests
- Keep test files alongside source or in tests/

### 3. Common Patterns

```python
# Fixture example
import pytest

@pytest.fixture
def sample_data():
    return {"key": "value"}

def test_with_fixture(sample_data):
    assert sample_data["key"] == "value"
```

## Available Tools

When this skill is activated, you can use standard file tools to:
- Create test files
- Generate pytest.ini configurations
- Set up conftest.py

## Resources

This skill includes:
- `pytest.ini.template` - Starter pytest configuration
- `conftest.py.example` - Common fixture patterns
```

### Required Frontmatter Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | ✅ Yes | Unique skill identifier (kebab-case recommended) |
| `description` | string | ✅ Yes | Brief description of what the skill does |
| `version` | string | ❌ No | Semantic version (e.g., "1.0.0") |
| `author` | string | ❌ No | Author name or email |
| `tags` | list | ❌ No | List of keywords for categorization |

### Frontmatter Examples

**Minimal (required only):**
```yaml
---
name: my-skill
description: Does something useful
---
```

**Complete (all fields):**
```yaml
---
name: python-testing
description: Comprehensive Python testing with pytest, including fixtures, mocks, and coverage
version: 2.1.0
author: Jane Developer <jane@example.com>
tags:
  - python
  - testing
  - pytest
  - quality
---
```

### Including Resources

You can bundle additional files with your skill. Place them in the same directory as `SKILL.md`:

```
my-skill/
├── SKILL.md              # Required
├── template.py           # Optional resource
├── config.yaml           # Optional resource
└── examples/
    └── sample.json       # Optional resource
```

These resources are listed when the skill is activated via the `resources` field in the output.

### Skill Naming Conventions

- Use **kebab-case** (e.g., `python-testing`, `api-client`)
- Keep names **descriptive but concise**
- Avoid generic names like `utils` or `helpers`
- Prefix domain-specific skills (e.g., `aws-s3`, `gcp-cloudrun`)

### Testing Your Skill

1. Place your skill in `~/.code_puppy/skills/`
2. Run `/skills refresh`
3. Verify it appears in `/skills list`
4. Test activation by asking an agent to use it

---

## Configuration Options

Agent Skills can be configured through Code Puppy's configuration system.

### Configuration Keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `skills_enabled` | boolean | `true` | Globally enable/disable skills integration |
| `skill_directories` | JSON list | `["~/.code_puppy/skills", "./skills"]` | Directories to scan for skills |
| `disabled_skills` | JSON list | `[]` | List of skill names to disable |

### Setting Configuration Values

Use the `/set` command to configure skills:

```
# Disable skills integration entirely
/set skills_enabled = false

# Enable skills integration
/set skills_enabled = true

# Add a custom skill directory
/set skill_directories = "[\"/path/to/skills\", \"~/.code_puppy/skills\"]"

# Disable specific skills
/set disabled_skills = "[\"skill-one\", \"skill-two\"]"
```

### Managing Skill Directories

You can also manage directories via the TUI:

```
/skills directories
```

This shows:
```
Skill Directories:
  1. ✓ /home/user/.code_puppy/skills
  2. ✓ /path/to/project/skills
  3. ✗ /old/path (does not exist)

Commands:
  add <path>        - Add a skill directory
  remove <num>      - Remove directory by number
  list              - List directories
  back              - Return to main menu
```

### Configuration File Location

Settings are stored in `~/.code_puppy/puppy.cfg`:

```ini
[puppy]
skills_enabled = true
skill_directories = ["/home/user/.code_puppy/skills", "./skills"]
disabled_skills = ["deprecated-skill"]
```

---

## Security Considerations

⚠️ **Important:** Skills execute with the same permissions as Code Puppy. Follow these security best practices:

### Skill Sources

- **Only install skills from trusted sources**
- Review skill content before installing
- Be cautious with skills that request elevated permissions
- Prefer skills from verified repositories or official sources

### Skill Content

- **Review SKILL.md** before using a new skill
- Check what tools and commands the skill uses
- Be wary of skills that:
  - Execute arbitrary shell commands
  - Access sensitive files or environment variables
  - Make network requests to unknown endpoints
  - Modify system configurations

### File System Access

Skills can access:
- Files within their own directory
- The project working directory
- Any files Code Puppy has access to

**Recommendation:** Run Code Puppy with minimal necessary permissions.

### Network Security

Skills may include instructions that:
- Download resources from the internet
- Call external APIs
- Clone repositories

**Best practice:** Review any URLs or network operations in skill instructions.

### Sandboxing Recommendations

For maximum security:

1. **Use a dedicated environment** (VM or restricted user)
2. **Limit file system access** to only necessary directories
3. **Monitor network activity** when using new skills
4. **Keep skills updated** to receive security patches
5. **Disable unused skills** to reduce attack surface

### Reporting Security Issues

If you discover a security vulnerability in a skill:

1. Disable the skill immediately: `/skills disable <skill-name>`
2. Report to the skill author
3. For core skills functionality issues, report to Code Puppy

### Skill Verification

Before installing a skill, verify:

- [ ] Source is trustworthy (official repo, known author)
- [ ] SKILL.md content is reviewed
- [ ] No suspicious shell commands or network calls
- [ ] Resource files are safe (no binaries, scripts are reviewed)
- [ ] Skill is actively maintained

---

## Example Workflow

Here's a complete example of using Agent Skills:

```bash
# 1. Start Code Puppy
code-puppy

# 2. Check available skills
/skills list

# 3. Start a conversation with an agent
/agent code-puppy

# 4. The agent automatically knows about available skills
# When you ask for testing help, it activates the testing skill

# User: Help me write tests for this Python app
# Agent: I'll help you write tests for this Python app. Let me activate the python-testing skill first.
# [Agent calls activate_skill(skill_name="python-testing")]
# [Agent follows skill instructions to create test files, pytest.ini, conftest.py]
```

---

## Additional Resources

- **Official Spec:** [https://agentskills.io](https://agentskills.io)
- **Skill Registry:** Community-contributed skills (coming soon)
- **Creating Skills Guide:** This document + spec at agentskills.io

---

*Happy skill building! 🐕🎯*
