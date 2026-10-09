// Passive observation only. Private launch configuration preserves existing policy and plugins.
import { request } from "node:http";
import { randomUUID } from "node:crypto";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

export default async function ({ client }) {
  const socketPath = __TWINE_SOCKET__;
  const sessions = new Map();
  const queue = [];
  let pending, closed = false, draining = false, drained;
  function pump() {
    if (closed || pending || !queue.length) return;
    const body = queue.shift();
    let req, timer, done = false;
    const finish = () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      req?.destroy();
      pending = undefined;
      pump();
      if (draining && !pending && !queue.length) drained?.();
    };
    try {
      req = request({ socketPath, path: "/", method: "POST", agent: false,
        headers: {"Content-Length": Buffer.byteLength(body), "Connection":"close"} }, res => {
        res.on("error", finish); res.on("end", finish); res.resume();
      });
      pending = req;
      req.on("error", finish); req.on("socket", socket => socket.unref());
      timer = setTimeout(finish, 200); timer.unref(); req.end(body);
    } catch { finish(); }
  }
  function send(event) {
    if (closed || draining || queue.length >= 256) return;
    let body = JSON.stringify(event);
    if (Buffer.byteLength(body) > 16384) {
      const path = join(dirname(socketPath), `record-${randomUUID()}.json`);
      writeFileSync(path, body, {mode:0o600});
      body = JSON.stringify({payload_file:path});
    }
    queue.push(body); pump();
  }
  function remember(info) {
    if (!info?.id) return;
    const parent = sessions.get(info.parentID);
    if (info.parentID && !parent) return; // No inferred relationship to unrelated sessions.
    const session = sessions.get(info.id) || {id:info.id, parent:info.parentID,
      turn:parent?.turn, root:parent?.root || info.id, text:new Map()};
    sessions.set(info.id, session);
    if (!session.parent) send({type:"session",session_id:info.id});
    return session;
  }
  function identity(session) {
    return {session_id:session.root, turn_id:session.turn,
      agent_id:session.parent ? session.id : undefined,
      parent_agent_id:session.parent && session.parent !== session.root ? session.parent : undefined};
  }
  function metadata(part) {
    return {source:"OpenCode observer",responseId:part.messageID,
      model:part.modelID,stopReason:part.reason,inputTokens:part.tokens?.input,
      outputTokens:part.tokens?.output,cacheReadTokens:part.tokens?.cache?.read,
      cacheWriteTokens:part.tokens?.cache?.write,cost:part.cost};
  }
  async function safe(handler) { try { await handler(); } catch {} }
  return {
    "chat.message": async (input, output) => safe(async () => {
      let session = sessions.get(input.sessionID);
      if (!session && client.session?.get) {
        const result = await client.session.get({path:{id:input.sessionID}});
        session = remember(result.data);
      }
      if (!session) return;
      session.succeeded = false; session.failed = false;
      const text = output.parts?.filter(p => p.type === "text").map(p => p.text).join("\n") || "";
      if (session.parent) {
        if (!session.assigned) {
          session.assigned = true;
          send({...identity(session),type:"agent_start",agent_name:input.agent || "Subagent",detail:text});
        }
      } else {
        session.turn = output.message.id;
        session.succeeded = false;
        session.failed = false;
        send({...identity(session),type:"prompt",detail:text});
      }
    }),
    "tool.execute.before": async (input, output) => safe(() => {
      const session = sessions.get(input.sessionID);
      if (session) send({...identity(session),type:"tool_start",tool_call_id:input.callID,
        tool_name:input.tool,target:output.args?.command || output.args?.filePath,detail:JSON.stringify(output.args)});
    }),
    "tool.execute.after": async (input, output) => safe(() => {
      const session = sessions.get(input.sessionID);
      if (session) send({...identity(session),type:"tool_end",tool_call_id:input.callID,
        tool_name:input.tool,detail:output.output || ""});
    }),
    event: async ({event}) => safe(() => {
      const p = event.properties || {};
      if (event.type === "session.created") { remember(p.info); return; }
      const part = p.part;
      const session = sessions.get(p.sessionID || part?.sessionID || p.info?.sessionID);
      if (!session) return;
      const id = identity(session);
      if (event.type === "message.updated" && p.info?.role === "assistant") {
        session.model = p.info.modelID;
        if (p.info.error) { session.failed = true; session.succeeded = false; }
        else if (p.info.time?.completed && p.info.finish && !["tool-calls","unknown"].includes(p.info.finish)) { session.succeeded = true; session.failed = false; }
      } else if (event.type === "message.part.updated") {
        if (part.type === "step-start") {
          session.call = part.id;
          session.text.clear();
          send({...id,type:"model_start",activity_id:part.id,title:"LLM call",
            metadata:{source:"OpenCode observer",model:session.model,responseId:part.messageID}});
        } else if (part.type === "text" || part.type === "reasoning-summary") {
          session.text.set(part.id,part.text || "");
        } else if (part.type === "step-finish") {
          send({...id,type:"model_end",activity_id:session.call || part.id,title:"LLM call",
            detail:[...session.text.values()].join("\n"),metadata:{...metadata(part),model:session.model}});
          session.call = undefined;
        } else if (part.type === "tool" && ["completed","error"].includes(part.state?.status)) {
          send({...id,type:"tool_end",tool_call_id:part.callID,tool_name:part.tool,
            is_error:part.state.status === "error",detail:part.state.output || part.state.error || ""});
        }
      } else if (event.type === "session.idle") {
        const detail = [...session.text.values()].join("\n");
        if (session.parent || (session.succeeded && !session.failed)) {
          send({...id,type:session.parent ? "agent_end" : "response",detail,is_error:session.failed === true});
          session.succeeded = false;
        }
      } else if (event.type === "session.error") {
        session.failed = true; session.succeeded = false;
        send({...id,type:"note",activity_id:randomUUID(),title:"Session error",is_error:true,
          detail:JSON.stringify(p.error),metadata:{source:"OpenCode observer",event:event.type}});
      } else if (event.type === "session.compacted" || event.type.startsWith("permission.") ||
                 (event.type === "session.status" && p.status?.type === "retry")) {
        send({...id,type:"note",activity_id:p.id || randomUUID(),title:event.type,
          detail:JSON.stringify(p),metadata:{source:"OpenCode observer",event:event.type}});
      } else if (event.type === "session.deleted") sessions.delete(p.info?.id);
    }),
    dispose: async () => {
      draining = true;
      await new Promise(resolve => {
        const finish = () => {clearTimeout(timer);closed=true;queue.length=0;pending?.destroy();resolve();};
        const timer = setTimeout(finish,3000);
        drained=finish;
        if (!pending && !queue.length) finish();
      });
      sessions.clear();
    }
  };
}
