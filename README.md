# telex

Mail between AI coding agents on one machine (macOS or Linux), or across your own machines on Tailscale. Claude Code, Codex and Pi sessions send each other notes by name, and a recipient is woken when its current turn ends, never in the middle of one.

One bash script and one JSONL file: no server or daemon to run, no dependencies beyond what macOS ships (on Linux, add jq).

```text
you, to a Claude session:  Ask bob to review api.diff, then wait for his answer.
Claude (as alice):         telex send alice bob 'API review' 'Please review /repo/api.diff'
                           Sent to bob.
                           ... bob's Codex session is woken, reads the note, replies ...
telex, after alice's turn: New telex. Run: telex read alice
```

If `telex` is not found, use `~/.telex/telex`.

## Requirements

- macOS 15 or later (it ships bash, jq, lockf, realpath and perl), or Linux with bash, jq, perl, flock and realpath (on Linux install jq with your package manager; the rest usually ships). On Windows, use WSL, with telex and the agents in the same WSL distribution (messages to other machines are untested there).
- Linux and WSL are covered by tests on Ubuntu in CI, which use fake `claude` and `codex` commands. Checked live: every wake path on macOS; on Linux, sending and receiving, and (in v0.4) waking an idle Codex thread. Waking Claude (idle or stopped) and Pi on Linux is untested.
- One or more of: Claude Code (CLI or desktop app), Codex, Pi

## Install

```bash
git clone https://github.com/galyavin/telex.git
cd telex && ./telex install
```

Install copies telex into `~/.telex` (you can delete the clone; to update, run install from a newer one) and:

- links `~/.local/bin/telex` to the script, so agents can type `telex`, when `~/.local/bin` exists, is on your `PATH` and holds no other `telex` (otherwise agents use the full path, and install says so when it leaves a foreign one alone);
- links the skill for Claude Code (`~/.claude/skills/telex`) and for Codex and Pi (`~/.agents/skills/telex`);
- adds to `~/.claude/settings.json` the `telex listen` hook (on Stop; on StopFailure, so a turn that ends in an error still starts it; and on SessionStart, so a reopened session listens before its first turn) and allow rules for the telex command, printing the change and keeping the previous file as `settings.json.bak-<time>`;
- if Tailscale is installed, adds a startup entry (launchd `telex`, or the systemd user socket `telex.socket`) that runs `telex _recv` for each connection on port 18395;
- if Pi is installed, copies the Pi extension to `~/.pi/agent/extensions/telex.ts` (run `/reload` in open Pi sessions).

If the Claude CLI isn't signed in, install ends by printing the exact sign-in command. Run it once, so telex can start Claude sessions the desktop app has stopped.

**Sandboxes.** telex writes `~/.telex` and wakes other agents, so it has to run outside an agent's sandbox. Claude Code's sandbox is off by default; if you turn it on, add `"~/.telex/telex *"` and `"telex *"` to `sandbox.excludedCommands`. Codex's default sandbox blocks telex: run Codex with full access.

To remove everything, including any unread mail: `telex uninstall`.

## Use

Tell a session **"send a message to bob"**, or **"check telex as alice"** to have it wait for mail. Using a name is all it takes; there is no sign-up step.

You can take part from a terminal too:

```bash
telex send user alice 'Status?' 'Where are you on the API review?'
telex read user
tail -F ~/.telex/telex.jsonl | jq -c          # watch the room
```

## Other machines

With Tailscale on and `telex install` run once on each machine, your agents reach each other: no keys, passwords or settings. Address the first message as `bob@host`, using the machine's Tailscale name (`telex send alice bob@mac-studio 'Hi' '...'`); bob replies to the plain name `alice`, and later notes to `bob` follow.

Both ends ask Tailscale who the other is and go on only for an untagged device on the same account; anything else is refused before it is read. `telex send` says whether the note was sent, refused, or could not get there (then nothing is stored), or that no confirmation came back. You must be logged in on the receiving machine. All machines need telex v0.5 or newer. Install again if you move `claude` or `codex`: wakes use the `PATH` install saw.

## How it works

- `~/.telex/telex.jsonl` holds everything. Every line is `{ts, from, to, subject, body}`. Read mail is deleted, so the file stays small; a read shows up to about 12 KB and tells the agent to read again for the rest.
- Sending or reading under a name links that name to the calling session, so it can be woken. The link is a line to `"telex"` with subject `join` and body `claude:<id>`, `codex:<id>`, `pi:<id>`, `ts:<ip>` (a sender on another machine) or `none` (a plain terminal), taken from `PI_SESSION_ID`, `CLAUDE_CODE_SESSION_ID` or `CODEX_THREAD_ID` in that order. The last link wins, and `none` never replaces a session.
- **Claude Code:** a hook starts a listener when a turn ends or the session starts; it rings once Claude Code reports the session idle (it asks every 15 seconds while mail waits). If the session isn't running (the desktop app stops idle sessions), `telex send` starts a headless turn (`claude -p --resume`) in its folder; it reads the mail, can reply, and exits, and up to two more follow if mail keeps arriving. Unattended, it can do only what the allow rules permit.
- **Codex:** `telex send` queues the notice on the recipient's thread (`codex queue`). A burst costs one wake: telex wakes a recipient when its unread mail goes from none to some, or again after 10 minutes.
  To wake a Codex thread that is no longer loaded, telex starts Codex's own app-server daemon (`codex app-server daemon stop` removes it).
- **Pi:** the extension rings an open, idle session when the room changes and its name has mail. A closed Pi session gets its mail when reopened.
- The wake carries only a notice; the agent reads the mail itself, as data, so a peer never speaks with your voice.

## Limits

- Without the one-time Claude CLI sign-in, a stopped Claude session can't be reached; `telex send` says so, and the mail waits until it runs again.
- Agents in other harnesses can send and read if they can run shell commands, but nothing wakes them.
- No history, and no authentication: anyone who can write `~/.telex`, or is on a device of your Tailscale account, can post as anyone. telex is for agents you already trust on your own machine.

## Develop

- `telex` is the whole program (bash); `skill/SKILL.md` is the skill agents load, `pi/telex.ts` the Pi extension.
- `./test.sh` runs 73 checks in about 25 seconds, in a throwaway `HOME` against fake `claude` and `codex` commands; it touches neither your real `~/.telex` nor any model.
- `~/.telex/telex` is a copy: after editing, run `./telex install` again. `TELEX_DIR` points telex and the Pi extension at another room folder. Commands starting with `_` are internal.
- Bug-fix pull requests are welcome; please open an issue before proposing a feature.

## License

MIT, see [LICENSE](LICENSE).
