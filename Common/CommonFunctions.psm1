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

#Add a folder to the path for next tasks
function Add-ToPath([string] $Path) { 
    Out-Log -Message "##vso[task.prependpath]$Path" 
}

function Assert-IsPositive { 
	param([string]$Parameter, [string]$Value)
	$caption = if ($Parameter) { "$($Parameter): " } else { '' }
	Exit-If -Condition (!(Test-IsPositive($Value))) -Message "$($caption)'$Value' is no positive number"
}

# Return the input with the first character capitalized.
# We can't use ToTitleCase because that removes all capitals after the first character
function Capitalize {
	param([string]$Source)
	return $Source[0].ToString().ToUpper() + $Source.Remove(0,1)
}

# Copy a folder from the source path to TargetFolder under the TargetPath
function Copy-Folder {
    param([string]$TargetPath, [string]$SourcePath, [string]$TargetFolder)
    $fullTargetPath = Join-Path -Path $TargetPath -ChildPath  $TargetFolder
    Out-Log -Message "  Copying $SourcePath to $fullTargetPath..." -Debug
    New-Item -ItemType Directory -Force -Path $fullTargetPath | Out-Null
    Copy-Item -Path "$SourcePath\*" -Recurse -Force -Destination $fullTargetPath
}

# In all packages under the sourcebase, copy (recursively) the content of the source folder to the target path
function Copy-FromPackage {
	param([string]$TargetPath, [string]$SourceBase, [string]$SourceFolder)
	Get-ChildItem $SourceBase -Directory -Recurse | 
	    Where-Object {$_.FullName -like "*packages\*\$SourceFolder"} | 
	    Get-ChildItem -Directory |
		ForEach-Object { Copy-Folder -TargetPath $TargetPath -SourcePath $_.FullName -TargetFolder $_.Name }    
}

# Exit the script with an error message if the condition is true
function Exit-If {
	param([boolean]$Condition, [string]$Message)
	if ($Condition) { Exit-WithError -Message $Message }
}

function ExitScript {
	exit 1
}

# Exit the script with an error message to allow Azure DevOps to pick it up 
function Exit-WithError {
    param([string]$Message)
	Out-Issue -Message $Message
	Out-Log -Message "##vso[task.complete result=Failed;]ABORTED"
	ExitScript
}

# Find an application in the environment path. If Assert is set, exit if it could not be found
function Find-InPath {
    param([string]$Command, [switch]$Assert) 
	$CommandPath = (Get-Command -Name $Command -CommandType Application -ErrorAction SilentlyContinue | 
					Select-Object -First 1).Path
	if ($Assert.IsPresent) {
		Exit-If -Condition (!$CommandPath) -Message "Could not find '$Command'"
	}
	return $CommandPath
}

# Find a file in the tree hierarchy below a folder. If Assert is set, exit if it could not be found
function Find-UnderFolder {
    param([string]$FileName, [string]$SearchRoot = $pwd, [switch]$Assert)
	$FilePath = (Get-ChildItem -Path $SearchRoot -Filter $FileName -Recurse | Select-Object -First 1).FullName
	if ($Assert.IsPresent) {
		Exit-If -Condition (!$FilePath) -Message "Could not find '$FileName' under '$SearchRoot'"
	}
	return $FilePath
}

function Get-EnvironmentVariable([string]$Key) {
	return (Get-Item Env:$Key -ErrorAction SilentlyContinue).Value
}

#Get the parameter values from Azure DevOps
Function Get-Parameters {
	param([string[]]$ParameterNames)
	$hashTable = @{}
	Trace-VstsEnteringInvocation $MyInvocation
	try {
		Import-VstsLocStrings (Join-Path -Path $PSScriptRoot -ChildPath "Task.json")
		foreach($parameter in $parameterNames) {
			$hashTable.Add((Capitalize -Source $parameter), (Get-VstsInput -Name $parameter))
		}
	} finally {
		Trace-VstsLeavingInvocation $MyInvocation
	} 
	return $hashTable
}

function Move-FolderContents {
	param([string]$Path, [string]$Destination)
	If (Test-Path -Path $Path) {
		if (Test-Path -Path $Destination -PathType Leaf) {
			Exit-WithError -Message "Target folder $Destination already exists as a file"
		}
		New-Item -Path $Destination -ItemType Directory -Force | Out-Null
		Move-Item -Path $Path\* -Destination $Destination -Force
		If ((Get-ChildItem -Path $Path -Recurse -Force).Count -eq 0) {
			remove-item -Path $Path -Force
		} else {
			Out-Issue -Message "Could not remove $Path after moving contents to $Destination" -Warning
		}
	}

}
# Create a folder if it didn't already exist
Function New-FolderIfNeeded {
	param ([string]$Path)
	if (!(Test-Path -Path $Path)) { New-Item -Path $Path -ItemType Directory | out-null }	
}

# Write an issue to the log. Can be a warning or an error
function Out-Issue {
	param([switch]$Warning, [string]$Message)
	$type = if ($Warning) { "warning" } else { "error" }
	Out-Log -Message "##vso[task.logissue type=$type;]$Message"
}

# Write a message to the log
function Out-Log {
    param([string]$Message, [switch]$Debug, [Switch]$Command)
	$InformationPreference = "Continue"
	If ($Debug.IsPresent) {
		Write-Information -MessageData "##[debug]$Message"
	} Else { 
		If ($Command.IsPresent) {
			Write-Information -MessageData "##[Command]$Message"
		} Else {
			Write-Information -MessageData $Message
		}
	}
}

function Test-IsPositive ([string]$Value) {
    return $Value -match "^[\d]+$"
}

Function Write-OutputVariable {
	param([string]$Name, [string]$Value)
	Out-Log -Message "##vso[task.setvariable variable=$Name;]$Value"
}

# Export all functions with a dash in them.
Export-ModuleMember -function *-* 