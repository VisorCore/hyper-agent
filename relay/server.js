"use strict";

const http = require("http");
const { WebSocketServer } = require("ws");

const port = Number(process.env.PORT || 8080);
const agentSockets = new Map();
const browserSockets = new Map();

function keyFor({ workspaceId, hostId, sessionId = "" }) {
  return `${workspaceId || ""}:${hostId || ""}:${sessionId || ""}`;
}

function sendJson(socket, payload) {
  if (socket.readyState !== socket.OPEN) return;
  socket.send(JSON.stringify(payload));
}

function parseJson(data) {
  if (Buffer.isBuffer(data)) return null;
  try {
    return JSON.parse(String(data));
  } catch {
    return null;
  }
}

function closeWith(socket, code, reason) {
  try {
    socket.close(code, reason);
  } catch {}
}

const server = http.createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, service: "visorcore-console-relay" }));
    return;
  }
  res.writeHead(404);
  res.end("not found");
});

const wss = new WebSocketServer({ server });

wss.on("connection", (socket, request) => {
  const url = new URL(request.url || "/", "http://localhost");
  const role = url.pathname === "/agent" ? "agent" : (url.pathname === "/browser" ? "browser" : "");
  if (!role) {
    closeWith(socket, 1008, "invalid endpoint");
    return;
  }

  socket.role = role;
  socket.isAlive = true;
  socket.on("pong", () => { socket.isAlive = true; });

  socket.on("message", (data, isBinary) => {
    if (isBinary) {
      if (socket.role !== "agent" || !socket.sessionKey) return;
      const browser = browserSockets.get(socket.sessionKey);
      if (browser?.readyState === browser.OPEN) browser.send(data, { binary: true });
      return;
    }

    const message = parseJson(data);
    if (!message?.type) return;

    if (socket.role === "agent") {
      if (message.type === "agent.hello") {
        socket.workspaceId = String(message.workspaceId || "");
        socket.hostId = String(message.hostId || "");
        if (!socket.workspaceId || !socket.hostId) {
          closeWith(socket, 1008, "missing agent identity");
          return;
        }
        agentSockets.set(keyFor(socket), socket);
        sendJson(socket, { type: "agent.ready" });
        return;
      }
      if (message.sessionId) {
        socket.sessionKey = keyFor({ workspaceId: socket.workspaceId, hostId: socket.hostId, sessionId: message.sessionId });
      }
      const browser = socket.sessionKey ? browserSockets.get(socket.sessionKey) : null;
      if (browser?.readyState === browser.OPEN) sendJson(browser, message);
      return;
    }

    if (message.type === "browser.hello") {
      socket.workspaceId = String(message.workspaceId || "");
      socket.hostId = String(message.hostId || "");
      socket.sessionId = String(message.sessionId || "");
      socket.sessionKey = keyFor(socket);
      browserSockets.set(socket.sessionKey, socket);
      sendJson(socket, { type: "browser.ready" });
      return;
    }

    if (!socket.sessionKey) return;
    const agent = agentSockets.get(keyFor({ workspaceId: socket.workspaceId, hostId: socket.hostId }));
    if (agent?.readyState === agent.OPEN) sendJson(agent, message);
  });

  socket.on("close", () => {
    if (socket.role === "agent" && socket.workspaceId && socket.hostId) {
      agentSockets.delete(keyFor(socket));
    }
    if (socket.role === "browser" && socket.sessionKey) {
      browserSockets.delete(socket.sessionKey);
    }
  });
});

setInterval(() => {
  for (const socket of wss.clients) {
    if (!socket.isAlive) {
      try { socket.terminate(); } catch {}
      continue;
    }
    socket.isAlive = false;
    try { socket.ping(); } catch {}
  }
}, 30000);

server.listen(port, () => {
  console.log(`VisorCore console relay listening on ${port}`);
});
