# VisorCore Enterprise Console Gateway Protocol

The PowerShell thumbnail console is a legacy fallback. Production console sessions use a signed Windows service on the Hyper-V host, Cloudflare Workers Durable Objects for WebRTC signaling, and direct browser-to-agent media whenever possible.

## Goals

- No inbound firewall rules on customer Hyper-V hosts.
- Browser-to-VM console input with sub-second feedback.
- Binary frame transport instead of PHP polling and base64 JSON.
- Session-scoped authorization, audit events, and license enforcement.
- Code-signed Windows service to reduce EDR/MDR friction.

## Transport

- Preferred no-VPS path: browser and agent connect to the Cloudflare Worker at `/signal/{sessionId}` with HMAC-signed short-lived URLs.
- Cloudflare Durable Object maps `workspace_id + host_id + session_id` and forwards WebRTC offer, answer, and ICE messages.
- WebRTC media should flow directly between browser and Hyper Agent when possible.
- Cloudflare STUN is used for discovery; Cloudflare TURN can be enabled as fallback when restrictive NAT/firewalls block direct media.
- Management commands stay in the Hyper Portal API; console signaling moves to Cloudflare; console media should not touch reseller PHP hosting.

## Message Types

All control messages are UTF-8 JSON.

```json
{ "type": "agent.hello", "workspaceId": "vc_x", "hostId": "host_x", "agentVersion": "1.0.0" }
{ "type": "console.start", "sessionId": "vcs_x", "vmName": "LAB01-VM-WIN10", "targetFps": 20 }
{ "type": "console.stop", "sessionId": "vcs_x" }
{ "type": "console.input.text", "sessionId": "vcs_x", "text": "password" }
{ "type": "console.input.key", "sessionId": "vcs_x", "key": "Enter", "keyCode": 13 }
{ "type": "console.input.mouse", "sessionId": "vcs_x", "x": 512, "y": 384, "button": "left", "action": "click" }
```

Legacy relay frames are binary WebSocket messages:

```text
uint32_be header_length
utf8_json_header
binary_payload
```

Example frame header:

```json
{ "type": "console.frame", "sessionId": "vcs_x", "mime": "image/jpeg", "width": 1280, "height": 720, "sequence": 42, "capturedAtUtc": "2026-06-10T18:00:00Z" }
```

## Security Requirements

- Agent release binaries are Authenticode signed.
- Agent update packages are hash-verified before install.
- Agent registration exchanges the workspace bootstrap token for a host identity token.
- Cloudflare signaling Worker rejects unsigned or expired session tokens.
- Browser console sessions require a short-lived session token issued by the Hyper Portal API.
- Every console start, stop, input event, and transfer is audit logged.

## Cloudflare Free-Tier Path

The no-VPS deployment lives in `cloudflare/signaling-worker`.

```text
Reseller PHP portal creates console session
  -> PHP mints browser + agent signaling URLs
  -> Browser connects to Cloudflare Worker
  -> Hyper Agent connects outbound to Cloudflare Worker
  -> Durable Object forwards offer/answer/ICE
  -> WebRTC connects browser directly to Hyper Agent where possible
  -> TURN fallback is used only when direct NAT traversal fails
```

## Console Backends

1. **Host console fallback:** Hyper-V WMI thumbnail + keyboard/mouse APIs. This works before guest OS networking, but it is not RMM-grade.
2. **Enhanced session/RDP backend:** Used when the guest supports Enhanced Session or RDP. Better input and smoother screen updates.
3. **Guest service backend:** Optional future VM-side agent for RMM-grade Windows console, clipboard, file transfer, multi-monitor, and Desktop Duplication capture.

The shipping product should select the best backend per VM and clearly show which backend is active.
