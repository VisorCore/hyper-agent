# VisorCore Enterprise Console Gateway Protocol

The PowerShell thumbnail console is a legacy fallback. Production console sessions use a signed Windows service on the Hyper-V host and an outbound WebSocket relay.

## Goals

- No inbound firewall rules on customer Hyper-V hosts.
- Browser-to-VM console input with sub-second feedback.
- Binary frame transport instead of PHP polling and base64 JSON.
- Session-scoped authorization, audit events, and license enforcement.
- Code-signed Windows service to reduce EDR/MDR friction.

## Transport

- Agent connects outbound to `wss://relay.hyper.visorcore.com/agent`.
- Browser connects to `wss://relay.hyper.visorcore.com/browser`.
- The relay maps `workspace_id + host_id + session_id`.
- Management commands stay in the Hyper Portal API; console traffic moves to the relay.

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

Frames are binary WebSocket messages:

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
- Relay rejects unsigned or expired session tokens.
- Browser console sessions require a short-lived session token issued by the Hyper Portal API.
- Every console start, stop, input event, and transfer is audit logged.

## Console Backends

1. **Host console fallback:** Hyper-V WMI thumbnail + keyboard/mouse APIs. This works before guest OS networking, but it is not RMM-grade.
2. **Enhanced session/RDP backend:** Used when the guest supports Enhanced Session or RDP. Better input and smoother screen updates.
3. **Guest service backend:** Optional future VM-side agent for RMM-grade Windows console, clipboard, file transfer, multi-monitor, and Desktop Duplication capture.

The shipping product should select the best backend per VM and clearly show which backend is active.
