# ChatGPTBridge

**English (default) · [简体中文](./README.zh-CN.md)**

**Repository:** [OwlLinker/ChatGPTBridge](https://github.com/OwlLinker/ChatGPTBridge)

## The pain points of coding with ChatGPT Web

When you use Chat to code in a local project, the conversation and the files on your computer are separate. This creates several problems:

- Chat cannot automatically see the latest state of your project.
- You have to copy files into Chat and copy generated code back by hand.
- You may use an old version or miss part of a change.
- A long answer may be difficult to apply safely, may be applied twice, or may leave syntax errors behind.
- You want to keep using the Chat service, but do not want to build an API integration or switch to another coding tool.

## The solution

> The simplest way to use Chat for coding with your own projects.

ChatGPTBridge connects your Chat conversation with a local Git project. You describe a change in Chat, provide a current project snapshot, and apply one complete answer to the project with local safety checks.

Chat remains the place where you ask questions, discuss designs, and generate code. ChatGPTBridge only connects that conversation with your project files. It does not require an API, a separate coding agent, or another coding subscription.

The Bridge itself does not impose request, token, or Patch quotas. You can use Chat for coding as much as your Chat account and plan allow. Chat service limits still apply.

ChatGPTBridge gives you this repeatable loop:

~~~text
Ask Chat for a change
        ↓
Create a current project snapshot
        ↓
Give the snapshot to Chat
        ↓
Chat returns one complete Patch
        ↓
Check and apply the Patch locally
        ↓
Review and test the result
~~~

## Quick start

### Beginner setup: install and make your first change

ChatGPTBridge installs its tools into an existing Git project. It does not create a project or send anything to Chat during installation. Run these steps in Terminal; replace the sample project path with the real folder on your Mac.

1. **Check the requirements.** You need macOS, Git, and a project that is already a Git repository. Check with:

   ~~~bash
   git --version
   git -C "$HOME/Projects/MyProject" status
   ~~~

   If the second command says the folder is not a Git repository, stop and choose the correct project folder. Do not run `git init` unless you intend to create a new repository. Apple’s command-line tools are needed for the native monitor and some Swift helpers; install them if needed with `xcode-select --install`.

2. **Download ChatGPTBridge once.** Choose a location for the tool itself; this example uses a folder in your home directory:

   ~~~bash
   git clone https://github.com/OwlLinker/ChatGPTBridge.git "$HOME/ChatGPTBridge"
   ~~~

3. **Install it into your project.** The target project must already exist and be a Git repository:

   ~~~bash
   "$HOME/ChatGPTBridge/tools/chat-bridge-install.sh" "$HOME/Projects/MyProject"
   cd "$HOME/Projects/MyProject"
   ~~~

   Use the same Bridge download to install separately into each project. If the installer says a Bridge file already exists, do not overwrite it blindly: use `--force` only when you intend to update that project's ChatGPTBridge files. Installation does not commit or push changes.

4. **Add project-specific exclusions.** Common secret files are excluded automatically, but this is not a secret scanner. Add private or irrelevant paths before creating a snapshot:

   ~~~bash
   mkdir -p .chatgpt
   touch .chatgpt/ignore
   open -e .chatgpt/ignore
   ~~~

   Put one ignore pattern per line, save the file, then generate and inspect the snapshot:

   ~~~bash
   ./tools/chat-context.sh full
   open -e .chatgpt/project-context.md
   ~~~

   Check that the snapshot contains only material you are comfortable sharing. When satisfied, copy it:

   ~~~bash
   pbcopy < .chatgpt/project-context.md
   ~~~

5. **Give the snapshot to Chat.** Open a normal Chat conversation (not Work), press **Command+V**, and send the snapshot. Then describe the change you want. For example: “Use the project snapshot I provided as the source of truth. Make this change: … Return one complete unified Diff in a single code block. Do not omit unchanged context or provide a partial Patch.” For a large project, Chat may ask you to provide a smaller relevant snapshot or use the incremental `diff` workflow below.

6. **Apply the returned change.** Copy the complete Diff code block from Chat, return to Terminal in the same project directory, and run:

   ~~~bash
   ./tools/chat-apply-shell.sh
   ~~~

   The tool reads the Patch from the clipboard, checks that it matches the current project, and applies it only if its safety checks pass. If it fails, read `.chatgpt/patch-error.txt`; do not repeatedly apply the same failed Patch. After success, review `git diff`, run the project's tests, and decide yourself whether to commit. ChatGPTBridge never commits or pushes for you.

For subsequent work, create a fresh `full` snapshot when starting from the current project state. `./tools/chat-context.sh diff` creates a separate snapshot of changes relative to Git `HEAD`; review `.chatgpt/project-diff.md` before sharing it, and use it only when Chat already has the matching earlier project context and that snapshot represents the same `HEAD` baseline. If your earlier full snapshot included uncommitted changes, create a fresh full snapshot instead of assuming the incremental Diff is a safe replacement. To automate monitoring and application, follow [the no-Hammerspoon setup](#automatically-apply-completed-diffs-without-hammerspoon); Hammerspoon is optional.

### Automatically apply completed Diffs without Hammerspoon

This option is built into ChatGPTBridge; Hammerspoon is not needed.

1. Install ChatGPTBridge in the target project.
2. In Terminal, enter the project and start the monitor:

   ~~~bash
   cd "/path/to/your-project"
   ./tools/chat-monitor.sh start
   ./tools/chat-monitor.sh status
   ~~~

   The launcher compiles the helper to `.chatgpt/chat-monitor` and sets its executable permission (`755`). On first start it requests Accessibility access for `chat-monitor`; allow that helper in System Settings, then run `start` again. Terminal or iTerm needs no Accessibility permission for this native monitor, and granting either one does not authorize the helper. It does not start at login.
3. In the supported Codex macOS app or a supported ChatGPT browser tab, open a normal Chat conversation (not Work, a Codex workspace, settings, or a blank New chat). Send a request asking Chat for a complete Diff and wait for the response to finish. ChatGPTBridge then reads the final Diff and runs the local Patch checks and apply flow.
4. Stop it when you are done:

   ~~~bash
   ./tools/chat-monitor.sh stop
   ~~~

The monitor does not send your normal prompts, and it does not commit or push. It will not apply a Diff that was already present when monitoring started or when you opened an old conversation. For an existing Diff, copy it and run `./tools/chat-apply-shell.sh` manually. More details are in [the no-Hammerspoon guide](#optional-automatically-monitor-and-apply-completed-diffs-without-hammerspoon).

### Status ring colors

- **Gold, pulsing:** monitoring is active, or a new request has been submitted. This is the waiting state; it does not mean the Patch succeeded.
- **Green, steady:** the Patch was applied successfully. Hammerspoon also treats a previously applied duplicate as success.
- **Red, steady:** Patch application failed. Check `.chatgpt/patch-error.txt` and `.chatgpt/failed.patch`.

The ring is an outline around the Chat send button. It is shown only when the monitored Chat window is in front; monitoring can continue while the app is in the background. A new request returns the ring to gold. There is no separate yellow duplicate state in the current implementation: the native monitor skips duplicates and keeps its current color; Hammerspoon shows an already-applied duplicate as green. An empty ring area can mean monitoring is off, or the window is not eligible or currently in front.

## What it provides

- Use Chat for coding without an API integration.
- Give Chat the current project state in one snapshot.
- Exclude private or unnecessary files with built-in rules and .chatgpt/ignore.
- Apply one complete Chat-generated Patch.
- Reject a Patch based on an older project version.
- Detect duplicate application.
- Roll back when validation fails.
- Undo the latest successful Bridge change.
- Read the latest Diff from the macOS app, Safari, Chrome, and supported Chromium browsers.

## Security and account safety

### Short answer

ChatGPTBridge cannot promise zero risk of an account warning or restriction. Your use of Chat is still governed by the current [OpenAI Terms of Use](https://openai.com/policies/terms-of-use/) and [Usage Policies](https://openai.com/policies/usage-policies/).

ChatGPTBridge is an unofficial third-party local tool and is not affiliated with or endorsed by OpenAI.

The important distinction is:

- ChatGPTBridge does not use an API key, a private Chat endpoint, a reverse proxy, or a method for bypassing Chat limits.
- The manual copy-and-apply workflow has the least automation and therefore the least policy uncertainty.
- Automatic Diff reading from the app or browser, and the Hammerspoon shortcut, programmatically read interface output. They are convenience features, but they add policy uncertainty because current OpenAI terms address automatic or programmatic extraction.
- ChatGPTBridge does not provide unlimited Chat quota and cannot guarantee that an account will never be restricted.

### Will using ChatGPTBridge get my account banned?

There is no honest yes-or-no guarantee. ChatGPTBridge is designed to keep the user in control of the normal Chat interface; it is not designed to bypass limits or hide activity. However, automatic UI reading is still third-party automation, and OpenAI decides how its current terms and safeguards apply. Treat the automatic reader and Hammerspoon path as optional conveniences, not as an officially approved integration.

### What ChatGPTBridge does and does not do

ChatGPTBridge runs locally and connects to the Chat interface you already use. It does not:

- ask for or store your Chat password, session cookie, API key, or private token;
- send prompts or requests to Chat by itself by default; the optional Hammerspoon failure-report feature can do so only when explicitly enabled;
- rotate accounts, evade CAPTCHAs, bypass rate limits, or hide usage;
- automatically commit or push to Git.

It can read the project snapshot or Diff that you choose to provide, read the macOS Accessibility interface when you enable automatic reading, and apply a Patch to the local Git project. The content you paste or send to Chat is still subject to Chat’s normal data handling and account rules.

### Safer use for beginners

1. Use your own account and only projects you are allowed to share with Chat.
2. Inspect `.chatgpt/project-context.md` before sending it. Keep passwords, private keys, tokens, environment files, and customer data out of the snapshot.
3. Start with the manual copy-and-apply workflow. Enable automatic reading or Hammerspoon only when you understand the extra automation involved.
4. Trigger one request at a time. Do not run unattended loops, scheduled batches, parallel accounts, or anything intended to avoid a service limit.
5. If Chat shows a warning, CAPTCHA, unusual login challenge, or account restriction, stop the automation and follow the instructions from the service. Do not try to work around it with another account or a different automation method.

If account safety is your highest priority, use the manual workflow and review every snapshot and Patch yourself. This reduces the local automation layer, but it is not a promise that OpenAI will approve or guarantee any third-party tool.

## Step 1: Check your computer

ChatGPTBridge is for macOS Git projects.

Required:

- macOS;
- a Git project;
- Terminal or iTerm;
- Git, zsh, Bash, and Python 3.

Optional validation dependencies, depending on the files you change:

- Node.js for JavaScript validation;
- HTML Tidy for HTML validation.

Check them:

~~~bash
git --version
zsh --version
python3 --version
~~~

Automatic reading from an app or browser additionally needs swiftc and Accessibility permission. If swiftc is missing:

~~~bash
xcode-select --install
~~~

If your system does not provide an HTML Tidy executable at a standard path, install Tidy and set its path when applying a Patch:

~~~bash
CHAT_BRIDGE_TIDY_BIN=/path/to/tidy ./tools/chat-apply-shell.sh
~~~

JavaScript validation can similarly use a specific Node.js executable with `CHAT_BRIDGE_NODE_BIN`.

## Step 2: Open the project

Replace the example path with the project you want ChatGPT to help modify:

~~~bash
cd /path/to/your-project
git status
~~~

If this is not the correct Git project, stop and change directory. Do not run git init unless you intentionally want a new repository.

## Step 3: Install ChatGPTBridge

Download or clone this repository, then replace `/path/to/ChatGPTBridge` below with the folder where you saved it.

Replace both example paths. For a first installation, omit `--force`:

~~~bash
/path/to/ChatGPTBridge/tools/chat-bridge-install.sh \
  /path/to/your-project
~~~

The installer copies the tools into the project and makes the Shell scripts executable. It checks for existing files before writing and does not commit or push anything. To update an existing installation, run:

~~~bash
/path/to/ChatGPTBridge/tools/chat-bridge-install.sh --force /path/to/your-project
~~~

This replaces the installed Bridge scripts and guide with the versions from this repository.

### Use more than one project

Install ChatGPTBridge separately in every Git project you want to use. Generate a snapshot from each project with its own `tools/chat-context.sh`; this registers the Git root for Hammerspoon routing. When Hammerspoon runs a Patch file, ChatGPTBridge first checks which registered project accepts that exact Patch. If it does not apply cleanly, it uses the Patch file paths to select a unique owning project. If the paths are missing, unreadable, or ambiguous, it refuses to apply the Patch instead of guessing from a stale “last active project” pointer.

For the regular Terminal workflow, change to the intended project directory and run that project's `./tools/chat-apply-shell.sh`. Hammerspoon multi-project routing applies to calls that provide a Patch file with `--patch-file`.

## Step 4: Add private-file exclusions

ChatGPTBridge excludes many common secret paths such as `.env`, private keys, credentials, cloud credential directories, `.git`, dependencies, build output, and caches. This is path-based protection, not a secret scanner; inspect every snapshot and add project-specific rules before sending it.

To add rules for this project:

~~~bash
cd /path/to/your-project
mkdir -p .chatgpt
touch .chatgpt/ignore
open -e .chatgpt/ignore
~~~

Add one pattern per line:

~~~gitignore
fixtures/
*.sqlite
local-notes.md
reports/
*.log
~~~

Save and close the editor. This affects only snapshots sent to ChatGPT. It does not block a Patch from changing a file.

For a one-time ignore file:

~~~bash
CHAT_BRIDGE_IGNORE_FILE=/path/to/project.ignore \
  ./tools/chat-context.sh full
~~~

## Step 5: Create and inspect the snapshot

From the project root:

~~~bash
./tools/chat-context.sh full
~~~

This creates:

~~~text
.chatgpt/project-context.md
~~~

The snapshot includes recognized implementation files (including Objective-C/C/C++ sources) before supporting documents. Implementation files are included in full; the default 512 KB per-file and approximately 12 MB total limits apply to supporting material. Built-in exclusions, symlink protection, and `.chatgpt/ignore` still apply.

Inspect it before sharing:

~~~bash
open -e .chatgpt/project-context.md
~~~

Check that ChatGPT has the files it needs and that no private content is present.

## Step 6: Give the snapshot to ChatGPT

Select and copy the snapshot, or use:

~~~bash
pbcopy < .chatgpt/project-context.md
~~~

Paste it into your ChatGPT conversation and send:

~~~text
This is the current project snapshot. Treat it as the source of truth.
Please make the requested change.
When finished, output exactly one complete unified diff in one code block.
Use project-root-relative paths.
Do not omit code with "..." and do not add explanations inside the diff.
~~~

Ask for one complete Patch. It should contain headers like:

~~~diff
diff --git a/path/to/file b/path/to/file
--- a/path/to/file
+++ b/path/to/file
~~~

Do not apply a partial answer or a Patch generated from an older snapshot.

## Step 7: Apply the Patch

For the first use, copy the complete Diff from ChatGPT and run:

~~~bash
cd /path/to/your-project
./tools/chat-apply-shell.sh
~~~

Or save the complete Patch as a file and run:

~~~bash
./tools/chat-apply-shell.sh --patch-file /path/to/change.patch
~~~

ChatGPTBridge checks the Patch, applies it, validates common changed files, detects duplicates, and creates diagnostics when something fails.

Review the result:

~~~bash
git diff --check
git status --short
git diff
~~~

Then run the tests or start command documented by your project. A valid Patch can still implement the wrong behavior.

## Optional: Read the latest Diff automatically

Make sure the ChatGPT conversation is open in the native app, Safari, or a supported Chromium browser. The first run requests Accessibility access for the compiled `chat-read-last-diff` helper; enable that process in System Settings when prompted.

~~~text
System Settings → Privacy & Security → Accessibility
~~~

Run:

~~~bash
./tools/chat-read-last-diff.sh
~~~

Choose a source when needed:

~~~bash
CHATGPT_SOURCE=native ./tools/chat-read-last-diff.sh
CHATGPT_SOURCE=chrome ./tools/chat-read-last-diff.sh
CHATGPT_SOURCE=safari ./tools/chat-read-last-diff.sh
CHATGPT_SOURCE=auto ./tools/chat-read-last-diff.sh
~~~

Supported sources are the ChatGPT/Codex macOS app, Safari, Chrome (including Beta/Canary/Dev), Chromium, Edge, Brave, Vivaldi, and Arc. A specific Bundle ID can be selected with `CHATGPT_BUNDLE_ID`.

If automatic reading cannot find the Diff, use the copy-and-apply method.

## Optional: Automatically monitor and apply completed Diffs without Hammerspoon

ChatGPTBridge includes a native macOS monitor. It watches an ordinary Chat conversation in the Codex macOS app (`com.openai.codex`), Safari, or a supported Chromium browser, then runs the existing local Patch checks when the Send button changes from generating back to ready. It does not send normal prompts, commit, or push Git changes.

### First-time setup

1. Install ChatGPTBridge in the Git project where you want changes applied.
2. In Terminal, go to that project and start the monitor:

   ~~~bash
   ./tools/chat-monitor.sh start
   ./tools/chat-monitor.sh status
   ~~~

   The launcher compiles the helper to `.chatgpt/chat-monitor` and sets its executable permission (`755`). On first start it requests Accessibility permission for `chat-monitor`. Allow that helper in System Settings, then run `start` again. Terminal or iTerm needs no Accessibility permission for this native monitor and cannot authorize the helper. The monitor does not start automatically when you log in.
4. Open a normal Chat conversation—not Work, a Codex workspace, settings, or a blank New chat—and use Chat as usual. A completed assistant response is eligible only when its last Diff is readable, complete, stable, and no larger than 8 MiB. Oversized or incomplete content is skipped, never truncated and applied.
   Starting the monitor or opening an already completed conversation does not apply an old Diff. Send a new request and let its response finish, or use the manual copy-and-apply command for an existing Diff.
5. To stop monitoring, run `./tools/chat-monitor.sh stop`. Check `.chatgpt/chat-monitor.log` if you need diagnostics.

The monitor works while the supported app is in the background; the status ring appears only when that same Chat window is frontmost. It checks the cached Send/Stop state once per second and uses coalesced accessibility events plus low-frequency full-tree scans. Browser fallback scans are no more frequent than every 30 seconds while generating or every 60 seconds while idle; this is a performance safeguard, not a measured CPU guarantee. If accessibility labels are unavailable, completion detection may be delayed or skipped.

Failure-report auto-submit is off by default. It can be explicitly enabled in the project-local `.chatgpt/chat-monitor.json` with `{"autoSendFailureReport": true}`. When enabled, the monitor still refuses to replace a non-empty draft or send unless it can confirm the same ordinary Chat and completed state. This sends local failure diagnostics to Chat; enable it only if that is what you want.

## Optional: Execute the Patch automatically with Hammerspoon

Hammerspoon is an optional shortcut layer for users who want one hotkey to finish the whole local step. After you configure it, the hotkey can:

1. read the latest complete Diff from the active Chat window;
2. save it as a temporary Patch;
3. call `tools/chat-apply-hammerspoon.sh`;
4. run the same validation, apply, syntax-check, and rollback protections;
5. show a short result notification;
6. reload your Hammerspoon configuration only after a confirmed successful apply.

ChatGPTBridge does not include the Lua hotkey integration itself. The Lua part belongs to your Hammerspoon configuration; the optional integration described here uses `OwlLinkerHS.spoon`, `ChatGPTApplyPatch.lua`, and `Tab+A`. ChatGPTBridge provides the local executor and its safety checks.

### Beginner setup

1. Install and open Hammerspoon.
2. In macOS, allow Hammerspoon under `System Settings → Privacy & Security → Accessibility`. Terminal or iTerm is only used to run the commands; it does not need Accessibility permission for this integration.
3. Add or enable your Hammerspoon Lua integration. It should read the active Chat Diff, create a unique temporary Patch file, and call the script with its absolute project path:

   ~~~bash
   /path/to/ChatGPTBridge/tools/chat-apply-hammerspoon.sh --patch-file /tmp/your-temporary-file.patch
   ~~~

   Replace `/path/to/ChatGPTBridge` with the actual folder where you saved this project.

4. Reload the Hammerspoon configuration.
5. In a supported ChatGPT/Codex app or browser, open an ordinary Chat conversation (not Work or a Codex workspace). Press `Tab+A` once to enable persistent monitoring, then send a new request asking for a complete Diff. The app may be moved to the background after monitoring starts.
6. Send a request normally and wait for the assistant response to finish.
7. Check the notification after the monitor applies the completed Diff. On first enable, an already completed Diff is treated as history and is not applied. After `HMReloadConfig`, a pending Diff with no saved success/failure result may resume. A successful apply may reload Hammerspoon, but monitoring remains enabled.

If the automatic run fails, do not press the hotkey repeatedly with the same Patch. Read the Hammerspoon console and `.chatgpt/patch-error.txt`, then use the copy-and-apply method or ask Chat to regenerate the Patch.

### Optional: monitor completed replies and run the same action automatically

The current `OwlLinkerHS.spoon` integration can monitor a supported ChatGPT/Codex app or browser after you enable it, including while it is in the background. It runs the local Patch flow after an observed send-and-complete cycle. Monitoring is off until you press `Tab+A`.

1. Reload Hammerspoon with monitoring disabled.
2. Press `Tab+A` once to enable persistent monitoring.
3. Send a request normally and wait for the reply to finish.
4. After a successful Patch, `HMReloadConfig` reloads Hammerspoon and monitoring continues automatically.

To start monitoring, the current window must be an ordinary Chat conversation rather than Work, and the latest assistant reply must contain a detectable Diff marker. A complete Patch can be processed immediately; if the Diff is still rendering, the monitor waits and retries. The monitor pairs an observed send/generation cycle with one completed, stable Diff, avoids concurrent Patch tasks, and processes the same Diff only once. Press `Tab+A` again to disable it. It does not send normal prompts or click Send; failure-report submission is a separate setting described below. Because this still programmatically reads the Chat interface, keep it disabled if you want the lowest-automation workflow.

Monitoring is not bound to one conversation title. Titles are used to restore per-conversation ring status when available, but switching between ordinary Chat conversations does not require toggling monitoring. Work, Codex workspaces, settings pages, and other non-Chat windows are not eligible for Patch processing; when you return to ordinary Chat, monitoring resumes there. The monitoring on/off setting survives `HMReloadConfig`.

Automatic application is restricted to the normal Chat conversation tree. Codex workspaces, settings pages, and other non-Chat windows are ignored.

When monitoring is enabled and ChatGPT/Codex is frontmost, the Send button is marked with a golden outline. Monitoring continues in the background; the marker is hidden while another app is frontmost and reappears when ChatGPT/Codex returns.

The outline is gold while monitoring and after a new request is submitted, green after a Patch is applied successfully (including a previously applied Patch), and red after an apply failure. The next request returns the status to gold. There is no yellow duplicate state in the current Hammerspoon implementation. The marker is an overlay around the Chat submit button and does not change the app button itself.

If `autoSendFailureReport` is `true` in the Hammerspoon configuration, a failed apply makes the monitor read `.chatgpt/patch-error.txt` and `.chatgpt/failed.patch`, paste the failure report into the normal Chat input, and submit it automatically. This setting belongs to the external Hammerspoon integration, not the ChatGPTBridge installer; check its value before enabling monitoring. Successes and duplicate applies do not trigger this step, and the report is not submitted from Work or other non-Chat windows.

Set it to `true` only after confirming that sending the failed Patch and local diagnostics to Chat is acceptable:

~~~json
{ "autoSendFailureReport": true }
~~~

Set `autoSendFailureReport` to `false` in your Hammerspoon `config/chatGPTPatchMonitor.json` to disable this behavior.

## Undo or recover

Undo only when you made no other changes after the Bridge applied the Patch:

~~~bash
./tools/chat-apply-shell.sh --undo
~~~

If something fails, do not apply the same failed Patch again. Read:

~~~text
.chatgpt/failed.patch
.chatgpt/patch-error.txt
~~~

Give the diagnostic and failed Patch to ChatGPT, and ask it to regenerate a complete Patch from the last successful project version.

## Verify the installation

~~~bash
for f in tools/chat-apply-shell.sh tools/chat-apply-hammerspoon.sh \
  tools/chat-read-last-diff.sh tools/chat-bridge-install.sh; do
  zsh -n "$f" || exit 1
done
bash -n tools/chat-context.sh
swiftc -parse tools/chat-read-last-diff.swift
~~~

ChatGPTBridge never commits or pushes automatically. Always inspect the snapshot before sharing it and test the result before committing.

## More

- [Chinese guide](./README.zh-CN.md)
- [License](./LICENSE)
