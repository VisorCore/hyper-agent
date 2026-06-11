# VisorCore Cloudflare Console Signaling Worker

This Worker is the no-VPS signaling layer for VisorCore WebRTC console sessions.

It does not stream video itself. It only pairs the browser and Hyper Agent long enough to exchange WebRTC offer, answer, and ICE candidate messages. Media should flow directly between the browser and the Hyper Agent whenever NAT/firewall rules allow it. Cloudflare STUN is free; Cloudflare TURN can be added as fallback when direct WebRTC fails.

## Free-Tier Role

- Runs on Cloudflare Workers.
- Uses Durable Objects for one room per console session.
- Uses WebSockets for low-latency signaling.
- Uses HMAC-signed short-lived URLs minted by the reseller-hosted PHP portal.

## Deploy

```bash
cd cloudflare/signaling-worker
npx wrangler login
npx wrangler secret put SIGNALING_SECRET
npx wrangler deploy
```

Set the same secret in the reseller-hosted portal config:

```php
'console_signaling_url' => 'https://visorcore-console-signaling.<account>.workers.dev',
'console_signaling_secret' => 'same-secret-used-in-wrangler',
```

## Endpoint

```text
wss://.../signal/{sessionId}?workspace=...&host=...&role=browser&exp=...&sig=...
wss://.../signal/{sessionId}?workspace=...&host=...&role=agent&exp=...&sig=...
```

The signature is:

```text
base64url(hmac_sha256(secret, "{sessionId}.{workspace}.{host}.{role}.{exp}"))
```

## Message Examples

```json
{ "type": "browser.hello" }
{ "type": "agent.hello" }
{ "type": "webrtc.offer", "sdp": "..." }
{ "type": "webrtc.answer", "sdp": "..." }
{ "type": "webrtc.ice", "candidate": { "candidate": "...", "sdpMid": "0", "sdpMLineIndex": 0 } }
```
