﻿# Copyright 2018 Rik Essenius
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in 
# compliance with the License. You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License is
# distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and limitations under the License.

[CmdletBinding(DefaultParameterSetName = 'None')]
param()

set-psdebug -strict

# if the environment variable AGENT_WORKFOLDER has a value, we run on an agent. Else we're likely to run under Pester.
function RunningOnAgent() {	return !!$Env:AGENT_WORKFOLDER }

# We don't want to duplicate the common functions during development, so we get the module from its folder. 
# The deployment to vsix copies them over to the task folders because tasks can only use their own folders.
function GetModuleFolder() { 
	if (RunningOnAgent) { 
		return $PSScriptRoot 
	} else { 
		return (Join-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -ChildPath "Common")
	}
}

Get-Module -Name "CommonFunctions" | Remove-Module
Import-Module -DisableNameChecking -Name (Join-Path -Path (GetModuleFolder) -ChildPath "CommonFunctions.psm1")

# The Gecko driver needs the Firefox binary in the path. So if it isn't there already and Firefox is installed, add it.
function AddFirefoxBinaryToPath {
    $firefoxFileName = "firefox.exe"
    if (Find-InPath -Command $firefoxFileName) { return }
    $firefoxInstallFolder = GetFirefoxInstallFolderFromRegisty
    if (!$firefoxInstallFolder) { return }
    Out-Log "Adding $FirefoxInstallFolder to path" -Debug
    Add-ToPath -Path $firefoxInstallFolder
}

# Convert a port spec (can be e.g. @(80, 443, 8080-8085) into a list of ports, so an intersection can be done
function ConvertToPortList {
    param([string[]]$PortSpec)
    $response = @()
    foreach ($entry in $PortSpec) {
        $parts = $entry.Split("-")
        if (($parts[1]) -and (Test-IsPositive($parts[0])) -and (Test-IsPositive($parts[1]))) {
            for ($port=[int]$parts[0]; $port -le [int]$parts[1]; $port++) {
                $response += $port
            }
        } else {
            $response += $entry
        }
    }
    return $response
}

# e.g. Port 8085 and PoolSize 5 becomes "8085-8089". We use this to translate the Slim variables
function ConvertToPortRange {
    param([string]$Port, [string]$PoolSize)
    Assert-IsPositive -Value $Port -Parameter 'Port'
    Assert-IsPositive -Value $PoolSize -Parameter 'PoolSize'
    $endPort = [int]$Port + [int]$PoolSize - 1
    $returnValue = if ($endPort -eq $Port) { "$Port" } else { "$Port-$endPort" }
    return $returnValue
}

# Find the Firefox installation folder from the registry. Return null if no Firefox installation was found
function GetFirefoxInstallFolderFromRegisty {
    $firefoxTree = (Get-ChildItem -Path "hklm:\software\mozilla\mozilla firefox" -Recurse -ErrorAction SilentlyContinue)
    if (!$firefoxTree) {
        $firefoxTree = (Get-ChildItem -Path "hkcu:\software\mozilla\mozilla firefox" -Recurse -ErrorAction SilentlyContinue)
        if (!$firefoxTree) { return $null }
    }
    $property = 'Install Directory'
    return ($firefoxTree | where-object {$_.Property -eq $property} | get-itemproperty -ErrorAction SilentlyContinue).$property
}


# Get the list of values that are in both lists
function GetIntersection {
    param([string[]]$x, [string[]]$y)
    $r = $x | where-object {$y -contains $_} 
    return $r
}

# Extract all property values from a list of merged plugins.properties
# We need that because multiple occurrences of properties like SymbolTypes and Responder need to become comma separated lists on one line.
function GetPropertyValues {
    param ([string]$Property, [string[]]$Properties) 
    $allItems = @()
    $Properties | foreach { if ($_ -match "\b$Property\b\s*=") { $name,$items = $_.split("=").split(",").trim(); $allItems += $items } }
    return ($allItems | Sort-Object | Get-Unique)
}

# Find the FitSharp folder. We look for dbFit since that's not used in the .net Core version, and we want the classic .Net version
function Find-FitSharp {
    param([string]$SearchRoot)
    $dbFit = Find-UnderFolder -FileName "dbfit.dll" -Description "DBFit" -SearchRoot $SearchRoot -Assert
    return Split-Path -Parent $dbFit
}

# Merge multiple occurrences of multi-entry properties for plugins.properties. Notice that for other properties, the last version in the file overrides.
function MergeProperties {
    param([string[]]$Properties)
    $keywords = @("SymbolTypes","Responders", "SlimTables", "CustomComparators")
    $result = @()
    $Properties | foreach { if ($_ -notmatch "\b($($keywords -join "|"))\b\s*=") { $result += $_ } }
    foreach ($keyword in $keywords) {
        $items = GetPropertyValues -Property $keyword -Properties $properties
        if ($items) { 
            $result += "$keyword=$($items -join ",")"
        }
    }
    return $result
}

# Write a warning if any of the ports in scope are blocked via another rule (but don't solve the issue)
function ShowBlockedPorts {
    param([string[]]$PortRange)
    $portList = ConvertToPortList -PortSpec $PortRange
    $portFiltersRaw = Get-NetFirewallPortFilter -Protocol "TCP" 
    $portsOfInterest = $PortFiltersRaw | where-object { (GetIntersection -x (ConvertToPortList -PortSpec $_.LocalPort) -y $portList) } 
    if ($portsOfInterest) {
        $rules = $portsOfInterest | Get-NetFirewallRule | Where-Object { TestRuleOk($_)}
        $blockedPortRule = @($rules | Where-Object { ($_.Action -eq "Block") } ) 
        if ($blockedPortRule) {
            $subMessage = if ($blockedPortRule.Count -gt 1) { "are already firewall rules" } else { "is already a firewall rule"}			
            $message = "There $subMessage '$($blockedPortRule.DisplayName -join ", ")' blocking incoming traffic on ports in the range '$PortRange'." +
            " This overrules a firewall rule allowing it. Please resolve this manually."
            Out-Issue -Message $message -Warning
        }
    }
}

# Cater for the "All" and "Any" values in the filters
function TestRuleAppliesTo {
    param([string]$RuleValue, [string]$FilterValue)
    return $RuleValue.Contains($FilterValue) -or $RuleValue.Contains("All") -or $RuleValue.Contains("Any")
}

# A rule is considered OK if it is enabled, if the profile applies to Domain, if the protocol applies to TCP, and direction is inbound
function TestRuleOk {
    param([PSObject]$Rule) 
    $result = ($Rule.Enabled -eq "True") -and 
            (TestRuleAppliesTo -RuleValue $Rule.Profile -FilterValue "Domain") -and
            ($Rule.Direction -eq "Inbound")
    return $result
}

# Unblock incoming TCP traffic on a port range for the domain. Port is the start port, Poolsize is the number of consecutive ports to use.
# E.g. -Port 8005 -Poolsize 5 will unblock ports 8085-8089
function Unblock-IncomingTraffic {
    param([string]$Port, [string]$PoolSize=1, [string]$Description)
    $PortRange = ConvertToPortRange -Port $Port -PoolSize $PoolSize
    $portList = ConvertToPortList -PortSpec $portRange
    # Don't use brackets in display name; they are used in wildcard scenarios. Escaping them via backticks is more complicated
    $displayName = "$Description (port $PortRange)"
    $commonMessage = "firewall rule '$displayName' to allow incoming traffic"
    # Use wildcard * to avoid an exception if it's not found
    $existingRule = Get-NetFirewallRule -DisplayName "$displayName*"
    if (!$existingRule) {
        Out-Log " Creating new $commonMessage" -Debug
        # Note that New does not use wildcards. Putting a rule in a group makes it 'predefined' in the MMC UI.
        New-NetFirewallRule -DisplayName $displayName -Direction Inbound -LocalPort $PortList -Protocol TCP `
            -Profile Domain -Action Allow -Group "FitNesseRun" | Out-Null
    } else {
        Out-Log " Updating existing $commonMessage" -Debug
        # It does not hurt to update it if it was good already, so we always update
        Set-NetFirewallRule -DisplayName $displayName -Direction Inbound -LocalPort $PortList -Protocol TCP `
           -Profile Domain -Action Allow -Enabled True
    }
    # Verification: if there is another rule still blocking any of the ports, show a warning
    ShowBlockedPorts -PortRange $portRange
}


# Create a new plugins.properties file using the parameters and the identified FitSharp location
Function Write-PropertiesFile {
    param([string]$TargetFolder, [string]$FitSharpFolder, [hashtable]$Parameters)
    New-FolderIfNeeded -Path $TargetFolder
    $configFile = "plugins.properties"
    $propertiesFile = Join-Path -Path $TargetFolder -ChildPath $configFile
    Out-Log " Creating properties file $propertiesFile"
    [string[]] $properties = "# first line must be a comment",
    "Port=$($Parameters.Port)",
    "SLIM_PORT=$($Parameters.SlimPort)",
    "slim.timeout=$($Parameters.SlimTimeout)", 
    "slim.pool.size=$($Parameters.SlimPoolSize)", 
    "FITSHARP_PATH=$($FitSharpFolder.Replace("\","\\"))",
    'FITNESSE_ROOT=${FITNESSE_ROOTPATH}\\${FitNesseRoot}',
    "TEST_SYSTEM=slim",
    'COMMAND_PATTERN=%m -r fitsharp.Slim.Service.Runner,"${FITSHARP_PATH}\\fitsharp.dll" %p',
    'TEST_RUNNER=${FITSHARP_PATH}\\Runner.exe'

    # does not include plugins.properties itself
    $rawExtraEntries = (Get-ChildItem -Path (Join-Path -Path $TargetFolder -ChildPath "plugins.properties.*")  | get-content)
    $cleanExtraEntries = MergeProperties -Properties $rawExtraEntries
    if ($cleanExtraEntries) {
        Out-Log "  Adding additional properties from partial plugins.properties file(s)"
        $properties += $cleanExtraEntries
    }

    if (Test-Path -Path $propertiesFile) {
        Out-Log "  File already exists - overwriting" -Debug
    }
    # Save as ANSI via Default encoding - FitNesse is picky about that
    Out-File -InputObject $properties -FilePath $propertiesFile -Encoding Default
}

# Orchestrate the process: get the parameters, validate them, create/clean target folder as needed, find FitSharp, create properties file, 
# copy any demos to the right locations, and open firewall ports if desired
function MainHelper {
    $parameters = Get-TaskParameter -ParameterNames "targetFolder","packageFolder","port","slimPort","slimPoolSize","slimTimeout",
                                                 "cleanupTarget","unblockPorts"
    Assert-IsPositive -Value $parameters.Port -Parameter 'port' 
    Assert-IsPositive -Value $parameters.SlimPort -Parameter 'slimPort' 
    Assert-IsPositive -Value $parameters.SlimPoolSize -Parameter 'slimPoolSize' 
    Assert-IsPositive -Value $parameters.SlimTimeout -Parameter 'slimTimeout' 

    Out-Log "Creating target folder if necessary" -Debug
    New-Item -ItemType Directory -Path $parameters.TargetFolder -Force | Out-Null
    if ($parameters.CleanupTarget -eq 'true') {
        Out-Log "Cleaning up target folder" -Debug
        Get-ChildItem -Path $parameters.TargetFolder -erroraction silentlycontinue | Remove-Item -recurse
    }
    
    Out-Log -Message "Generating plugins.properties and setting output variables.." -Debug
    $fitSharpFolder = Find-FitSharp -SearchRoot $parameters.PackageFolder
    Write-PropertiesFile -TargetFolder $Parameters.TargetFolder -FitSharpFolder $fitSharpFolder -Parameters $parameters
    $fitNesse = Find-UnderFolder -FileName "fitnesse*.jar" -Description "FitNesse" -SearchRoot $parameters.PackageFolder -Assert
    Write-OutputVariable -Name "FitNesse.StartCommand" -Value "java -jar $fitNesse -d $($parameters.TargetFolder) -e 0 -o"
    #to do - this is wrong for the new mechanism (no more fixtures subfolder). Correct.
	$fixtureFolder = Join-Path -Path $Parameters.TargetFolder -ChildPath "fixtures"
    Write-OutputVariable -Name "FitNesse.WorkFolder" -Value $fixtureFolder

    Out-Log -Message "Populating wiki and fixture folders from packages.." -Debug
    Copy-FromPackage -TargetPath $Parameters.TargetFolder -SourceBase $Parameters.PackageFolder -SourceFolder "content"
    $wikiPath = Join-Path -Path $Parameters.TargetFolder -ChildPath "wiki"
    $fitnesseRoot = Join-Path -Path $Parameters.TargetFolder -ChildPath "FitNesseRoot"
    Move-FolderContent -Path $wikiPath -Destination $fitNesseRoot

    Copy-FromPackage -TargetPath $fixtureFolder -SourceBase $Parameters.PackageFolder -SourceFolder "tools"
	$browserDriverFolder = Join-Path -path $fixtureFolder -ChildPath "BrowserDriver"
    Move-FolderContent -Path $browserDriverFolder -Destination $fixtureFolder
    
    AddFirefoxBinaryToPath

    if ($parameters.UnblockPorts -eq 'true') {
        Out-Log -Message "Unblocking incoming traffic" -Debug
        Unblock-IncomingTraffic -Port $parameters.Port -Description "FitNesse"
        Unblock-IncomingTraffic -Port $parameters.SlimPort -PoolSize $parameters.SlimPoolSize -Description "FitSharp"
    }
}

######## Start of script ########
if (RunningOnAgent) { MainHelper } else { Exit-WithError -Message "Not running on an agent. Exiting." }