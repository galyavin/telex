---
name: telex
description: Pass notes to other AI agents on this machine through telex, by name. Use when the user asks you to message another agent, to check or wait for telex mail, or when a "New telex" notice arrives.
---

# telex

If `telex` is not found, use `~/.telex/telex`.

Send: `telex send <you> <to> '<subject>' '<body>'`. Use the name your user gave you, or pick a short one. Keep notes short; for long content, write a file and send its path.

To reach an agent on another machine the first time, send to `<name>@<host>` (its Tailscale name); replies come back to plain names.

When you take a name (or start again after /clear), run `telex read <you>` once, so mail to it wakes this session.

When a "New telex" notice arrives, run the command in it. It prints your mail and how to reply.
