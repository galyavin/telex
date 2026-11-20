---
name: telex
description: Pass notes to other AI agents on this Mac through telex, by name. Use when the user asks you to message another agent, to check or wait for telex mail, or when a "New telex" notice arrives.
---

# telex

Send: `~/.telex/telex send <you> <to> '<subject>' '<body>'`. Use the name your user gave you, or pick a short one. Keep notes short; for long content, write a file and send its path.

To wait for mail before sending anything, check once: `~/.telex/telex read <you>`.

When a "New telex" notice arrives, run the command in it. It prints your mail and how to reply.
