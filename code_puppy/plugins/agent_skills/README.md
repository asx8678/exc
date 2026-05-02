# Agent Skills Plugin

The Agent Skills plugin provides skill management for Code-Puppy agents, enabling progressive skill disclosure to prevent context explosion when many skills are installed.

## What is Progressive Skill Disclosure?

Instead of injecting the full content of every skill into the system prompt (which causes context explosion), only **metadata** (name, description, path) is injected. The agent then pulls the full SKILL.md content **on-demand** when it decides a skill applies.

**Benefits:**
- Install 100+ skills with essentially zero context cost until needed
- Faster prompt processing
- Clear separation between skill catalog and skill implementation

## SKILL.md Format

Skills are defined by a `SKILL.md` file in a skill directory:

```yaml
---
name: python-refactoring
description: Systematic refactoring of Python code with multiple files affected
version: "1.0.0"
author: Your Name
license: MIT
tags:
  - python
  - refactoring
  - code-quality
allowed_tools:
  - read_file
  - grep
  - replace_in_file
---

# Python Refactoring Skill

## When to Use This Skill

Use this skill when you need to refactor Python code across multiple files...

## Workflow

1. First, analyze the codebase to understand the current structure...
```

### YAML Frontmatter Fields

**Required:**
- `name`: Unique identifier for the skill
- `description`: Brief description of what the skill does (shown in skill list)

**Optional:**
- `version`: Version string (e.g., "1.0.0")
- `author`: Author name
- `license`: License identifier (e.g., "MIT", "Apache-2.0")
- `tags`: List of tags for categorization
- `allowed_tools`: List of tool names this skill recommends using

### Size Limits

- Maximum SKILL.md file size: **10MB** (DoS protection)
- Skills exceeding this limit are skipped with a warning

## Skill Discovery

Skills are discovered from these directories (in precedence order):

1. `~/.code_puppy/skills/` - User-level skills (highest priority)
2. `./.code_puppy/skills/` - Project config skills
3. `./skills/` - Project workspace skills

Each skill is a subdirectory containing a `SKILL.md` file:

```
~/.code_puppy/skills/
├── python-refactoring/
│   └── SKILL.md
├── web-research/
│   └── SKILL.md
└── data-analysis/
    └── SKILL.md
```

### Duplicate Resolution

When skills share the same name, higher-precedence sources override lower ones:
- Project skills override project config skills
- Project config skills override user skills

## Using Skills in Agents

### Progressive Disclosure Mode (Default)

When progressive disclosure is enabled (the default), agents see:

```markdown
## Available Skills (Progressive Disclosure)

The following skills are available. Each shows its name, when to use it,
and the absolute path to its full instructions.
**You must read the full SKILL.md file to use a skill** — the metadata below is only a summary.

### python-refactoring
**When to use**: Systematic refactoring of Python code with multiple files affected
**Full instructions**: `/Users/you/.code_puppy/skills/python-refactoring/SKILL.md`

### web-research
**When to use**: Structured approach to gathering info from multiple web sources
**Full instructions**: `/Users/you/.code_puppy/skills/web-research/SKILL.md`
```

**To use a skill:**
1. **Recognize when a skill applies** — check "When to use" descriptions
2. **Read the full SKILL.md** — use `read_file(file_path="/path/to/skill/SKILL.md")`
3. **Follow the workflow** — the loaded SKILL.md contains detailed steps

### Legacy Mode (Deprecated)

If you disable progressive disclosure (`progressive_skill_disclosure = false`), the full content of skills without YAML frontmatter is injected directly into prompts. This is **deprecated** and not recommended for many skills.

## Configuration

### Global Enable/Disable

```bash
/skills enable    # Enable skills integration globally
/skills disable   # Disable skills integration globally
```

### Progressive Disclosure Toggle

```bash
/skills progressive           # Show current status
/skills progressive enable    # Enable progressive disclosure (default)
/skills progressive disable   # Disable (legacy full-content mode)
```

Or edit `puppy.cfg` directly:

```ini
[puppy]
progressive_skill_disclosure = true
```

### Skill Directories

Add custom skill directories:

```python
from code_puppy.plugins.agent_skills.config import add_skill_directory
add_skill_directory("/path/to/custom/skills")
```

### Disable Individual Skills

```bash
# Via the interactive menu
/skills
# Then select a skill and disable it
```

Or programmatically:

```python
from code_puppy.plugins.agent_skills.config import set_skill_disabled
set_skill_disabled("skill-name", disabled=True)
```

## Migration Path for Legacy Skills

Skills without YAML frontmatter are **deprecated** but still supported:

1. **Skills WITH frontmatter** → Use progressive disclosure (metadata-only injection)
2. **Skills WITHOUT frontmatter** → Injected with full content + deprecation warning

### Upgrading a Legacy Skill

Add YAML frontmatter to your existing SKILL.md:

```yaml
---
name: your-skill-name
description: What this skill does
---

[Your existing content here]
```

That's it! The skill will now use progressive disclosure.

## Commands

| Command | Description |
|---------|-------------|
| `/skills` | Launch interactive TUI menu |
| `/skills list` | Quick text list of all skills |
| `/skills install` | Browse & install from remote catalog |
| `/skills enable` | Enable skills integration globally |
| `/skills disable` | Disable skills integration globally |
| `/skills progressive` | Show progressive disclosure status |
| `/skills progressive enable` | Enable progressive disclosure |
| `/skills progressive disable` | Disable progressive disclosure |

## API

### Discovery

```python
from pathlib import Path
from code_puppy.plugins.agent_skills.discovery import discover_skills

skills = discover_skills([Path("~/.code_puppy/skills")])
for skill in skills:
    print(f"{skill.name}: {skill.path}")
```

### Metadata Parsing

```python
from code_puppy.plugins.agent_skills.metadata import parse_skill_metadata

metadata = parse_skill_metadata(Path("~/.code_puppy/skills/my-skill"))
if metadata:
    print(f"Name: {metadata.name}")
    print(f"Description: {metadata.description}")
    print(f"SKILL.md path: {metadata.skill_md_path}")
```

### Prompt Building

```python
from code_puppy.plugins.agent_skills.prompt_builder import (
    build_available_skills_markdown,
    build_available_skills_xml,
)

# Progressive disclosure format
markdown = build_available_skills_markdown([metadata])

# Legacy XML format
xml = build_available_skills_xml([metadata])
```

## Testing

Run the plugin tests:

```bash
python -m pytest tests/plugins/test_agent_skills.py -v
```

## Architecture

```
code_puppy/plugins/agent_skills/
├── register_callbacks.py    # Callback registration, prompt injection
├── prompt_builder.py        # XML and Markdown prompt builders
├── metadata.py              # YAML frontmatter parsing
├── discovery.py             # Skill directory scanning
├── config.py                # Configuration helpers
├── skills_menu.py           # Interactive TUI menu
├── skills_install_menu.py   # Remote catalog installer
├── skill_catalog.py         # Local skill catalog
├── remote_catalog.py        # Remote skill catalog
├── downloader.py            # Skill download logic
├── installer.py             # Skill installation
└── README.md                # This file
```

## See Also

- `code_puppy/tools/skills_tools.py` - `activate_skill` and `list_or_search_skills` tools
