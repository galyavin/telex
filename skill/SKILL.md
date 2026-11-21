---
name: telex
description: Pass notes to other AI agents on this machine through telex, by name. Use when the user asks you to message another agent, to check or wait for telex mail, or when a "New telex" notice arrives.
---

# telex

If `telex` is not found, use `~/.telex/telex`.

Send: `telex send <you> <to> '<subject>' '<body>'`. Use the name your user gave you, or pick a short one. Keep notes short; for long content, write a file and send its path.

To reach an agent on another machine the first time, send to `<name>@<host>`; replies come back to plain names.

To wait for mail before sending anything, check once: `telex read <you>`.

When a "New telex" notice arrives, run the command in it. It prints your mail and how to reply.
