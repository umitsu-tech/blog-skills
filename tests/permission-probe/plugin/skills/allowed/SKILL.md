---
name: allowed
description: 許可の試験（allowed-tools あり）
allowed-tools:
  - Bash(sh ${CLAUDE_SKILL_DIR}/scripts/probe.sh *)
---
Run exactly this command with the Bash tool and then reply with its output only:

```bash
sh ${CLAUDE_SKILL_DIR}/scripts/probe.sh hello
```
