// Pi and OMP lifecycle events: observe messages as they enter the agent, including queued prompts.
// Loaded only with --extension; never installed in a user or project config directory.
import { randomUUID } from "node:crypto";
import { request } from "node:http";

// OMP rebinds this module's factory to child sessions in the same process. Remember only
// observed relationships, keeping child turns tied to the root prompt that spawned them.
const agentTurns = new Map();

export default function (pi) {
  const socketPath = __TWINE_SOCKET__;
  const isOmp = __TWINE_OMP__;
  const queue = [];
  const calls = new Map();
  const children = new Map();
  let ownAgentId;
  let active;
  let sessionFile;
  let response = "";
  let responseStopReason;
  let responseSucceeded = false;
  let pending;
  let closed = false;
  let shuttingDown = false;
  let drained;

  const clip = (text, limit = 2048) => {
    const value = typeof text === "string" ? text : "";
    if (value.length <= limit) return value;
    let end = limit - 14;
    const last = value.charCodeAt(end - 1);
    if (last >= 0xd800 && last <= 0xdbff) end--;
    return value.slice(0, end) + "… [truncated]";
  };
  const identifier = value => typeof value === "string" && value.length > 0
    && Buffer.byteLength(value) <= 160 ? value : undefined;
  function textContent(content) {
    if (typeof content === "string") return clip(content);
    let text = "";
    for (const block of Array.isArray(content) ? content.slice(0, 32) : []) {
      if (block?.type === "text") text += clip(block.text) + "\n";
      else if (block?.type === "image") text += "[image]\n";
      if (text.length >= 2048) break;
    }
    return clip(text.trim());
  }
  function preview(value) {
    let remaining = 2048;
    function visit(item, depth) {
      if (remaining <= 0 || depth === 3) return "[truncated]";
      remaining -= 16;
      if (typeof item === "string") {
        const result = clip(item, Math.max(16, remaining));
        remaining -= result.length;
        return result;
      }
      if (item === null || typeof item !== "object") return item;
      const result = Array.isArray(item) ? [] : Object.create(null);
      let count = 0;
      for (const key in item) {
        if (!Object.hasOwn(item, key)) continue;
        if (++count > 16 || remaining <= 0) break;
        remaining -= key.length;
        result[clip(key, 160)] = key === "data" ? "[omitted]" : visit(item[key], depth + 1);
      }
      return result;
    }
    return visit(value, 0);
  }
  function pump() {
    if (closed || pending || queue.length === 0) return;
    const body = queue.shift();
    let timer;
    let req;
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      req?.destroy();
      pending = undefined;
      pump();
      if (shuttingDown && !pending && queue.length === 0) drained?.();
    };
    try {
      req = request({ socketPath, path: "/", method: "POST", agent: false,
        headers: { "Content-Length": Buffer.byteLength(body), "Connection": "close" } }, res => {
        res.on("error", finish);
        res.on("end", finish);
        res.resume();
      });
      pending = req;
      req.on("error", finish);
      req.on("socket", socket => socket.unref());
      timer = setTimeout(finish, 200);
      timer.unref();
      req.end(body);
    } catch { finish(); }
  }
  function send(event) {
    if (closed || shuttingDown || queue.length >= 256) return;
    queue.push(JSON.stringify({ ...event, session_id: sessionFile }));
    pump();
  }
  function shutdownTransport() {
    shuttingDown = true;
    calls.clear();
    return new Promise(resolve => {
      const finish = () => {
        clearTimeout(timer);
        closed = true;
        queue.length = 0;
        pending?.destroy();
        drained = undefined;
        resolve();
      };
      // Cover the entire bounded queue at the receiver's normal polling rate.
      const timer = setTimeout(finish, 3000);
      drained = finish;
      if (!pending && queue.length === 0) finish();
    });
  }
  function observeChild(name, event, agent) {
    const id = identifier(agent.id);
    if (!id) return;
    let child = children.get(id);
    if ((!child || child.finished) && name === "message_start" && event.message?.role === "user") {
      if (children.size >= 256 || agentTurns.size >= 256) return;
      const parent = agentTurns.get(agent.parentId);
      child = { agent_id: id, agent_name: clip(agent.name || "Subagent", 160),
        parent_agent_id: parent?.kind === "sub" ? identifier(agent.parentId) : undefined,
        turn_id: parent?.turn_id, calls: new Map(), finished: false, response: "", failed: false };
      children.set(id, child);
      agentTurns.set(id, { kind: "sub", turn_id: child.turn_id });
      send({ type: "agent_start", agent_id: id, agent_name: child.agent_name,
        parent_agent_id: child.parent_agent_id, turn_id: child.turn_id,
        detail: textContent(event.message.content) });
    }
    if (!child) return;
    const identity = { agent_id: id, agent_name: child.agent_name,
      parent_agent_id: child.parent_agent_id, turn_id: child.turn_id };
    if (name === "tool_execution_start" && child.calls.size < 256 && identifier(event.toolCallId)) {
      const call = { ...identity, tool_call_id: identifier(event.toolCallId),
        parent_tool_call_id: identifier(event.parentToolCallId),
        tool_name: clip(event.toolName, 160),
        target: clip(event.toolName === "bash" ? event.args?.command : event.args?.path, 160) };
      child.calls.set(event.toolCallId, call);
      send({ ...call, type: "tool_start", detail: clip(JSON.stringify(preview(event.args))) });
    } else if (name === "tool_execution_end") {
      const call = child.calls.get(event.toolCallId);
      if (call) {
        child.calls.delete(event.toolCallId);
        send({ ...call, type: "tool_end", is_error: event.isError === true,
          detail: textContent(event.result?.content) || clip(JSON.stringify(preview(event.result))) });
      }
    } else if (name === "message_end" && event.message?.role === "assistant") {
      child.response = textContent(event.message.content);
      child.failed = ["error", "aborted"].includes(event.message.stopReason);
    } else if (name === "agent_end" && !event.willContinue && !child.finished) {
      child.finished = true;
      send({ ...identity, type: "agent_end", detail: child.response, is_error: child.failed });
      // Completed sessions may remain resumable in OMP without shutting down. New
      // child factories must not exhaust the relationship cache over a long run.
      agentTurns.delete(id);
    } else if (name === "session_shutdown") {
      children.delete(id);
      agentTurns.delete(id);
      return shutdownTransport();
    }
  }
  // Work handlers never await I/O or alter decisions. Only shutdown waits for
  // already-observed events, with a fixed deadline even if the app is unavailable.
  const observe = (name, handler) => pi.on(name, (event, ctx) => {
    try {
      if (isOmp && ctx?.agent?.kind === "sub") {
        return observeChild(name, event, ctx.agent);
      }
      sessionFile = ctx?.sessionManager?.getSessionFile();
      ownAgentId = identifier(ctx?.agent?.id);
      const result = handler(event);
      if (isOmp && ownAgentId) {
        if (name === "session_shutdown") agentTurns.delete(ownAgentId);
        else if (agentTurns.size < 256 || agentTurns.has(ownAgentId)) {
          agentTurns.set(ownAgentId, { kind: "main", turn_id: active });
        }
      }
      return result;
    } catch { /* Recording is best effort. */ }
  });
  observe("session_start", () => send({ type: "session" }));
  observe("session_switch", () => send({ type: "session" }));
  observe("message_start", event => {
    if (event.message?.role !== "user") return;
    // Pi drains queued follow-ups before agent_settled. Finish an answered prompt before
    // the next one, while steering during a tool/model turn still interrupts the old span.
    if (active && responseSucceeded && ![...calls.values()].some(call => call.turn_id === active)) {
      send({ type: "response", turn_id: active, detail: response, stop_reason: responseStopReason });
    }
    active = randomUUID();
    response = "";
    responseStopReason = undefined;
    responseSucceeded = false;
    send({ type: "prompt", turn_id: active,
      detail: textContent(event.message.content) || "[Image prompt]" });
  });
  observe("tool_execution_start", event => {
    if (!active || calls.size >= 256 || !identifier(event.toolCallId)) return;
    responseSucceeded = false;
    const call = { turn_id: active, tool_call_id: identifier(event.toolCallId),
      parent_tool_call_id: identifier(event.parentToolCallId),
        tool_name: clip(event.toolName, 160),
      target: clip(event.toolName === "bash" ? event.args?.command : event.args?.path, 160) };
    calls.set(event.toolCallId, call);
    send({ ...call, type: "tool_start", detail: clip(JSON.stringify(preview(event.args))) });
  });
  observe("tool_execution_end", event => {
    const call = calls.get(event.toolCallId);
    if (!call) return;
    calls.delete(event.toolCallId);
    send({ ...call, type: "tool_end", is_error: event.isError === true,
      detail: textContent(event.result?.content) || clip(JSON.stringify(preview(event.result))) });
  });
  observe("message_end", event => {
    if (event.message?.role !== "assistant") return;
    response = textContent(event.message.content);
    responseStopReason = event.message.stopReason;
    responseSucceeded = ["stop", "length"].includes(event.message.stopReason)
      && !(Array.isArray(event.message.content) && event.message.content.some(block => block.type === "toolCall"));
  });
  // Pi settles after retries. OMP marks continuing agent_end notifications explicitly.
  observe(isOmp ? "agent_end" : "agent_settled", event => {
    if (isOmp && event.willContinue) return;
    if (active && responseSucceeded) send({ type: "response", turn_id: active, detail: response, stop_reason: responseStopReason });
    active = undefined;
    calls.clear();
  });
  observe("session_shutdown", shutdownTransport);
}
