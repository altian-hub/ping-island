# PingIsland — Dev Log

Chronological record of debug and build sessions: what broke, why, and what
changed. Newest entries at the top. Durable routing lives in `AGENTS.md`; this
is the narrative.

---

## 2026-11-18 — Auto-allow answered the wrong request, so the CLI still prompted

With "Auto-allow all Claude Code permissions" on, Claude Code still showed its
own prompt for a `WebFetch` to `lists.freedesktop.org`:
*"Permission rule WebFetch requires confirmation for this tool."*

| Commit | What |
| --- | --- |
| `f02c214` | Auto-approve the PermissionRequest that arrived, not the session's active one |

```
workflow subagent (shares the parent's sessionId 78cfc85e…)
  20:21:39.6  WebFetch lists.freedesktop.org  id …KQn ─┐ two PermissionRequests
  20:21:41.8  WebFetch learn.microsoft.com    id …JES ─┘ open at the same time
                         │
HookSocketServer holds one bridge socket per request, keyed by tool_use_id
                         │
SessionMonitor auto-approve (before fix):
  id = session.activePermission.toolUseId  ?? event.toolUseId
       └ one id per session
                         │
  20:21:52  auto-approvals.jsonl: …JES ✔   …HZVq ✘ (not this fetch's id)
                         │
  socket …KQn gets no reply → Claude Code shows its native prompt
```

### What happened
- No `ask` rule existed in user, project or managed settings. The prompt text
  is just Claude Code's generic WebFetch dialog.
- `~/Library/Logs/PingIsland/auto-approvals.jsonl` showed an auto-approval for
  that fetch at 20:21:52Z, under `toolUseId` `toolu_01HZVqK4…`.
- The subagent transcript
  (`~/.claude/projects/-Users-altian-gop-gpua/78cfc85e…/subagents/workflows/wf_4cd1719e-e61/agent-acb63b101f0e6916c.jsonl`)
  showed the real id was `toolu_01KQnU5v…`. The logged id was wrong.
- At 20:20:39Z, two different fetches were also logged under one id,
  `toolu_01UnbxTq…`. One of those approvals answered nothing.
- Root cause: `SessionMonitor.resolvePendingApprovalToolUseId` used
  `session.activePermission?.toolUseId` first and the event's own
  `tool_use_id` only as a fallback. A session can hold several open permission
  requests (parallel tool calls, or workflow subagents that share the
  parent's `sessionId`). `activePermission` names only one. Every approval went
  to that one, and the other held sockets got no reply.

### Fix
- `PingIsland/Services/Session/SessionMonitor.swift`: answer
  `event.toolUseId` first. This is the key `HookSocketServer` stores the held
  socket under (it sets it on `updatedEvent` before calling the event handler).
  Use `activePermission` only when the event has no id.
- Built Release with the local recipe, ad-hoc signed, installed to
  `/Applications/Ping Island.app`, relaunched. The installed binary matches the
  `f02c214` build.

### Not yet verified
- No run with several parallel permission requests since the install. Check:
  no CLI prompt appears, and each new line in `auto-approvals.jsonl` has a
  distinct `toolUseId` that matches a real `tool_use` in the transcript.

### Lessons
- **An auto-approval log entry does not prove the CLI got the answer.** Compare
  the logged `toolUseId` with the transcript's `tool_use` id.
- **Workflow subagents share the parent's `sessionId`.** Any per-session
  "single active X" state is wrong once subagents run in parallel. Key
  responses by `tool_use_id`, not by session.
- Claude Code shows its own dialog while the `PermissionRequest` hook is still
  pending. If the hook never answers, the user sees a normal prompt, with no
  sign that the hook failed.
