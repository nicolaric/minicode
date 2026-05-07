# minicode

`minicode` is a minimal local coding agent written in Zig. It runs in a full-screen terminal UI, chats with a local Ollama model, streams responses, and lets the model request a small set of file and shell tools through JSON tool calls.

## Installation

### Homebrew

```bash
brew install nicolascavallin/tap/minicode
```

### Build from source

See [Prerequisites](#prerequisites) and [Build and run](#build-and-run) sections below.

## Prerequisites

- Zig 0.15.x
- Ollama
- `curl` available on `PATH`
- macOS or Linux terminal

Windows is not currently documented as a supported platform.

## Ollama setup

Install Ollama from <https://ollama.com/download>, then start the service:

```bash
ollama serve
```

In another terminal, pull the default coding model:

```bash
ollama pull qwen3.6:27b-coding-nvfp4
```

By default, `minicode` uses:

- `OLLAMA_BASE_URL=http://127.0.0.1:11434`
- `OLLAMA_MODEL=qwen3.6:27b-coding-nvfp4`

Override them when needed:

```bash
OLLAMA_BASE_URL=http://127.0.0.1:11434 OLLAMA_MODEL=qwen3.6:27b-coding-nvfp4 zig build run
```

You can also set defaults in `~/.config/minicode/config.json`:

```json
{
  "model": "qwen3.6:27b-coding-nvfp4",
  "base_url": "http://127.0.0.1:11434"
}
```

Environment variables take precedence over the config file.

Syntax highlighting is enabled by default. Set `NIC_SYNTAX_HIGHLIGHTING` to a truthy value (`true`, `1`, or `yes`) to enable it explicitly; any other value disables it.

## Build and run

Build the executable:

```bash
zig build
```

Run from source:

```bash
zig build run
```

After building, the installed executable is available at:

```bash
./zig-out/bin/minicode
```

## Terminal UI controls

`minicode` opens a full-screen alternate terminal UI. The input line is at the bottom of the screen.

- `Enter`: send the current message
- `/exit` or `/quit`: exit
- `Ctrl+C`: exit while idle; cancel the current stream/tool turn while busy
- `Esc`: cancel while busy
- `Up` / `Down`: scroll the transcript
- `PageUp` / `PageDown`: scroll by a page
- `Left` / `Right`: move the input cursor
- `Backspace`: delete the character before the cursor

While the agent is busy streaming, new messages are not submitted. Draft input is kept and can be sent after the busy turn finishes or is cancelled.

## Supported tools

The model can request tools by replying with JSON such as:

```json
{"tool":"read_file","args":{"path":"src/main.zig"}}
```

Supported tools:

- `read_file(path, offset?, limit?)`: read numbered file lines. `offset` defaults to line 1; `limit` defaults to 300 and is capped at 300.
- `write_file(path, content)`: create or overwrite a file. Overwriting an existing file requires confirmation and reports a diff.
- `list_files(path?)`: list directory contents. `path` defaults to the current directory.
- `run_shell(command)`: run a shell command after confirmation.
- `glob(pattern, path?)`: list files matching a glob pattern, optionally from `path`.
- `grep(pattern, path?, include?, case_sensitive?, context?)`: search file contents. Matching is case-insensitive by default and supports basic regex features such as `.`, character classes, anchors, and `*`, `+`, `?`; results are capped at 20 matches.
- `edit(path, oldString, newString)`: replace a unique text match in a file and report a diff.

## Safety behavior

- File paths must be relative and stay inside the current working directory.
- Absolute paths and parent-directory traversal (`..`) are rejected.
- Shell commands require confirmation before running.
- Overwriting existing files requires confirmation.
- Invalid tool JSON, unknown tools, invalid arguments, and invalid paths return tool errors instead of being executed.
- Tool calls and results are logged locally to `~/Library/Logs/minicode/tool-calls.log` on macOS, or to `$XDG_STATE_HOME/minicode/logs/tool-calls.log` / `~/.local/state/minicode/logs/tool-calls.log` on Linux. Avoid asking the agent to read, print, or operate on secrets unless you are comfortable with those values appearing in local logs.

## Troubleshooting

- **Ollama is not running:** start it with `ollama serve`, then run `zig build run` again.
- **Model missing or unavailable:** pull the default model with `ollama pull qwen3.6:27b-coding-nvfp4`, or set `OLLAMA_MODEL` to a model that exists locally.
- **Custom Ollama endpoint fails:** check `OLLAMA_BASE_URL` and confirm the endpoint exposes Ollama's `/api/chat` API.
- **`curl` is missing:** install `curl` and ensure it is available on `PATH`; streaming uses the `curl` command.
- **Terminal display or input issues:** use a macOS or Linux terminal with alternate-screen and ANSI escape support, then restart the app to restore terminal state if needed.
