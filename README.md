<div align="center">

# 🌆 Neon Dusk

### A retro-synthwave theme for the Claude desktop app

<p>
  <img alt="Platform: macOS" src="https://img.shields.io/badge/platform-macOS-1c1830?style=for-the-badge&labelColor=14101e&color=b47dff">
  <img alt="Electron" src="https://img.shields.io/badge/electron-patched-1c1830?style=for-the-badge&labelColor=14101e&color=4df0ff">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-1c1830?style=for-the-badge&labelColor=14101e&color=ff4dd2">
  <img alt="Style" src="https://img.shields.io/badge/style-synthwave-1c1830?style=for-the-badge&labelColor=14101e&color=ffc266">
</p>

<p>
  <strong>Dark greys. Neon purples. Hot magenta. Cyan highlights.</strong><br>
  A persistent dark theme for Claude desktop, built by patching <code>app.asar</code>.
</p>

---

</div>

## ⚡ Quick start

```bash
git clone https://github.com/ben4mn/claude-neon-dusk.git ~/claude-theme
cd ~/claude-theme
# Quit Claude first (⌘-Q), then:
./patch.sh
```

That's it. Launch Claude from the Dock — the theme applies automatically to every window.

To revert:

```bash
./uninstall.sh
```

## 📸 What you get

| Element              | Treatment                                                      |
| -------------------- | -------------------------------------------------------------- |
| **Canvas**           | Deep dark grey-purple (`#14101e`)                              |
| **Panels, cards**    | Raised dark violet-grey with soft violet borders               |
| **Primary buttons**  | Solid magenta, violet on hover, subtle lift                    |
| **Links**            | Cyan with thin underline, glow on hover                        |
| **Code blocks**      | Amber mono on dark inset, violet glow                          |
| **User messages**    | Left border: lime (`#b8ff4d`)                                  |
| **Assistant messages** | Left border: violet (`#b47dff`)                              |
| **Scrollbars**       | Thin violet, glow on hover                                     |
| **Selection**        | Magenta fill, dark text                                        |
| **Focus rings**      | 1px magenta outline with offset                                |

## 🛠️ How it works

The Claude desktop app is an Electron bundle. Its `app.asar` contains:

- **Renderer HTML shells** — just window chrome; the actual chat UI is loaded from `claude.ai` into each window's `WebContents`.
- **The main process JS** (`.vite/build/index.pre.js`) — where `BrowserWindow` instances are created.

The naive approach (injecting a `<style>` tag into the shell HTML) doesn't work — the tag is in a parent document that doesn't style the loaded `claude.ai` content.

**The real trick:** append a small JS block to the main process that listens for every `web-contents-created` event and calls [`webContents.insertCSS()`](https://www.electronjs.org/docs/latest/api/web-contents#contentsinsertcsscss-options) on each page after it finishes loading. That method works on any loaded content regardless of origin.

```js
// simplified — see patch.sh for the real injector
app.on("web-contents-created", (_e, wc) => {
  wc.on("dom-ready", () => wc.insertCSS(NEON_DUSK_CSS));
});
```

### The CSS strategy

Claude's UI is built on Tailwind with HSL-triplet CSS variables (`--bg-000`, `--text-100`, `--accent-main-100`, etc.) composed via `hsl(var(--x) / alpha)`. Instead of chasing hashed class names like `.Button_primary__abc123`, **we override those design tokens at `:root`** — one elegant redefinition cascades through every styled component.

```css
:root {
  --bg-000: 258 28% 8%;      /* page canvas */
  --bg-100: 258 24% 11%;     /* sidebar, cards */
  --accent-main-100: 310 100% 66%;   /* magenta */
  /* ... */
}
```

The rest of the stylesheet is surgical fixes for things the token override doesn't reach: scrollbars, selection, focus rings, message-bubble accents.

### The full patcher

[`patch.sh`](./patch.sh) orchestrates the whole flow:

1. **Backup** the current `app.asar` to `./backups/app.asar.<timestamp>`
2. **Extract** via `npx @electron/asar`
3. **Inject** `<style>` into the shell HTMLs (cosmetic; catches edge cases)
4. **Append** the CSS-injector JS to the main process bundle
5. **Repack** the asar, atomically replace the original
6. **Disable** the `EnableEmbeddedAsarIntegrityValidation` Electron fuse (otherwise the modified asar fails the integrity check)
7. **Ad-hoc re-sign** the bundle so macOS launches it
8. **Clear** quarantine xattrs

All wrapped in a `trap ERR` that auto-rolls back to the backup if any step fails mid-flight. Idempotent — safe to re-run.

## 🎨 Customize

Edit [`neon-dusk.css`](./neon-dusk.css) and re-run `./patch.sh`. Easy knobs at the top of the file:

```css
:root {
  --nd-void:      #14101e;   /* deepest canvas */
  --nd-panel:     #1c1830;   /* raised surfaces */
  --nd-magenta:   #ff4dd2;
  --nd-violet:    #b47dff;
  --nd-cyan:      #4df0ff;
  --nd-lime:      #b8ff4d;
  --nd-amber:     #ffc266;
}
```

Want a different palette? Swap the hex values. For a completely different HSL anchor, change the `258` (violet family) on the `--bg-XXX` tokens.

## ⚠️ Gotchas

- **Auto-updates wipe the patch.** Claude's auto-updater replaces `app.asar`. Re-run `./patch.sh` after any update.
- **macOS Gatekeeper.** On first launch after patching you may see a "damaged app" dialog. System Settings → Privacy & Security → "Open Anyway." One-time.
- **No Windows/Linux support yet.** The patcher assumes `/Applications/Claude.app` (macOS). PRs welcome.
- **Electron version sensitivity.** Tested against Claude `1.3109.0` / Electron `41.2.0`. Future versions may restructure the asar; the patcher will warn if it can't find the expected files.

## 🗺️ Why not DevTools injection?

We tried. Claude's production Electron build strips `--remote-debugging-port` and `--inspect` flags — the process launches but no CDP endpoint binds. The asar-patching path is the only persistent route on a shipping build.

## 📦 What's in the box

```
.
├── README.md           ← you are here
├── LICENSE             ← MIT
├── neon-dusk.css       ← the theme (edit me)
├── patch.sh            ← installer / updater
├── uninstall.sh        ← rollback from backup
└── backups/            ← gitignored; app.asar snapshots live here
```

## 🤝 Contributing

Issues and PRs welcome — new themes, Windows/Linux support, better selectors, bug fixes. Drop a screenshot with any theme contribution.

## 📜 License

[MIT](./LICENSE) — do whatever, attribution appreciated.

---

<div align="center">

**Not affiliated with Anthropic.** Use at your own risk.

<sub>Built with a lot of `pkill`, one reboot, and an unreasonable amount of magenta.</sub>

</div>
