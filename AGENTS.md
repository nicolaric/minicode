# minicode Agent Notes

## Context Tracking System

This codebase includes a **context tracking system** that helps the agent maintain awareness during long conversation turns.

### Overview

The `ContextTracker` (in `src/context_tracker.zig`) monitors the agent's progress through a conversation turn and generates periodic summaries after every 4 rounds of thinking/tool calls.

### Purpose

- **Replace pruned thinking**: After 4 rounds, thinking content is pruned from context. This summary captures the intent and project understanding that would otherwise be lost
- **Maintain awareness**: Helps the agent remember what it was looking for and what it learned about the project structure
- **Long conversation support**: Especially helpful when editing multiple files or exploring large codebases

### How It Works

1. **Round counting**: Each thinking phase and tool execution increments a counter
2. **Context extraction**: 
   - Project type is inferred from file extensions (e.g., `.zig`, `.rs`, `Cargo.toml`)
   - Files touched are tracked (unique paths)
   - Key discoveries are captured (grep results, file modifications)
3. **Incremental summary generation**: After every 4 rounds, a minimal delta summary is generated. The tracker stores its previous output and only emits new/changed items:
   - Project info (only on first summary)
   - New discoveries since last report
   - Changed intent
   - Returns `null` if nothing new to report
4. **UI display**: The summary appears in the conversation as a system message

### Integration Points

- **App struct** (`src/tui/app.zig`): 
  - Field: `tracker: ContextTracker`
  - Initialized in `init()`, cleaned up in `deinit()`
  - Reset on `/new` command via `resetConversation()`
  
- **Tracking triggers**:
  - **Thinking analyzed** in `streamingCallback()` to extract intent ("Looking to...", "Trying to...")
  - **Tool executions** recorded in `completeTurn()` to detect project type and patterns being searched
  - **Summary generated** automatically via `generateContextSummaryIfNeeded()` after every 4 rounds

### Configuration

- `max_rounds_before_summary = 4` - Configurable in `src/context_tracker.zig`

### What Gets Captured

The summary includes:
- **Project type** - Inferred from file extensions and build files
- **Build system** - Detected from build.zig, Cargo.toml, package.json, etc.
- **Search intent** - "Looking for 'X'" when grep is used
- **Current work** - "Working on file: X" when editing files
- **Extracted intent** - "Looking to implement feature X" parsed from thinking

### Supported Project Types

The tracker auto-detects:
- **Zig** (`.zig`, `build.zig`)
- **Rust** (`.rs`, `Cargo.toml`)
- **Python** (`.py`, `requirements.txt`, `pyproject.toml`)
- **TypeScript/JavaScript** (`.js`, `.ts`, `package.json`)
- **Go** (`.go`, `go.mod`)
- **C/C++** (`.c`, `.h`, `.cpp`, `.hpp`)
- **Java** (`.java`)
- **Ruby** (`.rb`)

### Future Enhancements

Potential improvements:
- Make round threshold configurable via settings
- Track function/class names discovered
- Remember search patterns that were successful
- Track project structure (directory hierarchy)
