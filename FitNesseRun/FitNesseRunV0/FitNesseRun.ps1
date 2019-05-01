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

class ExecutionResult {
	[string]$output
	[string]$error 
	[int]$exitCode
}

class TestSpec {
	[string]$name
	[string]$runType
}

function AddNode([xml]$Base, [xml]$Source, [string]$TargetXPath) {
	$targetNode = $Base.SelectSingleNode($TargetXPath)
	$nodeToImport = $Base.ImportNode($Source.DocumentElement, $true)
	$targetNode.AppendChild($nodeToImport) | out-null
}

# Call a Rest API and retrieve the result
function CallRest([string]$Uri, [string]$ReadWriteTimeoutSeconds = "default") {
    $startTime = Get-Date
	Out-Log -Message "Calling: $Uri" -Debug
	# try/catch to be able to report e.g. connectivity issues
	try {
		# Using WebRequest, since it is not possible to set the ReadWriteTimeout with Invoke-RestMethod (TimeoutSec is something else)
		# Standard ReadWriteTimeout is 5 minutes, and that may not be enough for long running FitNesse tests. 
		$timeout = GetTimeout -TimeoutSeconds $ReadWriteTimeoutSeconds
		$request = [System.Net.Webrequest]::Create($Uri)
		if ($timeout -ne "default") {
			$request.ReadWriteTimeout = $timeout
		}
		$response = $request.GetResponse()
		$responseStream = $response.GetResponseStream()
		$reader = New-Object System.IO.StreamReader $responseStream
		$callResult = $reader.ReadToEnd()
		#$callResult = Invoke-RestMethod -Uri $Uri -TimeoutSec 0
	} catch {
	    $duration = ((Get-Date).Subtract($startTime)).TotalMilliseconds
		$stackTrace = GetStackTrace
		return Get-ErrorResponse -Exception $_.Exception -Uri $Uri -Duration (GetDuration -StartTime $startTime) -stackTrace $stackTrace
	}
	return $callResult
}

# Execute a command and retrieve the output
function Execute([string]$Command, [string]$Arguments) {
	Out-Log -Message "Executing: $Command $Arguments" -Command
	$processStartInfo = [System.Diagnostics.ProcessStartInfo]@{
        FileName = $Command;
        Arguments = $Arguments;
        RedirectStandardOutput = $true;
        RedirectStandardError = $true; 
        WorkingDirectory = (Get-Location).Path;
        UseShellExecute = $false; 
        CreateNoWindow = $true;
    }

	
    $process = [System.Diagnostics.Process]@{StartInfo = $processStartInfo}

	# This is a somewhat convoluted way to read the error and output streams, and is intended to prevent deadlocks
	# We read one stream synchronously and one stream asynchronously.
	$errorBuilder = [System.Text.StringBuilder]@{}
	$appendScript = {
        if (! [String]::IsNullOrEmpty($EventArgs.Data)) { $Event.MessageData.AppendLine($EventArgs.Data) }
    }
	$errorEvent = Register-ObjectEvent -InputObject $process -Action $appendScript -EventName 'ErrorDataReceived' -MessageData $errorBuilder 
	$process.Start() | Out-Null
	$process.BeginErrorReadLine()
	$returnValue = New-Object ExecutionResult
	# ReadToEnd needs to be done before WaitForExit to prevent deadlocks
	$returnValue.output = $process.StandardOutput.ReadToEnd()
	$process.WaitForExit()
	Unregister-Event -SourceIdentifier $errorEvent.Name
	$returnValue.error = $errorBuilder.ToString()
	$returnValue.exitCode = $process.ExitCode
	return $returnValue
}

# Run FitNesse on the local machine in 'single shot mode', and get the XML result
function ExecuteFitNesse([string]$AppSearchRoot, [string]$FixtureFolder, [string]$DataFolder, [string]$Port, [string]$RestCommand) {
	$fitNesse = Find-UnderFolder -FileName "fitnesse*.jar" -Description "FitNesse" -SearchRoot $AppSearchRoot -Assert
	$java = Find-InPath -Command "java.exe" -Description "Java" -Assert
	Exit-If -Condition (!(Test-Path -Path $FixtureFolder)) -Message "Could not find fixture folder '$FixtureFolder'"
	Exit-If -Condition (!(Test-Path -Path $DataFolder)) -Message "Could not find data folder '$DataFolder'"
	Assert-IsPositive -Value $Port -Parameter "Port"
	$usedPort = NextFreePort -DesiredPort $Port
	$originalLocation = Get-Location
	try {
		Set-Location -Path $FixtureFolder
		Out-Log -Message "Executing [$java] [$fitNesse], fixtures@[$FixtureFolder], port=[$usedPort], data@[$DataFolder], command=[$restCommand]" -Debug
		# -o ensures that FitNesse doesn't try to update - so we don't need the "properties" file
		$commandResult = Execute -Command $java -Arguments (
			"-jar", "`"$fitNesse`"", "-d", "`"$DataFolder`"", "-p", $usedPort, "-o", "-c", "`"$restCommand`"")
	} finally {
		Set-Location -Path $originalLocation
	}
	$response = ExtractResponse -Result $commandResult
	$cleanResponse = ExtractXmlOrHtml -RawInput $response
	return $cleanResponse
}

# For execution results: extract the response from the response object. Can be the output string or the error string
# weak typing is deliberate here - see 
# http://stackoverflow.com/questions/36804102/powershell-5-and-classes-cannot-convert-the-x-value-of-type-x-to-type-x
function ExtractResponse($Result) {
	# FitNesse can return non-zero exit codes e.g. when tests fail. For us this is business as usual which shouldn't result in 
	# exceptions. Also, FitNesse can return non-fatal messages on the error stream (e.g. missing plugins.properties). 
	# Therefore, we assume that the process has succeeded if the output stream contains data, even if there were errors
	if ($Result.output) {
		if ($Result.error) {
			Out-Log -Message "Found output, so ignoring exit code $($Result.exitCode), error message: $($Result.error)" -Debug
		}
		return $Result.output
	}
    # At this stage we know the output stream was empty. If the exit code was zero (e.g. the case with java -version) 
    # we just return the error stream (which may be empty). Otherwise raise an exception. 
	if ($Result.exitCode -eq 0) {
		return $Result.error
	}
	Exit-WithError -Message "Java returned exit code $($Result.exitCode). Error: $($Result.error)" 
}

# Extract the test specification (name and runtype) from the specified name: testName[:type]. 
function ExtractTestSpec([string]$TestSpec) {
	Set-Variable -Option Constant -name "suite" -value "suite";
	Set-Variable -Option Constant -name "examples" -value "examples";
	$splitTestSpec = $TestSpec.Split(':');
	# Type 'test' is the default
	$returnValue = [TestSpec]@{name = $splitTestSpec[0]; runType = "test"}
	# if the type is specified as 'suite', then honor it
    if ($splitTestSpec.Length -gt 1) {
    	if ($splitTestSpec[1].ToUpperInvariant() -eq $suite.ToUpperInvariant()) {
			$returnValue.runType = $suite;
    	}
    } else {
		# If not specified, then we assume everything starting or ending with 'suite' or 'examples' is a suite
		$ordinalIgnoreCase = [System.StringComparison]::OrdinalIgnoreCase
    	if ($returnValue.name.StartsWith($suite, $ordinalIgnoreCase) -or
			$returnValue.name.StartsWith($examples, $ordinalIgnoreCase) -or
			$returnValue.name.EndsWith($suite, $ordinalIgnoreCase) -or
			$returnValue.name.EndsWith($examples, $ordinalIgnoreCase)) {
        	$returnValue.runType = $suite;
        }
    }
	return $returnValue
}

# Extract the XML or HTML section from a string (ignore headers etc.)
function ExtractXmlOrHtml([string]$RawInput) {
	$ordinal = [System.StringComparison]::Ordinal
	$startLocation = $RawInput.IndexOf("<?xml", $ordinal);
	if ($startLocation -eq -1) { $startLocation = $rawInput.IndexOf("<!DOCTYPE html", $ordinal) }
	$endLocation = $RawInput.LastIndexOf(">", $ordinal) + 1;
	if (($startLocation -eq -1) -or ($endLocation -eq 0)) {
		Exit-WithError -Message "Could not find an XML or HTML section in the result. Raw result: $RawInput" 
	}
	$result = $RawInput.Substring($startLocation, $endLocation - $startLocation)
	return $result
}

function GetClrVersionInfo([string]$Assembly) {
	try {
		$assemblyRef = [Reflection.Assembly]::ReflectionOnlyLoadFrom($assembly)
		return $assemblyRef.ImageRuntimeVersion
	} catch {
		return ""
	}
}

function GetDuration([DateTime]$StartTime) {
	return ((Get-Date).Subtract($StartTime)).TotalMilliseconds
}

function GetErrorFromHtmlString([string]$InputHtml) {
	$html = New-Object -Com "HTMLFile"
	try {
		# Only works when Office is installed (e.g. on my machine)
		$html.IHTMLDocument2_write($InputHtml)
	} catch {
		# Only works when Office is not installed (so can't test it on my machine, did that manually on a hosted agent)
		$source = [System.Text.Encoding]::Unicode.GetBytes($InputHtml)
		$html.write($source)
	}
	return ($html.all.tags("span") | Where-Object {$_.className -eq "error"}).InnerText
}

function Get-ErrorResponse([exception]$Exception, [string]$Uri, [double]$Duration, [string]$StackTrace) {
	$errorMessage = $Exception.Message
	if ($errorMessage -notlike "*$($Exception.InnerException.InnerException.Message)*") {
		 $errorMessage += ": $($Exception.InnerException.InnerException.Message)"
	}
	return "<?xml version=`"1.0`"?><testResults>"+
	  "<rootPath>Exception</rootPath>" +
	  "<executionLog>" + 
	    "<exception><![CDATA[$errorMessage [URI: $Uri]]]></exception>" +
	    "<stackTrace><![CDATA[$StackTrace]]></stackTrace>" +
	  "</executionLog>" +
	  "<finalCounts><exceptions>1</exceptions></finalCounts>" +
	  "<totalRunTimeInMillis>$Duration</totalRunTimeInMillis>"+
	"</testResults>"
}

function GetStackTrace() {
	$caller = (Get-PSCallStack)[1]
	return "$(Split-Path -Leaf $caller.ScriptName) $($caller.Command)($($caller.Arguments))"
}

function GetTimeout([string]$TimeoutSeconds) {
	if ($TimeoutSeconds -eq "default") { return "default" }
	if($TimeoutSeconds -eq "infinite") { return [System.Threading.Timeout]::Infinite } 
	$converted = 0
	$isNumeric = [System.Double]::TryParse($TimeoutSeconds, [ref]$converted)
	if ($isNumeric) { return $converted * 1000 }
	Out-Log -Message "Could not understand timeout value '$TimeoutSeconds'. Assuming default."
	return "default"
}

function GetVersionInfo([string]$Assembly) {
	$assemblyItem = Get-Item $Assembly -ErrorAction SilentlyContinue
	if ($assemblyItem) {
		return "$($assemblyItem.VersionInfo.ProductName) $($assemblyItem.VersionInfo.FileVersion)"
	}
	return ""	
}

function Invoke-FitNesse([hashtable]$Parameters) {
	# The FitNesse xml format doesn't always contain an exception on complete failure. The HTML result usually contains 
	# more clues. So if we get a xml result without results node, we retry the command in HTML, and grab the error message 
	# from there. We put it into testResults/executionLog/exception as that is where the history pages keep them too.
	$htmlText = ""
	[xml]$xml = $null
	$TestSpecObject = ExtractTestSpec -TestSpec $Parameters.TestSpec
	$restCommand = "$($TestSpecObject.name)?$($TestSpecObject.runType)&format=xml&nochunk&includehtml"
    if ($Parameters.ExtraParam) { $restCommand += "&$($Parameters.ExtraParam)" }
	if ($Parameters.Command -eq 'call') {
		$uri = New-Object System.Uri([System.Uri]$Parameters.BaseUri, $restCommand)
		$xml = CallRest -Uri $uri -ReadWriteTimeoutSeconds $Parameters.TimeoutSeconds
		if (MayHaveMissedError -InputXml $xml) {
			$htmlRequest = $uri.ToString().Replace("format=xml","format=html")
			$htmlText = CallRest -Uri $htmlRequest -ReadWriteTimeoutSeconds $Parameters.TimeoutSeconds
		}
	} else { # Execute
		$xml = [xml](ExecuteFitNesse -AppSearchRoot $Parameters.AppSearchRoot -FixtureFolder $Parameters.FixtureFolder `
		            	        -DataFolder $Parameters.DataFolder -Port $Parameters.Port -RestCommand $restCommand)
		if (MayHaveMissedError -InputXml $xml) {
			$htmlRestCommand = $restCommand.Replace("format=xml","format=html")
			$htmlText = ExecuteFitNesse -AppSearchRoot $Parameters.AppSearchRoot -FixtureFolder $Parameters.FixtureFolder `
					            -DataFolder $Parameters.DataFolder -Port $Parameters.Port -RestCommand $htmlRestCommand
		}
	}
	if ($htmlText) { # Look for an exception message in the HTML page and insert that
		$missedErrorMessage =  GetErrorFromHtmlString -InputHtml $htmlText
		if (!$missedErrorMessage) {
			$missedErrorMessage = "No test results found"
		}
		Out-Log "Retried via HTML: $missedErrorMessage" -Debug
		$xPath= "/testResults/executionLog"
		if (!($xml.SelectSingleNode($xPath))) {
			$executionLog = [xml]"<executionLog/>"
			AddNode -Base $xml -Source $executionLog -TargetXPath "/testResults"
		}
		$exceptionXml = [xml]"<exception><![CDATA[$missedErrorMessage]]></exception>"
		$stackTraceXml = [xml]"<stackTrace><![CDATA[$(GetStackTrace)]]></stackTrace>"
		AddNode -Base $xml -Source $exceptionXml -TargetXPath $xPath
		AddNode -Base $xml -Source $stackTraceXml -TargetXPath $xPath
	}
	# todo: change this to returning an XML object
	return $xml.OuterXml
}

function MayHaveMissedError([xml]$InputXml) {
	return (!$xml.testResults.result) -and (!$xml.testResults.executionLog.exception)
}

function NextFreePort([int]$DesiredPort) {
	$selectedPort = $DesiredPort;
	while (!(TcpPortAvailable -Port $selectedPort)) { $selectedPort++ }
	return $selectedPort
}

function SaveXml([string]$xml, [string]$OutFile) {
	$xmlObject = [xml]$xml
	$xmlObject.Save($OutFile)
}

function TcpPortAvailable([int]$Port) {
    $ipGlobalProperties = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    return 0 -eq ($ipGlobalProperties.GetActiveTcpListeners() | where-object {$_.Port -eq $Port}).Count
}

function Transform([xml]$InputXml, [string]$XsltFile, [string]$Now = (Get-Date).ToUniversalTime().ToString("o")) {
    $xslt = New-Object Xml.Xsl.XslCompiledTransform
	$xsltSettings = New-Object Xml.Xsl.XsltSettings($true,$false)
	$xsltSettings.EnableScript = $true
	$XmlUrlResolver = New-Object System.Xml.XmlUrlResolver
    $xslt.Load((Join-Path -Path $PSScriptRoot -ChildPath $XsltFile), $xsltSettings, $XmlUrlResolver)
	
    $target = New-Object System.IO.MemoryStream
	$reader = New-Object System.IO.StreamReader($target)
    try {
		$xslArguments = New-Object Xml.Xsl.XsltArgumentList	
        $xslArguments.AddParam("Now", "", $Now);
		$xslt.Transform($InputXml, $xslArguments, $target)
        $target.Position = 0
		return $reader.ReadToEnd()
    } Finally {
		$reader.Close()
        $target.Close()
    }
}

function UpdateEnvironment([xml]$NUnitXml) {
	$env = $NUnitXml.SelectSingleNode("test-run/test-suite/environment")
	if (!($env)) { return $NUnitXml.OuterXml }
	$os = $os=get-ciminstance -classname win32_operatingsystem
	$testSystem=($NUnitXml.SelectSingleNode("test-run/test-suite[1]/settings").setting | 
		Where-Object {$_.name -eq "TestSystem"}).Value
	if ($testSystem) {
		$assembly = $testSystem.Split(":",2)[1]
		$versionInfo = GetVersionInfo -Assembly $assembly
		if ($versionInfo) {
			$env.SetAttribute("framework-version", $versionInfo)
			$clrVersion = GetClrVersionInfo($assembly)
			if ($clrVersion) { $env.SetAttribute("clr-version", $clrVersion) }
		}
	}
	$env.SetAttribute("os-architecture", $os.OSArchitecture)
	$env.SetAttribute("os-version", $os.Version) 
	# VSTS can't deal with the platform attribute.
	# $env.SetAttribute("platform", $os.Caption)
	$env.SetAttribute("cwd", ".") 
	$env.SetAttribute("machine-name", $os.CSName) 
	$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name.Split("\")
	$env.SetAttribute("user", $user[1]) 
	$env.SetAttribute("user-domain", $user[0]) 
	$env.SetAttribute("culture", (Get-Culture).Name) 
	$env.SetAttribute("uiculture", (Get-UICulture).Name)
	return $NUnitXml.OuterXml
}

function DidAllTestsPass([string]$FitNesseOutput) {
	$counts = ([xml]$fitNesseOutput).testResults.finalCounts
	return (([int]$counts.wrong + [int]$counts.exceptions) -eq 0) -and ([int]$counts.right -gt 0)
}

function MainHelper() {
	#$originalLocation = Get-Location
	$parameters = Get-Parameters -ParameterNames "command", "testSpec", "includeHtml", # All
		"port", "dataFolder", "fixtureFolder", "appSearchRoot",  # Execute
		"baseUri", "timeoutSeconds", # Call
		"resultFolder", "extraParam" # All
	
	if (!(Test-Path -Path $parameters.ResultFolder)) {
		New-Item -Path $parameters.ResultFolder -ItemType directory | out-null
	}
	Out-Log -Message "Invoking FitNesse" -Debug
	$xml = Invoke-FitNesse -Parameters $parameters
	SaveXml -xml $xml -OutFile (Join-Path -Path $parameters.ResultFolder -ChildPath "fitnesse.xml")

	Out-Log -Message  "Transforming output to summary result format" -Debug
	$summary = Transform -InputXml $xml -XsltFile "FitNesseToSummaryResult.xslt"
	SaveXml -xml $summary -OutFile (Join-Path -Path $parameters.ResultFolder -ChildPath "results.xml")
	Out-Log -Message  "Transforming output to NUnit 3 format" -Debug
	$nUnitOutput = Transform -InputXml $xml -XsltFile "FitNesseToNUnit3.xslt"
	$nUnitOutputWithEnvironment = [xml](UpdateEnvironment -NUnitXml $nUnitOutput)
	if ($parameters.IncludeHtml -eq $true) {
		Out-Log -Message "Generating detailed results file" -Debug
		$summaryXml = [xml]$summary
		$detailsFile = $summaryXml.DocumentElement.DetailedResultsFile
		if (!$detailsFile) { $detailsFile = "DetailedResults.html" }
		$details = (Transform -InputXml $xml -XsltFile "FitNesseToDetailedResults.xslt")
		$detailsFilePath = (Join-Path -Path $parameters.ResultFolder -ChildPath $detailsFile)
		$details | Out-File ($detailsFilePath)
		$attachment = [xml] @"
		<attachments>
			<attachment>
				<filePath>$detailsFilePath</filePath>
				<description>HTML log of all the executed tests and their results</description>
			</attachment>
		</attachments>
"@
		Out-Log -Message "Adding attachments section to NUnit 3 test-suite" -Debug
		AddNode -Base $nUnitOutputWithEnvironment -Source $attachment -TargetXPath "test-run/test-suite"
	}
	SaveXml -xml $nUnitOutputWithEnvironment.OuterXml -OutFile (Join-Path -Path $parameters.ResultFolder -ChildPath "results_nunit.xml")
	#Set-Location $originalLocation
	if (DidAllTestsPass -FitNesseOutput $xml) {
		Out-Log -Message "##vso[task.complete result=Succeeded;]Test run successful"
	} else {
		Out-Log -Message "##vso[task.complete result=Failed;]Test run failed"
	}
}

######## Start of script ########
if (RunningOnAgent) { MainHelper } else { Exit-WithError -Message "Not running on an agent. Exiting." }