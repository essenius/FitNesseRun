# Copyright 2018 Rik Essenius
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in 
# compliance with the License. You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License is
# distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and limitations under the License.

param([ValidateSet("Next","Sync","Ignore")][string]$VersionAction="Ignore", [switch]$NoTest, [switch]$NoPackage)

set-psdebug -strict

function ExitScript {
	exit 1
}

function Exit-WithError {
    param([string]$Message)
	Out-Log -Message $Message
	ExitScript
}

function Get-Version {
    param([string]$FilePath)
    $vssExtension = Get-Content -Raw -Path $FilePath | ConvertFrom-Json 
    return New-Object -TypeName System.Version -ArgumentList $vssExtension.Version
}

function Get-NextVersion {
    param([System.Version]$Version)
    return New-Object -TypeName System.Version -ArgumentList $Version.Major, $Version.Minor, ($Version.Build + 1)
}

function Invoke-Tests {
    param([string]$Folder, [string[]]$CodeCoverage, [string]$MainVersion)
	if ($MainVersion) {
		$basePath = Join-Path -Path $Folder -ChildPath "$($Folder)V$MainVersion"
	} else {
		$basePath = $Folder
	}
    if (!$CodeCoverage) { 
        $CodeCoverage = (Join-Path -Path $basePath -ChildPath "$(Split-Path -Path $Folder -Leaf).ps1")
    }

    $scripts = Join-Path -Path $basePath -ChildPath "*.tests.ps1"
    $testResult = invoke-Pester -PassThru -Script $scripts -CodeCoverage $CodeCoverage
    if ($testResult.FailedCount -gt 0) { 
        Exit-WithError -Message "$($basePath): $($testResult.FailedCount) test(s) failed"
    }
    if ($testResult.PassedCount -eq 0) {
        Exit-WithError -Message "$($basePath): no passing tests"
    }
    $coverage = $testResult.CodeCoverage
    $coveragePercentage = ($coverage.NumberOfCommandsExecuted / $coverage.NumberOfCommandsAnalyzed) * 100
    $missedCommands = $coverage.NumberOfCommandsAnalyzed - $coverage.NumberOfCommandsExecuted
    $coverageOK = ($missedCommands -le 5)
    if (!$coverageOK) {
        Exit-WithError -Message "$($Folder): Missed $missedCommands (more than 5) commands; code coverage is $coveragePercentage%"
    }
}

function Out-Log {
    param([string]$Message)
	$InformationPreference = "Continue"
	Write-Information $Message 
}

function Save-ToJson {
    param($Object, [string]$FilePath)
    $backupFilePath = [System.IO.Path]::ChangeExtension($FilePath,"backup")
    if (Test-Path -Path $backupFilePath) {
        Remove-Item -Path $backupFilePath
    }
    if (Test-Path -Path $FilePath) {
        Move-Item -Path $FilePath -Destination $backupFilePath
    }
    $Object | ConvertTo-Json -depth 10 | Out-File -FilePath $FilePath -Encoding "UTF8"
}

function Set-VersionInExtension {
    param([string]$FilePath, [System.Version]$Version)
    $extensionFile = $FilePath
    $vssExtension = Get-Content -Raw -Path $extensionFile | ConvertFrom-Json
    $vssExtension.Version = "$Version"
    Save-ToJson -Object $vssExtension -FilePath $extensionFile 
}

function Set-VersionInTask {
    param([string]$TaskName, [System.Version]$Version, [string]$MainVersion)
	if ($MainVersion) {
	    $task = (Split-Path -Path $TaskName -Leaf)
		$subFolder = "\$($task)V$MainVersion" 
	} else {
		$subFolder = ""
	}
    $taskFile = "$TaskName$subFolder\task.json"
    $task = Get-Content -Raw -Path $taskFile | ConvertFrom-Json
    $task.helpMarkDown = "Version $Version"
    $task.Version.Major = $Version.Major
    $task.Version.Minor = $Version.Minor
    $task.Version.Patch = $Version.Build
    Save-ToJson -Object $task -FilePath $taskFile
}

function Invoke-Tfx {
    param()
    tfx extension create --manifest-globs vss-extension.json --output-path Archive
}

function MainHelper {
    param([string]$VersionAction, [bool]$NoTest, [bool]$NoPackage)
	$mainVersion = 1
    if (!$NoTest) {
        Invoke-Tests -Folder "Common" -CodeCoverage "Common\CommonFunctions.psm1"
        Invoke-Tests -Folder "FitNesseConfigure" -MainVersion $mainVersion
        Invoke-Tests -Folder "FitNesseRun" -MainVersion $mainVersion
    }
    $version = Get-Version -FilePath "vss-extension.json"
    Out-Log -Message "Current version: $version"
    if ($VersionAction -ne "Ignore") {        
        if ($VersionAction -eq "Next") {
            $versionToApply = Get-NextVersion -Version $version
        } else {
            $versionToApply = $version
        }
        Set-VersionInExtension -FilePath "vss-extension.json" -Version $versionToApply
        Set-VersionInTask -TaskName "FitNesseConfigure" -Version $versionToApply -MainVersion $mainVersion
        Set-VersionInTask -TaskName "FitNesseRun" -Version $versionToApply -MainVersion $mainVersion
    }
    if (!$NoPackage) {
        Invoke-Tfx
    }
}

if ($MyInvocation.InvocationName -ne '.') { 
    MainHelper -VersionAction $VersionAction -NoTest $NoTest.IsPresent -NoPackage $NoPackage.IsPresent
}