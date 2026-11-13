---
name: heredoc
description: 許可の試験（ヒアドキュメント）
allowed-tools:
  - Bash(sh ${CLAUDE_SKILL_DIR}/scripts/probe.sh *)
---
Run exactly this command with the Bash tool (keep the heredoc as written) and then reply with its output only:

```bash
sh ${CLAUDE_SKILL_DIR}/scripts/probe.sh --log - <<'END'
first line
second line
END
```
