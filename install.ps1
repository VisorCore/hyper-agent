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

function Test-VisorCoreInstallerPayload {
    param([string] $Content)
    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $false
    }
    $trimmed = $Content.TrimStart()
    $htmlTag = "<" + "html"
    $doctype = "<!" + "DOCTYPE"
    if ($trimmed.StartsWith($htmlTag, [StringComparison]::OrdinalIgnoreCase) -or $trimmed.StartsWith($doctype, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    return $trimmed.StartsWith("# VisorCore Hyper bootstrap installer", [StringComparison]::OrdinalIgnoreCase)
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

$script:VisorCoreConsoleSessions = @{}
$script:VisorCoreLastConsoleFrames = @{}

function Get-VisorCoreVmSystem {
    param([string] $VmName)
    return Get-WmiObject -Namespace root\virtualization\v2 -Class Msvm_ComputerSystem -ErrorAction Stop |
        Where-Object { $_.ElementName -eq $VmName } |
        Select-Object -First 1
}

function Get-VisorCoreVmSettingData {
    param([string] $VmName)
    $vmSystem = Get-VisorCoreVmSystem -VmName $VmName
    if ($null -eq $vmSystem) { throw "VM '$VmName' was not found for console capture." }
    $settings = @($vmSystem.GetRelated("Msvm_VirtualSystemSettingData"))
    $setting = $settings |
        Where-Object { [string] $_.VirtualSystemIdentifier -eq [string] $vmSystem.Name -or [string] $_.ConfigurationID -eq [string] $vmSystem.Name } |
        Select-Object -First 1
    if ($null -eq $setting) {
        $setting = $settings | Select-Object -First 1
    }
    if ($null -eq $setting) { throw "Hyper-V setting data was not available for VM '$VmName'." }
    return $setting
}

function Get-VisorCoreVmKeyboard {
    param([string] $VmName)
    $vmSystem = Get-VisorCoreVmSystem -VmName $VmName
    if ($null -eq $vmSystem) { throw "VM '$VmName' was not found for console input." }
    $keyboard = $vmSystem.GetRelated("Msvm_Keyboard") | Select-Object -First 1
    if ($null -eq $keyboard) { throw "Hyper-V keyboard channel was not available for VM '$VmName'." }
    return $keyboard
}

function Send-VisorCoreVmConsoleText {
    param(
        [string] $VmName,
        [string] $Text
    )
    if ([string]::IsNullOrEmpty($Text)) { return }
    $keyboard = Get-VisorCoreVmKeyboard -VmName $VmName
    $keyboard.TypeText($Text) | Out-Null
}

function Send-VisorCoreVmConsoleCtrlAltDel {
    param([string] $VmName)
    $keyboard = Get-VisorCoreVmKeyboard -VmName $VmName
    $keyboard.TypeCtrlAltDel() | Out-Null
}

function Get-VisorCoreVmConsoleFrame {
    param([string] $VmName)
    Add-Type -AssemblyName "System.Drawing" -ErrorAction SilentlyContinue
    $vmSystem = Get-VisorCoreVmSystem -VmName $VmName
    if ($null -eq $vmSystem) { throw "VM '$VmName' was not found for console capture." }
    $vmSetting = Get-VisorCoreVmSettingData -VmName $VmName
    $video = $vmSystem.GetRelated("Msvm_VideoHead") | Select-Object -First 1
    $sourceWidth = 1024
    $sourceHeight = 768
    try {
        if ($video -and $video.CurrentHorizontalResolution[0] -gt 0 -and $video.CurrentVerticalResolution[0] -gt 0) {
            $sourceWidth = [int] $video.CurrentHorizontalResolution[0]
            $sourceHeight = [int] $video.CurrentVerticalResolution[0]
        }
    } catch {}
    $targetWidth = [Math]::Min($sourceWidth, 1280)
    $targetHeight = [Math]::Max(1, [int] [Math]::Round(($sourceHeight / [double] $sourceWidth) * $targetWidth))
    $vmms = Get-WmiObject -Namespace root\virtualization\v2 -Class Msvm_VirtualSystemManagementService -ErrorAction Stop | Select-Object -First 1
    $thumbnail = $vmms.GetVirtualSystemThumbnailImage($vmSetting, $targetWidth, $targetHeight)
    if ($null -eq $thumbnail -or [int] $thumbnail.ReturnValue -ne 0) {
        throw "Hyper-V thumbnail capture returned code $([int] $thumbnail.ReturnValue) for VM '$VmName'."
    }
    $image = $thumbnail.ImageData
    if ($null -eq $image -or $image.Length -le 0) { throw "Hyper-V did not return a console frame for VM '$VmName'." }
    $bitmap = New-Object System.Drawing.Bitmap -ArgumentList $targetWidth, $targetHeight, ([System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
    $rect = New-Object System.Drawing.Rectangle 0, 0, $targetWidth, $targetHeight
    $bmpData = $bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadWrite, [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
    try {
        [System.Runtime.InteropServices.Marshal]::Copy($image, 0, $bmpData.Scan0, ($bmpData.Stride * $bmpData.Height))
    } finally {
        $bitmap.UnlockBits($bmpData)
    }
    $stream = New-Object System.IO.MemoryStream
    try {
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        return @{
            mime = "image/jpeg"
            data = [Convert]::ToBase64String($stream.ToArray())
            width = $targetWidth
            height = $targetHeight
            captured_at = (Get-Date).ToUniversalTime().ToString("o")
        }
    } finally {
        $stream.Dispose()
        $bitmap.Dispose()
    }
}

function Get-VisorCoreInventory {
    $inventory = @{
        agent_version = "0.9.3"
        synced_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        host = @{}
        console = @{
            installed = $true
            enabled = $true
            mode = "portal_relay"
            display_capture = "hyperv_thumbnail"
            keyboard_input = "msvm_keyboard"
            transport = "outbound_tls_polling"
            features = @("display_stream", "keyboard_text", "ctrl_alt_del", "audit_trail")
        }
        storage = @{
            total_gb = 0
            free_gb = 0
            used_gb = 0
        }
        volumes = @()
        network = @{
            rx_mbps = 0
            tx_mbps = 0
            rx_bytes_per_sec = 0
            tx_bytes_per_sec = 0
            adapters = @()
        }
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
        $processors = @()
        try { $processors = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue) } catch {}
        $logicalProcessors = 0
        $physicalProcessors = 0
        $cpuLoadTotal = 0
        $cpuLoadSamples = 0
        foreach ($processor in $processors) {
            try { $logicalProcessors += [int] $processor.NumberOfLogicalProcessors } catch {}
            $physicalProcessors += 1
            if ($null -ne $processor.LoadPercentage) {
                $cpuLoadTotal += [double] $processor.LoadPercentage
                $cpuLoadSamples += 1
            }
        }
        if ($logicalProcessors -le 0 -and $computer) {
            try { $logicalProcessors = [int] $computer.NumberOfLogicalProcessors } catch {}
        }
        if ($physicalProcessors -le 0 -and $computer) {
            try { $physicalProcessors = [int] $computer.NumberOfProcessors } catch {}
        }
        $inventory.host = @{
            name = $env:COMPUTERNAME
            os = if ($os) { [string] $os.Caption } else { "" }
            version = if ($os) { [string] $os.Version } else { "" }
            uptime_seconds = if ($os -and $os.LastBootUpTime) { [int] ((Get-Date) - $os.LastBootUpTime).TotalSeconds } else { 0 }
            total_memory_gb = if ($computer) { ConvertTo-VisorCoreGb $computer.TotalPhysicalMemory } else { 0 }
            logical_processor_count = $logicalProcessors
            processor_count = $physicalProcessors
            cpu_load_percent = if ($cpuLoadSamples -gt 0) { [math]::Round(($cpuLoadTotal / $cpuLoadSamples), 0) } else { 0 }
        }
    } catch {}

    try {
        $volumes = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue | Select-Object -First 80)
        $totalGb = 0
        $freeGb = 0
        foreach ($volume in $volumes) {
            $sizeGb = ConvertTo-VisorCoreGb $volume.Size
            $volumeFreeGb = ConvertTo-VisorCoreGb $volume.FreeSpace
            $totalGb += [double] $sizeGb
            $freeGb += [double] $volumeFreeGb
            $inventory.volumes += @{
                device_id = [string] $volume.DeviceID
                name = [string] $volume.VolumeName
                file_system = [string] $volume.FileSystem
                size_gb = $sizeGb
                free_gb = $volumeFreeGb
                used_gb = [math]::Round(([double] $sizeGb - [double] $volumeFreeGb), 2)
            }
        }
        $inventory.storage = @{
            total_gb = [math]::Round($totalGb, 2)
            free_gb = [math]::Round($freeGb, 2)
            used_gb = [math]::Round(($totalGb - $freeGb), 2)
        }
    } catch {}

    try {
        $samples = @((Get-Counter -Counter "\Network Interface(*)\Bytes Received/sec","\Network Interface(*)\Bytes Sent/sec" -ErrorAction SilentlyContinue).CounterSamples)
        $adapterMap = @{}
        foreach ($sample in $samples) {
            $path = [string] $sample.Path
            $adapter = ""
            $direction = ""
            if ($path -match "\\network interface\((.+)\)\\bytes received/sec$") {
                $adapter = $Matches[1]
                $direction = "rx"
            } elseif ($path -match "\\network interface\((.+)\)\\bytes sent/sec$") {
                $adapter = $Matches[1]
                $direction = "tx"
            }
            if ([string]::IsNullOrWhiteSpace($adapter)) { continue }
            $adapterLower = $adapter.ToLowerInvariant()
            if ($adapterLower -eq "_total" -or $adapterLower -like "*loopback*" -or $adapterLower -like "*isatap*" -or $adapterLower -like "*teredo*") { continue }
            if (-not $adapterMap.ContainsKey($adapter)) {
                $adapterMap[$adapter] = @{ name = $adapter; rx_bytes_per_sec = 0; tx_bytes_per_sec = 0; rx_mbps = 0; tx_mbps = 0 }
            }
            if ($direction -eq "rx") {
                $adapterMap[$adapter].rx_bytes_per_sec = [math]::Round([double] $sample.CookedValue, 2)
            } elseif ($direction -eq "tx") {
                $adapterMap[$adapter].tx_bytes_per_sec = [math]::Round([double] $sample.CookedValue, 2)
            }
        }
        $rxBytes = 0
        $txBytes = 0
        foreach ($adapterName in $adapterMap.Keys) {
            $adapterStats = $adapterMap[$adapterName]
            $adapterStats.rx_mbps = [math]::Round((([double] $adapterStats.rx_bytes_per_sec * 8) / 1MB), 2)
            $adapterStats.tx_mbps = [math]::Round((([double] $adapterStats.tx_bytes_per_sec * 8) / 1MB), 2)
            $rxBytes += [double] $adapterStats.rx_bytes_per_sec
            $txBytes += [double] $adapterStats.tx_bytes_per_sec
            $inventory.network.adapters += $adapterStats
        }
        $inventory.network.rx_bytes_per_sec = [math]::Round($rxBytes, 2)
        $inventory.network.tx_bytes_per_sec = [math]::Round($txBytes, 2)
        $inventory.network.rx_mbps = [math]::Round((($rxBytes * 8) / 1MB), 2)
        $inventory.network.tx_mbps = [math]::Round((($txBytes * 8) / 1MB), 2)
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

function Invoke-VisorCoreCommand {
    param($Command)

    $result = @{
        id = [string] $Command.id
        action = [string] $Command.action
        success = $false
        status = "failed"
        message = ""
        completed_at = (Get-Date).ToUniversalTime().ToString("o")
    }

    try {
        Import-Module Hyper-V -ErrorAction Stop
        $action = [string] $Command.action
        $targetName = [string] $Command.target_name
        $options = $Command.options
        if ($null -eq $options) {
            $options = @{}
        }
        if ([string]::IsNullOrWhiteSpace($targetName)) {
            throw "Command target is missing."
        }

        switch ($action) {
            "agent.update" {
                $installerUri = "https://raw.githubusercontent.com/VisorCore/hyper-agent/main/install.ps1"
                $installer = (Invoke-WebRequest -Uri $installerUri -UseBasicParsing -UserAgent "curl/8.0" -ErrorAction Stop).Content
                if (-not (Test-VisorCoreInstallerPayload -Content $installer)) {
                    throw "Installer download returned HTML instead of PowerShell."
                }
                [scriptblock]::Create($installer) | Out-Null
                $updaterPath = Join-Path $root "update-agent.ps1"
                $updater = @"
`$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
`$installer = (Invoke-WebRequest -Uri "$installerUri" -UseBasicParsing -UserAgent "curl/8.0").Content
`$trimmed = `$installer.TrimStart()
`$htmlTag = "<" + "html"
`$doctype = "<!" + "DOCTYPE"
if ([string]::IsNullOrWhiteSpace(`$installer) -or `$trimmed.StartsWith(`$htmlTag, [StringComparison]::OrdinalIgnoreCase) -or `$trimmed.StartsWith(`$doctype, [StringComparison]::OrdinalIgnoreCase)) { throw "Installer download returned HTML instead of PowerShell." }
Invoke-Expression `$installer
Install-VisorCoreAgentTask -InstallRoot "$root" | Out-Null
"@
                Set-Content -Path $updaterPath -Value $updater -Encoding UTF8
                Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy RemoteSigned -File `"$updaterPath`"" -WindowStyle Hidden
                $result.message = "Hyper Agent update verified and launched from GitHub. The host will report the new version after the scheduled task restarts."
            }
            "console.prepare" {
                $sessionId = [string] $options.session_id
                if ([string]::IsNullOrWhiteSpace($sessionId)) { throw "Console session ID is required." }
                $expiresAt = [string] $options.expires_at
                if ([string]::IsNullOrWhiteSpace($expiresAt)) {
                    $expiresAt = (Get-Date).ToUniversalTime().AddMinutes(10).ToString("o")
                }
                try { Set-VMHost -EnableEnhancedSessionMode $true -ErrorAction SilentlyContinue | Out-Null } catch {}
                $script:VisorCoreConsoleSessions[$sessionId] = @{
                    session_id = $sessionId
                    vm_name = $targetName
                    expires_at = $expiresAt
                }
                $script:VisorCoreLastConsoleFrames[$sessionId] = [datetime]::MinValue
                $result.message = "Console relay prepared for VM '$targetName'."
            }
            "console.type_text" {
                Send-VisorCoreVmConsoleText -VmName $targetName -Text ([string] $options.text)
                $result.message = "Console text sent to VM '$targetName'."
            }
            "console.ctrl_alt_del" {
                Send-VisorCoreVmConsoleCtrlAltDel -VmName $targetName
                $result.message = "Ctrl+Alt+Del sent to VM '$targetName'."
            }
            "vm.start" {
                Start-VM -Name $targetName -ErrorAction Stop | Out-Null
                $result.message = "VM '$targetName' started."
            }
            "vm.stop" {
                Stop-VM -Name $targetName -Force -ErrorAction Stop | Out-Null
                $result.message = "VM '$targetName' stopped."
            }
            "vm.shutdown" {
                Stop-VM -Name $targetName -Shutdown -ErrorAction Stop | Out-Null
                $result.message = "Guest shutdown requested for VM '$targetName'."
            }
            "vm.turn_off" {
                Stop-VM -Name $targetName -TurnOff -Force -ErrorAction Stop | Out-Null
                $result.message = "VM '$targetName' powered off."
            }
            "vm.restart" {
                Restart-VM -Name $targetName -Force -ErrorAction Stop | Out-Null
                $result.message = "VM '$targetName' restarted."
            }
            "vm.pause" {
                Suspend-VM -Name $targetName -ErrorAction Stop | Out-Null
                $result.message = "VM '$targetName' paused."
            }
            "vm.resume" {
                Resume-VM -Name $targetName -ErrorAction Stop | Out-Null
                $result.message = "VM '$targetName' resumed."
            }
            "vm.save" {
                Save-VM -Name $targetName -ErrorAction Stop | Out-Null
                $result.message = "VM '$targetName' saved."
            }
            "vm.checkpoint" {
                $checkpointName = [string] $options.name
                if ([string]::IsNullOrWhiteSpace($checkpointName)) {
                    $checkpointName = "VisorCore " + (Get-Date).ToString("yyyy-MM-dd HHmmss")
                }
                Checkpoint-VM -Name $targetName -SnapshotName $checkpointName -ErrorAction Stop | Out-Null
                $result.message = "Checkpoint '$checkpointName' created for VM '$targetName'."
            }
            "vm.rename" {
                $newName = [string] $options.new_name
                if ([string]::IsNullOrWhiteSpace($newName)) { throw "New VM name is required." }
                Rename-VM -Name $targetName -NewName $newName -ErrorAction Stop | Out-Null
                $result.message = "VM '$targetName' renamed to '$newName'."
            }
            "vm.set_notes" {
                $notes = [string] $options.notes
                Set-VM -Name $targetName -Notes $notes -ErrorAction Stop | Out-Null
                $result.message = "VM '$targetName' notes updated."
            }
            "vm.set_cpu" {
                $count = [int] $options.count
                if ($count -lt 1 -or $count -gt 256) { throw "CPU count must be between 1 and 256." }
                Set-VMProcessor -VMName $targetName -Count $count -ErrorAction Stop | Out-Null
                $result.message = "VM '$targetName' CPU count set to $count."
            }
            "vm.set_memory" {
                $startupGb = [double] $options.startup_gb
                if ($startupGb -le 0 -or $startupGb -gt 4096) { throw "Startup memory must be between 1 GB and 4096 GB." }
                Set-VMMemory -VMName $targetName -StartupBytes ([int64]($startupGb * 1GB)) -ErrorAction Stop | Out-Null
                $result.message = "VM '$targetName' startup memory set to $startupGb GB."
            }
            "vm.export" {
                $path = [string] $options.path
                if ([string]::IsNullOrWhiteSpace($path)) { throw "Export path is required." }
                Export-VM -Name $targetName -Path $path -ErrorAction Stop | Out-Null
                $result.message = "VM '$targetName' exported to '$path'."
            }
            "vm.move_storage" {
                $path = [string] $options.path
                if ([string]::IsNullOrWhiteSpace($path)) { throw "Destination storage path is required." }
                Move-VMStorage -VMName $targetName -DestinationStoragePath $path -ErrorAction Stop | Out-Null
                $result.message = "VM '$targetName' storage moved to '$path'."
            }
            "checkpoint.delete" {
                $vmName = [string] $options.vm_name
                if ([string]::IsNullOrWhiteSpace($vmName)) { throw "VM name is required for checkpoint deletion." }
                Remove-VMCheckpoint -VMName $vmName -Name $targetName -Confirm:$false -ErrorAction Stop
                $result.message = "Checkpoint '$targetName' deleted from VM '$vmName'."
            }
            "checkpoint.apply" {
                $vmName = [string] $options.vm_name
                if ([string]::IsNullOrWhiteSpace($vmName)) { throw "VM name is required for checkpoint restore." }
                $checkpoint = Get-VMCheckpoint -VMName $vmName -Name $targetName -ErrorAction Stop
                Restore-VMCheckpoint -VMCheckpoint $checkpoint -Confirm:$false -ErrorAction Stop
                $result.message = "Checkpoint '$targetName' applied to VM '$vmName'."
            }
            "switch.rename" {
                $newName = [string] $options.new_name
                if ([string]::IsNullOrWhiteSpace($newName)) { throw "New switch name is required." }
                Rename-VMSwitch -Name $targetName -NewName $newName -ErrorAction Stop | Out-Null
                $result.message = "Switch '$targetName' renamed to '$newName'."
            }
            "switch.set_notes" {
                $notes = [string] $options.notes
                Set-VMSwitch -Name $targetName -Notes $notes -ErrorAction Stop | Out-Null
                $result.message = "Switch '$targetName' notes updated."
            }
            "disk.resize" {
                $sizeGb = [double] $options.size_gb
                if ($sizeGb -le 0 -or $sizeGb -gt 65536) { throw "Disk size must be between 1 GB and 65536 GB." }
                Resize-VHD -Path $targetName -SizeBytes ([int64]($sizeGb * 1GB)) -ErrorAction Stop | Out-Null
                $result.message = "Virtual disk resized to $sizeGb GB."
            }
            "disk.optimize" {
                Optimize-VHD -Path $targetName -Mode Full -ErrorAction Stop | Out-Null
                $result.message = "Virtual disk optimized."
            }
            default {
                throw "Command action '$action' is not supported by this agent."
            }
        }

        $result.success = $true
        $result.status = "succeeded"
    } catch {
        $result.success = $false
        $result.status = "failed"
        $result.message = $_.Exception.Message
    }

    return $result
}

function Invoke-VisorCoreCommandResponse {
    param(
        [string] $Portal,
        [hashtable] $Payload,
        $Response
    )

    if (-not $Response.commands) {
        return
    }

    $commandResults = @()
    foreach ($command in @($Response.commands)) {
        $commandResult = Invoke-VisorCoreCommand -Command $command
        $commandResults += $commandResult
        Write-VisorCoreAgentLog ("command " + $commandResult.id + " " + $commandResult.status + ": " + $commandResult.message)
    }

    if (@($commandResults).Count -le 0) {
        return
    }

    try {
        $resultPayload = @{}
        foreach ($key in $Payload.Keys) {
            $resultPayload[$key] = $Payload[$key]
        }
        $resultPayload["inventory"] = Get-VisorCoreInventory
        $resultPayload["command_results"] = $commandResults
        $resultBody = $resultPayload | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Uri ($Portal.TrimEnd("/") + "/api/agent/checkin") -Method Post -Body $resultBody -ContentType "application/json" -UserAgent "curl/8.0" -ErrorAction Stop | Out-Null
        Write-VisorCoreAgentLog "command results posted"
    } catch {
        Write-VisorCoreAgentLog ("command result post failed: " + $_.Exception.Message)
    }
}

function Invoke-VisorCoreConsoleStreams {
    param(
        [string] $Portal,
        [hashtable] $Payload
    )

    if ($script:VisorCoreConsoleSessions.Count -le 0) {
        return
    }

    $nowUtc = (Get-Date).ToUniversalTime()
    foreach ($sessionId in @($script:VisorCoreConsoleSessions.Keys)) {
        $session = $script:VisorCoreConsoleSessions[$sessionId]
        try {
            $expires = [datetime] $session.expires_at
            if ($expires.ToUniversalTime() -lt $nowUtc) {
                $script:VisorCoreConsoleSessions.Remove($sessionId)
                $script:VisorCoreLastConsoleFrames.Remove($sessionId)
                continue
            }
        } catch {
            $script:VisorCoreConsoleSessions.Remove($sessionId)
            $script:VisorCoreLastConsoleFrames.Remove($sessionId)
            continue
        }

        $lastFrame = [datetime]::MinValue
        if ($script:VisorCoreLastConsoleFrames.ContainsKey($sessionId)) {
            $lastFrame = [datetime] $script:VisorCoreLastConsoleFrames[$sessionId]
        }
        if (($nowUtc - $lastFrame).TotalMilliseconds -lt 900) {
            continue
        }
        $script:VisorCoreLastConsoleFrames[$sessionId] = $nowUtc

        $framePayload = @{}
        foreach ($key in $Payload.Keys) {
            $framePayload[$key] = $Payload[$key]
        }
        $framePayload["session_id"] = $sessionId
        $framePayload["vm_name"] = [string] $session.vm_name

        try {
            $frame = Get-VisorCoreVmConsoleFrame -VmName ([string] $session.vm_name)
            $framePayload["status"] = "streaming"
            $framePayload["mime"] = $frame.mime
            $framePayload["frame_data"] = $frame.data
            $framePayload["width"] = $frame.width
            $framePayload["height"] = $frame.height
            $framePayload["captured_at"] = $frame.captured_at
            $framePayload["message"] = "Console frame captured."
        } catch {
            $framePayload["status"] = "waiting"
            $framePayload["message"] = $_.Exception.Message
        }

        try {
            $frameBody = $framePayload | ConvertTo-Json -Depth 8
            Invoke-RestMethod -Uri ($Portal.TrimEnd("/") + "/api/console-frame") -Method Post -Body $frameBody -ContentType "application/json" -UserAgent "curl/8.0" -ErrorAction Stop | Out-Null
        } catch {
            Write-VisorCoreAgentLog ("console frame post failed: " + $_.Exception.Message)
        }
    }
}

Write-VisorCoreAgentLog "scheduled task agent started"

$inventorySyncSeconds = 10
$commandPollSeconds = 1
$lastInventorySyncUtc = [datetime]::MinValue

while ($true) {
    try {
        if (-not (Test-Path $configPath)) {
            Write-VisorCoreAgentLog "config missing"
            Start-Sleep -Seconds 10
            continue
        }

        $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
        $portal = [string] $config.portal
        if ([string]::IsNullOrWhiteSpace($portal)) {
            $portal = "https://hyper.visorcore.com"
        }

        $payload = @{
            workspace = [string] $config.workspace
            region = [string] $config.region
            computer_name = [string] $config.computer_name
            user_name = [string] $config.user_name
            hyperv_module_available = [bool] $config.hyperv_module_available
            require_mfa = [bool] $config.require_mfa
            service_status = "scheduled_task_running"
        }

        $nowUtc = (Get-Date).ToUniversalTime()
        $runInventorySync = (($nowUtc - $lastInventorySyncUtc).TotalSeconds -ge $inventorySyncSeconds)

        if ($runInventorySync) {
            $payload["inventory"] = Get-VisorCoreInventory
            $body = $payload | ConvertTo-Json -Depth 10
            $response = Invoke-RestMethod -Uri ($portal.TrimEnd("/") + "/api/agent/checkin") -Method Post -Body $body -ContentType "application/json" -UserAgent "curl/8.0" -ErrorAction Stop
            $lastInventorySyncUtc = $nowUtc
            Write-VisorCoreAgentLog "check-in ok"
        } else {
            $body = $payload | ConvertTo-Json -Depth 5
            $response = Invoke-RestMethod -Uri ($portal.TrimEnd("/") + "/api/agent/commands") -Method Post -Body $body -ContentType "application/json" -UserAgent "curl/8.0" -ErrorAction Stop
        }

        Invoke-VisorCoreCommandResponse -Portal $portal -Payload $payload -Response $response
        Invoke-VisorCoreConsoleStreams -Portal $portal -Payload $payload

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

    Start-Sleep -Seconds $commandPollSeconds
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

    $applyTaskName = "Hyper Agent Apply Update"
    $applyPath = Join-Path $InstallRoot "apply-agent-task.ps1"
    $applyStatusPath = Join-Path $InstallRoot "last-update.json"
    $applyScript = @"
`$ErrorActionPreference = "Continue"
`$taskName = "$taskName"
`$taskPath = "$taskPath"
`$applyTaskName = "$applyTaskName"
`$logPath = "$logPath"
`$statusPath = "$applyStatusPath"
function Write-ApplyLog {
    param([string] `$Message)
    try { Add-Content -Path `$logPath -Value ("{0} update {1}" -f (Get-Date).ToUniversalTime().ToString("o"), `$Message) } catch {}
}
Write-ApplyLog "apply task started"
Start-Sleep -Seconds 3
try { Stop-ScheduledTask -TaskPath `$taskPath -TaskName `$taskName -ErrorAction SilentlyContinue } catch { Write-ApplyLog ("stop failed: " + `$_.Exception.Message) }
Start-Sleep -Seconds 1
try { Unregister-ScheduledTask -TaskPath `$taskPath -TaskName `$taskName -Confirm:`$false -ErrorAction SilentlyContinue } catch { Write-ApplyLog ("unregister failed: " + `$_.Exception.Message) }
try {
    `$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument '-NoProfile -ExecutionPolicy RemoteSigned -File "$agentPath"'
    `$trigger = New-ScheduledTaskTrigger -AtStartup
    `$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    `$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName `$taskName -TaskPath `$taskPath -Action `$action -Trigger `$trigger -Principal `$principal -Settings `$settings -Force | Out-Null
    Start-ScheduledTask -TaskPath `$taskPath -TaskName `$taskName -ErrorAction Stop
    `$state = "Unknown"
    try { `$state = (Get-ScheduledTask -TaskPath `$taskPath -TaskName `$taskName -ErrorAction Stop).State } catch {}
    @{ success = `$true; version = "0.9.3"; state = [string] `$state; applied_at_utc = (Get-Date).ToUniversalTime().ToString("o") } | ConvertTo-Json -Depth 4 | Set-Content -Path `$statusPath -Encoding UTF8
    Write-ApplyLog ("main task started: " + `$state)
} catch {
    @{ success = `$false; version = "0.9.3"; message = `$_.Exception.Message; applied_at_utc = (Get-Date).ToUniversalTime().ToString("o") } | ConvertTo-Json -Depth 4 | Set-Content -Path `$statusPath -Encoding UTF8
    Write-ApplyLog ("apply failed: " + `$_.Exception.Message)
}
try { Unregister-ScheduledTask -TaskPath `$taskPath -TaskName `$applyTaskName -Confirm:`$false -ErrorAction SilentlyContinue } catch {}
"@
    Set-Content -Path $applyPath -Value $applyScript -Encoding UTF8
    $applyAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy RemoteSigned -File `"$applyPath`""
    $applyTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds(1))
    $applyPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    $applySettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $applyTaskName -TaskPath $taskPath -Action $applyAction -Trigger $applyTrigger -Principal $applyPrincipal -Settings $applySettings -Force | Out-Null
    Start-ScheduledTask -TaskName $applyTaskName -TaskPath $taskPath -ErrorAction Stop

    $task = $null
    try { $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop } catch {}
    return [PSCustomObject] @{
        TaskName = $taskName
        TaskPath = $taskPath
        Script = $agentPath
        Log = $logPath
        State = if ($null -ne $task) { $task.State } else { "UpdateQueued" }
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
    Write-Host "The background scheduled task checks inventory every 10 seconds, listens for commands every 1 second, and posts fresh inventory immediately after commands finish."

    return [PSCustomObject] $hostInfo
}

Write-Host "VisorCore Hyper bootstrap loaded." -ForegroundColor Cyan
Write-Host "Run Register-VisorCoreHost -Workspace `"your_workspace`" -Region `"us-central`" -RequireMfa to register this host."
