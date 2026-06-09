# VisorCore Hyper Agent

Secure outbound PowerShell agent for connecting Microsoft Hyper-V hosts to the VisorCore Hyper management portal.

## Overview

VisorCore Hyper Agent is a lightweight PowerShell-based background agent for Microsoft Hyper-V hosts. It registers hosts with the VisorCore Hyper Portal, runs as a Windows Scheduled Task, checks in outbound over HTTPS, and reports host, VM, virtual switch, checkpoint, storage, replication, and event inventory without exposing WinRM or Hyper-V management ports to the internet.

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

## Security Model

The agent uses outbound-only HTTPS check-ins so Hyper-V hosts do not need inbound WinRM, RDP, or management ports exposed to the internet. Future releases should add signed releases, short-lived registration tokens, command authorization, stronger agent identity validation, and signed PowerShell releases.
