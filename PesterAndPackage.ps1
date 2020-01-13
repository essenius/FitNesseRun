# Copyright 2017-2019 Rik Essenius
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in
# compliance with the License. You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License is
# distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and limitations under the License.

using namespace System.Management.Automation # for OutLog colors

param([ValidateSet("Next","Sync","Ignore")][string]$VersionAction="Ignore", [switch]$NoTest, [switch]$NoPackage, [switch]$Production)

set-psdebug -strict

function ExitScript {
	exit 1
}

function ExitWithError {
	param([string]$Message)
	OutLog -Message $message -Fail
	ExitScript
}

function GetVersion {
    param([string]$FilePath)
    $vssExtension = Get-Content -Raw -Path $FilePath | ConvertFrom-Json
    return New-Object -TypeName System.Version -ArgumentList $vssExtension.Version
}

function GetNextVersion {
    param([System.Version]$Version)
    return New-Object -TypeName System.Version -ArgumentList $Version.Major, $Version.Minor, ($Version.Build + 1)
}

function InvokeTest {
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
        ExitWithError -Message "$($basePath): $($testResult.FailedCount) test(s) failed"
    }
    if ($testResult.PassedCount -eq 0) {
        ExitWithError -Message "$($basePath): no passing tests"
    }
    $coverage = $testResult.CodeCoverage
    $coveragePercentage = ($coverage.NumberOfCommandsExecuted / $coverage.NumberOfCommandsAnalyzed) * 100
    $missedCommands = $coverage.NumberOfCommandsAnalyzed - $coverage.NumberOfCommandsExecuted
    $coverageOK = ($missedCommands -le 5)
    if (!$coverageOK) {
        ExitWithError -Message "$($Folder): Missed $missedCommands (more than 5) commands; code coverage is $coveragePercentage%"
    }
}

function InvokeTfx {
    param()
    tfx extension create --manifest-globs vss-extension.json --output-path Archive
}

function OutLog {
    param([string]$Message, [switch]$Fail, [switch]$Pass)
	if ($Fail.IsPresent -or $Pass.IsPresent) {
		$informationMessage = [HostInformationMessage]@{
			Message         = $Message
			ForegroundColor = if ($Fail.IsPresent) { "Red" } else { "Green" }
			BackgroundColor = $Host.UI.RawUI.BackgroundColor
			NoNewline       = $false
		}
		Write-Information -MessageData $informationMessage -InformationAction "Continue"
	} else {
		Write-Information -MessageData $Message -InformationAction "Continue"
	}
}

function SaveToJson {
    param($Object, [string]$FilePath)
    $backupFilePath = [System.IO.Path]::ChangeExtension($FilePath, "backup")
    if (Test-Path -Path $backupFilePath) {
        Remove-Item -Path $backupFilePath
    }
    if (Test-Path -Path $FilePath) {
        Move-Item -Path $FilePath -Destination $backupFilePath
    }
    $Object | ConvertTo-Json -depth 10 | Out-File -FilePath $FilePath -Encoding "UTF8"
}

function UpdateExtension {
    param([string]$FilePath, [System.Version]$Version, [bool]$Production)
    $extensionFile = $FilePath
    $vssExtension = Get-Content -Raw -Path $extensionFile | ConvertFrom-Json
    $vssExtension.Version = "$Version"
    if ($Production) {
        $id = "FitNesseRun"
        $runTaskId = "fitnesse-run-task"
        $configureTaskId = "fitnesse-configure-task"
        $public = $true 
    } else {
        $id = "FitNesseRun-Test"
        $runTaskId = "fitnesse-run-test-task"
        $configureTaskId = "fitnesse-configure-test-task"
        $public = $false 
    }
    $vssExtension.id = $id
    $vssExtension.name = $id
    $vssExtension.public = $public
    $vssExtension.contributions[0].id = $runTaskId
    $vssExtension.contributions[1].id = $configureTaskId
    SaveToJson -Object $vssExtension -FilePath $extensionFile
}

function SaveVersionInTask {
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
    SaveToJson -Object $task -FilePath $taskFile
}

function InvokeMainTask {
    param([string]$VersionAction, [bool]$NoTest, [bool]$NoPackage, [bool]$Production)
	$mainVersion = 1
    if (!$NoTest) {
        InvokeTest -Folder "Common" -CodeCoverage "Common\CommonFunctions.psm1"
        InvokeTest -Folder "FitNesseConfigure" -MainVersion $mainVersion
        InvokeTest -Folder "FitNesseRun" -MainVersion $mainVersion
		OutLog -Message "All tests passed" -Pass
    }
    $version = GetVersion -FilePath "vss-extension.json"
    OutLog -Message "Current version: $version"
    if ($VersionAction -ne "Ignore") {
        if ($VersionAction -eq "Next") {
            $versionToApply = GetNextVersion -Version $version
        } else {
            $versionToApply = $version
        }
        UpdateExtension -FilePath "vss-extension.json" -Version $versionToApply -Production $Production
        SaveVersionInTask -TaskName "FitNesseConfigure" -Version $versionToApply -MainVersion $mainVersion
        SaveVersionInTask -TaskName "FitNesseRun" -Version $versionToApply -MainVersion $mainVersion
    }
    if (!$NoPackage) {
        InvokeTfx
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    InvokeMainTask -VersionAction $VersionAction -NoTest $NoTest.IsPresent -NoPackage $NoPackage.IsPresent -Production $Production.IsPresent
}