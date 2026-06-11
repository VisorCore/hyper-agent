const encoder = new TextEncoder();

function json(payload, status = 200, headers = {}) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...headers,
    },
  });
}

function corsHeaders(env) {
  return {
    "access-control-allow-origin": env.ALLOWED_ORIGIN || "https://hyper.visorcore.com",
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "content-type,authorization",
  };
}

function base64Url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function safeEqual(a, b) {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function hmacSha256(secret, message) {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return base64Url(new Uint8Array(signature));
}

async function validateToken(url, env) {
  const secret = env.SIGNALING_SECRET || "";
  if (!secret) return { ok: false, status: 503, message: "Signaling secret is not configured." };

  const sessionId = decodeURIComponent(url.pathname.split("/").filter(Boolean).pop() || "");
  const workspace = url.searchParams.get("workspace") || "";
  const host = url.searchParams.get("host") || "";
  const role = url.searchParams.get("role") || "";
  const exp = url.searchParams.get("exp") || "";
  const sig = url.searchParams.get("sig") || "";

  if (!sessionId || !workspace || !host || !["agent", "browser"].includes(role) || !exp || !sig) {
    return { ok: false, status: 400, message: "Missing signaling token fields." };
  }
  if (Number(exp) < Math.floor(Date.now() / 1000)) {
    return { ok: false, status: 401, message: "Signaling token expired." };
  }

  const expected = await hmacSha256(secret, `${sessionId}.${workspace}.${host}.${role}.${exp}`);
  if (!safeEqual(sig, expected)) {
    return { ok: false, status: 401, message: "Invalid signaling token." };
  }

  return { ok: true, sessionId, workspace, host, role, exp };
}

export class ConsoleRoom {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.sockets = new Map();
    this.queues = new Map([
      ["agent", []],
      ["browser", []],
    ]);
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders(this.env) });

    const validation = await validateToken(url, this.env);
    if (!validation.ok) return json({ success: false, message: validation.message }, validation.status, corsHeaders(this.env));

    if (request.headers.get("Upgrade") !== "websocket") {
      return json({ success: true, service: "visorcore-console-signaling", session_id: validation.sessionId }, 200, corsHeaders(this.env));
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    this.acceptSocket(server, validation);
    return new Response(null, { status: 101, webSocket: client, headers: corsHeaders(this.env) });
  }

  acceptSocket(socket, auth) {
    const previous = this.sockets.get(auth.role);
    if (previous) {
      try { previous.close(4000, "superseded"); } catch {}
    }

    socket.accept();
    socket.auth = auth;
    this.sockets.set(auth.role, socket);
    this.send(socket, { type: `${auth.role}.ready`, sessionId: auth.sessionId, workspace: auth.workspace, host: auth.host });
    this.flush(auth.role);

    socket.addEventListener("message", (event) => {
      if (typeof event.data !== "string") {
        this.send(socket, { type: "error", message: "Signaling accepts JSON text messages only." });
        return;
      }
      let message;
      try {
        message = JSON.parse(event.data);
      } catch {
        this.send(socket, { type: "error", message: "Invalid JSON signaling message." });
        return;
      }
      this.forward(auth.role, {
        ...message,
        sessionId: auth.sessionId,
        workspace: auth.workspace,
        host: auth.host,
        from: auth.role,
      });
    });

    socket.addEventListener("close", () => {
      if (this.sockets.get(auth.role) === socket) this.sockets.delete(auth.role);
      this.forward(auth.role, { type: `${auth.role}.closed`, sessionId: auth.sessionId, from: auth.role });
    });

    socket.addEventListener("error", () => {
      if (this.sockets.get(auth.role) === socket) this.sockets.delete(auth.role);
    });
  }

  peerRole(role) {
    return role === "agent" ? "browser" : "agent";
  }

  forward(fromRole, message) {
    const targetRole = this.peerRole(fromRole);
    const target = this.sockets.get(targetRole);
    if (target) {
      this.send(target, message);
      return;
    }
    const queue = this.queues.get(targetRole) || [];
    queue.push(message);
    while (queue.length > 128) queue.shift();
    this.queues.set(targetRole, queue);
  }

  flush(role) {
    const socket = this.sockets.get(role);
    const queue = this.queues.get(role) || [];
    if (!socket || !queue.length) return;
    while (queue.length) this.send(socket, queue.shift());
  }

  send(socket, payload) {
    try {
      socket.send(JSON.stringify(payload));
    } catch {}
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders(env) });
    if (url.pathname === "/health") return json({ success: true, service: "visorcore-console-signaling" }, 200, corsHeaders(env));
    if (!url.pathname.startsWith("/signal/")) return json({ success: false, message: "Not found." }, 404, corsHeaders(env));

    const sessionId = decodeURIComponent(url.pathname.split("/").filter(Boolean).pop() || "");
    if (!sessionId) return json({ success: false, message: "Missing session ID." }, 400, corsHeaders(env));

    const id = env.CONSOLE_ROOMS.idFromName(sessionId);
    return env.CONSOLE_ROOMS.get(id).fetch(request);
  },
};
