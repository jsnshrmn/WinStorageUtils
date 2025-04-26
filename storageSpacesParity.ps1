# intended to ease repetitive setup for Windows DAS using parity storage spaces
# See: https://wasteofserver.com/storage-spaces-with-parity-very-slow-writes-solved/
# See: https://storagespaceswarstories.com/storage-spaces-and-slow-parity-performance/#more-63

Import-Module BitsTransfer
Add-Type -AssemblyName System.Windows.Forms

$availablePools = Get-StoragePool -IsPrimordial $False -ErrorAction SilentlyContinue
if ($availablePools) {
    Write-Output "available pools"
    Write-Output $($availablePools | Out-String )
}

if (!($poolName = Read-Host "Storage pool name [Storage pool]")) { $poolName = "Storage pool" }

$confirm = Read-Host "create a new pool?"
if ($confirm -eq "y") {
    Get-VirtualDisk -StoragePool (Get-StoragePool -FriendlyName $poolName) | Remove-VirtualDisk -Confirm:$false -ErrorAction SilentlyContinue
    Remove-StoragePool -FriendlyName $poolName -Confirm:$false -ErrorAction SilentlyContinue
    $poolDisks = @()
    $availableDisks = (Get-PhysicalDisk -HealthStatus "Healthy" -CanPool $true | Sort-Object { [int] $_.DeviceId })
    foreach ($disk in $availableDisks) {
        Write-Host $($disk | Out-String)
        $confirm = Read-Host "add to pool?"
        if ($confirm -eq "y") {
            $poolDisks += ($disk)
        }
    }
    Write-Host $($poolDisks | Out-String)
    $confirm = Read-Host "create pool with the following disks?"
    Write-Host $($poolDisks | Out-String)
    if ($confirm -ne "y") {
        exit
    }
    New-StoragePool -FriendlyName $poolName -StorageSubsystemFriendlyName "Windows Storage*" -PhysicalDisks $poolDisks
}

[Int]$diskCount = (Get-PhysicalDisk -StoragePool (Get-StoragePool -FriendlyName "Storage pool")).length
if (!($spaceName = Read-Host "Storage space name [Storage space]")) { $spaceName = "Storage space" }
if (!([Int]$columns = Read-Host "Columns [$diskCount]")) { $columns = $diskCount }
if (!([Int]$redundancy = Read-Host "Redundancy [2]")) { $redundancy = 2 }

$ntfsSizes = @(4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048)
$alignedAus = @()
# @FIXME: just a guess based on observation; is there a way to query this from a resiliency settings object?
$minSize = 8 * ($columns - $redundancy)
foreach ($aus in $ntfsSizes) {
    $size = $aus / ($columns - $redundancy)
    if ($size -gt $minSize -and $size -lt $ntfsSizes[-1]) {
        $alignedAus += $size
    }
}
Write-Host "possible stripe sizes"
Write-Host $alignedAus
if (!([Int]$interleave = Read-Host "Stripe size (KiB) $($alignedAus[0])")) { $interleave = $($alignedAus[0]) }
$interleave = $interleave * 1024
$aus = ($columns - $redundancy) * $interleave

if (!($driveLetter = Read-Host "drive letter [D]")) { $driveLetter = "D" }
Remove-VirtualDisk -FriendlyName $spaceName -Confirm:$false -ErrorAction SilentlyContinue
New-VirtualDisk -StoragePoolFriendlyName $poolName -FriendlyName $spaceName -NumberOfColumns $columns -Interleave $interleave -ResiliencySettingName Parity -PhysicalDiskRedundancy $redundancy -UseMaximumSize | Initialize-Disk -PartitionStyle GPT -PassThru | New-Volume -FileSystem NTFS -AllocationUnitSize $aus -DriveLetter $driveLetter -FriendlyName 'DAS'

$confirm = Read-Host "benchmark write speed?"
if ($confirm -eq "y") {
    Write-Output "Please choose a test file for benchmarking"
    $fileBrowser = New-Object System.Windows.Forms.OpenFileDialog -Property @{ InitialDirectory = [Environment]::GetFolderPath('MyComputer') }
    $fileBrowser.ShowDialog()
    $source = $fileBrowser.FileName


    $fileMiB = ((Get-Item -Path $source).Length)/1024/1024
    $seconds = (Measure-Command { Start-BitsTransfer -Source $source -Destination "$($driveLetter):\" -Description "benchmark" -DisplayName "benchmark" }).TotalSeconds

    $rate = ($fileMiB/$seconds).ToString()
    Write-Output "write speed: $rate MiB/sec"
}
