# VisorCore Hyper bootstrap installer
# PowerShell 5.1 compatible bootstrap for Windows Server Hyper-V hosts.

$ErrorActionPreference = "Stop"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Warning "Could not force TLS 1.2. Continuing with system defaults."
}

function Test-VisorCoreAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-VisorCoreAgentTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $InstallRoot
    )

    $taskName = "Hyper Agent"
    $taskPath = "\VisorCore\"
    $agentPath = Join-Path $InstallRoot "agent.ps1"
    $logPath = Join-Path $InstallRoot "agent.log"

    $agentScript = @'
$ErrorActionPreference = "Continue"
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

$root = Join-Path $env:ProgramData "VisorCore\Agent"
$configPath = Join-Path $root "host-registration.json"
$logPath = Join-Path $root "agent.log"

function Write-VisorCoreAgentLog {
    param([string] $Message)
    try {
        Add-Content -Path $logPath -Value ("{0} {1}" -f (Get-Date).ToUniversalTime().ToString("o"), $Message)
    } catch {}
}

function ConvertTo-VisorCoreIso {
    param($Value)
    try {
        if ($null -eq $Value) { return "" }
        return ([datetime] $Value).ToUniversalTime().ToString("o")
    } catch {
        return ""
    }
}

function ConvertTo-VisorCoreGb {
    param($Value)
    try {
        return [math]::Round(([double] $Value / 1GB), 2)
    } catch {
        return 0
    }
}

function Get-VisorCoreInventory {
    $inventory = @{
        agent_version = "0.2.0"
        synced_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        host = @{}
        vms = @()
        switches = @()
        checkpoints = @()
        disks = @()
        replication = @()
        events = @()
        vm_count = 0
        running_vm_count = 0
        switch_count = 0
        checkpoint_count = 0
        disk_count = 0
        replication_count = 0
        event_count = 0
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        $inventory.host = @{
            name = $env:COMPUTERNAME
            os = if ($os) { [string] $os.Caption } else { "" }
            version = if ($os) { [string] $os.Version } else { "" }
            uptime_seconds = if ($os -and $os.LastBootUpTime) { [int] ((Get-Date) - $os.LastBootUpTime).TotalSeconds } else { 0 }
            total_memory_gb = if ($computer) { ConvertTo-VisorCoreGb $computer.TotalPhysicalMemory } else { 0 }
        }
    } catch {}

    try {
        Import-Module Hyper-V -ErrorAction Stop

        $vms = @(Get-VM -ErrorAction SilentlyContinue | Select-Object -First 250)
        $inventory.vm_count = @($vms).Count
        $inventory.running_vm_count = @($vms | Where-Object { [string] $_.State -eq "Running" }).Count
        foreach ($vm in $vms) {
            $adapters = @()
            try {
                $adapters = @(Get-VMNetworkAdapter -VMName $vm.Name -ErrorAction SilentlyContinue | Select-Object -First 20)
            } catch {}
            $switchNames = @($adapters | ForEach-Object { [string] $_.SwitchName } | Where-Object { $_ -ne "" } | Select-Object -Unique)
            $ips = @($adapters | ForEach-Object { $_.IPAddresses } | ForEach-Object { [string] $_ } | Where-Object { $_ -ne "" } | Select-Object -First 8)
            $inventory.vms += @{
                id = [string] $vm.VMId
                name = [string] $vm.Name
                host = $env:COMPUTERNAME
                state = [string] $vm.State
                status = [string] $vm.Status
                cpu_usage = [int] $vm.CPUUsage
                memory_assigned_mb = [math]::Round(([double] $vm.MemoryAssigned / 1MB), 0)
                memory_demand_mb = [math]::Round(([double] $vm.MemoryDemand / 1MB), 0)
                processor_count = [int] $vm.ProcessorCount
                uptime_seconds = [int] $vm.Uptime.TotalSeconds
                version = [string] $vm.Version
                generation = [int] $vm.Generation
                switch_names = $switchNames
                ip_addresses = $ips
            }
        }

        $switches = @(Get-VMSwitch -ErrorAction SilentlyContinue | Select-Object -First 100)
        $inventory.switch_count = @($switches).Count
        foreach ($switch in $switches) {
            $inventory.switches += @{
                id = [string] $switch.Id
                name = [string] $switch.Name
                host = $env:COMPUTERNAME
                switch_type = [string] $switch.SwitchType
                net_adapter = [string] $switch.NetAdapterInterfaceDescription
                allow_management_os = [bool] $switch.AllowManagementOS
                notes = [string] $switch.Notes
            }
        }

        foreach ($vm in $vms) {
            try {
                $checkpoints = @(Get-VMCheckpoint -VMName $vm.Name -ErrorAction SilentlyContinue | Select-Object -First 100)
                foreach ($checkpoint in $checkpoints) {
                    $inventory.checkpoints += @{
                        vm = [string] $vm.Name
                        host = $env:COMPUTERNAME
                        name = [string] $checkpoint.Name
                        type = [string] $checkpoint.CheckpointType
                        created_at = ConvertTo-VisorCoreIso $checkpoint.CreationTime
                    }
                }
            } catch {}

            try {
                $drives = @(Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction SilentlyContinue | Select-Object -First 100)
                foreach ($drive in $drives) {
                    $vhd = $null
                    try { $vhd = Get-VHD -Path $drive.Path -ErrorAction SilentlyContinue } catch {}
                    $inventory.disks += @{
                        vm = [string] $vm.Name
                        host = $env:COMPUTERNAME
                        path = [string] $drive.Path
                        controller = ([string] $drive.ControllerType) + " " + ([string] $drive.ControllerNumber) + ":" + ([string] $drive.ControllerLocation)
                        size_gb = if ($vhd) { ConvertTo-VisorCoreGb $vhd.Size } else { 0 }
                        file_size_gb = if ($vhd) { ConvertTo-VisorCoreGb $vhd.FileSize } else { 0 }
                        type = if ($vhd) { [string] $vhd.VhdType } else { "" }
                        format = if ($vhd) { [string] $vhd.VhdFormat } else { "" }
                    }
                }
            } catch {}
        }
        $inventory.checkpoint_count = @($inventory.checkpoints).Count
        $inventory.disk_count = @($inventory.disks).Count

        try {
            $replicas = @(Get-VMReplication -ErrorAction SilentlyContinue | Select-Object -First 100)
            $inventory.replication_count = @($replicas).Count
            foreach ($replica in $replicas) {
                $inventory.replication += @{
                    vm = [string] $replica.VMName
                    host = $env:COMPUTERNAME
                    replica_server = [string] $replica.ReplicaServer
                    state = [string] $replica.State
                    health = [string] $replica.Health
                    mode = [string] $replica.Mode
                    last_replication_time = ConvertTo-VisorCoreIso $replica.LastReplicationTime
                }
            }
        } catch {}
    } catch {
        Write-VisorCoreAgentLog ("hyper-v inventory failed: " + $_.Exception.Message)
    }

    try {
        $eventLogs = @("Microsoft-Windows-Hyper-V-VMMS-Admin", "Microsoft-Windows-Hyper-V-Worker-Admin")
        foreach ($eventLog in $eventLogs) {
            try {
                $events = @(Get-WinEvent -LogName $eventLog -MaxEvents 10 -ErrorAction SilentlyContinue)
                foreach ($event in $events) {
                    $inventory.events += @{
                        host = $env:COMPUTERNAME
                        log = [string] $eventLog
                        id = [int] $event.Id
                        level = [string] $event.LevelDisplayName
                        provider = [string] $event.ProviderName
                        time = ConvertTo-VisorCoreIso $event.TimeCreated
                        message = ([string] $event.Message)
                    }
                }
            } catch {}
        }
        $inventory.event_count = @($inventory.events).Count
    } catch {}

    return $inventory
}

Write-VisorCoreAgentLog "scheduled task agent started"

while ($true) {
    try {
        if (-not (Test-Path $configPath)) {
            Write-VisorCoreAgentLog "config missing"
            Start-Sleep -Seconds 60
            continue
        }

        $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
        $portal = [string] $config.portal
        if ([string]::IsNullOrWhiteSpace($portal)) {
            $portal = "https://hyper.visorcore.com"
        }

        $inventory = Get-VisorCoreInventory

        $payload = @{
            workspace = [string] $config.workspace
            region = [string] $config.region
            computer_name = [string] $config.computer_name
            user_name = [string] $config.user_name
            hyperv_module_available = [bool] $config.hyperv_module_available
            require_mfa = [bool] $config.require_mfa
            service_status = "scheduled_task_running"
            inventory = $inventory
        }
        $body = $payload | ConvertTo-Json -Depth 10

        $response = Invoke-RestMethod -Uri ($portal.TrimEnd("/") + "/api/agent/checkin") -Method Post -Body $body -ContentType "application/json" -UserAgent "curl/8.0" -ErrorAction Stop
        Write-VisorCoreAgentLog "check-in ok"

        if ($response.uninstall_service -eq $true -or $response.uninstall_agent -eq $true) {
            try {
                $payload.service_status = "removed"
                $payload.uninstall_confirmed = $true
                $finalBody = $payload | ConvertTo-Json -Depth 10
                Invoke-RestMethod -Uri ($portal.TrimEnd("/") + "/api/agent/checkin") -Method Post -Body $finalBody -ContentType "application/json" -UserAgent "curl/8.0" -ErrorAction Stop | Out-Null
                Write-VisorCoreAgentLog "uninstall confirmation sent"
            } catch {
                Write-VisorCoreAgentLog ("uninstall confirmation failed: " + $_.Exception.Message)
            }
            Write-VisorCoreAgentLog "uninstall requested; unregistering scheduled task"
            try {
                Unregister-ScheduledTask -TaskPath "\VisorCore\" -TaskName "Hyper Agent" -Confirm:$false -ErrorAction SilentlyContinue
            } catch {}
            break
        }
    } catch {
        Write-VisorCoreAgentLog ("check-in failed: " + $_.Exception.Message)
    }

    Start-Sleep -Seconds 60
}

Write-VisorCoreAgentLog "scheduled task agent stopped"
'@

    Set-Content -Path $agentPath -Value $agentScript -Encoding UTF8

    try {
        $legacyServices = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -in @("VisorCoreHyperAgent", "VisorCore Hyper Agent") -or $_.DisplayName -like "VisorCore*Hyper*Agent*"
        }
        foreach ($legacyService in @($legacyServices)) {
            if ($legacyService.State -eq "Running") {
                Invoke-CimMethod -InputObject $legacyService -MethodName StopService -ErrorAction SilentlyContinue | Out-Null
                Start-Sleep -Seconds 2
            }
            Invoke-CimMethod -InputObject $legacyService -MethodName Delete -ErrorAction SilentlyContinue | Out-Null
        }
        Get-ChildItem -Path $InstallRoot -Filter "*.exe" -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like "*VisorCore*" -or $_.Name -like "*HyperAgent*"
        } | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "Legacy VisorCore agent cleanup could not complete: $($_.Exception.Message)"
    }

    try {
        $existing = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) {
            Stop-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    } catch {}

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy RemoteSigned -File `"$agentPath`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName -TaskPath $taskPath

    $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath
    return [PSCustomObject] @{
        TaskName = $taskName
        TaskPath = $taskPath
        Script = $agentPath
        Log = $logPath
        State = $task.State
    }
}

function Register-VisorCoreHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Workspace,

        [Parameter(Mandatory = $false)]
        [string] $Region = "us-central",

        [Parameter(Mandatory = $false)]
        [switch] $RequireMfa,

        [Parameter(Mandatory = $false)]
        [string] $Portal = "https://hyper.visorcore.com"
    )

    if (-not (Test-VisorCoreAdministrator)) {
        throw "Run PowerShell as Administrator, then run Register-VisorCoreHost again."
    }

    $installRoot = Join-Path $env:ProgramData "VisorCore\Agent"
    $configPath = Join-Path $installRoot "host-registration.json"
    if (-not (Test-Path $installRoot)) {
        New-Item -Path $installRoot -ItemType Directory -Force | Out-Null
    }

    $hyperVAvailable = $false
    try {
        $module = Get-Module -ListAvailable -Name Hyper-V | Select-Object -First 1
        if ($null -ne $module) {
            Import-Module Hyper-V -ErrorAction Stop
            $hyperVAvailable = $true
        }
    } catch {
        $hyperVAvailable = $false
    }

    $hostInfo = @{
        workspace = $Workspace
        region = $Region
        portal = $Portal
        require_mfa = [bool] $RequireMfa
        computer_name = $env:COMPUTERNAME
        user_name = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        hyperv_module_available = $hyperVAvailable
        registered_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        agent_status = "PendingPortalApproval"
    }

    $hostInfo | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath -Encoding UTF8

    $portalRequest = $null
    try {
        $registerUri = $Portal.TrimEnd("/") + "/api/hosts/register"
        $jsonBody = $hostInfo | ConvertTo-Json -Depth 5
        $portalRequest = Invoke-RestMethod -Uri $registerUri -Method Post -Body $jsonBody -ContentType "application/json" -UserAgent "curl/8.0" -ErrorAction Stop
        if (-not $portalRequest.success) {
            throw ($portalRequest.message | Out-String)
        }
    } catch {
        Write-Warning "The host was configured locally, but VisorCore Hyper did not receive the portal approval request: $($_.Exception.Message)"
    }

    $taskInfo = $null
    try {
        $taskInfo = Install-VisorCoreAgentTask -InstallRoot $installRoot
    } catch {
        Write-Warning "The portal request was created, but the background scheduled task could not be installed: $($_.Exception.Message)"
    }

    Write-Host ""
    Write-Host "VisorCore host bootstrap complete." -ForegroundColor Green
    Write-Host "Workspace: $Workspace"
    Write-Host "Region: $Region"
    Write-Host "Config: $configPath"
    if ($null -ne $portalRequest -and $portalRequest.success) {
        Write-Host "Portal request: received" -ForegroundColor Green
        if ($portalRequest.host.id) {
            Write-Host "Request ID: $($portalRequest.host.id)"
        }
    } else {
        Write-Host "Portal request: not received" -ForegroundColor Yellow
    }
    if ($hyperVAvailable) {
        Write-Host "Hyper-V PowerShell module: detected" -ForegroundColor Green
    } else {
        Write-Host "Hyper-V PowerShell module: not detected on this host" -ForegroundColor Yellow
    }
    if ($null -ne $taskInfo) {
        Write-Host "Agent scheduled task: $($taskInfo.TaskPath)$($taskInfo.TaskName) $($taskInfo.State)" -ForegroundColor Green
        Write-Host "Agent script: $($taskInfo.Script)"
        Write-Host "Agent log: $($taskInfo.Log)"
    } else {
        Write-Host "Agent scheduled task: not installed" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Next step: return to VisorCore Hyper. A pending host approval should appear in the Hosts tab."
    Write-Host "The background scheduled task checks in every 60 seconds. Secure token exchange and signed remote command execution will be handled by the next agent hardening release."

    return [PSCustomObject] $hostInfo
}

Write-Host "VisorCore Hyper bootstrap loaded." -ForegroundColor Cyan
Write-Host "Run Register-VisorCoreHost -Workspace `"your_workspace`" -Region `"us-central`" -RequireMfa to register this host."
