# Nikxel - Your Pixel Desktop Companion

A tiny pixel-art character that lives on your macOS desktop. It watches your AI terminal agents work — thinks when they think, jumps when tasks complete.

![Nikxel](nikxel_avatar.png)

## What it does

| Feature | Trigger |
|---|---|
| 🐱 **Floats on desktop** | Always visible above all windows |
| 🤔 **Thinking mode** | When Claude Code, OpenCode, Cursor, Codex, or any AI agent is working |
| 🎉 **Celebration jump** | When the agent completes a task |
| 🖱️ **Draggable** | Click and drag anywhere — stretches like mochi, springs back on release |
| ⌨️ **Overheat** | Turns red + steams when typing >30 WPM |
| 💭 **Thinking dots** | Animated "..." above head during agent processing |

## Quick Start

### Step 1: Create your sprite sheet

1. Open `sprite_prompt.txt`
2. Copy the entire prompt
3. Paste into [Gemini](https://gemini.google.com) or any AI image generator
4. Attach a photo of yourself as reference
5. Save the output as `final_sprite.png` in this folder

### Step 2: Run setup

Double-click `setup.command`

### Step 3: Grant permissions

On first launch:
- Click **Open Settings** when prompted
- Enable **Nikxel** under Privacy & Security → Accessibility
- Restart Nikxel

That's it. Your pixel companion is live.

## Requirements

- macOS 13.0 or later
- Python 3 with Pillow (`pip3 install Pillow`)
- Gemini or any sprite-sheet-capable AI image generator

## Customizing

### Make your own character
1. Replace `final_sprite.png` with your new sprite sheet (7 rows × 4 columns, magenta background)
2. Re-run `setup.command`

### Add an AI agent
Edit `src/AgentMonitor.swift`, add the process name to `agentNames`, rebuild with `build.sh`.

### Supported agents (autodetected)
opencode · claude · claude-code · codex · cursor · antigravity · kiro

## How it works

- **macOS floating window**: Transparent, borderless, always-on-top overlay
- **Agent detection**: Polls `ps aux` for known agent process names + CPU activity
- **Sprite rendering**: Nearest-neighbor pixel scaling at 156×156
- **Typing detection**: macOS CGEventTap (requires Accessibility permission)

## License

MIT — use it, modify it, share it.

Built with Swift + AppKit. No telemetry. No internet connection. Your desktop, your character.
