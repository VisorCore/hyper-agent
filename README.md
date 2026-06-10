# VisorCore Hyper Agent

Secure outbound PowerShell agent for connecting Microsoft Hyper-V hosts to the VisorCore Hyper management portal.

## Overview

VisorCore Hyper Agent is a lightweight PowerShell-based background agent for Microsoft Hyper-V hosts. It registers hosts with the VisorCore Hyper Portal, runs as a Windows Scheduled Task, checks in outbound over HTTPS, and reports host, VM, virtual switch, checkpoint, storage, replication, and event inventory without exposing WinRM or Hyper-V management ports to the internet.

The PowerShell console relay is a legacy fallback. The production console track lives under `src/VisorCore.HyperAgent` and `relay/` and is designed as a signed Windows service with an outbound WebSocket relay.

## Install

Run from an elevated PowerShell session on the Hyper-V host. Use the workspace code generated inside the VisorCore Hyper Portal.

```powershell
Set-ExecutionPolicy RemoteSigned -Scope Process -Force
$installer = (iwr "https://raw.githubusercontent.com/VisorCore/hyper-agent/main/install.ps1" -UseBasicParsing).Content
iex $installer
Register-VisorCoreHost -Workspace "YOUR_WORKSPACE_CODE" -Region "us-central" -RequireMfa
```

## What It Does

- Registers a Hyper-V host for portal approval.
- Installs the local agent script under `C:\ProgramData\VisorCore\Agent`.
- Creates the `\VisorCore\Hyper Agent` scheduled task running as `SYSTEM`.
- Checks in outbound over HTTPS every 60 seconds.
- Reports host, VM, virtual switch, checkpoint, virtual disk, replication, and Hyper-V event inventory.
- Supports soft delete by unregistering the scheduled task when requested by the portal.

## Enterprise Console Track

The current PowerShell console uses Hyper-V WMI thumbnail capture and WMI keyboard/mouse injection. That path is not RMM-grade and should not be sold as the production console.

The enterprise console gateway adds:

- Signed Windows service agent source in `src/VisorCore.HyperAgent`.
- Outbound WebSocket relay scaffold in `relay/`.
- Binary frame protocol in `protocol/console-gateway.md`.
- GitHub Actions Windows build in `.github/workflows/build-windows-agent.yml`.
- Optional Authenticode signing through repository secrets:
  - `WINDOWS_CODE_SIGNING_CERT_BASE64`
  - `WINDOWS_CODE_SIGNING_PASSWORD`

Production deployment should use `relay.hyper.visorcore.com` on a VPS/container platform or Cloudflare Tunnel-backed service that supports WebSockets. Shared PHP hosting is not appropriate for the console relay.

## Security Model

The agent uses outbound-only HTTPS check-ins so Hyper-V hosts do not need inbound WinRM, RDP, or management ports exposed to the internet. Production releases should add signed releases, short-lived registration tokens, command authorization, stronger agent identity validation, signed PowerShell releases, and signed native gateway binaries.
