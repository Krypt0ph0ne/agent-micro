#!/usr/bin/env node

// Manual integration probe for the official Codex app-server protocol.
// Approval and user-input server requests are deliberately observed but never answered.
import { spawn } from "node:child_process";
import readline from "node:readline";

const mode = process.argv[2] ?? "completed";
const codex = "/Applications/Codex.app/Contents/Resources/codex";
const child = spawn(codex, ["app-server", "--stdio"], { stdio: ["pipe", "pipe", "pipe"] });
const lines = readline.createInterface({ input: child.stdout });
let nextId = 1;
const pending = new Map();
let threadId = null;

function send(method, params, label) {
  const id = nextId++;
  pending.set(id, label);
  child.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
}

function finish(result, code = 0) {
  process.stdout.write(`${JSON.stringify(result)}\n`);
  child.kill("SIGTERM");
  setTimeout(() => process.exit(code), 50).unref();
}

child.stderr.on("data", (data) => process.stderr.write(data));
child.on("error", (error) => finish({ mode, threadId, status: "spawn_error", error: error.message }, 1));
child.on("exit", (code, signal) => {
  if (code && code !== 0) process.stderr.write(`app-server exited with code ${code} (${signal ?? "no signal"})\n`);
});

const timeout = setTimeout(() => finish({ mode, threadId, status: "timeout" }, 2), Number(process.env.AGENT_MICRO_PROBE_TIMEOUT_MS ?? 120_000));

lines.on("line", (line) => {
  let message;
  try { message = JSON.parse(line); } catch { return; }

  if (message.id != null && pending.has(message.id)) {
    const label = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) return finish({ mode, threadId, status: "request_error", error: message.error }, 1);

    if (label === "initialize") {
      child.stdin.write(`${JSON.stringify({ method: "initialized" })}\n`);
      if (mode === "inspect" || mode === "turns") {
        const inspectedThreadId = process.env.AGENT_MICRO_THREAD_ID;
        if (!inspectedThreadId) return finish({ mode, status: "missing_thread_id" }, 2);
        threadId = inspectedThreadId;
        if (mode === "turns") {
          send("thread/turns/list", { threadId, limit: 1, sortDirection: "desc", itemsView: "summary" }, "turnsList");
        } else {
          send("thread/read", { threadId, includeTurns: true }, "threadRead");
        }
        return;
      }
      if (mode === "list") {
        const listParams = {
          limit: 100,
          sortKey: "recency_at",
          sortDirection: "desc",
          sourceKinds: ["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"],
        };
        if (process.env.AGENT_MICRO_SEARCH_TERM) listParams.searchTerm = process.env.AGENT_MICRO_SEARCH_TERM;
        send("thread/list", listParams, "threadList");
        return;
      }
      const params = {
        cwd: process.cwd(),
        approvalPolicy: mode === "approval" ? "untrusted" : "never",
        sandbox: mode === "approval" ? "read-only" : "workspace-write",
        ephemeral: false,
      };
      if (mode === "failed") {
        params.model = "definitely-not-a-real-codex-model";
        params.allowProviderModelFallback = false;
      }
      send("thread/start", params, "threadStart");
    } else if (label === "threadRead") {
      clearTimeout(timeout);
      const thread = message.result.thread;
      finish({
        mode,
        threadId,
        status: thread.status,
        updatedAt: thread.updatedAt,
        turns: thread.turns.slice(-5).map((turn) => ({
          id: turn.id,
          status: turn.status,
          startedAt: turn.startedAt,
          completedAt: turn.completedAt,
          items: turn.items.slice(-5).map((item) => ({ type: item.type, status: item.status ?? null, id: item.id ?? null })),
        })),
      });
    } else if (label === "threadList") {
      clearTimeout(timeout);
      finish({ mode, threads: message.result.data.map(({ id, status, name, preview }) => ({ id, status, name, preview })) });
    } else if (label === "turnsList") {
      clearTimeout(timeout);
      finish({ mode, threadId, turns: message.result.data });
    } else if (label === "threadStart") {
      threadId = message.result.thread.id;
      const text = mode === "approval"
        ? "Create the file /private/tmp/codexpad-approval-probe using a shell command now."
        : "Reply exactly AGENT_MICRO_COMPLETE and do not use any tools.";
      send("turn/start", { threadId, input: [{ type: "text", text, text_elements: [] }] }, "turnStart");
    }
    return;
  }

  if (message.method === "turn/started" && message.params?.threadId === threadId) {
    process.stdout.write(`${JSON.stringify({ mode, threadId, status: "running" })}\n`);
  }
  if (message.method === "turn/completed" && message.params?.threadId === threadId) {
    clearTimeout(timeout);
    finish({ mode, threadId, status: message.params.turn.status, error: message.params.turn.error ?? null });
  }
  if ([
    "item/commandExecution/requestApproval",
    "item/fileChange/requestApproval",
    "item/permissions/requestApproval",
    "item/tool/requestUserInput",
    "mcpServer/elicitation/request",
    "applyPatchApproval",
    "execCommandApproval",
  ].includes(message.method) && message.params?.threadId === threadId) {
    clearTimeout(timeout);
    finish({ mode, threadId, status: "approval_required", method: message.method });
  }
});

send("initialize", {
  clientInfo: { name: "agentmicro-status-probe", title: "Agent Micro Status Probe", version: "1.0" },
  capabilities: { experimentalApi: true, requestAttestation: false, mcpServerOpenaiFormElicitation: false },
}, "initialize");
