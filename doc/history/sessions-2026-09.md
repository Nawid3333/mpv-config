# Session history: this mpv config repo, September 2026

Split out of `AGENTS.md` on 2026-09-14. This is the chronological
engineering log - what was investigated, what was measured, what turned
out to be wrong and why. It is reference material, read it when you need
the reasoning behind a decision; `AGENTS.md` keeps the conventions and
the current state and is the file to read first.

Cross-references inside these sections that say "above"/"below" refer to
other sections *in this file*, unless they name `AGENTS.md` explicitly.

---

## 2026-09-11 session: three real bugs found and fixed, plus a GPU benchmark

Everything in this repo up to commit `8c75b64` had been written and committed without ever being exercised live in mpv the way `input.conf` actually invokes it. Three separate, confirmed bugs were found by scripting mpv itself (a Lua script driving `script-binding`/`script-message-to` calls and reading back `glsl-shaders`/`vf`/`vo-passes` properties) rather than by reading the source. **If you're validating a future change here, prefer that same approach over re-reading the code and assuming it's wired correctly** - see "How this was actually tested" below.

1. **`script-binding gpu_toggles/*` never worked.** (Note: `cycle-anime`/`cycle-movie`/`cycle-artcnn` named below no longer exist - see the 2026-09-12 section further down; the underlying bug and fix described here are unchanged and now apply to `cycle-upscale` instead.) `input.conf` reached `cycle-anime`, `cycle-movie`, `cycle-artcnn`, `cycle-interp`, and `interp-off` via `script-binding gpu_toggles/<name>` (used for both the `Shift+A`/`Shift+F`/`Ctrl+i` keys AND every uosc menu entry under Video > Shaders / Interpolation). `script-binding` can only reach a name registered with `mp.add_key_binding`; `gpu-toggles.lua` only ever called `mp.register_script_message` for these names, which is a *different* mechanism reached only via `script-message-to`. Net effect: the keys and that entire menu section silently did nothing, on every commit since Phase 3. Fixed by adding `mp.add_key_binding(nil, '<name>', fn)` calls for all five names (see the "Key bindings" block in `gpu-toggles.lua`, just above the `register_script_message` block). Confirmed fixed by scripting `mp.command('script-binding gpu_toggles/cycle-anime')` etc. and reading back `glsl-shaders`/`vf`/`interpolation`.
2. **`set_interp_amf()` / `set_interp_rife()` called `mp.command` with 4 separate arguments instead of `mp.commandv`.** `mp.command(string)` takes exactly one argument; Lua silently drops the extra ones, so only `'no-osd'` ever reached mpv, which failed with "Command name missing." Worse, this was wrapped in `pcall`, which only catches thrown Lua errors - `mp.command`/`mp.commandv` return `nil`/`false` + `mp.last_error()` on failure rather than throwing, so `pcall` reported `ok = true` unconditionally and the code believed amf_frc/RIFE had been enabled even though nothing was added to the `vf` chain. Fixed by using `mp.commandv` directly and checking its return value (no `pcall`). If you ever wrap an `mp.command`/`mp.commandv` call in `pcall` again, you're reintroducing this - check the return value instead.
3. **RIFE's `.vpy` path lost its drive letter.** `VPY_PATH` (e.g. `C:/Program Files/mpv/portable_config/Scripts/RifeFilter.disable/rife.vpy`) was interpolated unquoted into the `vf add @rife:vapoursynth=file=...` spec. mpv's filter sub-option parser splits on `:`, so the `C:` drive letter got parsed as a delimiter and silently dropped, leaving a driveless path that only "worked" by accident (resolving against mpv's current drive). `user-data` was already correctly wrapped in `%N%` fixed-length quoting for the same reason (it contains `=` and `|`); the fix applies the identical `%N%` quoting to `VPY_PATH`. Confirmed via `mp.get_property_native('vf')`, which showed the corrupted `file` param before the fix and the correct full path after.

All three are fixed in `gpu-toggles.lua`. After the fix, a full live RIFE run (`av://lavfi:testsrc2` source, real mpv process, correct PATH) shows `[vapoursynth] initializing...` -> `initialized.` and frames flowing - confirmed end to end, not just "vf add didn't error."

**RIFE PATH caveat:** the venv's VapourSynth dir (`.venv\Lib\site-packages\vapoursynth`, containing `vsscript.dll`) is correctly on the persisted Windows **user** PATH (`[Environment]::GetEnvironmentVariable('Path','User')` shows it). A process only sees this if its environment block was created *after* that PATH entry was set - a long-lived shell/tool session started before the PATH change will have a stale snapshot and RIFE will fail with "Failed to load VapourSynth VSScript library" purely because of that, not because of a real bug. If RIFE fails, first close and reopen whatever launched mpv (fresh terminal, or just relaunch mpv.exe/mpv.com directly) before assuming the config is broken.

### GPU shader chain benchmark (real RX 9070 XT, via `vo-passes`)

mpv exposes real per-shader-pass GPU execution time via the `vo-passes` property (ns, rolling average). Benchmarked every preset with a synthetic `av://lavfi:testsrc2=size=1920x1080:rate=24` source, fullscreen on the real 2560x1440 display (so Anime4K/ArtCNN's `WHEN` upscale-gating clauses actually trigger):

| Preset | GPU time/frame | Fits 144Hz (6.94ms) | Fits 60Hz (16.67ms) |
|---|---|---|---|
| baseline (`profile=high-quality` only, no glsl-shaders) | 0.69ms | yes | yes |
| ArtCNN C4F16 | 4.13ms | yes | yes |
| ArtCNN C4F32 | 27.1ms | **no** | **no** |
| ArtCNN C4F32 DN | 27.1ms | **no** | **no** |
| Anime4K A (HQ) | 5.16ms | yes | yes |
| Anime4K A+A (HQ) | 6.23ms | yes (tight, ~0.7ms slack) | yes |
| Anime4K C+A (HQ) | 4.12ms | yes | yes |
| Movie: FSRCNNX + SSimSuperRes | 4.65ms | yes | yes |
| Movie: SSimSuperRes only | 1.21ms | yes | yes |

**IMPORTANT CORRECTION (2026-09-12), read before trusting the "fits 144Hz/60Hz" columns above:** those columns compare pass cost against the *display* refresh interval, which is the wrong deadline whenever `video-sync=display-resample` is active (it is, globally, in `mpv.conf`) and the source isn't itself 60fps+. Verified empirically: with a 24fps source, fullscreen on the real 144Hz display, `vo-passes/fresh`'s sample count advanced by exactly 24/sec, not 144/sec - "fresh" (actually-shaded) frames fire at the *source* frame rate; the display just repeats/redraws the same shaded frame between them ("redraw" passes, cheap, not what's tabulated above). So the real budget for typical 24fps anime/movie content is ~41.7ms/frame, not 6.94ms - **every preset in the table above, including ArtCNN C4F32 at 27ms, fits comfortably**, confirmed with `frame-drop-count` staying at 0 through 6+ seconds of real timed playback. The 60/144Hz columns only matter for genuinely 60fps+ source content, or if interpolation forces a higher fresh-shading cadence (not verified either way - if you need to know, redo the cadence check described in "How this was actually tested" with interpolation mode 1 active).

This matters because the original "ArtCNN C4F32 is 4-6x heavier, not real-time-safe" conclusion (previously the headline takeaway here) was too pessimistic for this repo's actual use case (24fps anime/movies) - see the 2026-09-12 redesign section below, which supersedes the "fixed by reordering `ARTCNN_PRESETS`" sentence that used to be here (that array no longer exists). The raw per-pass costs in the table are still accurate and useful; only the pass/fail budget columns were being misapplied.

## 2026-09-12 session: simplified to one best preset per content type, added uosc toolbar buttons, then made it resolution-aware too

User feedback that reshaped this, in two rounds:

**Round 1** - they have a capable GPU and always want max quality, not a tunable quality/performance ladder - so the multi-tier `ANIME_PRESETS`/`MOVIE_PRESETS`/`ARTCNN_PRESETS` cycles (and `Shift+F`, and the ArtCNN cycle from the 09-11 session) were **removed** from `gpu-toggles.lua` and replaced with a single on/off toggle (`cycle-upscale` / `set-upscale`, bound to `Shift+A`) that auto-detects anime vs movie per file (`is_anime_content()` path heuristic).

**Round 2** - they then asked for the preset to also depend on input resolution (e.g. a 720p movie stream vs a 1080p one should get different upscalers), so `current_upscale_preset()` now picks from **four** presets, keyed on (anime|movie) x (<=720p | >720p), with `RESOLUTION_TIER_HEIGHT = 720` as the boundary:

| | <= 720p (SD/720p) | > 720p (HD, 1080p+) |
|---|---|---|
| **anime** | Anime4K C+A (HQ) | `ArtCNN_C4F32_DS.glsl` |
| **movie** | FSRCNNX + SSimSuperRes | `SSimSuperRes.glsl` only |

Reasoning for each cell (also in the comment above `RESOLUTION_TIER_HEIGHT` in `gpu-toggles.lua`, so it can be re-evaluated rather than re-derived from scratch):
- **anime <=720p**: Anime4K's own strength (and this repo's original plan's "ANIME SD/720p" section) is exactly this - badly-compressed/downscaled sources needing real restoration.
- **anime >720p**: per web research (the shader author's own mathematical evaluation of mpv upscalers, linked from the ArtCNN GitHub repo), ArtCNN beats Anime4K on real HD content; Anime4K's aggressive artifact removal costs fine detail once the source is already reasonably clean. "DS" (denoise+sharpen) is the ArtCNN variant recommended for web-sourced/compressed content, i.e. HLS streaming.
- **movie <=720p**: FSRCNNX is a fixed ~2x CNN; at 720p->1440p that's almost exactly its native scale factor, so the full restorative chain is well-matched. Already the community-recommended combo over FSRCNNX+adaptive-sharpen.
- **movie >720p**: at 1080p->1440p the actual scale factor is only ~1.33x; running a full 2x CNN then downscaling back down is wasted work and can over-process detail that was already there, so the lighter SSimSuperRes-only corrective pass is the better match.

**Testing note - a real bug this surfaced:** `is_anime_content()`'s pattern was `'[\\/]%' .. dir .. '[\\/]'` - the stray `%` before `dir` doesn't escape anything (none of "anime"/"Anime"/"ANIME" are Lua pattern special characters); instead `%a` is itself a Lua pattern token meaning "any letter", so the pattern actually matched "(slash)(any single letter)nime(slash)" - it happened to still match a real `anime` folder (since the letter 'a' trivially satisfies "any letter"), but would have also matched a folder like "Xnime" for any letter X. Fixed by dropping the stray `%` (now `'[\\/]' .. dir .. '[\\/]'`). Low real-world impact (no realistic folder is named "Xnime"), but worth knowing this pattern exists if you ever extend the folder-name list - don't copy the old form.

The other shipped shader files (`ArtCNN_C4F16.glsl`, `ArtCNN_C4F32.glsl` (no DS), `ArtCNN_C4F32_DN.glsl`, and the non-C+A Anime4K chains) are **no longer referenced by any active toggle** - left on disk deliberately (harmless, useful if a "best" pick above is ever revisited) but if you `grep` for them and find nothing calling them, that's expected, not a bug.

Also added: two managed uosc toolbar buttons, `button:upscale` and `button:interp` (declared in `script-opts/uosc.conf`'s `controls=` line, right after `button:speed`), following the exact pattern `scripts/speed-button.lua` already established for the speed button - `gpu-toggles.lua` pushes `script-message-to uosc set-button <name> <json>` (icon/badge/tooltip/command) from `update_upscale_button()`/`update_interp_button()`, called after every state change and once at startup via `mp.add_timeout(0.5, ...)` (uosc load-order safety, same as speed-button.lua). The upscale button's badge is one of `Off`/`Anime SD`/`Anime HD`/`Movie SD`/`Movie HD`, keyed off the active preset's `.name` via `UPSCALE_BADGES`. Clicking either button sends the same `script-message-to gpu_toggles cycle-*` the keybinds use - one source of truth, confirmed by reading back the actual `set-button` JSON mpv sent for both buttons across all four content/resolution combinations (see "How this was actually tested" below for the loadfile-sequence pattern used).

**Testing gotcha to remember:** when driving mpv via `loadfile` from a throwaway Lua script, use real Windows-style paths (`C:/Users/...`) inside the Lua string - an MSYS/git-bash-style path (`/c/Users/...`), which is what this Bash tool's own shell uses, means nothing to mpv's native Windows process and `loadfile` will silently fail to find the file (no error, just never fires `file-loaded`). Also, a raw top-level function call at the end of a script (not deferred via `mp.add_timeout`) can run before mpv has fully finished initializing the script - defer the first action the same way `speed-button.lua` and this session's fixes already do.

### How this was actually tested (repeat this pattern for future changes)

Reading the Lua/GLSL source is not sufficient to know whether a change works - all three bugs above were invisible from a source read and only surfaced by driving a real mpv process. Pattern used:

1. Write a throwaway Lua script (anywhere outside the repo, e.g. a scratch dir) that uses `mp.add_timeout` to sequence `mp.command('script-binding gpu_toggles/<name>')` / `mp.commandv('script-message-to', 'gpu_toggles', ...)` calls exactly as `input.conf` would invoke them - not the other script-message path, which can mask a `script-binding`-only bug.
2. After each step, log `mp.get_property_native('glsl-shaders')`, `mp.get_property_native('vf')` (the native form shows parsed sub-option values, e.g. catches a corrupted `file=` path that the plain string form re-escapes and hides), and `mp.get_property('interpolation')`.
3. Launch with `--script=<that file>` and either `--idle=yes` (menu/shader checks only) or a real/synthetic source (`av://lavfi:testsrc2=size=WxH:rate=N`, `--fullscreen=yes` to match the real display and make upscale `WHEN` clauses trigger) for anything touching `vo-passes` or RIFE/VapourSynth.
4. For RIFE/amf_frc specifically, a synthetic source is enough to prove the filter *initializes* (`[vapoursynth] initializing...` / `initialized.` in the log) - you don't need real anime content for that.
5. Run via PowerShell `Start-Process ... -PassThru` + `Start-Sleep` + `Stop-Process`, with `--log-file=` to a real Windows path (not a `/tmp`-style path from a bash-ish tool, which won't resolve the same way for a Windows GUI process) so the full log survives after the process is killed.
6. For `vo-passes`, query the whole `vo-passes` property natively and read `.fresh` from the returned table (a plain Lua array of pass tables with `desc`/`avg`/`last`/`peak` in ns) - `vo-passes/fresh` is *not* itself a gettable property path; only `vo-passes` and the documented per-index leaf paths are.

## 2026-09-12 session (continued): FastStream browser-extension content-type hint

`is_anime_content()` in `gpu-toggles.lua` only ever had a folder-name
heuristic to go on, which is useless for the real workflow: streams opened
via the FastStream Firefox extension's mpv integration, not local files in
an `anime/` folder. Extended it (in the fork at
`<FastStream fork checkout>`, branch
`dev/mv3-modernization`) rather than only on the mpv side:

- **MPV Allowlist tag** - a site line in FastStream's MPV Allowlist can end
  in `@anime` or `@movie` (e.g. `https://crunchyroll.com @anime`), parsed by
  `UrlMatchList.parseEntry`/`getContentType` as that site's default.
- **Manual per-video override** - right-clicking the player's existing
  "Open this stream in mpv" button (`SaveManager.mjs`) cycles Auto -> Anime
  -> Movie -> Auto, shown as a small A/M badge; it wins over the allowlist
  tag and resets to Auto on every new video (`FastStreamClient.resetPlayer`).
- Both resolve to one `contentType` in `background.mjs` (manual override if
  set, else `MpvAllowlist.getContentType(tab.url)`), threaded through
  `MpvBackend.openStream`'s new 4th argument into the native-messaging
  `open` message.
- `native-host/faststream-mpv-host.mjs`'s new `withContentTypeFragment`
  appends it to the stream URL as `#fs-content=anime`/`#fs-content=movie`
  before either mpv launch path (`launchMpv`'s spawn args,
  `loadIntoExisting`'s `loadfile` IPC command) - a URL fragment, never sent
  over HTTP, so it cannot break a signed/tokenized CDN URL. Extends an
  already-present fragment with `&` instead of a second `#`.

On the mpv side, `is_anime_content()` now checks `path` for a plain (not
Lua-pattern) `fs-content=anime`/`fs-content=movie` substring first - explicit
tag wins in both directions - before falling back to the `anime` folder
check. Verified live end-to-end: a local Python `http.server` served the
09-11 session's `test.mp4`/`test720.mp4` over real HTTP, then real mpv was
driven with `#fs-content=anime`/`#fs-content=movie` (including one case with
a pre-existing `#t=10` fragment ahead of it) appended to the URL. All four
cases - tag overriding a non-anime-looking URL, tag overriding what would
read as anime, the pre-existing-fragment case, and the untagged fallback -
selected exactly the expected one of the four presets, confirmed by reading
back `glsl-shaders` after `set-upscale 1`. This is the same
"script mpv itself" methodology as "How this was actually tested" below,
extended to a real HTTP source instead of only local files, specifically
because fragment handling only matters for URLs.

FastStream-side unit coverage: `tests/unit/UrlMatchList.test.mjs` (tag
parsing, `getContentType` precedence), `tests/unit/MpvBackend.test.mjs`
(`contentType` included/omitted in the native message),
`tests/unit/MpvNativeHost.test.mjs` (`withContentTypeFragment`, and
`loadIntoExisting` actually applying it to the `loadfile` command). Lint,
typecheck, `pnpm test` (164 tests) and both `pnpm run build:keep` /
`pnpm run lint:amo` (still the baseline 0 errors / 3 pre-existing vendored-
library warnings) all pass after this change.

Not yet done: the extension itself has not been reloaded/tested in a real
Firefox profile by a human - only its build output and pure logic were
verified here. If the button or badge look wrong in practice, check
`chrome/player/ui/SaveManager.mjs`'s `updateMpvContentBadge` /
`chrome/player/assets/fluidplayer/css/fluidplayer.css`'s `#mpv_content_banner`
rules first.

### Follow-up same day: movie-by-default, and the folder heuristic deleted

Two user-reported issues, both the same root cause:

1. "the upscale button only toggles one version but I thought I have 2
   upscalers" - `current_upscale_preset()` was in fact always resolving to a
   *movie* preset for every stream, because `is_anime_content()`'s only
   signal for FastStream traffic was the `anime`/`Anime`/`ANIME` folder
   check - and an HTTP URL has no folder to match. The anime presets were
   effectively dead code for the real streaming workflow.
2. "the auto picker is not working, so we decided on the FastStream @anime
   solution - delete the auto selection in mpv."

Fix, in both repos:

- **FastStream side** (`background.mjs`): added `resolveMpvContentType(explicit, url)`,
  used at all three `Mpv.openStream` call sites. It now always resolves to
  an explicit `'anime'` or `'movie'` - never `null`/undefined - falling
  back to `'movie'` when neither the player's manual override nor the MPV
  Allowlist's tag says otherwise. This is a deliberate product decision:
  most sites are expected to be movie sites, so only the anime ones need an
  `@anime` tag; nothing needs an explicit `@movie` tag (though it's still
  accepted). Every FastStream-driven mpv launch now carries a `#fs-content=`
  marker unconditionally - the old "send nothing, let mpv guess" path is
  gone.
- **mpv side** (`gpu-toggles.lua`): `is_anime_content()` had its folder-name
  fallback deleted outright, per the user's explicit request - it is now
  `return path:find('fs-content=anime', 1, true) ~= nil`, nothing else. No
  marker means movie, always. This mirrors the FastStream-side default so
  both halves agree without either one needing to guess.

Re-verified live the same way as above (local `http.server`, real mpv,
`#fs-content=` fragments): an untagged URL - even one that would have
matched the old `anime/` folder pattern - now resolves to a movie preset,
and only an explicit `#fs-content=anime` marker selects an anime preset.
`glsl-shaders` after `set-upscale 1` confirmed all four cases.

**Consequence for local files (no FastStream, no fragment):** they now
always resolve to a movie preset, since there is no folder heuristic left
to catch them. If local anime files need the anime chain again, that has to
be re-added deliberately (e.g. reading `mp.get_property('filename')` against
a folder list once more) - it is not an accidental side effect of this fix,
it was traded away on purpose for the FastStream workflow being reliable.

### Follow-up same day: upscale is a cycle again, not plain on/off

User report: "the upscale button only toggles one version but I thought I
have 2 upscalers." Root cause was the bug just above - `is_anime_content()`
never worked for streamed content, so every stream resolved to a *movie*
preset and the anime half of the four presets was practically unreachable
through the button. That's now fixed independently (see above), but the
user separately asked for the button itself to let them browse/compare all
four presets on demand, the same way `cycle-interp` lets you step through
every interpolation mode rather than only ever showing mpv's own pick.

`gpu-toggles.lua`'s upscale button is a 6-state cycle now, `upscale_mode`
0-5, structurally identical to `current_interp` (which gained the same
"Auto + forced modes" shape for interpolation the same day - see the
"interpolation gets a content-aware Auto too" section further below):

| mode | meaning |
|---|---|
| 0 | off |
| 1 | **Auto** - `current_upscale_preset()`, re-evaluated every `file-loaded` (content type + resolution, as before) |
| 2-5 | one of `UPSCALE_ANIME_SD`/`_HD`/`UPSCALE_MOVIE_SD`/`_HD` **forced**, via `UPSCALE_FORCED_BY_MODE[mode]` - ignores content type and resolution entirely |

`preset_for_mode(mode)` is the single place that resolves a mode to a
preset (or nil for off); `apply_upscale()`/`cycle_upscale()`/`set_upscale()`
(now taking 0-5, was 0-1) all go through it. `set-upscale 2`/`3`/`4`/`5`
menu entries were added to `input.conf`'s uosc right-click menu, mirroring
the `set-interp 1`/`2`/`3` entries already there.

**Deliberately sticky, like interpolation:** a forced mode (2-5) does NOT
get re-evaluated on the next `file-loaded` - `apply_upscale()` just
re-applies the same forced preset regardless of the new file's actual
content type or resolution, exactly like `current_interp` is never reset by
a file change. Only mode 1 (Auto) re-evaluates per file. This was verified
live, not assumed: a forced Anime SD selection survived loading a plain
1080p movie file with no tag at all, still showing Anime4K afterward.

Verified live end-to-end (same local-`http.server` methodology as above),
11 checks in one run: Auto on a movie file -> Movie HD; cycling through
modes 2-5 on that same movie file forces Anime SD -> Anime HD -> Movie SD
-> Movie HD regardless of the file being a movie; mode 5->0 clears shaders;
0->1 returns to Auto; loading a new anime-tagged 720p file while still on
Auto re-evaluates to Anime SD; forcing mode 2 then loading an untagged
movie file leaves it on Anime SD (sticky). All confirmed by reading back
`glsl-shaders` after each step - see
`validate-upscale-cycle.lua` pattern in "How this was actually tested".

The on-screen `Shaders: <name>` OSD message (not just the button tooltip)
now also says `(Auto)` or `(forced)` after the preset name via
`apply_shader_preset`'s new optional `suffix` argument, so which mode
produced a given preset is visible without needing to hover the button.

### Follow-up same day: interpolation gets a content-aware Auto too

User: "can we now determine which interpolation is the best for what
content so we have a similar fixed selection like the upscalers." Same
shape as upscale's Auto - a single deterministic pick per content type,
plus the existing manual modes kept for override/comparison - but the
axis here is *which RIFE model*, not which method, per a quick research
pass (see Sources below):

- **Both content types land on RIFE**, not `amf_frc`. AMD's driver-level
  FRC (block/optical-flow motion estimation tuned for continuous real-world
  motion) is repeatedly reported to not suit hand-drawn/limited animation
  (held frames, fast pans over static foregrounds, stylized motion confuse
  it); RIFE (an ML model) is generally reported cleaner/more artifact-free
  than traditional frame blending on either content type. So there is no
  method trade-off to make by content type, only which RIFE model fits -
  matching the "always the best, no quality ladder" philosophy already
  applied to upscale.
- **Anime -> model 4.4** (Practical-RIFE's long-standing anime-tuned
  baseline - this was already this repo's default before today, just not
  content-conditional). **Movie -> model 4.25** (the project's own
  documented movie/general default, see the `RIFE_MODELS` comment in
  `gpu-toggles.lua`). Model 4.26 (heaviest) stays manual-only via
  `set-rife-model`.

`gpu-toggles.lua`'s interpolation cycle grew from 4 states to 5,
restructured to the exact same shape as upscale's:

| mode | meaning |
|---|---|
| 0 | off |
| 1 | **Auto** - RIFE, model from `best_rife_model_index_for_content()`, re-resolved every `file-loaded` |
| 2 | display-smooth, forced (was mode 1) |
| 3 | amf_frc, forced (was mode 2) |
| 4 | RIFE, forced - keeps whatever model `set-rife-model` last set, ignores content type (was mode 3) |

The actual `@rife` vf-filter-building logic was factored out of the old
`set_interp_rife()` into a shared `apply_rife_filter()` (no side effects on
`current_interp`/the button) so both Auto (mode 1) and forced RIFE (mode 4)
call the same filter-application code, differing only in how `RIFE_MODEL`
got set beforehand and which mode number they report. `set_interp(index)`
also lost a latent bug found while touching it: it used to set
`current_interp = n` unconditionally *after* calling `set_interp_mode(n)`,
which clobbered the correct `current_interp = 0` a failed RIFE/amf_frc add
had just set - each `set_interp_*` function already sets `current_interp`
on every path (success or failure), so that outer assignment was both
redundant and, on a failure, actively wrong.

**Manually picking a model always breaks out of Auto into forced mode 4**
(`set_rife_model`, when `current_interp` is 1 or 4, calls `set_interp_rife()`
rather than re-running Auto) - otherwise the button would keep claiming
"Auto" while actually showing a model the user just picked by hand, which
would be misleading. `interp_target` mirrors this the other way: it
re-applies via whichever of `set_interp_auto()`/`set_interp_rife()` matches
the currently active mode, so a target change takes effect immediately
without silently changing which mode is active.

Verified live (VapourSynth PATH caveat from the 09-11 session applies here
too - see below): loaded a movie file, Auto -> model 4.25; loaded a new
anime-tagged file with Auto still active -> model 4.4, no user action
needed; manually set model 4.26 -> forced mode, confirmed by reading the
`@rife` vf filter's own `user-data` field back (`target=...|model=...|mult=...`),
not just `current_interp`; loaded another movie file with forced mode active
-> still model 4.26 (sticky, exactly like the forced upscale presets);
cycling through off/Auto/display-smooth all produced the right
`vf`/`interpolation` property state. Not re-verified live in this pass:
`amf_frc` itself (mode 3) - its filter-add logic is unchanged from the
09-11 session, only its mode *number* moved from 2 to 3, and it fails fast
under `--vo=null` (no `hwdec=d3d11va` frames), which is expected and
unrelated to this change.

Sources consulted for the content-type-to-method mapping (general research,
not project-specific docs - see "What Is AI Anime Motion Smoothing?" and the
AMD Fluid Motion / RIFE comparison discussion linked from a Practical-RIFE
GitHub issue thread, both accessed 2026-09-12): AMD's driver-level frame
generation is described as not matching well with 2D/hand-drawn animation's
directing and filming conventions; RIFE is described as generally producing
cleaner, less artifact-prone results than traditional interpolation,
though not artifact-free on every anime scene. Treat this as directional
community consensus, not a rigorous side-by-side on this user's own content
- same caveat already on record for the upscale shader picks.

### Follow-up same day: the RIFE target FPS was quietly degrading quality

User: "so what if the fps target in those interpolation settings" - asked
to give the RIFE target its own visible UI toggle (previously buried in the
uosc right-click menu only) and to make it auto-select from the input's own
fps, "without degrading the visual experience." Investigating that last
part surfaced a real problem with the *existing* default, not just a
missing UI:

**`rife.vpy`'s old `target=0` ("follow display") computed
`multi = display_fps / src_fps`** - on this user's 144Hz display with
typical 24fps anime/movie content, that is `144/24 ≈ 6x`. Research on RIFE
multipliers (see Sources below) is consistent that quality holds up well
through roughly 2x-4x and degrades into visible ghosting on fast motion and
scene cuts before 6x; the SmoothVideo Project community independently
converged on the same number for this *exact* scenario (24fps content on a
144Hz+ display), explicitly recommending 2x (48fps) over chasing the full
display rate, and calling 120Hz-class multipliers a sharpness/ghosting
trade-off even then. So the "smart" default already in this repo was
quietly the single worst setting available for the user's own display and
content - not a missing feature, an active bug in the recommendation.

Why this was safe to just fix rather than needing a lower-quality
trade-off: `video-sync=display-resample` is set unconditionally in
`mpv.conf` (not just for "display-smooth" mode - see line ~28), so mpv is
*always* resampling whatever fps the filter chain outputs to the display's
actual clock. RIFE's output does not need to be an integer multiple of
144Hz for smooth presentation; display-resample's whole job is exactly that
translation. This freed the target to be chosen purely for RIFE's own
output quality, independent of the display.

**New `target=0` ("Auto") behavior in `rife.vpy`:**
`multi = min(2.0, max(1.0, display_fps / src_fps))` - always the
quality-safe ~2x, except backing off below 2x if the source is already
close enough to the display rate that 2x would ask for more frames than
the panel can even show (pointless, not an improvement). Re-derives from
the *actual* per-file source fps (`video_in.fps`, already read by the
script) and the real display refresh, so it is correct per file without
gpu-toggles.lua needing to know either value itself.

**New uosc toolbar button, "fps"** (`button:fps` in `uosc.conf`'s
`controls=`, after `button:interp`), separate from the interpolation
button per the request - it applies to RIFE specifically regardless of
whether RIFE got activated via Auto (mode 1) or forced (mode 4). Cycles
Auto -> 60Hz -> 120Hz -> 144Hz -> Auto (`FPS_TARGETS`/`cycle_fps_target`/
`fps_target_index` in `gpu-toggles.lua`), reusing the existing
`interp_target(value)` apply-if-active logic - forced 60/120/144 pass
straight through as an explicit `target_fps` in `rife.vpy` (unchanged
branch, `multi = target_fps / src_fps`), so picking one of those is still
available for deliberate experimentation even though it can land well past
the safe 2x-4x zone (e.g. 144 forced on 24fps content is still the old,
research-discouraged ~6x - now an explicit opt-in, not the default).

Verified: `rife.vpy`'s edited branch by direct arithmetic (144/24.51 gives
multi 5.87 pre-cap, capped to 2.0 - the file's own inline comment walks
through why); the uosc "fps" button's full cycle by reading the `@rife` vf
filter's `user-data` field back after each `cycle-fps-target` step
(`target=0|...` -> `60` -> `120` -> `144` -> `0`, model/mult unaffected);
and, importantly, that `display_fps` is actually non-nil in a real session
(`--vo=null` reports it as nil, which would have silently masked this via
rife.vpy's `else: multi = 2.0` fallback and made the display-capping branch
look tested when it was not) - a real fullscreen window against this
machine's actual display confirmed `display-fps=144`, so the capping
branch really does receive real numbers, not just the safe fallback.

Sources for the multiplier guidance (accessed 2026-09-12, general research):
a RIFE frame-interpolation overview describing ghosting artifacts around
fast motion and scene cuts becoming a primary concern above roughly 4x, and
several SVP (SmoothVideo Project) community sources specifically discussing
24fps-on-144Hz setups, converging on a 2x/48fps target as the practical
choice over chasing the full display rate. Same "directional consensus,
not this user's own content" caveat as the other sourced picks above.

### Follow-up same day: full-repo stability review, and a critical RIFE model bug found

User: "review all changes and the repo in general so we can make sure
everything is stable and polished without bugs or potential issues" - a
review pass over every uncommitted change, not a new feature. Findings,
most important first:

**4.25/4.26 crash mpv - the content-aware RIFE model feature never actually
worked, in two different ways.** `RIFE_MODELS = { '4.4', '4.25', '4.26' }`
and `best_rife_model_index_for_content()` (anime->4.4, movie->4.25) were
already in `gpu-toggles.lua` before this review, documented above as
"verified live" - but that verification only ever checked the `@rife` vf
filter's `user-data` field (i.e. that the *label* said "4.25"), never which
model actually executed. Two real problems, found by finally checking that:

1. `rife.vpy`'s `model_map` never had `'4.25'`/`'4.26'` keys, and
   `model_map.get(rife_model, RIFEModel.v4_4)` silently substituted v4.4 for
   both - so "Auto -> movie -> model 4.25" was *always* actually running
   v4.4, just labeling it "4.25" in the OSD/button/vf user-data. Same for
   manually picking 4.26. Fixed the silent fallback into a loud one:
   `model_map[rife_model]` now, with a `raise` if the key is missing, so
   this class of bug cannot hide silently again.
2. The `.onnx` files for 4.25/4.26 were never actually installed by
   `install-rife.ps1` either (it only ever pinned the `rife_v8` pack,
   v4.0-v4.10) - `gpu-toggles.lua`'s own comment referencing a "rife_v2 pack
   (models.v15.16.7z)" was aspirational/incorrect, not something the
   installer ever fetched. Downloaded the real files from vs-mlrt's
   `external-models` GitHub release tag (`rife_v4.25.7z`/`rife_v4.26.7z`,
   ~20MB each) and added them to `install-rife.ps1`'s `$RIFE_MODELS`/download
   step, and to `model_map`.

Fixing both of the above (so 4.25/4.26 would *actually* run instead of
silently aliasing to 4.4) surfaced a third, worse problem: **live-tested
with a real mpv process and a synthetic source, both 4.25 and 4.26 segfault
the entire mpv process** within about a second of `[vapoursynth]
initialized.` - not a Lua error, not an OSD failure message, the whole
process dies (exit code 139). Reproduced twice each, isolated one model at a
time. ncnn's own conversion log shows why for both: `GridSample not
supported yet!` / `Unsupported split axis !` while building either model's
network graph - an op introduced in the 4.25/4.26 architecture that this
repo's installed vsncnn build (`v16.2.test1`) apparently cannot convert
correctly, corrupting the graph rather than failing cleanly. Confirmed this
is specific to those two models, not a general regression: 4.4, tested the
identical way (real process, synthetic source, forced RIFE), survived 10
full seconds of real decoded playback with no crash, both before and after
all the changes in this section.

**Reverted to the only confirmed-safe state**: `RIFE_MODELS` is back to
`{ '4.4' }` only; `best_rife_model_index_for_content()` keeps its shape
(still calls into the content check) but both branches resolve to the same
index now, since there is currently only one safe model to resolve to.
`model_map` in `rife.vpy` still maps `'4.25'`/`'4.26'` correctly (the
`.onnx` files are genuinely installed now) and `install-rife.ps1` still
fetches them - left in place, and clearly commented, as groundwork for
whenever a newer vsncnn build fixes the `GridSample` conversion, rather than
deleted outright. **Do not re-add either to `RIFE_MODELS` without
re-running the same live check** (a real mpv process, forced RIFE, several
seconds of actual decoded playback, not just the `[vapoursynth]
initializing... / initialized.` log lines - those alone were exactly what
made this bug look fine for as long as it did). Removed the now-dead
`set-rife-model 2`/`3` menu entries from `input.conf` (`RIFE_MODELS` has
only one element, so they would just log a warning and do nothing).

**Other findings from the same pass, all fixed:**

- **`set_interp_amf()` could falsely report failure and reset to "off" while
  amf_frc was still actually running.** It removed a leftover `@rife` filter
  before adding `@amf-frc`, but never removed a leftover `@amf-frc` itself -
  so re-selecting the amf_frc mode while it was already active (re-clicking
  the same uosc menu entry, or `set-interp 3` twice) tried to add a
  second filter under the same label, which mpv rejects, which the code read
  as "amf_frc failed" and reset `current_interp` to 0 even though the
  original filter was untouched and still running. Fixed with the same
  `vf remove @amf-frc` guard `apply_rife_filter()` already had for `@rife`.
  Confirmed via a real amf_frc session: re-selecting amf_frc twice in a row
  now keeps `vf=[amf-frc]` both times instead of resetting.
- **`portable_config/Scripts/uosc/lib/menus.lua`'s stream-quality menu
  (from the earlier, already-summarized part of this session) could lose
  track of the actually-selected track.** `get_stream_quality_items()`
  groups tracks by height and keeps whichever has the highest bitrate seen
  so far at that height - but a later, higher-bitrate, non-selected track at
  the same height would overwrite an already-selected one's entry,
  including its `id`, so the menu's "active" row could point at the wrong
  track to switch to. Fixed so a selected track's slot can only be replaced
  by another selected track, never evicted by a merely-higher-bitrate one.
  Also restored the `<=?` soft-match yt-dlp format operator (present before
  this session's stream-quality rework, silently dropped from the synthetic
  fallback item's format string) - without it, a format filter with no exact
  height match can fail instead of falling back gracefully.
- **`mpv.conf`'s "INTERPOLATION TARGETS" comment block still described the
  pre-2026-09-12 mode numbering** (`mode 1 display-smooth`, `mode 2
  amf_frc`, `mode 3 RIFE` - stale since the Auto+forced cycle restructure)
  and said `interp-target-refresh: 0 = follow display (recommended)`,
  contradicting the actual fix earlier in this same session (0 = Auto, a
  capped ~2x, specifically *not* "follow display exactly" any more).
  Rewritten to match current mode numbers and the real Auto behavior. Also
  removed a reference to a `user-data/gpu/upscale-target-height` property
  that no script in this repo actually reads - leftover from an earlier,
  abandoned design, not a real, working feature.
- **`script-opts/uosc.conf`'s `controls=` line had dropped `editions`**
  (present in every prior commit, gone in this session's uncommitted edit
  that added `button:upscale`/`button:interp`/`button:fps` - looks like an
  incidental drop while retyping the line, not a deliberate decision anyone
  asked for). Restored. Low practical impact either way - the editions
  button only renders itself when a file actually has more than one
  edition (`Controls.lua`'s `editions>1` condition), which is rare.
- `script-opts/uosc.conf`'s `stream_quality_options` option is no longer
  read by anything (the stream-quality menu now derives its list from
  `track-list` instead) - left as-is (harmless dead config), but if you go
  looking for what controls that menu's resolution list, it is
  `get_stream_quality_items()` in `menus.lua`, not this option.

All shader files referenced by the four upscale presets were confirmed
present in `portable_config/shaders/` (`ls` against every `.shaders` entry
in `UPSCALE_ANIME_SD`/`_HD`/`UPSCALE_MOVIE_SD`/`_HD`) - no missing-file
regression there. `input.conf` still parses cleanly (30 binds) and
`gpu-toggles.lua` still loads with no Lua errors after every change above,
confirmed the same way as every other change in this file: a real mpv
process, not just a source read.

## 2026-09-13 session: RIFE was silently corrupting every frame, and upscale presets stalled 10-20s each - two real, previously-undiscovered bugs

User report: "the interpolation and upscaling both have so many problems...
sometimes I get green screens and most of the stuff seems to not work." This
was not a wiring bug like the 2026-09-11 ones - both features were reached
correctly - it was two separate, deeper bugs that "doesn't crash" and
"compiles a valid shader" had both been masking. Found by actually
reproducing the user's symptom (a real mpv process, a real H.264 file
generated with ffmpeg since no test video existed on disk, screenshots
inspected as images) rather than re-reading the Lua/GLSL/Python source - see
"How this was actually tested" further above; that methodology caught both
of these, and neither would have been visible from source alone.

### Bug 1: RIFE's NCNN_VK (Vulkan) backend cannot run ANY RIFE model correctly

Forcing RIFE (`set-interp 4`) on a real H.264 1080p file and screenshotting
mid-playback produced a solid dark-green frame - reproduced twice. The
2026-09-12 "4.25/4.26 crash mpv" section (still accurate about the crash
itself) had concluded 4.4 was the one safe model, verified only by "survives
N seconds without crashing." That conclusion was incomplete: nobody had
actually looked at 4.4's decoded pixels.

Root cause, isolated with a standalone script (`vapoursynth` + `vsmlrt`
directly, no mpv involved - see the script shape below) feeding a flat test
clip through the exact same `RGB -> RIFE -> YUV` pipeline as `rife.vpy`:

- ncnn (this machine's installed vsncnn build, v16.2.test1) logs
  `GridSample not supported yet!` / `Unsupported split axis!` while
  converting **every** RIFE version's graph, v4.0 and v4.4 included - not
  just 4.25/4.26 as the 2026-09-12 section concluded. RIFE's optical-flow
  warp step is GridSample-based across the whole model family; this vsncnn
  build simply cannot execute that op on any of them.
- For 4.4 (and presumably 4.0-4.10), the broken op leaves the output tensor
  zeroed rather than erroring - every **interpolated** frame (not the
  passthrough source frames - confirmed by checking frame indices
  individually) came back exactly `RGB(0,0,0)`. A solid black frame,
  converted back to limited-range YUV and displayed, is what showed up as
  the green screen.
- For 4.25/4.26, apparently a different (larger?) shape mismatch downstream
  of the same broken op is fatal instead of silent, which is why those two
  specifically segfault mpv while 4.4 "survives" - the earlier
  investigation correctly observed the difference in *symptom* but drew the
  wrong conclusion about *cause* (assumed 4.4's architecture was fine; it
  wasn't, it just failed more quietly).

**Fix: switched the backend from `Backend.NCNN_VK` to `Backend.ORT_DML`**
(ONNX Runtime + DirectML, i.e. D3D12) in `rife.vpy`'s `RIFE(...)` call - a
one-line change plus installing the plugin. DirectML is a mainstream ONNX
Runtime execution provider with full GridSample support, sidestepping
ncnn's op-coverage gap entirely rather than working around it, and runs
over D3D12 on any modern GPU (AMD included) with no vendor SDK needed -
unlike `MIGX` (AMD's own backend, needs a separate MIGraphX/ROCm runtime not
installed here) or `TRT`/`ORT_CUDA` (NVIDIA-only). It also does not need the
ncnn-specific graph conversion step at all, since ONNX Runtime consumes the
`.onnx` files directly - the same model files already installed by
`install-rife.ps1` work unchanged.

Installed via `installer/install-rife.ps1`'s new step 2b: downloads
`VSORT-Windows-x64.v16.2.test1.7z` (same release tag as the existing
vsncnn install, from AmusementClub/vs-mlrt) and extracts `vsort.dll` +
`vsort/{onnxruntime.dll,DirectML.dll,onnxruntime_providers_shared.dll}`
into the plugins dir (`onnxruntime_providers_cuda.dll` from the same
archive is skipped - dead weight on this AMD system, and loading it prints
a harmless but noisy "failed to load" probe warning on every mpv start).
`vsncnn.dll` is left installed (harmless) but is no longer used by
`rife.vpy` - see its header comment.

**Verified thoroughly, the same "script mpv itself" way as every fix in
this file**: after the switch, screenshotting the same real H.264 file with
RIFE forced showed the actual test-pattern content (not green), and
playback was noticeably faster (ORT_DML is a much better fit for this op
than the broken ncnn conversion path was). All three models -
**4.4, 4.25, and 4.26** - were re-tested live (real mpv process, real
decoded video, forced RIFE with each model directly): none crashed, none
produced blank/corrupt frames, all three screenshotted correctly. This
means the 2026-09-12 "4.25/4.26 crash mpv" restriction is now obsolete:

- `RIFE_MODELS` is back to `{ '4.4', '4.25', '4.26' }` in `gpu-toggles.lua`.
- `best_rife_model_index_for_content()` is restored to its originally-
  intended content-aware behavior (anime -> 4.4, movie -> 4.25) - the
  2026-09-12 reasoning for that pairing was always sound; only the backend
  running the models underneath it was broken.
- `input.conf`'s `set-rife-model 1/2/3` menu entries (removed 2026-09-12 as
  dead - `RIFE_MODELS` had only one element then) are restored.

**Standalone reproduction script shape** (useful for any future backend or
model change - no mpv process needed, much faster iteration than driving
mpv for this specific question):
```python
import vapoursynth as vs
from vapoursynth import core
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(vs.__file__)), 'plugins'))
from vsmlrt import RIFE, RIFEModel, Backend
clip = core.std.BlankClip(width=64, height=64, format=vs.YUV420P8, length=4,
                           fpsnum=24, fpsden=1, color=[180, 90, 200])
rgb = core.resize.Bicubic(clip, format=vs.RGBS, matrix_in_s='709')
interp = RIFE(rgb, multi=2, model=RIFEModel.v4_4, backend=Backend.ORT_DML(device_id=0, fp16=False))
# inspect interp.get_frame(i) for i in range(interp.num_frames) - even
# (passthrough) indices should equal the source color, odd (interpolated)
# indices should NOT be all-zero for a non-flat clip.
```
Needs the venv's VapourSynth dir on PATH (`vsscript`/plugin loading) - see
the RIFE PATH caveat elsewhere in this file; run via the venv's own
`python.exe`, not a system Python.

### Bug 2: upscale presets stalled the player for 10-20+ seconds per switch

Cycling through the four forced upscale presets on a real 720p file (with
`--gpu-context` left at its default) showed only the FIRST preset
(`Anime4K C+A`) had even started compiling 20 seconds later. The log showed
why: `[vo/gpu-next/libplacebo] Spent 16848.530 ms translating HLSL to DXBC
(slow!)` for that one shader alone - ArtCNN's, tested separately, was
similarly slow. This is a one-time cost per distinct shader (recompiled
whenever `glsl-shaders` changes to a preset not already compiled this
session - i.e. on essentially every upscale-preset switch in normal use,
and always on the first use of each preset after mpv starts), not a
steady-state cost - it would not show up in the `vo-passes` steady-state
benchmark from the 2026-09-11 session, which measured per-frame execution
time, not one-time compile time. **This is almost certainly what "upscaling
doesn't work" actually was** - the player appears to hang for 10-20+ seconds
every time the preset changes, which reads as broken/frozen, not "still
compiling."

Root cause: `hwdec=d3d11va` (unconditional in `mpv.conf`) steers gpu-next/
libplacebo to pick the D3D11 GPU context for rendering (for zero-copy
interop with the d3d11va-decoded frames). libplacebo's shader compiler for
the D3D11 context has to cross-compile GLSL -> SPIR-V -> HLSL -> DXBC; that
extra HLSL/DXBC translation step is what measured 16.8 **seconds** for a
single heavy CNN shader on this RX 9070 XT. The Vulkan context needs only
GLSL -> SPIR-V (shaderc), skipping the translation step entirely.

**Fix, confirmed live**: forcing `--gpu-context=winvk` (Vulkan on Windows)
and re-running the identical preset-cycling test compiled and displayed
**all four** presets inside the same ~7.5s test window that previously
couldn't even finish the first one - no "translating HLSL to DXBC" message
at all. `gpu-context=winvk` is now set in `mpv.conf`.

**Consequence 1 - hwdec had to change too.** With `hwdec=d3d11va` (zero-copy)
and `gpu-context=winvk`, the log showed `[autoconvert] Failed to create HW
uploader for format yuv420p` / `Disabling filter format.00 because it has
failed.` and video silently fell back to software-decoded frames (no hwdec
benefit at all, just a swallowed failure). Testing several combinations live
found the actual fix: `hwdec=d3d11va-copy` (decode on the GPU's dedicated
video block, then copy the frame to system RAM) genuinely works alongside
`gpu-context=winvk` - confirmed via `hwdec-current` reporting `d3d11va-copy`
(not silently `no`) and the frame format reaching the VO as `nv12` (the
hardware decoder's native tagged format, not `yuv420p`, which is what a pure
software decode would have produced) - real hardware-accelerated decode, no
zero-copy, no interop needed for the (now Vulkan) render step.
`d3d11va-zero-copy=yes` is removed (meaningless once decode isn't zero-copy
- and independently, mpv issue #10963 documents it as its own source of
green-screen/corruption artifacts on some D3D11+HDR combinations, one less
thing that can go wrong for no measured benefit here).

**Consequence 2 - amf_frc (interpolation mode 3) can no longer get D3D11
frames and is now non-functional on this config.** The manual is explicit:
"AMF FRC only supports D3D11 input... Use --hwdec=d3d11va or
--vf-pre=format=d3d11 to upload the data" - and there is no working D3D11
upload path once the VO is on the Vulkan context (confirmed live: adding
`format=d3d11,@amf-frc:amf_frc=...` as a single `vf add` returns `ok=nil`,
mpv logs "Creating filter 'amf_frc' failed", and a DANGLING partial filter
was observed to survive the failed multi-filter add in one test - which is
exactly why `set_interp_amf()` was NOT changed to bundle its own inline
`format=d3d11` pre-filter; it still adds only `@amf-frc` alone, fails
cleanly via the existing `ok` check, and leaves nothing dangling). The
global `vf-pre=format=d3d11` line (which existed only for amf_frc) is
removed from `mpv.conf` entirely - it produced the same "Disabling filter
format.00" failure noise on every file load for zero benefit once nothing
downstream of it can use a D3D11 frame anyway.

**This is treated as an accepted trade, not a regression to chase further**:
RIFE (now fixed, see Bug 1) was already the research-backed better pick for
both anime and movies before amf_frc lost D3D11 access (see the 2026-09-12
"interpolation gets a content-aware Auto too" section - no quality
trade-off was ever found in amf_frc's favor). `set_interp_amf()`'s code is
untouched otherwise and will simply start working again unmodified if a
future mpv/driver version restores D3D11-Vulkan interop; its OSD failure
message was updated to say so explicitly rather than blaming `hwdec`, so a
future user/agent isn't sent chasing the wrong config option.

**Update, same day - re-measured, and the assumption above was wrong**: the
`vo-passes` steady-state cost is NOT unaffected by the context switch. Same
methodology as the 2026-09-11 benchmark (`av://lavfi:testsrc2=size=
1920x1080:rate=24`, real fullscreen on the 2560x1440 display, summing
`vo-passes`' `fresh` list `avg` fields), now under `gpu-context=winvk`:

| Preset | D3D11 (2026-09-11) | Vulkan (2026-09-13) |
|---|---|---|
| Anime SD (Anime4K C+A HQ) | 6.23ms | **3.40ms** |
| Movie SD (FSRCNNX + SSimSuperRes) | 4.65ms | **4.07ms** |
| Movie HD (SSimSuperRes only) | 1.21ms | **1.12ms** |
| ArtCNN C4F32 (plain, same exact shader file both times) | 27.1ms | **8.43ms** |

Vulkan isn't just faster to *compile* (the bug this session fixed) - it's
also meaningfully faster to *run*, every frame, steady-state. The ArtCNN
comparison is the cleanest evidence (identical shader file, identical GPU,
only the GPU context changed): 27.1ms -> 8.43ms, a ~3.2x drop. Anime4K
dropped ~1.8x; the two lighter movie presets moved less (~13% and ~7%) since
they had less compute to begin with. Plausible explanation, not confirmed
further: D3D11's GLSL->SPIR-V->HLSL->DXBC cross-compile path (the same one
responsible for the 10-20s compile stall) likely also produces less
efficient machine code for these Conv2D-heavy compute shaders than Vulkan's
more direct SPIR-V path, on this GPU/driver.
`Anime HD (ArtCNN C4F32 DS)`, the currently-active preset for anime >720p,
was also measured fresh under Vulkan at **7.65ms** (no prior D3D11 figure
exists for the DS variant specifically - it wasn't in the original table).
All four active presets remain trivially within budget even under the
strict per-*display*-refresh reading the 2026-09-12 correction argued against
(144Hz = 6.94ms, 60Hz = 16.67ms) let alone the correct per-*source*-frame
one (~41.7ms at 24fps) - there was no real headroom concern before and
there still isn't now, just less GPU work spent getting there.

### Follow-up same day: shader compile caching was already on, now confirmed warm

User asked whether shaders could be pre-compiled to avoid any remaining
switch delay. They already are: `--gpu-shader-cache` defaults to `yes`, and
because this is a `portable_config` install, mpv already writes that cache
into `portable_config/cache/shader_*` (gitignored) rather than
`%LOCALAPPDATA%` - see the manual's "FILES ON WINDOWS" section. This was
silently active the whole time the D3D11 10-20s stall bug was happening;
it didn't help because that stall was the HLSL->DXBC translation step,
which is downstream of (and not covered by) the cached GLSL->SPIR-V result
- only the `gpu-context=winvk` switch above actually fixed it. Confirmed by
cycling all four upscale presets, in real fullscreen at this machine's
actual display (2560x1440@144Hz), with both a 720p and 1080p real H.264
source (spanning the SD/HD tier boundary): zero shader recompiles, ~16MB of
cache total, nowhere near gpu-next's 128MiB auto-eviction ceiling. No config
change was needed - just verification and a documentation note (see
mpv.conf's new "SHADER COMPILE CACHING" section) so this isn't rediscovered
as a mystery later. If a shader edit ever silently fails to take effect,
clearing `portable_config/cache/shader_*` is the fix (forces one recompile).

### Follow-up same day: RIFE fp16 investigated and deliberately NOT enabled

User asked about enabling `fp16` on RIFE's `Backend.ORT_DML()` (currently
`fp16=False` in `rife.vpy`) for speed, given RDNA4's fp16 throughput. Tested
properly rather than assumed:

- At 1080p, even RIFE's heaviest model (4.26) already sustains full
  real-time playback (`speed_ratio` ~1.0, 0 frame drops) at `fp16=False` -
  no deficit to fix at any resolution this user is likely to actually play.
- Pushed to 4K (`av://lavfi` won't hwdec, so a real 4K H.264 file was
  encoded with `libopenh264` for this) to find an actual compute-bound case:
  the first-ever run of a given (model, precision, resolution) combination
  measured `speed_ratio` ~0.21-0.24 (both `fp16=False` and `fp16=True`
  alike) - but a SECOND run of the identical config jumped to ~1.0 for
  BOTH. This is a one-time warm-up cost (likely a DirectML/driver-level
  compiled-kernel cache, the ONNX-Runtime-side analog of the GLSL shader
  cache above) that persists across separate mpv.exe process launches, not
  an `fp16` effect - confirmed by re-running `fp16=False` twice more and
  seeing the same cold-then-warm jump independent of precision.
- **Conclusion: fp16 gave no measurable steady-state speed advantage over
  fp32 on this GPU for this workload**, at any resolution tested, once
  warm. Since fp32 has strictly better numerical quality for identical
  speed, `rife.vpy` was left at `fp16=False` (tried, measured, reverted -
  not left untried). Re-test if a future model, GPU, or resolution range
  changes this calculus; don't assume it's still true from this note alone.
- Prewarmed the common real-world combinations anyway (models 4.4 and 4.25,
  at both 720p and 1080p) so the one-time cold-cache cost described above
  is already paid on this machine and won't surprise the user as first-use
  stutter.

### Follow-up same day: real (non-synthetic) content verification

The 2026-09-13 fixes above were all verified against synthetic
`testsrc2`-pattern video. Re-verified against genuine decoded, non-flat
video content this same day: Blender Foundation's "Big Buck Bunny" (CC-BY
licensed, freely redistributable, fetched from `archive.org` since no local
media existed on this machine to test with) at 416x240 h264. All four
forced upscale presets were screenshotted against it (real gradients,
lighting, foliage detail, not solid color bars) and looked correct - no
green screen, no corruption, real added detail from each shader. RIFE
(forced, model 4.4) was also confirmed correct on this same clip. This is
still 3D-rendered animation, not hand-drawn 2D anime or live-action -
if the user reports a specific real anime/movie file looking wrong, that
still needs checking against that actual file; this only rules out "the
whole approach is broken on any real video," which the synthetic-only
testing up to this point had not strictly ruled out.

### 2026-09-13 (later the same day): interpolation quality follow-up - GPU decode path, duplicate-frame handling, RIFE ensemble

User asked three things in one go: (1) whether RIFE interpolation can safely
target 120/144Hz given movies are 24fps and anime is sometimes on
twos/threes (already answered conversationally: no code change needed there
- `video-sync=display-resample` always resamples smoothly to the display's
real refresh regardless of what rate RIFE outputs, and `rife.vpy`'s Auto
already deliberately caps at ~2x rather than chasing 120/144 - see the
"decide target frame rate" comment in `rife.vpy`, unchanged); (2) whether a
more sophisticated pipeline exists so heavy action doesn't get blurry/mushy
under interpolation; (3) to audit whether this RX 9070 XT's decode/media
engine is being fully used, and improve the pipeline/quality generally. (2)
and (3) needed real changes, made and verified below.

**GPU decode path upgraded: `hwdec=d3d11va-copy` -> `hwdec=vulkan,d3d11va-copy,no`.**
`--hwdec=help` on this build lists `vulkan` (h264/hevc/vp9/av1, via ffmpeg's
`VK_KHR_video_decode_*`) as a real option, not just d3d11va/dxva2/nvdec. Since
this config's VO is already Vulkan (`gpu-context=winvk`), decoding natively
into a Vulkan image is a strictly better match than `d3d11va-copy`: confirmed
live (real mpv process, Big Buck Bunny) that `hwdec-current=vulkan` and,
important, `hwdec-interop=vulkan` (genuine zero-copy, not a silent
software-decode fallback), 0 dropped frames, and a clean screenshot (not
another green-screen-class failure). `d3d11va-copy`'s own name says what it
cost: every decoded frame got copied GPU->system RAM specifically because a
zero-copy D3D11 texture has no interop path into a Vulkan-context VO here -
`hwdec=vulkan` doesn't pay that, since decode and render now speak the same
API throughout. Also re-tested RIFE (vf-level vapoursynth filter, software-
only, still forces its own hw-download regardless of which hwdec is used)
under `hwdec=vulkan` specifically - works identically, no regression, clean
screenshot. The `,d3d11va-copy,no` tail is mpv's real comma-separated hwdec
fallback list (tested, works): covers the handful of old codecs (mpeg2video/
vc1/wmv3) vulkan's hwaccel list omits, and guarantees playback never hard-
fails outright if a future driver regresses Vulkan video decode.

**Duplicate-frame (anime "on twos/threes") awareness added to `rife.vpy`.**
Anime frequently holds a drawn frame for 2-3 identical output frames before
the next pose. Measured real separation before picking a threshold (ffmpeg+
numpy frame-to-frame diff, R-channel mean abs diff, on both a synthetic
"on-twos" clip built by decimating-then-duplicating real motion, and on Big
Buck Bunny's real on-ones content): true duplicate pairs measured
~0.0000-0.0002, genuine motion in real content measured >=0.003 (median
~0.011) - a clean order-of-magnitude gap, so `DUP_THRESHOLD = 0.003` sits
safely between the two with margin on both sides. Rather than build a new
mechanism, this reuses vsmlrt's own existing `_SceneChangeNext`-gated "hold
the left frame instead of blending" fallback (already present in
`vsmlrt.py`'s `RIFE()` for every multi value, integer or fractional, and
already what keeps interpolation from smearing across a hard scene cut via
`misc.SCDetect`) - a near-duplicate pair wants the exact same outcome
(hold, don't blend) as a cut, for a different reason (nothing changed vs.
everything changed), so `rife.vpy` just ALSO sets that prop when
`PlaneStatsDiff` is below threshold, never clearing what SCDetect already
decided. **Verified the mechanism actually engages, not just "looks
plausible"**: temporarily forced `DUP_THRESHOLD = 1.0` (matches every pair)
against the synthetic on-twos clip and confirmed the previously-~5.6-6.1
real-motion frame-diffs collapsed to ~0.12 too, exactly as expected if every
pair is now being held instead of interpolated; restored `0.003` after.
Real-world effect at the correct threshold: held pairs already looked clean
even before this (RIFE(A,A) already approximated A well, matching the prior
session's synthetic on-twos test) - the actual win is skipping wasted
inference work on those pairs and removing any residual model-noise risk on
frames that are supposed to be pixel-identical, not a dramatic visual
change.

**RIFE `ensemble` (bidirectional flow, vsmlrt's own documented quality knob
for hard motion/occlusion cases) added, on by default where available.**
This is the actual, direct answer to "heavy action gets blurry/mushy":
`ensemble=True` is exactly the lever vsmlrt exposes for that, at ~2x
inference cost. First attempt crashed on live-testing
(`RuntimeError: rife_v4.4_ensemble.onnx not found`) - `vsmlrt.py`'s own code
only rejects ensemble for models 4.25/4.26 (`ValueError`), it does NOT
verify the ensemble weight file exists for models it does accept, and this
machine only had the plain (non-ensemble) `.onnx` for every model installed.
Traced the real asset: vs-mlrt ships ensemble weights as a SEPARATE archive,
`rife_ensemble_v1.7z` under the `external-models` release tag, containing
ensemble graphs for 4.0/4.2/4.3/4.4/4.5/4.6 ONLY (not 4.7-4.10, not 4.25/
4.26) - downloaded and installed it (`models/rife/rife_v4.*_ensemble.onnx`),
and made `rife.vpy` check the actual file's existence at runtime rather than
trust a hardcoded "which models support ensemble" list, so this degrades
safely regardless of which ensemble files happen to be present on a given
install. `install-rife.ps1` updated (step 4b) to fetch this archive too, so
a fresh install/RECREATE.md re-run gets it automatically. Re-verified live
after the fix: model 4.4 (anime Auto's pick) with ensemble on - clean
screenshot, no corruption; model 4.25 (movie Auto's pick, ensemble
unavailable for it) - confirmed ensemble silently stays off and playback is
unaffected.

Timed properly before deciding the default (real, unpaused, real-time
playback; `frame-drop-count`/`decoder-frame-drop-count`/actual `time-pos`
advancement over the same wall-clock window, ensemble on vs. off):

| Resolution | ensemble=False | ensemble=True |
|---|---|---|
| 1080p (model 4.4) | real-time, 0 drops | real-time, 0 drops (no measurable difference) |
| 4K (model 4.4) | ~31% of real-time | ~23% of real-time |

4K RIFE was **already** not real-time-capable on this GPU even without
ensemble (a pre-existing limit of RIFE's own per-frame inference cost at
that resolution, nothing to do with this change) - ensemble made an
already-too-slow case slower still, for no practical benefit since nothing
above ~1080p was getting real-time interpolation regardless. Since 1080p and
below (this repo's own established SD/HD tier boundary, see the 2026-09-12
section) showed zero measurable cost, `rife.vpy` auto-enables ensemble only
at `height <= 1080` (`ENSEMBLE_MAX_HEIGHT`); a `user-data` `ensemble=0`/`1`
override exists for re-testing on different hardware without editing the
file.

All of the above was tested together in one pass too (Vulkan hwdec + a
forced upscale preset + Auto RIFE, on real decoded video, screenshotted) to
confirm nothing regressed when combined, not just each piece in isolation.

### 2026-09-13 (same day, further follow-up): RIFE `scale` investigated (not defaulted), VRR audit

User asked "what else can we improve" as an open-ended follow-up. Two more
real changes came out of it; a third (RIFE `scale`) was investigated,
measured, and deliberately NOT changed from its default.

**RIFE `scale` (vsmlrt's own documented "0.5 recommended for 4K" knob) added
to `rife.vpy`, but `auto` still resolves to 1.0 everywhere.** Wired it up to
revisit the "4K RIFE isn't real-time" finding from earlier the same day.
First attempt crashed (`ModuleNotFoundError: No module named 'onnx'`) -
vsmlrt.py rewrites the RIFE onnx graph on the fly for any non-1.0 scale and
needs the `onnx` pip package for that, which this venv didn't have; installed
it (and added it to `install-rife.ps1`'s package line). Once working, timed
properly (a first/cold run of a new scale value pays a one-time DirectML
graph-compile cost, same as the fp16 investigation - re-ran until
steady-state): 4K went from ~30% of real-time (scale=1.0) to ~35-37% (scale=
0.5, warm) - a real ~15-20% relative speedup, but nowhere near the multiple-x
gain that would actually make 4K RIFE usable, and it costs real optical-flow
precision. Trading quality for a speedup that still leaves the feature
unusable isn't a good trade, so `rife.vpy`'s `scale=auto` stays at 1.0
unconditionally; the parameter is left in as a `user-data` override (e.g.
`scale=0.5`) for manual experimentation or a future faster GPU, not because
anything in this repo sets it today.

**VRR/FreeSync audit - `video-sync` changed from `display-resample` to
`audio`.** User confirmed this display (LG UltraGear, 1440p144Hz) has
FreeSync/VRR actually enabled. Researched properly (mpv's manual, issue
tracker, and libplacebo docs - see the sources below) rather than assumed:
`display-resample` forces presentation to a fixed detected-Hz cadence so it
can resample/duplicate frames onto it - which is structurally the opposite
of what VRR wants (let the panel's scan-out interval float to match content)
and is documented to cause real breakage (mpv issues
[#12005](https://github.com/mpv-player/mpv/issues/12005) and
[#12338](https://github.com/mpv-player/mpv/issues/12338); a proposed
VRR-aware `display-vrr` sync mode was filed and closed unimplemented). It
also defeats AMD's Low Framerate Compensation for sub-VRR-floor content like
24fps movies, since LFC needs to observe the source's real (slow) frame
cadence to know how many times to duplicate each scan-out, and
display-resample never presents at that native cadence. `mpv.conf` now sets
`video-sync=audio` (mpv's own default) as the VRR-friendly baseline. The one
real constraint found: mpv's manual states `--interpolation` silently
no-ops on any `video-sync` mode other than a `display-*` one - meaning
interpolation mode 2 ("display-smooth") structurally cannot work under
`audio`. Fixed by making that coupling explicit instead of losing the mode:
`gpu-toggles.lua`'s `set_interp_smooth()` now sets
`video-sync=display-resample` when that mode is chosen, and a new
`restore_vrr_video_sync()` helper (called from `set_interp_off()`,
`set_interp_amf()`, and `apply_rife_filter()` - i.e. every other mode) sets
it back to `audio` on the way out. Verified live: cycled off -> display-
smooth -> Auto RIFE -> display-smooth -> off while reading the `video-sync`
property back after each step - `audio` at every mode except display-smooth,
`display-resample` only while display-smooth is actually active, exactly as
designed. Also re-confirmed RIFE itself (Auto mode) still produces a clean,
uncorrupted frame under the new `audio` default (screenshot), and that plain
non-interpolated playback is still 0-drop. Sources: mpv manual's
`--video-sync`/`--interpolation`/`--vulkan-swap-mode` entries, the two GitHub
issues above, and a general LFC mechanics explainer - full citations kept in
the research notes, not reproduced here.

**HDR tone-mapping - investigated and completed, including identifying the
actual monitor.** `profile=high-quality` was the only HDR-adjacent setting in
this config. Checked against the current manual: `tone-mapping=auto` already
resolves to `spline` (not the older `bt.2390`) on `--vo=gpu-next`
specifically, which is what this config uses - already correct, left alone.
`hdr-compute-peak` already auto-enables itself whenever compute shaders are
available (true for RDNA4) - added it explicitly (`hdr-compute-peak=yes`)
purely for clarity/certainty, not a behavior change.

`target-peak` (mpv tone-maps HDR down to the display's REAL peak instead of
a generic assumption - the manual's own stated rationale for doing tone-
mapping in mpv at all rather than trusting the display's passthrough
handling) needed the panel's actual spec figure first - initially left unset
rather than guessed. Identified the exact model from Windows WMI
(`WmiMonitorID`, namespace `root\wmi`): manufacturer PNP id `GSM` (LG) +
product code `0x5BB4` -> cross-referenced against public EDID dumps
(linuxhw/EDID database) and a ddccontrol-db GitHub issue that ties this
exact product code to the **LG 27GN800-B**. Its real brightness was then
confirmed two independent ways landing on the same number: LG's own
authorized-distributor datasheet lists "350 cd/m2 typical" (no separate HDR
figure - this model has no VESA DisplayHDR certification and no local
dimming; "HDR10 support" just means it accepts an HDR10 signal on the same
~350-nit panel), and this exact unit's own EDID CTA-861 HDR static metadata
block independently reports a max luminance of 351.25 cd/m2. `mpv.conf` now
sets `target-peak=350` (confirmed live via the `target-peak` property
reading back `350`) - libplacebo's tone-mapping now compresses HDR
highlights to what this panel can actually reproduce before the signal
reaches it, instead of leaving that to the panel's own (basic, no-local-
dimming) passthrough handling. `target-trc`/`target-prim`/`target-contrast`
and the finer peak-detection knobs (`hdr-peak-percentile`,
`hdr-contrast-recovery`) were deliberately left at mpv's defaults -
community guides suggest specific numbers for those, but unlike
`target-peak` none were independently verifiable for this exact panel, and
getting them wrong is a "looks worse" risk only a human eye can catch; not
worth setting on a guess the way `target-peak` no longer is.

### 2026-09-13 (same day): FastStream anime tag - real bug found and fixed (Auto was never on by default)

User reported that an anime web stream (a real HLS URL,
confirmed via mpv's stats.lua dump: 1080p24 h264, hardware-decoded) did not
get anime treatment. Traced the whole path before touching anything:

1. Tested (previous session entry, "GPU decode path" section originally,
   see also the standalone test this same day) that mpv genuinely preserves
   a `#fs-content=anime` URL fragment through to the `path` property on a
   REAL `http://` stream URL (not just a local file), via a throwaway local
   HTTP server - ruled out "mpv strips the fragment for network streams."
2. Read the actual FastStream source
   (`<FastStream fork checkout>`, outside this repo,
   see "Notes for future agents" below) - `UrlMatchList.mjs`'s
   `getContentType()` resolves anime/movie from a user-configured allowlist
   matched against the BROWSER TAB's page URL, and `faststream-mpv-host.mjs`'s
   `withContentTypeFragment()` always appends exactly `fs-content=anime` (or
   `movie`) - grepped for any other code path that could produce a
   differently-shaped tag and found none. The user's pasted stats dump
   showed `content=anime` (missing the `fs-` prefix) but this is now
   understood to be a transcription artifact from copying a wrapped/cut-off
   OSD line, not a real difference - the code cannot produce that string.
3. Asked the user directly whether the uosc upscale/interp buttons were
   showing anything (Auto badge, a named preset) or looked off/grey when
   the stream played. Answer: **off**. That's the actual root cause, and it
   had nothing to do with the tag, FastStream, or content detection at all:
   `gpu-toggles.lua`'s `upscale_mode`/`current_interp` both defaulted to `0`
   (off) at script load, and NOTHING - not mpv itself, not the FastStream
   host - ever sent a command to turn Auto on. The tag was very likely
   correct and simply unused, because Auto (the only mode that reads it)
   was never active in the first place. This off-by-default predates Auto
   existing at all (see the comment removed from `mpv.conf` around
   `interpolation=no`, still accurate for mpv's OWN native interpolation
   property but never revisited for `gpu-toggles.lua`'s own Auto state once
   content-aware Auto was added the day before - see the 2026-09-12
   "content-aware Auto cycles" section).

**Fix**: `gpu-toggles.lua`'s `current_interp` and `upscale_mode` now both
start at `1` (Auto) instead of `0` (off). Verified with two from-scratch mpv
launches (no manual toggling, no pre-existing state) - one on an anime-
tagged filename, one on a plain one - both picked the correct model/shader
chain immediately from the very first frame, confirmed via the actual `vf`
filter params and `glsl-shaders` list (not just the OSD), with a clean
screenshot both times. Ctrl+i / Shift+A / the uosc menus still fully
override this per session exactly as before - this only changes what a
brand new mpv process starts at.

## 2026-09-14 session: RIFE/VapourSynth across a mid-stream resolution change - tested, not assumed

User raised (via general research on HLS + VapourSynth upscaler pipelines, not a
specific bug report) a real architectural question: `rife.vpy` reads
`width, height = clip.width, clip.height` **once** at script init (see the
`### ---- scene detection` block) and bakes MOD-padding/tiling into the graph
from that. If an HLS stream's frame dimensions changed mid-playback (ABR
variant switch, a user-triggered quality change, etc.) while RIFE was active,
would that crash or corrupt the pipeline, the same failure class as the
2026-09-13 "RIFE was silently corrupting every frame" bug?

Rather than answer from how VapourSynth graphs are generally known to work
(constant format/size per clip), this was tested for real:
`ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=24:duration=3 -c:v libopenh264
...` and the same at `640x360` (this repo's ffmpeg build has no libx264, same
as the 2026-09-13 precedent), joined into one continuous mpv playback session
via `edl://a_720p.mp4;b_360p.mp4` (EDL keeps a single filter-chain instance
running across the segment boundary, the closest local simulation of an HLS
variant switch without a real ABR server), with `--vf=vapoursynth=[rife.vpy]`
forcing RIFE on (mult=2/1, model 4.4) and `--vo=null --hwdec=no` to isolate
the VapourSynth graph from decode/display concerns. Note for reproducing:
the `.venv` VapourSynth dir needs to be on `PATH` for `vsscript.dll` to load
(same caveat as the RIFE PATH note elsewhere in this doc) - a bare shell that
hasn't picked up the one-time PATH addition will fail at
`[vapoursynth] Failed to load VapourSynth VSScript library` before ever
reaching the actual question, which is a PATH problem, not a resolution-
change problem, and was the first (false) result here before fixing the test.

**Result: no bug.** The log shows mpv's own `vf_vapoursynth` handling the
transition itself: `[vf] [vapoursynth] 640x360 ...` (the new size) followed
immediately by `[vapoursynth] draining VS for format change` then
`[vapoursynth] finishing up` - i.e. mpv drains and reloads the whole VS
script on a format change, exactly the same mechanism the manual documents
for seeks ("The script will be reloaded on every seek. This is done to reset
the filter properly on discontinuities" - `doc/manual.txt`'s `vapoursynth`
filter section), just also triggered by a resolution change, not only a
seek. `rife.vpy` has no state that persists across a reload (everything is
recomputed from `video_in`/`user_data` at the top of the script each time),
so the fresh `width, height` read on the reload is already correct for the
new size - no stale padding, no dimension mismatch. Full run completed
`finished playback, success (reason 0)`, zero errors/tracebacks/drops beyond
the expected end-of-segment "pin disconnect" messages every filter logs
during a normal drain.

**Conclusion**: no code change needed - the concern was reasonable (it's a
real constraint for VapourSynth graphs in general) but doesn't apply here
because mpv's own filter, not this repo's script, already owns recovery from
a format change. Do not add defensive dimension-mismatch handling to
`rife.vpy` for this scenario; there is nothing for it to defend against, and
per this repo's own conventions that would be unnecessary code for a case
that can't happen. If this is ever revisited (e.g. after an mpv upgrade),
re-run the same `edl://` test rather than re-deriving this from first
principles - it is cheap (a few seconds, two synthetic clips) and gives a
definitive answer either way.

### 2026-09-14 (same day): uosc proximity fade was per-element, not global - fixed and verified live

User reported the actual symptom directly: jiggling the mouse only brought up
whichever uosc bar the cursor happened to be near (e.g. near the bottom ->
only the timeline/controls; center of the video -> nothing), instead of the
whole UI appearing together the way a typical player's OSD does. Traced it to
`uosc/elements/Element.lua`'s `update_proximity()`: `self.proximity_raw =
get_point_to_rectangle_proximity(cursor, self)` is computed **per element**
(distance from the cursor to THAT element's own box), and `get_visibility()`
for an ordinary element is just `self.proximity` - there is no "cursor moved
anywhere in the window" global reveal in stock uosc, only this per-element
distance fade. `proximity_in`/`proximity_out` (`uosc.conf`) had already been
raised once before (40/120 -> 80/120... see the 2026-09-12 section values) but
that only widened the per-element radius, it didn't remove the fact that it's
per-element - a window taller/wider than ~2x that radius still leaves the top
bar and bottom controls independently gated.

**Fix**: `proximity_in`/`proximity_out` raised to `10000`/`10100` - comfortably
beyond any realistic window/display diagonal (2560x1440's is ~2939px), which
makes `self.proximity` effectively binary per element: 1 (fully visible)
whenever the cursor is anywhere inside the window, 0 when it actually leaves
(that path is separate - `cursor:move()`'s `global_mouse_leave` fadeout,
untouched). Net effect: every element now appears together on any mouse
movement, gated only by "cursor in window or not," not by nearness to each
individual bar.

**Verified live**, not assumed - this repo's own convention (see "Validation
targets" below): launched real mpv with a throwaway `--script` that moves the
(mpv-internal, non-OS-level - see the "no real input injection" constraint on
this machine) cursor via the `mouse <x> <y>` input command to the dead center
of a 1280x720 window (>=320px from every bar, so the OLD 80/120 values would
show nothing there), waited past `top_bar_flash_on`'s load-flash
(`flash_duration=1000ms`, an unrelated confound the first attempt didn't
control for), then used `screenshot-to-file ... window` to capture the actual
rendered OSD. Result: both the top bar (title, window controls) and the full
bottom controls bar (menu, buttons, timeline) appeared together at dead
center - confirmed by inspecting the screenshot directly, not by reading
mpv's exit code or log. No config-reachable regression found: leaving the
window still fades everything out (separate code path, unaffected), and
click/hover hit-testing uses raw pixel containment (`proximity_raw <= 0`),
not `proximity_in`/`out`, so button clicks are unaffected by how large those
got.

### 2026-09-14 (same day): fps toolbar button replaced - target readout was "useless in real world scenarios" per user, now shows real measured input/output fps

The uosc "fps" toolbar button used to just echo back the configured RIFE
target (Auto/60Hz/120Hz/144Hz) - a number you had just set yourself via the
same button's menu, telling you nothing about what the video was actually
doing. User asked for it to show the source fps, and the real output fps
once interpolation is active, instead.

**Implementation** (`gpu-toggles.lua`'s `update_fps_button()`): badge is now
`{input}fps` when interpolation is off, or `{input}->{output}` once any
interpolation mode is active. Input is `container-fps` (mpv's own source-fps
property, same value `rife.vpy` already reads as `container_fps`). Output is
mpv's own **measured** `estimated-vf-fps` for the vf-chain-based modes (RIFE
Auto/forced, amf_frc) - deliberately not a recomputation of what the target
*should* produce, which would silently drift from reality exactly when it
matters (Auto backing off its quality-safe 2x cap, the GPU not keeping up
with a forced target, etc. - see rife.vpy's own target-rate comments).
display-smooth (mode 2) is a special case: it never touches the vf chain (it
interpolates at the final display-compositing step via
`video-sync=display-resample`), so `estimated-vf-fps` would just read back
the source fps unchanged for that mode - `estimated-display-fps` (populated
because mode 2 forces a display-sync video-sync mode) is used instead for a
number that's actually true for what that mode does. A 1s
`mp.add_periodic_timer` keeps the reading live during playback, since
`estimated-vf-fps`/`estimated-display-fps` are continuously-changing rolling
averages, not one-time config values like the thing this button used to show;
the existing discrete update call sites (mode toggles, target changes) are
unchanged and still fire immediately on top of that for snappier feedback on
an explicit action. The click-to-open RIFE target menu itself is unchanged -
only the readout changed.

**Verified live**: same real-mpv-plus-screenshot method as the proximity fix
above, PLUS direct property readback via a throwaway script (`mp.msg.info`
dumping `container-fps`/`estimated-vf-fps`/`estimated-display-fps` at each
step) rather than trusting the screenshot's small, crowded badge text alone -
this repo's `controls=` list (`uosc.conf`) is long enough that several
adjacent badges render touching/overlapping at a 1280px test window width,
which visually truncated the badge in the first screenshot attempts (looked
like `4->48` instead of `24->48`) even though the underlying value was
correct - a purely cosmetic pre-existing crowding characteristic at narrow
widths, unrelated to this change, not something this session touched. Direct
property dump confirmed real numbers end to end on a real 24fps source: Auto
default measured `container-fps=24`, `estimated-vf-fps=46.4` (converging
toward RIFE's 2x target); forcing RIFE explicitly measured `estimated-vf-fps`
settle at exactly `48.0` (real 2x); turning interpolation back off read
`36.09` mid-transition (expected - `estimated-vf-fps` is a 10-frame rolling
average, so it drifts back down toward 24 over the next several frames rather
than snapping instantly - the button's `current_interp == 0` branch
deliberately ignores `estimated-vf-fps` entirely for exactly this reason, so
this transitional artifact never actually reaches the badge).

## 2026-09-14 session (later): full-repo review - one dead feature, several state/idempotency bugs

A read-through of everything user-authored in the repo (Lua, `rife.vpy`, the
configs, the PowerShell installers, `mpv-single.cs`, the CI workflow, the
docs), followed by actually exercising the parts that looked suspicious.

### The RIFE fps-target button never worked on real content

The uosc "fps" button and its 60/120/144Hz menu entries were a dead feature.
`rife.vpy` computed `multi = target_fps / src_fps` and handed the resulting
`Fraction` to vsmlrt's `RIFE()` **without `video_player=True`**. vsmlrt has two
implementations of a fractional `multi`, and the default (non-player) one
requires the akarin plugin, which this repo has never installed:

    RuntimeError: fractional multi requires plugin akarin

which mpv surfaced as gpu-toggles.lua's `RIFE failed (check .venv / rife.vpy)`
OSD - pointing at the venv, which was fine the whole time.

This was invisible because **Auto (the default, and the only target anyone had
tested) always resolves to exactly 2.0**, an integer, which takes vsmlrt's
other code path entirely. Measured by executing the real `rife.vpy` against
synthetic clips at each target x source-fps pair:

| target | 23.976 | 24 | 29.97 | 60 |
|---|---|---|---|---|
| Auto | OK | OK | OK | OK |
| 60Hz | FAIL | FAIL | FAIL | FAIL (`multi must be at least 2`) |
| 120Hz | FAIL | OK | FAIL | OK |
| 144Hz | FAIL | OK | FAIL | FAIL |

10 of 12 broken - and the failures are exactly the common cases, since
23.976/29.97 is most real content.

Two fixes, both in `rife.vpy`:

1. `video_player=True` on the `RIFE()` call. This is vs-mlrt's own
   player-oriented branch (their issue #59): it builds the same output lazily
   via `FrameEval` with no akarin dependency. It also matters for a second,
   independent reason - the non-player path materialises explicit per-frame
   index lists over `int(src_frames * multi)`, and mpv hands `vf_vapoursynth`
   a clip whose `num_frames` is a huge fake value, so even *with* akarin
   installed that path would have tried to loop ~2 billion times at
   filter-init time. It changes nothing for an integer multi, so Auto is
   untouched.
2. `multi = max(2.0, target / src)`. vsmlrt rejects `multi < 2` outright, so a
   target at or below the source fps (60Hz on 60fps content) failed the whole
   `vf add`. Asking an interpolator for fewer frames than the source has is
   meaningless anyway; 2x is the floor this repo uses everywhere else.

Re-verified across 28 target x source-fps combinations plus odd resolutions
(mod-32 pad), model 4.26 (mod-64), empty `user_data` and a malformed target:
all pass, each producing exactly the requested output fps. **Auto on a
high-fps source (90-143fps, where `min(2.0, display/src)` lands between 1 and
2) was silently broken by the same bug and is fixed too.**

Also removed `rife.vpy`'s `mult` user-data key: it was parsed, documented in
the header, and then unconditionally overwritten from `target` a few lines
later. gpu-toggles.lua had been faithfully sending `mult=2/1` on every filter
add for nothing.

### `c` could claim "Subtitles: on" and show nothing

`subtitle-toggle.lua` treated "the file has a subtitle track" as "a subtitle
track is selected". mpv's `--subs-fallback` defaults to `default`, so with this
config's `slang=de,en` a file carrying only e.g. Japanese subs gets **no** track
selected at all. The old code then flipped `sub-visibility`, printed
`Subtitles: on`, and displayed nothing - the exact case where a "smart"
subtitle key most needs to do something. Now scans `track-list` once for both
the first sub track and whether any is `selected`, and selects the first one
when none is.

### gpu-toggles.lua state/feedback bugs

- `apply_shader_preset()` returned nothing, so `apply_upscale()` recorded
  `upscale_active_preset = preset` even when the preset had been abandoned for
  missing files - leaving the *previous* chain live on the GPU while the OSD
  said "staying off" and the state variable claimed the new preset. It now
  reports success, clears the chain on failure, and the caller records `nil`.
- The identity dedupe in `apply_upscale()` suppressed the OSD as well as the
  recompile. Two modes can resolve to the same preset table (Auto on anime
  <=720p and the forced "Anime SD" mode are the same object), so cycling
  between them looked like a dead keypress. Split into an `announce` argument:
  user-initiated changes always confirm, the per-file re-evaluation stays quiet.
- `restore_vrr_video_sync()` hardcoded `'audio'` instead of restoring what
  mpv.conf asked for. It matched by luck; editing mpv.conf's `video-sync` line
  would have been silently overridden on the first mode switch. Now captured
  once at script load.
- The 1s fps-button timer pushed `set-button` unconditionally, and uosc's
  handler calls `request_render()` on every push - so it forced a full UI
  repaint every second forever, including paused, UI hidden, and idle with no
  file (where the badge is a constant string). `set_uosc_button()` now skips
  identical pushes. Measured over 20s of idle: 20+ pushes down to 1.
- The upscale badge read Auto's preset off `height` in idle mode, where there
  is no file, picking the `<=720p` tier from a height of 0 and confidently
  showing "Movie SD" on a player with nothing loaded. Shows "Auto" now.

### install-rife.ps1 was not idempotent, despite saying so

Steps 3/4/4b all shell out to `py7zr`, but `py7zr` was only pip-installed
inside steps 2 and 2b - which are skipped when `vsncnn.dll`/`vsort.dll` already
exist. Re-running against a partial install (DLLs present, models or
`vsmlrt.py` missing) reached step 3 with no py7zr and died with
`ModuleNotFoundError`. That is precisely the re-run the script's "idempotent;
safe to re-run" header promises. Moved into the unconditional pip step.

Also deleted `$basePy`/`$basePyOk` (assigned, never read, and `$basePyOk` was
never defined at all).

### install-shaders.ps1 never installed ArtCNN

`ArtCNN_C4F32_DS.glsl` *is* the entire "Anime HD" upscale preset, and none of
the four ArtCNN files were in the installer - they only existed because they
happen to be committed. A clean recreate-on-a-new-PC run per `RECREATE.md`
would have produced a broken preset. Added, pinned to ArtCNN `v1.6.2` (the
tag's files verified byte-identical to the committed copies), and the verify
step now exits non-zero on a missing file instead of just printing `False`.

### mpv-single.cs

- Launched console-mode `mpv.com` from a `winexe` with no `CreateNoWindow`, so
  Windows allocated a fresh console for every opened file.
- Swapped the running instance's playlist but never raised its window, so
  opening a file from Explorer started playback behind whatever you were
  looking at. Now restores/foregrounds it from the launcher process, which
  still holds the foreground rights Windows would deny mpv itself.
- Argument quoting wrapped the path in quotes and escaped embedded quotes,
  which breaks on any path ending in a backslash - what Explorer hands out for
  directories. Replaced with proper `CommandLineToArgvW` escaping (backslashes
  doubled only where they precede a quote) and round-tripped through
  `CommandLineToArgvW` itself: 9/9 cases correct, where the old version
  corrupted 5 - a trailing-backslash directory path parsed as the path plus a
  stray quote, swallowing the argument that followed it.

### Docs that had drifted from the code

`AGENTS.md`'s own "Key runtime features" summary still said Auto no longer
picks the RIFE model by content type and that only 4.4 was offered - reverted
on 2026-09-13, but only "Current status" further down had been updated, so the
file contradicted itself. `input.conf`, `install-rife.ps1` and `RECREATE.md`
carried the same stale claim. `mpv.conf` attributed the VapourSynth PATH
requirement to "RIFE mode 3" (mode 3 is amf_frc; RIFE is 1 and 4) and
described `vd-lavc-film-grain` as a yes/no grain-synthesis toggle - it takes
`auto|cpu|gpu` and only controls *where* the codec's own grain metadata is
applied. `input.conf`'s menu still labelled Quit as `(q)` though `q` is a
speed key; a plain quit is now on `Ctrl+q`.

Also: `vo=gpu-next` is now set explicitly. It was already the default, but the
manual says the default VO "is subject to change, and must not be relied
upon", and several settings in mpv.conf are correct only under gpu-next
(tone-mapping auto resolving to spline rather than bt.2390, hdr-compute-peak,
GPU film-grain application).

And `.styluaignore` did not cover `portable_config/Scripts/autoload.lua` -
vendored upstream mpv code on 4-space indent, against this repo's
`indent_type = "Tabs"`, with format-on-save enabled in `.vscode/settings.json`.
One accidental save would have rewritten all 275 indented lines.

## 2026-09-14 session (later still): interpolation target removed, interpolation off by default

Direct follow-up to the same day's "full-repo review" session above, prompted
by the user after that session's `rife.vpy` fix made the forced 60/120/144Hz
target actually work for the first time: **"it is not realtime and i think it
does not work so just keep the logical framrates and delete the fps targets
just show what interpolation can achive"**, followed shortly after by
**"as i see it the interpolation is just too inconsistent and frame drop i
need a good visual experience."**

Two separate asks, both acted on:

### 1. Delete the fps target feature entirely

Not disable, not keep as a manual-only option - remove the code. Deleted from
`gpu-toggles.lua`: `FPS_TARGETS`, `target_refresh()`, `fps_target_index()`,
`fps_target_label()`, `interp_target()`, `cycle_fps_target()`,
`open_fps_menu()`, the `cycle-fps-target` key binding, and the
`interp-target`/`cycle-fps-target`/`open-fps-menu` script-message
registrations. Deleted from `input.conf`: the four `interp-target N` menu
entries and the `cycle-fps-target` menu entry. Deleted from `rife.vpy`: the
`target` user_data key and its parsing/branching - there is now exactly one
multiplier policy (the old "Auto" branch, unconditionally): quality-safe ~2x,
backed off only when the source is already close to the display refresh.

The uosc "fps" toolbar button stays, but as a pure readout: `set_uosc_button`
is called with no `command` key, which uosc's `ManagedButton:update()` reads
as `is_clickable = false` (verified against `elements/ManagedButton.lua`
before relying on it, not assumed) - the button renders but does nothing on
click, "just show what interpolation can achieve" taken literally.

`rife.vpy` still calls `RIFE()` with `video_player=True`. That is not a target
leftover - it is independently needed because the display-refresh backoff
itself produces a non-integer multiplier whenever the source is close to (but
not exactly at) the display rate, e.g. a 120fps source on this 144Hz panel
(120 -> min(2.0, 144/120)=1.2x). Removed anyway would have been wrong.

### 2. Interpolation defaults to OFF, not Auto

The 2026-09-13 "both cycles start at Auto" change (see that section far
above) is half-reverted: `upscale_mode` stays at 1 (Auto), `current_interp`
goes back to 0 (off). This is not symmetric on purpose. The reasoning for
Auto-by-default was sound for upscale and turned out not to transfer to
interpolation:

- Upscale is GLSL shaders inline in the normal GPU render pipeline. No
  round-trip, no extra latency budget to blow, no way for "the wrong preset"
  to look like anything worse than a slightly different picture. Auto costs
  nothing to leave on.
- RIFE is a vf-level VapourSynth filter: GPU frame -> system RAM -> ONNX
  Runtime inference -> back to GPU, per frame, plus a Python duplicate-frame
  callback on top. That has a real, variable cost, and this session's user
  report is that on real content it does not consistently win that race -
  the visible result is dropped frames, which is a worse defect than the
  judder RIFE exists to fix. A benchmark on synthetic/CC content saying
  "1080p measured free" (see the 2026-09-13 sections) does not generalize to
  "always free on everything the user actually watches" - direct viewing
  experience overrides it here.
- This display has FreeSync (VRR) confirmed on, and `mpv.conf` already keeps
  `video-sync=audio` specifically so VRR (plus AMD's Low Framerate
  Compensation for sub-VRR-floor 24fps content) does judder smoothing in
  hardware, with zero frames to drop, for free. That was always the real
  smoothness mechanism this setup leans on; RIFE was the extra on top, never
  the foundation. Defaulting the extra off when it is not reliably paying for
  itself is the correct default, not a regression.

RIFE remains one keypress away (`Ctrl+i`, or the uosc "interp" button) for
content where it does keep up and is worth trying.

Updated to match: `gpu-toggles.lua`'s `current_interp` initializer and its
surrounding comment (now explaining the off default instead of the Auto
default), `mpv.conf`'s INTERPOLATION section, `input.conf`'s GPU section
comment, `RECREATE.md`'s verification steps and mermaid diagram, and
`AGENTS.md`'s "Key runtime features"/"Current status"/open-items sections
(items 5 and 7 in particular - item 5's "not real-time at 4K" concern turned
out to understate the problem, and item 7's open question about whether the
forced targets were real-time is now moot since the feature is gone).

Nothing here was re-verified with a real RIFE run on the user's actual
content - that was the report this session acted on, not a benchmark to
reproduce. If interpolation reliability is revisited later, the right
evidence is dropped-frame counts (`frame-drop-count`, `decoder-frame-drop-count`)
or `vo-passes` timings against the user's own files, not another synthetic
clip.

## 2026-09-14 session (final follow-up): closed the last open item - source fps at/above display refresh

Direct continuation of the two sessions above. The previous session's closing
note flagged one loose thread rather than expanding scope on its own: the
"quality-safe ~2x, backed off near the display refresh" formula -

    multi = min(2.0, max(1.0, display / src_fps))

- floors to exactly the integer `1.0` whenever `src_fps >= display` (a source
at or above the display's own refresh rate: 144fps content on this 144Hz
display, or anything faster - 150/200/240fps clips, screen recordings, etc).
vsmlrt's `RIFE()` rejects an integer `multi < 2` outright
(`RIFE: multi must be at least 2`), so that case failed the whole `vf add`
instead of doing the correct thing, which is nothing - the display cannot
present more frames than its own refresh rate regardless, so there is no
useful interpolation to do.

The user asked to "fix everything again so nothing is left to do or left
unclear," which is what turned this from a footnote into a fix. Wrapped the
scene-detection/duplicate-frame/RIFE-call/colorspace-convert pipeline into a
local `_interpolate()` function, then dispatch on the multiplier:

    if multi == 1.0:
        video_in.set_output()
    else:
        _interpolate()

The equality check is exact-float-safe here (not a fragile `abs(x-1)<eps`):
`multi` is the literal return value of `max(1.0, ratio)`, and Python's `max`
returns one of its actual input objects, not a recomputed value - so when
`ratio <= 1.0` the result IS the float literal `1.0`, not something merely
close to it.

Verified against the real `.vpy` through the venv, using `vs.get_output(0)`
to read back what the script actually produced (the `VideoOutputTuple` this
VapourSynth build returns needs `.clip`, not `.fps` directly - noted here in
case a future probe script hits the same `AttributeError` and wastes time on
it):

- The four previously-failing cases (144/150/200/240fps source at 144Hz
  display) now all pass through cleanly, each preserving its own fps and
  frame count exactly (not coerced to 144).
- The four normal interpolating cases (23.976/24/60/120fps) are unaffected -
  same output fps as before this change.
- Pixel/frame-count/fps identity check on the pass-through path: bit-for-bit
  identical to the untouched source clip.
- Re-ran the full mpv end-to-end harness (real `Ctrl+i`, real VapourSynth
  init/teardown against the actual `.venv`): unchanged from the prior
  session's confirmed-good run.

This was the only item left open by the prior two sessions. Nothing else is
outstanding as of this entry.

## 2026-09-14 session (fourth follow-up): "fix everything again so nothing is left to do or left unclear" - full consistency sweep

Prompted by exactly that instruction after the third follow-up closed the
`multi == 1.0` item. Treated it as license to re-read every file touched
across all four sessions today end-to-end, not just re-verify the specific
fixes already made - looking for anything stale, contradictory, or merely
duplicated that a careful read would flag as "not actually done."

### A real bug this pass caught: an invented keybind

The third-session fix for input.conf's stale "Quit (q)" menu label (see the
"full-repo review" session) added `Ctrl+q quit` as a new active keybind and
a matching menu entry. Re-checking it against mpv's actual defaults
(`--input-cmdlist` / the manual) found this was never necessary: mpv's own
default plain-quit bindings are `q`, `Ctrl+w`, **and** `Ctrl+c` - and this
repo's `input.conf` only ever redefines `q`. `Ctrl+w`/`Ctrl+c` had been
working the entire time; nothing was actually lost when `q` became a speed
key, only the menu's label describing it had gone stale.

Worse, the invented `Ctrl+q` menu entry was misplaced: uosc's own menu
builder (`uosc/lib/menus.lua`'s `get_menu_items()`, read directly rather than
guessed) gives a `#!`-titled item with no `>` in its title a standalone
ROOT-LEVEL menu row, positioned by where it first occurs in the file. Since
the existing "Quit & save position (Q)" entry lived in the menu-only
reference block at the very end of `input.conf`, and the new `Ctrl+q` line
had been placed up near the GPU section for convenience, the two "Quit"
actions would render nowhere near each other in the right-click menu -
confirmed with an actual screenshot of the real uosc context menu before
touching anything, not assumed:

    Playback / Subtitles / Tools / Video / Audio / Playlist / Tools / Quit...

with the invented entry sandwiched between Video and Audio.

Fix: removed the fabricated `Ctrl+q` binding and its section entirely.
Restored a correctly-labeled menu-only entry (`#   quit  #! Quit (Ctrl+w /
Ctrl+c, mpv defaults)`) immediately next to `quit-watch-later`, matching the
file's own "key column `#` = no keybind, menu entry only" convention and its
original layout before the earlier session's edit. Re-screenshotted the real
menu to confirm: both Quit entries now render adjacent at the bottom, exactly
as intended, with an honest label (no fake keybind hint - `is_dummy` entries
correctly get `hint = nil` per uosc's own code).

### Other staleness found on the full re-read

- `rife.vpy`'s own header comment still said "Ctrl+i mode 3" for RIFE -
  mode 3 is amf_frc; RIFE is modes 1 and 4. Leftover from an old cycle
  ordering, corrected.
- `AGENTS.md`'s "Current status" section repeated the "fps button is a
  measured-only readout" fact in three separate places across two sections
  (once tersely, once in detail, once in "Key runtime features") - the kind
  of redundancy that itself reads as unclear ("did they mean something
  different each time?"). Consolidated to one detailed statement.
- Two spots in `AGENTS.md` had a stray blank line splitting what should have
  been one continuous bullet list into two visually separate lists
  (Markdown quirk, not a rendering bug, but sloppy) - removed.
- `RECREATE.md`'s file-inventory table still described `mpv.conf` as
  containing "interpolation targets" (plural, the removed feature) instead
  of just "interpolation." Its "key facts" list also hadn't been updated to
  mention the `multi == 1.0` pass-through fix from the previous follow-up.
- `mpv.conf`'s own top-of-file comment still referenced "the interpolation
  target block" as a thing that exists.

None of these were functional bugs - all were documentation/UI-label drift
of exactly the kind this whole day's work was already about eliminating.
Caught by treating "nothing left unclear" as licensing a genuine fresh
re-read rather than a re-verification of prior fixes only.

Verified after all of the above: `stylua --check` clean, mpv.conf/input.conf
parse clean, `rife.vpy` Python-syntax-checks clean, and the real uosc context
menu screenshot (attached to this session's working notes, not committed)
confirms the Quit grouping fix. Nothing outstanding.

## 2026-09-18 session: remembered playback speed across launches

The user asked for the last-selected playback speed to carry to the next
video and the next mpv launch. mpv's `speed` is a global option, so within
one process it already carries across files (manual, "Per-File Options" -
only file-local options reset between files); what resets to 1x is a fresh
`mpv.exe` launch. mpv's watch-later store was the wrong shape for this: it
is keyed by hashed file path (it would restore the speed OF a file, not the
last speed chosen for anything) and it only writes on watch-later events
(quit-with-save / file end), not on every speed change.

Fix: new `portable_config/Scripts/remember-speed.lua`. It observes the
`speed` property (so it catches the `input.conf` speed keys, the uosc speed
button's menu, and mpv's own `[`/`]`/`{`/`}` alike - no keybind was wrapped),
writes every change to `portable_config/speed.json`, and re-applies the
saved value once at script load, before the first file settles. Save
failures are logged, never fatal; a missing/corrupt state file self-heals on
the next save (`observe_property` fires on its initial read, so the first
write happens even with no user input).

`~~state/` was chosen over a hardcoded path and resolved live via
`expand-path` at script load: on this portable install it expands to
`portable_config/` itself (verified by asking mpv itself - `mpv --idle
--script=<probe>` printing the expansion - not assumed from the manual's
generic "on some platforms" wording), so the state file lands next to
`mpv.conf`. A hardcoded absolute path would have broken on any other
machine or install layout.

Verified with a two-process roundtrip against a real decoded file (per
AGENTS.md validation item 8, a real H.264 file, not a synthetic in-process
only check): run 1 - probe script sets speed 2.5 after `file-loaded`, quits;
state file exists with `{"speed":2.500000}`. Run 2 - FRESH mpv process,
read-only probe reads `speed` after `file-loaded`: 2.5, i.e. restored. The
in-process-only alternative ("set it, read it back in the same process")
would have proven nothing, since `speed` was already global within one
process. Test artifacts (probe scripts, test video, the test-written state
file) were deleted afterwards so the user's first real launch starts from
their own usage, not the test value.

Deliberately NOT done: no new keybind or uosc button (the feature is
invisible when it works); `speed-button.lua` untouched (its badge/menu
already reads the same live `speed` property, so it shows the restored
value with no changes); no `watch-later-options` config (the per-file store
stays per-file - `remember-speed.lua` covers the global case).

## 2026-09-19 session: preset-speed toggle, click-to-pause, mouse-fade confirmation

Three user requests; one real feature, one real feature, one false alarm.

### Preset speed keys now toggle back on repeat

The user wanted q (3x) -> press again -> back to the previous speed, and asked
up front what a SECOND different preset would do so the semantics could be
confirmed before building. Answer given: per-key memory - pressing a preset
sets its speed, pressing the SAME key again reverts to whatever was active
just before that key took effect. q(3x) -> y(5x) -> y -> 3x; then a(4x), a ->
3x, a -> 4x again. Implemented as new `portable_config/Scripts/speed-presets.lua`;
`input.conf`'s g/b/q/w/a/y/e/h now route through
`script-binding speed_presets/preset <value>` instead of `set speed`.

Two dispatch facts each cost a debugging cycle and are easy to hit again:

1. AGENTS.md validation item 2 (the script-binding/script-message bug) bites
   for Lua-side receivers too: `script-binding speed_presets/preset` from
   input.conf does NOT call a bare `mp.register_script_message('preset', ...)`
   - the first live test pressed keys and nothing happened (silent, no error).
   The manual's script-binding internals say it dispatches a `key-binding`
   message that only mp.add_key_binding's registry unpacks. Registered with
   `mp.add_key_binding(nil, 'preset', ...)` (nil key = no default binding,
   input.conf is the only path) it worked immediately.
2. `event.arg` (the script-binding argument carrying the preset value) only
   exists with `{ complex = true }`. Without it the handler is called with NO
   arguments - second live test crashed with "attempt to index local 'event'
   (a nil value)". complex handlers also fire on down AND up, so the handler
   gates on `event.event == 'down' or 'press'` to apply exactly once per press.

First-press fallback: with no memory for a key yet (e.g. speed was restored by
remember-speed.lua from last session), reverting falls back to 1x rather than
doing nothing - probed: restore 4x, first `a` press -> 1x.

The uosc speed MENU was rewired to the same binding (speed-button.lua items are
now `script-binding speed_presets/preset <v>` instead of `set speed <v>`) so
menu clicks toggle exactly like the keys; probed end to end (2.5 -> 4 revert).

Verified with the user's exact sequence via `keypress` probes:
q=3, y=5, y=3, a=4, a=3, a=4. Fine-adjust keys (s/d), r, [ ] { }, and the uosc
speed slider are deliberately NOT routed through the toggle - they are
adjustments, not presets; tracking them would make the revert target drift.

### Click-to-pause and double-click fullscreen

`mbtn_left cycle pause; script-binding uosc/flash-pause-indicator` and
`mbtn_left_dbl cycle fullscreen` added to input.conf. Two interactions were
checked against mpv's input.c (fetched for this) before relying on them:

- uosc over plain video: its cursor.lua `decide_keybinds()` disables uosc's
  mbtn_left binding group (level 0) whenever the cursor is not over a uosc
  element, so the input.conf binding only fires over bare video; clicks on
  timeline/controls/menus stay UI clicks.
- window dragging: holding mbtn_left and moving past
  --input-dragging-deadzone (3px) begins VO dragging and mpv's core cancels
  the pending click (`release_down_cmd(ictx, true)` in input.c when dragging
  starts), so pause does not fire after a completed drag.

Probed: `keypress MBTN_LEFT` three times -> pause true/false/true. The explicit
`flash-pause-indicator` in the binding is belt-and-braces (pause_indicator=flash
already flashes on any pause change; uosc's own docs show the same combined
form for the property race documented in PauseIndicator.lua).

### Mouse/UI fade: confirmed already working, NOT changed

The user reported the cursor "sits in the video". Before changing anything, a
real-window probe counted `mouse-pos` property events for 6s after the cursor
stopped: exactly 1 (the initial move), no event stream - nothing in this
config resets uosc's autohide timer during playback, and cursor-autohide=1000 +
uosc autohide=yes + the binary proximity config were all already correct. The
user then confirmed on a real session that the fade works (their report was a
mid-test hover). Lesson recorded in AGENTS.md: do not "fix" the fade again
without a fresh repro.

Two verification methods tried and their limits learned: mpv's
screenshot-to-file captures VIDEO FRAMES ONLY (no OSD/uosc layer), so it can
never prove a UI-fade change; a real screen capture (CopyFromScreen) during a
windowed run is the method that can. The CopyFromScreen captures taken showed
the UI visible - because the user was actively hovering mid-test (as they then
confirmed themselves), which the event-count probe corroborates.

Test artifacts (probe scripts, test video, screenshots, the test-written
speed.json) were all deleted after the session.

## 2026-09-19 session (later): FastStream anime sometimes does not start playing

Reported: "sometimes when I start an anime via FastStream in mpv the video
does not start, I still have to hit enter or start". Investigated the full
launch chain before touching anything: a subagent read the FastStream fork
(outside this repo, `<FastStream fork checkout>`) end to
end. Its flow: webRequest intercepts the stream -> MpvBackend sends
`{type:'open', url, contentType, headers}` over native messaging -> the Node
host reuses its single mpv instance over the named pipe
(`set_property http-header-fields`, `force-media-title`, then
`loadfile <url> replace`) or spawns a fresh one via WMI. The URL already
carries `#fs-content=` (appended host-side), and the header relay (Referer /
Origin / UA) is the mechanism the FastStream streams depend on. Notably, the
fresh-spawn path is fire-and-forget (no retry, no playback verification), and
there are several documented ways a stream can fail outright (signed-URL
expiry, header-cache race, cookies never relayed) - but none of those match
"video shows and I just have to press enter/start".

The symptom - the file IS loaded and rendered, sitting on its first frame -
points at pause, not at loading. Root cause: mpv's `pause` option is global
and carries across files in one process (manual, "Per-File Options"), and the
FastStream reuse path (and mpv-single.exe) loads the next episode into an
already-running player. If the previous file was paused - user-paused (common
since yesterday's mbtn_left click-to-pause binding) or paused AT EOF by
keep-open=yes in mpv.conf (manual: keep-open "will act like set pause yes on
EOF") - the new file inherits pause=yes. Fresh spawns are unaffected (pause
defaults to no), which is exactly why it was intermittent.

Fix: new `portable_config/Scripts/auto-start.lua` - clears an inherited pause
once per file at `file-loaded`, i.e. only at the load boundary. A pause set
during playback is respected (file-loaded does not refire until the next
load), so click-to-pause / space / the uosc timeline scrub-pause all keep
working. `paused-for-cache` (mpv's internal buffering pause) is a separate
mechanism and is not touched, so cache-pause-initial=yes still works. Accepted
edge, documented in the script header: a pause set during the load window
itself (between loadfile and file-loaded, 1-3s on a network stream) is
indistinguishable from an inherited pause and is also cleared.

Verified with real two-load probes on a generated H.264 file: (1) pause on
file 1, `loadfile ... replace` (the exact IPC action the FastStream host
issues) -> file 2 plays (pause=false at file-loaded). (2) pause DURING file 2
-> stays paused (respected). (3) the real EOF path: a 3s file plays out under
keep-open=yes (mpv auto-pauses at EOF), then `loadfile replace` -> new load
plays. Not probed against a real FastStream stream (none was at hand; the
mechanism is generic - ANY loadfile into a paused player), which is an honest
limit of this verification: the property-level behavior is confirmed, the
end-to-end repro with the real extension is not.

Deliberately NOT done: no change to FastStream's native host (the repo rule
is to edit it in its own directory if ever needed - the fix does not belong
there, since mpv-single.exe and any other external loadfile source have the
same latent behavior); no `pause=no` hack in the launch command (it would
fight a deliberate pause on the file being replaced); no keep-open change
(keep-open is load-bearing for playlist-friendly behavior).

## 2026-09-19 session (later still): FastStream mpv sometimes opens late AND behind the browser

Reported: after clicking an anime, the page played in the browser for a while,
then mpv appeared - in the background instead of the usual foreground +
fullscreen (with the remembered speed, which was fine).

Root cause, reproduced deterministically (not inferred): the FastStream native
host (`native-host/faststream-mpv-host.mjs`, installed copy in
`%LOCALAPPDATA%\FastStreamMpvHost\`) raises mpv with a PowerShell helper that
polls for mpv's window for at most 10s (the 2026-09-15 bump from 3s). mpv has
no window until the stream has been opened and probed, so a slow CDN/HLS
manifest that holds the window back past the deadline makes the helper give
up (`focus: "nowindow"` in the host debug log) - mpv then opens later, behind
the browser, because a WMI-spawned process has no foreground rights of its own.
Test rig: a local HTTP server that stalls the FIRST request for 12s, real host
(`FASTSTREAM_MPV_DEBUG=1`), a 100ms poller logging foreground process + mpv
window presence. Before: host replies at 10.4s with `nowindow`, window appears
at 13.1s, foreground stays on the previous app. The same mechanism explains
"played in the browser": the extension only pauses the tab
(`pauseTabMedia`) when the host REPLIES, and the reply waits for the focus
helper, so a late window keeps the browser playing.

Fix (FastStream fork, two changes in the host, deployed to the installed copy):
1. `--force-window=immediate` on the fresh-spawn command line. The window now
   exists ~1s after launch regardless of stream latency, so the focus helper
   always finds it in time, the tab is paused promptly, and the stream loads
   inside a visible, focused fullscreen player. This is host-side, not
   `mpv.conf`, on purpose: it only changes FastStream-spawned instances, not
   double-click / mpv-single.exe launches.
2. Focus-wait deadline 10s -> 30s (`WindowWaitSeconds`), with the PowerShell
   kill timeouts derived from it. Belt-and-braces for mpv's own startup being
   slow (cold start, AV scan) rather than the stream: measured in isolation
   (immediate window disabled), a window appearing at 13.2s is now focused at
   13.4s (`focus: True, foreground: True`).

Verified with the real host and real mpv, same stalled server: host replies at
0.9s, window at 1.0s, mpv foreground at 1.2s (baseline foreground was Firefox
in that run), stream starts at ~12s with `hwdec-current=vulkan`, speed 3
restored by remember-speed.lua, fullscreen, 0 dropped frames; screenshots show
a black fullscreen window while stalled, then the video. FastStream unit
tests (`MpvNativeHost`, `MpvBackend`) pass; they only cover pure functions, so
the behavioural check above is the real evidence.

Known trade-off: while a slow stream is still opening the user now sees a
black fullscreen mpv (previously: the browser kept playing and mpv popped up
late). A stream that never opens leaves a visible black window instead of an
invisible windowless mpv (`idle=yes`). Not touched: the reuse path
(`focusPid`) shares the same deadline constant, and `singleInstance` reuse of
a window that already exists is unchanged.

## 2026-09-19 session (last): upscale cycle - the "forced" framing removed

Reported: the Shift+A upscale cycle showed a "forced" extra step. The user
wants exactly three options when toggling: Auto, the anime upscaler, and the
movie upscaler - no "forced" step.

What was actually there: the cycle was already off -> Auto -> Anime -> Movie
-> off (4 states, `UPSCALE_MODE_COUNT = 4`) - no extra state existed. The
"forced" the user saw was framing, in five places:

1. `preset_for_mode()` comment called modes 2/3 "Anime forced"/"Movie forced".
2. `apply_upscale()`'s OSD suffix appended "(forced)" for modes 2-3 ("(Auto)"
   for mode 1), so every named-pick OSD read e.g. "Shaders: Anime4K C+A (HQ)
   [anime] (forced)".
3. `update_upscale_button()` appended `*` to the named-mode badge ("Anim*"/
   "Movi*") and said "(forced)" in the tooltip.
4. The uosc menu items came from the same labels.
5. `input.conf`'s menu entries read "Anime (forced)"/"Movie (forced)".

The labels are framing, not behavior: a named mode picks its preset the same
way Auto does (`preset_for_mode()` resolves mode -> preset per call; Auto
resolves via content type, Anime via the anime chain, Movie via
`current_movie_preset()`), the pick is sticky across file changes exactly as
before, and Movie is still resolution-adaptive internally. Removing the word
changes nothing except what the UI calls it.

Changes (labels only, no behavior):
- `gpu-toggles.lua`: preset_for_mode()/apply_upscale() comments reworded;
  OSD suffix "(forced)" -> "(chosen)" ("(Auto)" unchanged); badge `*` suffix
  dropped (badges now Off/Auto/Anim/Movi, matching the 2026-09-15
  fixed-width badge rationale - the `*` made the badge 5 chars in the same
  fixed-size icon box the 4-char limit was set for); tooltips reworded
  ("one of the 2 forced presets" -> "Auto, Anime or Movie").
- `input.conf`: the Shaders menu entries drop "(forced)"; the Shift+A label
  is "Cycle upscale (Auto/Anime/Movie)"; comment block notes the change.
- `AGENTS.md`: Key runtime features + Current status bullets reworded; the
  `*`-on-badge mention in the badge bullet is now historical.

Verified live (real mpv process, real H.264 test file 720p24 via
`ffmpeg -f lavfi -i testsrc2=... -c:v libopenh264`, probe script passed via
`--scripts=` from OUTSIDE `Scripts/` so it does not auto-load - an earlier
probe copy placed in `Scripts/` loaded twice, once as `--scripts` arg and
once via mpv's Scripts/ dir auto-load, doubling every PROBE line):
`set-upscale 2` -> Anime chain list, `set-upscale 3` -> FSRCNNX+SSimSuperRes
(720p file -> FSRCNNX chain, resolution split intact), `set-upscale 0` ->
empty list; then cycling with `cycle-upscale` from Off: Off -> Auto (empty,
local file - FastStream gate) -> Anime -> Movie -> Off -> Auto -> Anime,
wrapping cleanly with no extra step anywhere. OSD text itself was not
screenshot-verified this time (the probe asserts the applied shader list,
which is what the OSD reflects; the suffix string change is a literal in the
diff).

Note for future probes: script `print()` output is suppressed by
`--really-quiet` (first isolated run produced a 0-byte log because of it);
`mpv.com` output via `cmd /c` redirect came up empty twice - the reliable
pattern was `Start-Process mpv.exe -Wait -PassThru
-RedirectStandardOutput/-RedirectStandardError`, consistent with the
2026-09-11 capture gotchas.


## 2026-09-20/21 - movie upscaler rebuilt, interpolation removed

The user reported the Movie upscaler gave "no improvement at all" on a test
film they had added (1712x720 H.264,
~1.4 Mbps, 23.976 fps, dark and soft), asked for a better one ("make
optimal use of my RX 9070 XT"), and over the session added: they believe FSR +
FSRCNNX is the best; they want visible improvement, not lower GPU cost; then
that interpolation should be deleted entirely and only Movie fixed; then that
frametimes must stay well under 20 ms, that they hear coil whine, that the
picture looked "pulled" on zoom-out, and (correctly) that their own test film
might be a bad test source.

### Why "no difference" - two separate causes

1. **Auto applies nothing to a local file** (the 2026-09-16 FastStream-only
   gate). Real-player probe on the film: `glsl-shaders` is `[]` in Auto,
   identical to Off; Movie mode (`set-upscale 3`) applied FSRCNNX +
   SSimSuperRes (32 passes) and Anime applied its 34-pass chain. From the
   default state the upscaler never touches a local file.
2. **The film is a worst case.** Downscale-then-upscale benchmark (12 frames,
   1.33x/1.5x/2x, luma PSNR) put FSRCNNX, ArtCNN, RAVU-Zoom, NNEDI3 and AMD
   FSR all within ~1-2 dB of plain `ewa_lanczossharp`; real-window screenshot
   crops (off vs Movie) looked the same. FSR was measured WORSE than plain
   scaling (luma 42.3 vs 43.6 dB) and cannot stack with FSRCNNX (its
   `WHEN OUTPUT > input` gate is false once FSRCNNX has upscaled - verified
   identical output with/without it).

### The misleading result and the correction

On the soft film, ArtCNN C4F32 came out best at 1.33x/1.5x, so an interim build
used ArtCNN below 2x. That was an artifact of the source. Blender's *Tears of
Steel* (CC-BY; clean 1080p master 1920x800 + its real 720p encode, 16 frames
across the film, true ground truth) gave the opposite ordering - luma
PSNR / SSIM / VMAF vs the master:

| scale | plain | SSimSuperRes only | FSRCNNX+SSSR | ArtCNN C4F32 |
|---|---|---|---|---|
| 1.25x | 42.05 / .9939 / 99.70 | 41.25 / .9939 / 99.94 | (gated off <1.3x) | - |
| 1.33x | 41.13 / .9933 / 99.68 | 40.67 / .9935 / 99.94 | 38.98 / .9924 / 99.79 | 38.73 / .9919 / 99.86 |
| 1.50x | 39.21 / .9906 / 99.61 | 39.41 / .9912 / 99.91 | 38.14 / .9907 / 99.78 | 37.99 / .9904 / 99.85 |
| 1.75x | 35.83 / .9855 / 99.44 | 36.44 / .9869 / 99.79 | 35.99 / .9873 / 99.70 | - |
| 2.00x | 33.87 / .9808 / 99.30 | 34.64 / .9836 / 99.71 | **35.92 / .9863 / 99.70** | 35.68 / .9847 / 99.74 |
| 3.00x | 28.93 / .9558 / 94.37 | 29.38 / .9621 / 97.62 | **30.36 / .9687 / 99.62** | 29.96 / .9655 / 98.71 |
| real 720p encode -> 1080p (1.5x) | 35.74 / .9717 / 99.09 | **37.16** / .9716 / **99.41** | 36.75 / .9725 / 99.23 | 36.84 / .9725 / 99.30 |

Below 2x a 2x CNN then a downscale loses 1-2 dB (it overshoots and the
downscale discards the gain); SSimSuperRes targets the real output size
directly and is best or tied. From 2x up the CNN's fixed 2x lines up and
FSRCNNX wins (+2 dB at 2x). ArtCNN never wins on clean material. This is the
original ">720p = SSimSuperRes only" split from 2026-09-15, re-derived - now on
the real display scale (crossover ~2x) instead of input height. The downscaler
after a 2x CNN matters too: `ewa_lanczossharp` beat mpv's default `hermite` by
+0.9 dB on the real-720p FSRCNNX chain, so the Movie presets set
`dscale=ewa_lanczossharp` while active and hand it back to the startup value
for Anime/Off. (The user's belief that FSRCNNX is better than ArtCNN was
right for >=2x, and the "FSR + FSRCNNX with Vulkan" combination is what the
old chain already was - Vulkan `winvk`, FSRCNNX; FSR itself adds nothing.)

Real-player cost (`vo-passes`, 1080p24 clip): SSimSuperRes ~1-2 ms,
FSRCNNX+SSSR 2-5 ms, ArtCNN C4F32 3.4-8.5 ms (peak 13.9 ms at 1x, ~6.7 ms at
3x - the GPU clocks down between frames at 1x). Pacing on the real ToS files,
real config, 15 s windows: 1080p -> SSimSuperRes only, render peak 2.0 ms @1x /
2.6 ms @3x; 720p -> FSRCNNX+SSSR, 3.2 ms @1x / 1.7 ms @3x; 0 dropped, 0
delayed, 0 mistimed at both speeds. Visible effect on a ToS 1080p frame at
the real 2560x1440 target: a touch crisper edges (fingers, teeth, hair), no
artifacts - modest, as the numbers say.

### AI restoration tried and removed

`2xLiveActionV1_SPAN` (jcj83429/Phhofm, CC-BY, 1.6 MB ONNX) via a VapourSynth
vf on the ORT_DML stack RIFE used was the only candidate with a clearly visible
effect in still crops (block artifacts cleaned). Offline it ran 21 fps at full
size (47 ms/frame), 52 fps with a 0.75x pre-shrink (19 ms) so the 2x output
lands on the display size; fp16 IO and the NCNN_VK backend were ~2x slower
still. Wired in behind the Movie mode with a speed gate (off above 1x). It was
removed after the user's real-viewing report (not visibly sharper, picture
"pulled" on zoom-out, coil whine): a frame-by-frame network has no temporal
consistency, needs a second GPU context (D3D12) beside the Vulkan renderer,
and cannot follow the 2x-16x speed keys. A CPU deblock/denoise vf
(`deblock`, `hqdn3d`, `fftdnoiz`, ~1-5 ms/frame) was also looked at: only a
subtle change, softer - not adopted. `mpv --sharpen` is `vo=gpu` only (this
config is `gpu-next`), so it is not available either.

**Test-harness mistakes worth remembering (both cost a wrong conclusion):**
(a) `remember-speed.lua` restores the last speed (`speed.json` = 3x) on start,
so the first "SPAN drops 200-430 frames" run was actually a 3x run - a probe
must set `speed=1` AFTER startup and restore `speed.json` afterwards; (b)
`autoload.lua` rolls into the next file in the folder when a short clip ends,
polluting drop counters and `src` readings (use a folder with no siblings or a
clip longer than the window). Also: `--glsl-shaders` list separator on Windows
is `;`, not `,`.

### Interpolation removed

The user decided (mid-session) to delete interpolation from mpv. Before that
they had asked to use SVP with RIFE: SVP's RIFE supports TensorRT (NVIDIA only)
or ncnn/Vulkan; on AMD it is ncnn/Vulkan only - the backend this repo measured
as silently corrupting RIFE frames on this GPU (2026-09-13) - so it would not
have improved on the existing ORT_DML path. Removed: `Ctrl+i`, the uosc
"interp" and "fps" toolbar buttons and their `gpu-toggles.lua` code,
`rife.vpy`, `installer/install-rife.ps1`, the interpolation/VapourSynth/amf_frc
comment sections in `mpv.conf`, the Ctrl+i/menu entries in `input.conf`, and
the RIFE sections of `RECREATE.md`/`AGENTS.md`. The old sections of this file
stay as the engineering history. `.venv` and the user PATH entry were left on
the machine (unused).

### Other observations

- The test film disappeared from the mpv folder during the session (the user
  moved or deleted it; it was never touched here - `git status` never tracked
  it, `.gitignore` covers `*.mp4`). Frames/clips for tests were kept in the
  scratch folder; *Tears of Steel* (downloaded from
  `download.blender.org/demo/movies/ToS/`) is the recommended replacement test
  source: `tears_of_steel_1080p.mov.zip` (clean 1080p master) and
  `tears_of_steel_720p.mov` (a real compressed 720p encode of the same film).
- The user reported coil whine during testing. It cannot be measured from
  here; likely contributors were the SPAN filter's bursty second-context load
  and the sustained 3x-speed/looping probe runs, both gone. The shipped
  chains are 1-5 ms of Vulkan work per source frame.

### 2026-09-21 - "Auto" naming on local files

The user decides Anime/Movie themselves for local files, so the state must read
as off. Before, Auto on a local file resolved to no shaders but the toolbar said
`Auto`, the OSD said `Shaders: off`, and Shift+A landed on an invisible extra
step. Now (gpu-toggles.lua): the badge reads `Off` whenever Auto resolves to
nothing, the upscale menu hides its Auto entry and highlights Off for non-
FastStream files, and `cycle_upscale()` skips Auto there (Off -> Anime -> Movie
-> Off). FastStream content is unchanged (verified with a simulated stream: a
local HTTP URL with `#fs-content=movie` - Auto applies the Movie chain, cycle
Off -> Auto -> Anime -> Movie). Verified in real screenshots of the toolbar:
local default `Off`, stream default `Movi`, local after one Shift+A `Anim`.
Test-rig notes: Python's `http.server` has no Range support, so a stream test
needs a fast-start MP4 played from the start; start the server with a captured
PID and stop only that PID (an earlier `taskkill /IM python.exe` was too broad).

### 2026-09-21 - are the shipped Movie chains really the best? (alternatives re-tested on clean material)

RAVU, NNEDI3 and FSR had only been tried on the soft test film, so they were
re-run on the Tears of Steel ground-truth set (same 16 frames; luma
PSNR / SSIM / VMAF; `ewa_lanczossharp` downscaler):

| scale | plain | SSimSuperRes (shipped <2x) | FSRCNNX+SSSR (shipped >=2x) | RAVU-Zoom-AR r3 | FSR EASU+RCAS |
|---|---|---|---|---|---|
| 1.33x | 41.13 / .9933 / 99.68 | 40.67 / .9935 / 99.94 | 38.98 / .9924 / 99.79 | 41.43 / .9940 / 99.76 | 37.54 / .9859 / 100.0 |
| 1.50x | 39.21 / .9906 / 99.61 | 39.41 / .9912 / 99.91 | 38.14 / .9907 / 99.78 | 39.54 / .9914 / 99.71 | 36.26 / .9832 / 99.97 |
| 2.00x | 33.87 / .9808 / 99.30 | 34.64 / .9836 / 99.71 | **35.92 / .9863 / 99.70** | 34.39 / .9826 / 99.46 | 32.82 / .9753 / 99.70 |
| real 720p enc, 1.5x | 35.74 / .9717 / 99.09 | **37.16** / .9716 / **99.41** | 36.75 / .9725 / 99.23 | 36.28 / .9725 / 99.19 | 34.70 / .9639 / 99.56 |

RAVU-Zoom-AR is marginally ahead on PSNR/SSIM at 1.33-1.5x but loses on the
real compressed 720p encode and on VMAF, and is a 5 MB shader: no clear win.
NNEDI3 (128/256) was no better than plain at 1.5x and far worse at 2x (30 dB).
FSR is the sharpest-looking (highest VMAF at 1.33-1.5x - VMAF rewards
sharpening) but the least faithful (-3.6 dB PSNR at 1.33x); 2x-zoom crops of the
real 720p encode show only slightly more edge contrast with a hint of halo, and
plain / SSimSuperRes / RAVU / FSR differ only subtly. Nothing beat the shipped
choice overall; the honest ceiling for real-time spatial upscaling of a
compressed source is low. Caveats: one film (VFX-heavy sci-fi), 16 frames, a
synthetic downscale test plus one real encode at one ratio, and proxy metrics.
A visibly larger step needs offline processing (pre-upscale a movie once with a
heavy model and play the result), which was not built.

### 2026-09-21 - buffering: 1 GiB, and it was only applying to FastStream

Asked whether movie streams get the same buffering as the anime ones (and
whether it lives in RAM or VRAM): RAM - the demuxer cache holds compressed
packets; VRAM would only hold decoded frames/shaders (`swapchain-depth`). Raised
`demuxer-max-bytes` 512 MiB -> 1 GiB (~11 min ahead at 12 Mbps instead of ~6;
63 GB RAM installed). Reading the options back from a running player then showed
the buffering block and `swapchain-depth` did NOT apply to local files or
untagged URLs: the `[faststream-hwdec]` profile header sat mid-file, so every
option below it was part of that profile. Moved the profile to the end of
`mpv.conf` (with a warning comment); re-verified 4 cases (local, untagged
stream, movie tag, anime tag): all cache=yes / 1 GiB / 128 MiB back / wait 3 s /
swapchain 4, hwdec per file as before. Local-file pacing re-checked with the
real config at 1x and 3x: 0 dropped / delayed / mistimed.
### 2026-09-21 - arrow keys "skip 12 seconds": relative seeks were keyframe-snapping

Reported: arrow keys skip ~12 s (want 5), j/k behave oddly (want 10). `input.conf`
already said 5/10 s - a source read was not the problem, so it was measured in the
real player (`test-media/tools/probe_seekkeys.lua`, new):

- Single keypresses on the 45 s fast-start clip (dense keyframes) were CORRECT:
  left -4.6, right +5.7, j -10.1 (incl. playback drift).
- A 40 s clip re-encoded with 10 s keyframe spacing (ffmpeg `-g 9999999`, made
  from tears_of_steel_720p) reproduced it: `right` (+5) landed **+9.3**, `left`
  (-5) landed **-7.2**, `j` (-10) landed **-13.7**. That is the bug: `seek N`
  without flags is a KEYFRAME-snap seek (`--hr-seek=default` only precise-seeks
  absolute seeks), so the real jump overshoots by up to one GOP. Typical movie/
  anime encodes have 4-10 s keyframe intervals - exactly the reported "~12 s".
- Also caught in passing: a 1.2 s HOLD of `left` fires mpv autorepeat and moved
  -31 s (~6 repeats of 5 s). Holding = repeated skipping is by design; the
  complaint was about single presses.

Fix: the SHORT hops (left/right +5/-5, j/k +10/-10) are now EXACT seeks
(`seek N exact`); z/x (60s) deliberately stay keyframe seeks - on a long hop the
snap is proportionally tiny and the seek stays instant, even on network streams.
The cost of exact on this machine (probe: each seek applied and playing again
within ~0.4 s, local file): one forward-decode from the keyframe before the
target. `uosc.conf`'s `timeline_step` (wheel-over-timeline seek) got the same
treatment: `5` -> `5!` (uosc's exact suffix), measured +4.3 overshoot on a +5
wheel step (mechanism inferred from the same keyframe-snap behavior, not separately probed - uosc issues plain seek commands). Verified: same probe re-run on BOTH clips, all four keys land on
target (+5.3 / -4.6 / -9.6 / +10.1 incl. drift); `input-bindings` dump shows the
exact-flag bindings active, no duplicate/conflicting bindings. mpv.conf's
buffering comment (2026-09-16 section, "(c)") no longer claims all skip keys are
keyframe-snap.

## 2026-09-25 - Movie: sharpening, chroma, and a benchmark on real encodes

Reported: the Movie shaders still give no visible difference; the user watches
mostly low-quality 720p (sometimes lower, rarely 1440p/4K) on the 2560x1440
display and wants it visibly sharper. Diagnosis: every Movie chain so far was
chosen for fidelity to a clean master, where the achievable gain is a few
tenths of a dB - correct, and invisible. Colour had never been measured at all.

Built on branches while the user was watching (static checks only), then
measured once mpv was free:

- `movie/sharpen` - adaptive-sharpen on OUTPUT, runtime strength PARAM.
- `movie/chroma` - CfL_Prediction (chroma from luma) in both Movie chains.
- `movie/nlmeans` - nlmeans_sharpen_denoise at source size. REJECTED.
- `movie/combined` - sharpen + chroma, plus the Auto strength rule. The
  candidate.

At the user's go-ahead `movie/combined` was merged into main (`0381f03`)
and all four branches were deleted; the nlmeans shader never reached main.

Benchmark (`test-media/tools/bench_branches.py`; 16 frames = 4 frames from each
of 4 contiguous 20 s segments; libplacebo filter rendering float RGB, harness
does the BT.709 4:2:0 conversion; truth = the clean 1920x800 master). Edge
sharpness is the mean Sobel gradient relative to the master (1.00 = as crisp):

| case | chain | PSNR-Y | U / V | VMAF | VMAF-NEG | sharpness |
|---|---|---|---|---|---|---|
| D 1440x600 x264 1400k, 1.33x | current | 40.62 | 47.55 / 47.11 | 97.96 | 97.16 | 0.975 |
| | sharpen 0.5 | 38.09 | 47.41 / 47.05 | 98.44 | 96.79 | 1.123 |
| | sharpen 1.0 | 36.30 | 47.29 / 47.00 | 98.42 | 95.58 | 1.234 |
| | chroma (CfL) | 40.62 | 47.62 / 47.28 | 97.96 | 97.16 | 0.975 |
| | nlmeans | 37.82 | 46.51 / 45.98 | 98.48 | 95.92 | 0.985 |
| A Blender 720p, 1.5x | current | 41.51 | 48.37 / 47.86 | 99.50 | 99.19 | 0.984 |
| | sharpen 0.5 | 39.55 | 48.26 / 47.83 | 99.72 | 99.11 | 1.130 |
| B 960x400 x264 800k, 2x | current | 39.20 | 46.31 / 45.54 | 95.67 | 94.93 | 0.898 |
| | sharpen 0.5 | 37.71 | 46.15 / 45.50 | 96.53 | 94.90 | 1.006 |
| | sharpen 1.0 | 36.38 | 46.09 / 45.48 | 96.68 | 93.86 | 1.086 |
| | chroma (CfL) | 39.20 | 46.49 / 45.84 | 95.67 | 94.93 | 0.898 |
| | nlmeans | 35.75 | 44.81 / 44.20 | 96.93 | 91.37 | 0.951 |
| C 640x266 x264 400k, 3x | current | 36.62 | 44.33 / 43.37 | 89.91 | 87.77 | 0.832 |
| | sharpen 1.0 | 34.80 | 44.21 / 43.34 | 91.51 | 86.65 | 0.955 |
| | sharpen 1.5 | 34.10 | 44.17 / 43.33 | 91.39 | 85.48 | 1.002 |
| | chroma (CfL) | 36.62 | 44.60 / 43.74 | 89.91 | 87.78 | 0.832 |
| | nlmeans | 32.76 | 42.83 / 42.21 | 91.69 | 77.89 | 0.920 |

Reading: sharpening raises VMAF but not VMAF-NEG or PSNR - it is perceived
sharpness (edge contrast), not recovered detail, which is exactly what was
asked for. The right strength depends on the scale: one fixed level either
overshoots at 1.33x or undershoots at 3x, hence Auto = scale - 1 clamped to
0.5..1.5 (1.12 / 1.13 / 1.09 / 1.00 at 1.33 / 1.5 / 2 / 3x). 2x-zoom crops
agree: at 2x the current chain is visibly softer than the master and 0.5-1.0
brings it to about master crispness with no obvious halos; nlmeans is waxy on
every case. CfL is small but consistent on real encodes at 2-3x.

Harness mistakes caught on the way (both would have produced a wrong
conclusion): (1) the libplacebo filter writing yuv420p ran the OUTPUT hook so
that chroma changed (-2.3 dB U/V for a luma-only sharpener); rendering to
gbrpf32le showed mean |dCb| 0.00002, so the harness renders RGB and converts
itself (roundtrip of the master: 68 dB Y / 58 dB UV). (2) The first low-bitrate
cases encoded the 16 unrelated frames as one clip - all intra frames on a tiny
budget, macroblock mush; sharpening made the blocks MORE visible while VMAF
still rose. Contiguous x264 segments fixed it; look at the crops, not VMAF.
Also: `lua-language-server --check <file>` reported "no problems" without
checking anything (an injected undefined global went unreported) - directory
mode (`test-media/tools/lls_check.sh`) works.

Real player (`test-media/tools/probe_branch.lua`, fullscreen 2560x1440, isolated
copies of the ToS files, `speed.json` restored after each run): 720p -> FSRCNNX
+ SSimSuperRes + CfL + adaptive-sharpen, 1080p -> SSimSuperRes + CfL +
adaptive-sharpen; Auto applied 1.000 and 0.500 respectively; the level menu
changes the paused frame's sharpness live (glsl-shader-opts, no reload); 0
dropped / delayed / mistimed at 1x and 3x on both, worst render 3.4 ms.

## 2026-09-26 - clicks that did nothing, regression suite, warm shaders, faster switching

**"Clicking the video sometimes does nothing unless I click without moving."**
Root cause in mpv itself (input/input.c at the installed commit 2a4eb8067):
MBTN_LEFT bindings fire on release; on press, with `window-dragging=yes`
(default) mpv arms a drag, and if the pointer moves `--input-dragging-deadzone`
(3 px) before release it calls `release_down_cmd(ictx, true)` - dropping the
click - and queues `begin-vo-dragging`. In fullscreen, w32_common.c's
`begin_dragging()` returns on `current_fs`, so the click was lost for a drag
that never happened. 3 px on a 2560x1440 display with a 1:1 pointer (Razer
Basilisk V3, pointer speed 10, no acceleration) is a fraction of a millimetre.
uosc was ruled out: over bare video it registers no click zone (binding level
0), so mpv's own binding handles the click. Reproduced headless with mpv's own
`mouse`/`keydown`/`keyup`: 0/2 px toggled, 3/6/15 px were lost; with
`window-dragging=no` all toggled. The user moves windows with PowerToys
GrabAndMove (Alt+drag) and asked for no drag-moving at all - `window-dragging=no`.

**Regression suite** (`tests/`, see its README): static + 12 headless tests +
gpu tier; isolation by running a copy of mpv.exe in its own portable folder
(a hardlink to the Program Files exe is refused - access denied - so it is
copied; `--config-dir` alone was not used because portable paths still point at
the exe's folder). First run: 182/199 - all failures were the tests'
own mistakes (built-in `commands`/`select` scripts, a regex splitting
`mp.get_script_name()`, PowerShell's case-insensitive `-match` treating `q` as
`Q`, and a stream-resume expectation that ignored the one-entry-per-page-URL
design) plus gpu-toggles settling slowly under `--vo=null` (below). Each test
then had to fail on a deliberate break (8 mutations, all caught).

**Shader cache.** Cold vs warm first frame at 720p: Anime 491/182 ms, Movie
(FSRCNNX) 404/216 ms. `shaderc compile status` appears once per GLSL->SPIR-V
compile and never on a cache hit - the counter the warm-up uses. The cache keys
on the passes, not the size (colour constants are specialization constants:
0.0440, 1.0663, ... in the log). With a warm cache all 84 pipelines of a run
took ~11 ms together (max 0.3 ms). The real cache lacked 17 entries (Anime on
the vulkan path at 720p/1080p, 480p 10-bit, 4K Movie). Two runs from identical
cache copies first disagreed; the difference was the old slow switching
(below) rendering half-applied states long enough to compile them - after the
fix the runs agree.

**Switching latency.** Each `display-width`/`display-height` read is a
video-thread round trip, and gpu-toggles made ~20 `display_scale()` calls per
switch (under `--vo=null` ~40 ms each, one frame of the null VO; in the real
renderer a few ms). Lazy once-per-action read: Movie 148 -> 75 ms median,
sharpness Auto 201 -> 117 ms, worst cases 360 -> 146 ms. First use of the Movie
chain in a process still costs 0-4 late frames (file read + parse ~45 ms on the
render thread, then texture allocation) in BOTH versions; rounds 2-4 were clean
in every run. Measurement trap: polling `vo-passes` every 10 ms caused late
frames by itself.

**Also found:** `mpv-build.json` said 20260924 while the committed binary is
the 20260925 daily (same mpv commit) - refreshed, and now a static test.

## 2026-09-26 (later) - the shader cache checks itself at every start

Asked: run the warm-up and the gpu tier after the user's update to 20260926,
"or even better, when I start mpv always check are the shaders compiled, if not
do it like games would" (new GPU driver, shader cache deleted), and: does mpv
keep its shaders in its own folder or in the GPU driver's?

**20260926.** All 13 files hash-identical to the release; `mpv-build.json`
refreshed (the static test caught the drift). libplacebo is unchanged
(v7.372.0): the warm-up compiled nothing (0 of 80 steps) and the full suite
passed (251).

**Where shaders live.** mpv's `portable_config/cache` holds SPIR-V objects (217)
and Vulkan pipeline-cache blobs (175) - the AMD driver's finished binaries,
6-83 KB each, header vendor 0x1002. Two devices: 0x7550 (RX 9070 XT) and 0x164e
(the Ryzen iGPU; 47 files, all from one run on 2026-09-22). The driver's
own cache is `%LOCALAPPDATA%/AMD/VkCache` (~27 MB). A copy of mpv's cache with
every blob removed still created all 75 pipelines of a run in 11.7 ms in total,
the same as intact: AMD's cache answered. Either layer is enough, so resetting
the AMD cache alone costs mpv nothing; a new driver invalidates both.
`mp_save_to_file` writes a temp file and renames it (a killed warm-up cannot
corrupt the cache); mpv's cleanup deletes only `shader_<16 hex>` files unused
for 24 h once the folder is over 128 MiB.

**Design.** `Scripts/shader-cache/main.lua` builds a fingerprint (libplacebo
version, `DriverVersion` of every display adapter via `reg query` in ~25 ms,
the shader files and gpu-toggles.lua, the cache file count) and compares it
with a stamp that only a completed warm-up writes. The first file's load waits
in an `on_load` hook. Measured on warm starts: 70 ms median start-to-playback
with the check, 71 ms without. When stale, `warmup.lua` runs in a second mpv
(fullscreen, on top, an opaque progress screen) and the file plays after it.
It is a second process because running test clips inside the player would mean
swapping its playlist, which races FastStream's IPC and autoload. When only
shaders/gpu-toggles changed, a quick check runs 3 representative clips and
goes full only if they compiled something.

Rejected: blocking forever (Esc skips, and a 270 s timeout); retrying a failed
warm-up at every start (`shader-warmup.failed`, per fingerprint); keying on the
mpv version (daily updates would each cost ~45 s for nothing - libplacebo
decides); `force-window=yes` to give the player a window first (it does nothing
during a load; mpv waits to know whether the file has video).

**Measured.** A cold cache on the real renderer: 99 compiles over 80 steps,
48.6 s, then the video (FastStream anime 720p) started. That run happened on a
locked screen, which confirms the manual: mpv on Windows renders whether or not
its window is visible.

**Tests.** A 6-phase headless test (cold, fresh, Esc skip, quick, timeout,
not retried). A gpu test does a real cold warm-up and then checks that a fresh
second start compiles nothing. Static checks keep the warm-up out of the
auto-loaded scripts. The other runtime tests run with the check off.

## 2026-09-26 (last) - the warm-up moves to the background; a capture of real-use misses

Asked, in order: "compiling is very slow ... my CPU sits at ~20 % ... could we
move it to the background"; "check which CPU I have and optimise ... 2 seconds
or less"; "no blocking screen, just a small bar top right which shows percent
and what is compiling"; remove the "By hand" text and the big screen ("when I
hit pause the compiling pauses - that should not happen"); triggers only for
logical events such as a new driver or an mpv update; and "make sure you got
all shaders - if not sure, let a capturing log run and I will use mpv for a
week".

**Why it was slow.** Ryzen 5 7600X (6c/12t). libplacebo's own log of a cold run:
GLSL->SPIR-V 1.2 s, pipelines 0.1 s - ~1.3 s of real work in a 44.7 s run. The
rest was fixed sleeps (0.4-0.6 s per step, 80 steps). Now each clip sits
paused; a step waits until gpu-toggles reports the switch done (a counter its
`entry()` wrapper bumps: `user-data/gpu-toggles/applied`) and then frame-steps
3 frames, each confirmed by `time-pos` moving. The VO reads option changes at
the start of a draw, so the third frame queued after the change proves the new
chain was drawn - a cold step takes exactly as long as its compile. That gave
19.6 s; the rest was frame-step itself waiting out each clip's 24 fps slot
(92 ms per step) - `--untimed` makes it 5 ms median. **A cold warm-up is now
5-6 s (80 steps, ~74 compiles, ~1 s of it compiling).** A timed check against
the cache the untimed warm-up built: 0 compiles over 80 steps (it is not
missing anything real timing needs). A step whose frames never come (a window
that does not draw) now FAILS the check and writes no stamp - the first version
"passed" a minimized run with 0 compiles.

**Background, invisible.** Tried in order (full numbers in host.ps1's header):
`--window-minimized` - no focus taken, but nothing drawn, 0 compiles; a normal
second window - takes the keyboard focus from the video; a hidden window
off-screen - draws, but mpv cannot read the monitor there and picks another
output format (17 of ~120 shaders differed from fullscreen); a hidden window ON
the monitor - matches fullscreen. So `host.ps1` (Windows PowerShell 5.1,
DPI-aware) creates a borderless WinForms window over the player's monitor,
never shows it, and runs the warm-up mpv embedded in it (`--wid`). mpv kills
the host when the player quits (the subprocess is `killed_by_us` on exit), and
the host puts mpv in a kill-on-close job object, so nothing outlives the player
- a `--vo=null` warm-up has no window whose loss would end it (the mutation
without the job left one behind). Measured in the real player (720p FastStream
anime, fullscreen): 0 dropped/delayed/mistimed frames while the warm-up ran,
focus never left the player, and with the player paused at step 8 the warm-up
went on to 80 (it is a separate process; the "pause stops it" the user saw was
the old full-screen manual run, whose window had the focus and took Space).

**The bar.** Top right, below uosc's bar: "Compiling shaders 51%", then what is
being drawn ("Anime · 3840x2160 8-bit · local file"), a 2 px progress line; then
"Shaders ready" (or "Shaders up to date" after a quick check) for 2.5 s. Read
from `shader-warmup.progress` every 0.25 s. Verified by screenshots, also while
paused. The full-screen "Preparing video shaders" screen, its reason line
("started by hand") and Esc/q skip are gone; `installer\warm-shader-cache.ps1`
runs the same hidden warm-up with its progress in the terminal.

**Triggers.** The fingerprint now also holds `mpv-version`, as a QUICK check
(3 clips, ~1 s, full matrix only if they compiled something). This reverses the
earlier rejection ("daily updates would each cost ~45 s for nothing"): it now
costs about a second in the background, and mpv's own render settings could
change a pass without a libplacebo change. A daily build of the same mpv
commit has the same version string and triggers nothing. Full warm-up: no
stamp, fewer cache files, new libplacebo, new display driver, new
`WARMUP_VERSION`. Nothing else.

**Capture.** mpv writes each compiled shader/pipeline to its own file the
moment it is made (a hidden real-GPU run on an empty cache: 85 files at the
first frame, 165 after switching to Movie, 169 after Off). So the player lists
the cache folder (~1 ms, script thread) 1 s after anything that can need new
shaders changes, and every minute, and appends new files with what was on
screen to `portable_config/shader-misses.log`. That run logged +85 Anime, +80
Movie (FSRCNNX+SSimSuperRes), +4 no upscaler - one line per switch (with 3 s
the Movie switch merged into the start's line). Not libplacebo's debug log:
100k lines in one warm-up log, ~2,000-3,000 per chain switch, formatted on the
render thread.

**Tests.** Headless shader-cache, still 6 phases: the video plays BEFORE the
warm-up ends (the old blocking design as a mutation fails it), progress reaches
8/8, the Esc-skip phase became quit-mid-warm-up (the runner then checks no
host.ps1 or warm-up mpv is left - the no-job-object mutation fails it), the
capture logs a faked new object with its context and ignores one written during
a warm-up, mpv+shaders changed is still quick. gpu-auto-warm: cold warm-up in
the background, paused halfway, must finish, 0 dropped/delayed frames while it
played.

**Found by the gpu tier: stepped frames are not enough.** gpu-auto-warm's second
start (Anime at start, then Movie, Off) compiled 2 shaders after the
background warm-up; a hidden reproduction on a fresh cache, 4. Diffing each
compiled shader against its closest match in the warm-up's log: the same passes
(an overlay pass: sample, colour map, encode; the main pass: read, polar
scaler, colour map, dither), but the player's had ~10 more specialization
constants and an extra empty encode block. mpv options were identical in both
processes, so it is playing vs stepping. Each step now also PLAYS 3 frames
after its 3 stepped ones (`play_frames`), with the clips on `loop-file=inf` -
an untimed `--vo=null` play otherwise ran a whole clip to its end between two
checks and every later step stalled. Cold warm-up: 124 compiles, 7.7 s; the
next real start compiled 0, twice. `WARMUP_VERSION` 2, so every cache warmed
the old way re-warms once, in the background.

**Found by accident: another agent's tests kill mpv.** Twice an mpv of this
suite died mid-run with no log flush and exit 1 (a warm-up with a log file, and
the quit phase's player). The FastStream fork's e2e specs were running in
another session: their `after()` hooks `taskkill /F` every mpv.exe that started
during the spec. Such an outside kill made the warm-up "failed" - never retried
for that fingerprint. Now any exit that is not one of warmup.lua's own failure
codes is "interrupted": retried at the next start, the third in a row for a
fingerprint counts as failed. New headless phase (5/7) with a stand-in warm-up
that exits 1 at once.

**Same day, after the user's live test: an empty mpv, and "Rebuild shaders".**
The user cleared both caches (backups kept), opened mpv with no file and saw no
bar - by design then: the warm-up waited for a video to start. Asked for:
check and compile even when nothing is loaded, and a menu entry that deletes
the old shaders and compiles again - "but not the AMD ones". Now an idle mpv
(no file, `idle-active`) warms 2 s after the check (`idle_delay`); a file
opened in that time warms after its own start instead. "Rebuild shaders" is in
Video > Shaders (input.conf) and at the end of the upscale button's menu; it
deletes only mpv's `shader_<16 hex>` files plus the stamp/failed/interrupted
files and starts a full warm-up at once, also after a failure. Real GPU,
hidden: an empty mpv on an empty cache warmed by itself (11.2 s, 252 files),
the rebuild deleted 252 files and rebuilt them in 8.2 s; a small visible,
always-on-top, unfocused window showed "Compiling shaders 30%" over mpv's
"drop files here" screen. Found on the way: a player killed outright mid
warm-up (Task Manager) left its lock behind - its warm-up still finished and
wrote the stamp, but "Rebuild shaders" would have said "compiling in another
mpv window" for ~5 min; host.ps1 now removes the control files when the
player's window no longer exists. New headless phases 8 (rebuild) and 9 (idle);
the runner starts a phase without a File idle. Also: VS Code showed 63
PSScriptAnalyzer findings on run-tests.ps1 that CI does not - it used its
default rules; `.vscode/settings.json` now points it at
PSScriptAnalyzerSettings.psd1.
