# zig-agent

Minimal local coding agent written in Zig. It chats with a local Ollama model and supports a small JSON tool protocol for basic coding tasks.

## Requirements

- Zig 0.15.x
- Ollama running locally
- Linux or macOS terminal

## Install And Run Ollama

Install Ollama from <https://ollama.com/download>, then start it:

```bash
ollama serve
```

In another terminal, pull a coding model:

```bash
ollama pull qwen3.6:27b-coding-nvfp4
```

Run the agent:

```bash
OLLAMA_MODEL=qwen3.6:27b-coding-nvfp4 zig build run
```

By default, `zig-agent` uses:

- `OLLAMA_BASE_URL=http://127.0.0.1:11434`
- `OLLAMA_MODEL=qwen3.6:27b-coding-nvfp4`

## Usage

```bash
zig build run
```

The app opens a full-screen terminal UI using the alternate screen and a Catppuccin Mocha truecolor theme. Type messages in the single-line input field at the bottom. Use `/exit` or `/quit` to leave.

Example with qwen3.6:

```bash
ollama pull qwen3.6:27b-coding-nvfp4
OLLAMA_MODEL=qwen3.6:27b-coding-nvfp4 zig build run
```

## Tools

The model can request tools by replying with only JSON:

```json
{
  "tool": "read_file",
  "args": {
    "path": "src/main.zig"
  }
}
```

Supported tools:

- `read_file(path, offset?, limit?)` reads 100 numbered lines from offset
- `write_file(path, content)` shows a numbered diff when overwriting
- `list_files(path)`
- `run_shell(command)`
- `grep(pattern, path?, include?)` returns matches with line numbers and supports simple `a|b` alternation, not full regex
- `edit(path, oldString, newString)` shows a numbered diff

Safety behavior:

- Shell commands are shown and require confirmation before running.
- Existing files require confirmation before overwrite.
- File operations are restricted to relative paths inside the current working directory.

## Build

```bash
zig build
```
