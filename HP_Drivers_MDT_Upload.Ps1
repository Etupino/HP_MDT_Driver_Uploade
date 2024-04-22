# Script Variables 
$scriptName = "MDT HP Driverpack Download"
$OS = "Win10" # [ValidateSet("Win10", "Win11")]
$OSVER = "22H2" # [ValidateSet("22H2", "23H2")]
$LogFile = "$PSScriptRoot\MDTDriverPackDownload.log"
$DownloadDir = Read-Host "Enter the download directory (e.g., C:\Driversource\softpaqs)"
$ExtractedDir = Read-Host "Enter the directory for extracted drivers (e.g., C:\driversource\Extracted)"
$MDTModule = Read-Host "Enter the path to MDT module (e.g., C:\Program Files\Microsoft Deployment Toolkit\bin\MicrosoftDeploymentToolkit.psd1)"
$deploymentshare = " # Read-Host "Enter the deployment share path (e.g.\\DeploymentShare\g$\WinBase10)"

#Reset Vars
$DriverPack = ""
$Model = ""

#region: CMTraceLog Function formats logging in CMTrace style
function CMTraceLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $Message,

        [Parameter(Mandatory = $false)]
        $ErrorMessage,

        [Parameter(Mandatory = $false)]
        $Component = "HP BIOS Downloader",

        [Parameter(Mandatory = $false)]
        [int]$Type,

        [Parameter(Mandatory = $true)]
        $LogFile
    )
    <#
    Type: 1 = Normal, 2 = Warning (yellow), 3 = Error (red)
    #>
    $Time = Get-Date -Format "HH:mm:ss.ffffff"
    $Date = Get-Date -Format "MM-dd-yyyy"

    if ($ErrorMessage -ne $null) { $Type = 3 }
    if ($Component -eq $null) { $Component = " " }
    if ($Type -eq $null) { $Type = 1 }

    $LogMessage = "<![LOG[$Message $ErrorMessage" + "]LOG]!><time=`"$Time`" date=`"$Date`" component=`"$Component`" context=`"`" type=`"$Type`" thread=`"`" file=`"`">"
    $LogMessage | Out-File -Append -Encoding UTF8 -FilePath $LogFile
}

function Get-FolderSize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        $Path,
        [ValidateSet("KB", "MB", "GB")]
        $Units = "MB"
    )
    if ((Test-Path $Path) -and (Get-Item $Path).PSIsContainer) {
        $Measure = Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
        $Sum = $Measure.Sum / "1$Units"
        [pscustomobject]@{
            "Path" = $Path
            "Size($Units)" = $Sum
        }
    }
}

function Get-HPModelsTable {
    [CmdletBinding()]
    param(
        [int]$NumberOfDevices
    )

    $HPModelsTable = @()

    for ($i = 1; $i -le $NumberOfDevices; $i++) {
        $Model = Read-Host "Enter the HP Model for Device $i"
        $ProdCode = Read-Host "Enter the Product Code for Device $i"
        $HPModelsTable += @{
            "ProdCode" = $ProdCode
            "Model" = $Model
        }
    }

    return $HPModelsTable
}

# Prompt user for the number of devices
$NumberOfDevices = Read-Host "Enter the number of devices"

# Get the HP models table from user input
$HPModelsTable = Get-HPModelsTable -NumberOfDevices $NumberOfDevices

CMTraceLog -Message "Starting Script: $scriptName" -Type 1 -LogFile $LogFile
Write-Output "Starting Script: $scriptName"

Import-Module $MDTModule -Verbose

if (!(Get-PSDrive -LiteralName PSDeploymentshare -ErrorAction 'silentlycontinue')) {
    New-PSDrive -Name "PSDeploymentShare" -PSProvider MDTProvider -Root $deploymentshare
    Write-Host Adding MDT Deploymentshare
    CMTraceLog -Message "Adding $deploymentshare as a PSdrive" -Type 1 -LogFile $LogFile
}
else {
    Remove-PSDrive PSDeploymentshare
    Write-Host removing MDT Deploymentshare
    New-PSDrive -Name "PSDeploymentShare" -PSProvider MDTProvider -Root $deploymentshare
    Write-Host Re-adding MDT Deploymentshare
    CMTraceLog -Message "Adding $deploymentshare as a PSdrive" -Type 1 -LogFile $LogFile
}

foreach ($HPModel in $HPModelsTable) {
    Write-Output "Checking Model $($HPModel['Model']) Product Code $($HPModel['ProdCode']) for Driver Pack Updates"
    CMTraceLog -Message "Checking Model $($HPModel['Model']) Product Code $($HPModel['ProdCode']) for Driver Pack Updates" -Type 1 -LogFile $LogFile
    $SoftPaq = Get-SoftpaqList -platform $HPModel['ProdCode'] -os $OS -osver $OSVER
    $DriverPack = $SoftPaq | Where-Object { $_.category -eq 'Manageability - Driver Pack' }
    $DriverPack = $DriverPack | Where-Object { $_.Name -notmatch "Windows PE" }
    $DriverPack = $DriverPack | Where-Object { $_.Name -notmatch "WinPE" }
    $DownloadDriverPackRootArchiveFullPath = "$($DownloadDir)\$($HPModel['Model'])\$($DriverPack.Version)"
    $DownloadDriverPackExtractFullPath = "$($ExtractedDir)\$($HPModel['Model'])"
    $MDTTargetFolder = "PsDeploymentShare:\Out-of-Box Drivers\$($HPModel.Model)"

    if (!(Test-Path "$MDTTargetFolder")) {
        Write-Output "Drivers folder for $($HPModel.Model) does not exist. Uploading drivers to MDT..."
        CMTraceLog -Message "Drivers folder for $($HPModel.Model) does not exist. Uploading drivers to MDT..." -Type 1 -LogFile $LogFile
        
        # Create the target folder if it doesn't exist
        New-Item -Path "$MDTTargetFolder" -ItemType Directory -Force

        # Download and extract drivers
        try {
            if (-not (Test-Path $DownloadDriverPackRootArchiveFullPath)) { New-Item -Path $DownloadDriverPackRootArchiveFullPath -ItemType Directory -Force }
            $SaveAs = "$($DownloadDriverPackRootArchiveFullPath)\$($DriverPack.id).exe"
            Get-Softpaq -number $DriverPack.id -saveAs $SaveAs -overwrite yes
            if (Test-Path $DownloadDriverPackExtractFullPath) { Remove-Item -Path $DownloadDriverPackExtractFullPath -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item $DownloadDriverPackExtractFullPath -ItemType Directory -Force

            $TempDir = "$($env:temp)\SPExtract\$($HPModel['ProdCode'])"
            if (Test-Path $TempDir) { Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item $TempDir -ItemType Directory -Force
            Start-Process $SaveAs -ArgumentList "-e -s -f$($TempDir)" -Wait
            $CopyFromDir = (Get-ChildItem -Path ((Get-ChildItem -Path $TempDir -Directory).FullName) -Directory).FullName
            Copy-Item "$($CopyFromDir)\*" -Destination $DownloadDriverPackExtractFullPath -Force -Recurse
            Export-Clixml -InputObject $DriverPack -Path "$($DownloadDriverPackExtractFullPath)\DriverPackInfo.XML"
            if (Test-Path $TempDir) { Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        catch {
            Write-Error "Error downloading or extracting drivers for $($HPModel['Model']): $_"
            CMTraceLog -Message "Error downloading or extracting drivers for $($HPModel['Model']): $_" -Type 3 -LogFile $LogFile
        }
    }
    else {
        $userChoice = Read-Host "The drivers folder for $($HPModel.Model) already exists. Do you want to upload drivers to the existing folder? (Y/N)"
        if ($userChoice -ne "Y" -and $userChoice -ne "y") {
            Write-Output "Exiting script..."
            return
        }
    }

    # Import drivers into the MDT target folder
    try {
        import-mdtdriver -Path "$MDTTargetFolder" -SourcePath "$DownloadDriverPackExtractFullPath" –Verbose
    }
    catch {
        Write-Error "Error importing drivers for $($HPModel['Model']): $_"
        CMTraceLog -Message "Error importing drivers for $($HPModel['Model']): $_" -Type 3 -LogFile $LogFile
    }
}

# Remove PSDeploymentshare PSdrive and exit script        
if (Get-PSDrive -LiteralName PSDeploymentshare -ErrorAction 'silentlycontinue') { Remove-PSDrive -Name "PSDeploymentShare" }
CMTraceLog -Message "Finished Script: $scriptName" -Type 1 -LogFile $LogFile
Write-Output "Finished Script: $scriptName"
