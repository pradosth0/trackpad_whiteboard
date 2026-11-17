# Trackpad Board

A macOS whiteboard you write on with your trackpad. The trackpad is mapped to a zone on an
unlimited board: wherever your finger touches, ink appears at the matching spot. Press Enter and
the line you wrote is recognized and replaced by typeset text and math.

Built for writing math quickly without a tablet.

## Install

Requirements: macOS 13 or later, and Apple's Command Line Tools for the Swift compiler
(`xcode-select --install` if you do not have them; full Xcode is not needed).

```bash
git clone https://github.com/pradosth0/trackpad_whiteboard.git
cd trackpad_whiteboard
./install.sh
```

The script builds the app and copies it to `/Applications` (or `~/Applications` if that folder is
not writable). The first build downloads one dependency and takes a minute or two. Open
**Trackpad Board** from Spotlight afterwards.

To update later: `git pull && ./install.sh`.

## First launch: recognition setup

The first time the app opens it asks how handwriting should be recognized. You can reopen this
dialog at any time from **Board > Recognition Setup…**

| Choice | What you need | Delay per line | Cost |
|---|---|---|---|
| Claude subscription | [Claude Code](https://claude.com/claude-code) installed and logged in | about 4 s | counts against your subscription limits |
| API key | an Anthropic API key from console.anthropic.com | faster | about $0.003 per line |
| Not now | nothing | – | the board works without recognition |

**Claude subscription.** If Claude Code is not installed, the dialog shows the install command.
After installing, run `claude` once in Terminal to log in, then relaunch the app.

**API key.** Paste the key into the dialog. It is saved only on your Mac, in
`~/.config/trackpad-board/api_key`, readable by your account alone. The `ANTHROPIC_API_KEY`
environment variable is used instead when it is set.

With either choice, a picture of each finished line is sent to Anthropic to be read.

## Using it

When the window is active the trackpad is *captured*: the cursor is frozen and hidden, and the
trackpad only draws. Press **Esc** to get the cursor back, and Esc or a click to capture again.

### Writing

| Action | What it does |
|---|---|
| Finger on the trackpad | Draws at the matching spot in the dashed zone |
| ⌘ + finger | Moves the zone around the board |
| ↩ | New line: moves the zone down by the height you used, and sends the line to recognition |
| ⇧↩ | Back to the previous line |
| ⇧ + finger | Hover: shows a pointer without drawing |
| ⌃ + finger | Moves a crosshair; your next stroke starts exactly there |
| ⌘Z | Undo (strokes, recognition, edits, deletions) |
| ⌘⌫ | Clear the board |
| ⌘= / ⌘- | Larger / smaller zone |
| ⌘↩ | Set the left margin where the zone is |

When you reach the right end of the zone and start again on the left, the zone jumps along so the
line continues (**Board > Auto-continue Lines** turns this off).

### Typing and editing

| Action | What it does |
|---|---|
| Start typing | Opens a field at the bottom and adds a typed block. Plain text by default, math between `$...$` |
| ↩ / Esc in the field | Keep the block / cancel |
| ⇧ or ⌃ + click on a block | Opens that block (typed or recognized) for editing |
| ⌘ + finger while a block is open | Moves the block |
| ⌘⌫ while a block is open | Deletes the block |
| ⌫ with the pointer or crosshair on a block | Deletes the block |

Example of typed input: `the roots of $x^2+3x+3=0$ are complex`.

### Saving

| Action | What it does |
|---|---|
| ⌘S / ⇧⌘S | Save / Save As, to a `.tboard` file |
| ⌘O | Open a saved board (double-clicking a `.tboard` file works too) |
| ⌘N | New empty board |
| ⌘E / ⇧⌘E | Export as PDF / PNG: one page sized to the content, black on white |
| ⌥⌘E | Export as LaTeX: blocks in reading order, drawings as PDF pictures next to the `.tex` file |

A saved board reopens exactly as it was: ink stays as strokes, typed and recognized blocks stay
editable, and everything keeps its position. The undo history is not saved.

The board is also kept automatically between launches: quit at any time and it comes back as you
left it, saved or not. New and Open still ask before replacing a board with unsaved changes.

### Recognition options

In the **Board** menu:

- **Recognize Lines on Enter** (⌘⇧R): turn recognition off and on.
- **Use Most Accurate Model** (⌘⇧M): Opus instead of Sonnet; fewer misread symbols, about twice the price.
- **Use Claude Code Subscription** (⌘⇧K): switch between the subscription and the API key.

## Known limits

- Recognition occasionally misreads a symbol; open the block and fix it.
- In typed plain text, accented letters render in an italic style, and `&`, `^`, `~` are dropped.
  Inside `$...$` only the LaTeX commands supported by [SwiftMath](https://github.com/mgriebling/SwiftMath) work.
- Each line is recognized on its own, without the rest of the page as context.

## Development

```bash
./build_app.sh                 # build TrackpadBoard.app in the repository folder
open TrackpadBoard.app
```

The app is a Swift package with no Xcode project. Sources are in `Sources/TrackpadBoard`:

| File | Role |
|---|---|
| `BoardView.swift` | The board: touches, zone, ink, lines, typing and editing |
| `Typeset.swift` | Typeset blocks and the `$...$` ⇄ LaTeX conversion |
| `BoardFile.swift` | The `.tboard` file format (versioned JSON) |
| `LatexExport.swift` | The LaTeX export: reading order and grouping of ink into pictures |
| `Recognizer.swift` | Recognition through the Anthropic API |
| `ClaudeCodeSession.swift` | Recognition through a long-lived `claude` process |
| `Setup.swift` | The recognition setup dialog |
| `main.swift` | Window, menus, and the checks below |

Checks that need no trackpad, run on the built binary
(`TrackpadBoard.app/Contents/MacOS/TrackpadBoard`):

| Flag | What it does |
|---|---|
| `--no-capture` | Start without freezing the cursor |
| `--render-test <latex> <out.png>` | Typeset LaTeX to a picture |
| `--source-test <text>` | Show the LaTeX produced for typed input and whether it renders |
| `--ocr-test <line.png>... [--claude-code] [--accurate]` | Send pictures through recognition and print the result and delay |
| `--type-test <prefix>` | Type sample lines with synthetic keystrokes, save pictures of the board, and check that saving and reopening gives the same board |
