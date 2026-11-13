---
name: quoted
description: 許可の試験（本文だけクォートあり）
allowed-tools:
  - Bash(sh ${CLAUDE_SKILL_DIR}/scripts/probe.sh *)
---
Run exactly this command with the Bash tool (keep the double quotes as written) and then reply with its output only:

```bash
sh "${CLAUDE_SKILL_DIR}/scripts/probe.sh" hello
```
