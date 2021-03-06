# Copyright 2017-2020 Rik Essenius
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in
# compliance with the License. You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License is
# distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and limitations under the License.

# This script is intended for PowerShell 5.0. It uses some features not available on PowerShell Core.
# Also, some of the error messages are different, causing tests to fail.

[CmdletBinding(DefaultParameterSetName = 'None')]
param()

set-psdebug -strict

# if the environment variable AGENT_WORKFOLDER has a value, we run on an agent. Else we're likely to run under Pester.
function TestOnAgent() {	return !!$Env:AGENT_WORKFOLDER }

# We don't want to duplicate the common functions during development, so we get the module from its folder.
# The deployment to vsix copies them over to the task folders because tasks can only use their own folders.
function GetModuleFolder() {
	if (TestOnAgent) {
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
	[int]$id
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
	} catch {
		#$stackTrace = GetStackTrace
		return GetErrorResponse -Exception $_.Exception -Uri $Uri -Duration (GetDuration -StartTime $startTime) -stackTrace (GetStackTrace)
	}
	return $callResult
}

function ConvertXml([xml]$InputXml, [string]$XsltFile, [string]$Now = (Get-Date).ToUniversalTime().ToString("o")) {
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

function EditEnvironment([xml]$NUnitXml) {
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

function EditAttachments([xml]$NUnitXml, [string]$RawResults, [string]$Details) {
	$suite = $NUnitXml.SelectSingleNode("test-run/test-suite[1]")
	@($suite.attachments.attachment)[0].filePath = $RawResults
	if ($Details) {
		$attachment = [xml]"<attachment><filePath>$Details</filePath><description>Test results in HTML</description></attachment>"
		AddNode -Base $NUnitXml -Source $attachment -TargetXPath "test-run/test-suite[1]/attachments"
	}
	return $NUnitXml.OuterXml
}

# Run FitNesse on the local machine 
# If there is a RestCommand, run in 'single shot mode', and get the XML result
# If not, start it and keep it running, and return the port number 
function ExecuteFitNesse([string]$AppSearchRoot, [string]$DataFolder, [string]$Port, [string]$RestCommand) {
	$fitNesse = Find-UnderFolder -FileName "fitnesse*.jar" -Description "FitNesse" -SearchRoot $AppSearchRoot -Assert
	$java = Find-InPath -Command "java.exe" -Description "Java" -Assert
	Exit-If -Condition (!(Test-Path -Path $DataFolder)) -Message "Could not find data folder '$DataFolder'"
	Assert-IsPositive -Value $Port -Parameter "Port"
	$usedPort = GetNextFreePort -DesiredPort $Port
	$originalLocation = Get-Location
	try {
		Set-Location -Path $DataFolder
		Out-Log -Message "Executing [$java] [$fitNesse], port=[$usedPort], data@[$DataFolder], command=[$restCommand]" -Debug
		# -o ensures that FitNesse doesn't try to update - so we don't need the "properties" file
		$commandArguments = "-jar", "`"$fitNesse`"", "-d", "`"$DataFolder`"", "-p", $usedPort, "-o"
		if ($RestCommand) {
			$commandArguments += "-c", "`"$restCommand`""
		}
		$commandResult = InvokeProcess -Command $java -Arguments $commandArguments -Wait (!!$restCommand)
		if (!$RestCommand) {
			return "<?xml version=`"1.0`"?><root><port>$usedPort</port><id>$($commandResult.id)</id></root>"
		}
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
	Set-Variable -Option Constant -name "test" -value "test";
	$validTypes = $test, $suite, "shutdown"
	$splitTestSpec = $TestSpec.Split(':');
	if (!$splitTestSpec) { 
		return [TestSpec]@{name = ""; runtype=""}
	}
	# Type 'test' is the default
	$returnValue = [TestSpec]@{name = $splitTestSpec[0]; runType = $test}
	# if the type is specified, then honor it
    if ($splitTestSpec.Length -gt 1) {
		$lowerType = $splitTestSpec[1].ToLowerInvariant()
    	if ($validTypes.Contains($lowerType)) {
			$returnValue.runType = $lowerType;
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

function GetErrorFromHtmlString([string]$InputHtml, [string]$Default) {
	$html = New-Object -Com "HTMLFile"
	try {
		# Only works when Office is installed (e.g. on my machine)
		$html.IHTMLDocument2_write($InputHtml)
	} catch {
		# Only works when Office is not installed (so can't test it on my machine, did that manually on a hosted agent)
		$source = [System.Text.Encoding]::Unicode.GetBytes($InputHtml)
		$html.write($source)
	}
	$result= ($html.all.tags("span") | Where-Object {$_.className -eq "error"}).InnerText
	if ($result) { return $result }
	return $Default
}

function GetErrorResponse([exception]$Exception, [string]$Uri, [double]$Duration, [string]$StackTrace) {
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

function GetNextFreePort([int]$DesiredPort) {
	$selectedPort = $DesiredPort;
	while (!(TestTcpPortAvailable -Port $selectedPort)) { $selectedPort++ }
	return $selectedPort
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

# Execute a command and retrieve the output if Wait is true. 
#If Wait is false, return the process id and exit code 0 
function InvokeProcess([string]$Command, [string]$Arguments, [bool]$Wait) {
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
	if ($Wait) {
		# This is a somewhat convoluted way to read the error and output streams, and is intended to prevent deadlocks
		# We read one stream synchronously and one stream asynchronously. Also, ReadToEnd must happen before WaitForExit.
		# We use Output as the synchronous one since the async read is a bit flaky with large inputs, and that's less of an 
		# issue with the error stream which doesn't usually generate a lot of data.
		$errorBuilder = [System.Text.StringBuilder]@{}
		$appendScript = {
			if ($EventArgs.Data) { $Event.MessageData.AppendLine($EventArgs.Data) }
		}
		$errorEvent = Register-ObjectEvent -InputObject $process -Action $appendScript -EventName 'ErrorDataReceived' -MessageData $errorBuilder
	} 
	$process.Start() | Out-Null
	$returnValue = New-Object ExecutionResult
	if ($Wait) {
		$process.BeginErrorReadLine()
		$returnValue.output = $process.StandardOutput.ReadToEnd()
		$process.WaitForExit()
		Unregister-Event -SourceIdentifier $errorEvent.Name
		$returnValue.error = $errorBuilder.ToString()
		$returnValue.exitCode = $process.ExitCode
		$returnValue.id = 0
	} else {
		$returnValue.ExitCode = 0
		$returnValue.id = $process.Id
	}
	return $returnValue
}

function Invoke-FitNesse([hashtable]$Parameters) {
	# The FitNesse xml format doesn't always contain an exception on complete failure. The HTML result usually contains
	# more clues. So if we get a xml result without results node, we retry the command in HTML, and grab the error message
	# from there. We put it into testResults/executionLog/exception as that is where the history pages keep them too.
	$htmlText = ""
	[xml]$xml = $null
	$restCommand = $null
	$includeHtmlSpec = if ($Parameters.IncludeHtml -eq $true) { "&includehtml" } else { "" }
	$containsTest = $false
	if ($Parameters.TestSpec) {
		$TestSpecObject = ExtractTestSpec -TestSpec $Parameters.TestSpec
		$restCommand = "$($TestSpecObject.name)?$($TestSpecObject.runType)&format=xml&nochunk$includeHtmlSpec"
		if ($TestSpecObject.name) { 
			$containsTest = $true 
		}
	    if ($Parameters.ExtraParam) { $restCommand += "&$($Parameters.ExtraParam)" }
	}
	if ($Parameters.Command -eq 'call') {
	    if (!$restCommand) {
			Exit-WithError -Message "No Rest command identified" 
		}
		$uri = New-Object System.Uri([System.Uri]$Parameters.BaseUri, $restCommand)
		$callRestResult = CallRest -Uri $uri -ReadWriteTimeoutSeconds $Parameters.TimeoutSeconds
		if (!$containsTest) {
			return $null
		}
		$xml = [xml]$callRestResult
		if (TestMissedError -InputXml $xml) {
			$htmlRequest = $uri.ToString().Replace("format=xml","format=html")
			$htmlText = CallRest -Uri $htmlRequest -ReadWriteTimeoutSeconds $Parameters.TimeoutSeconds
		}
	} else { # Execute
		$xml = [xml](ExecuteFitNesse -AppSearchRoot $Parameters.AppSearchRoot -DataFolder $Parameters.DataFolder `
									 -Port $Parameters.Port -RestCommand $restCommand)
		# Bit of a hack. If FitNesse is started and keeps running, this xml snippet contains port number and process id
	    if (!$restCommand) {
			return $xml.OuterXml
		}
		if (TestMissedError -InputXml $xml) {
			$htmlRestCommand = $restCommand.Replace("format=xml","format=html")
			$htmlText = ExecuteFitNesse -AppSearchRoot $Parameters.AppSearchRoot -DataFolder $Parameters.DataFolder `
										-Port $Parameters.Port -RestCommand $htmlRestCommand
		}
	}
	if ($htmlText) { # Look for an exception message in the HTML page and insert that
		$missedErrorMessage =  GetErrorFromHtmlString -InputHtml $htmlText -Default "No test results found"
		Out-Log "Retried via HTML: $missedErrorMessage" -Debug
		SaveExceptionMessage -xml $xml -Message $missedErrorMessage -StackTraceMessage (GetStackTrace)
	}
	return $xml.OuterXml
}

function SaveExceptionMessage([xml]$xml, [string]$Message, [string]$StackTraceMessage) {
	$xPath= "/testResults/executionLog"
	if (!($xml.SelectSingleNode($xPath))) {
		$executionLog = [xml]"<executionLog/>"
		AddNode -Base $xml -Source $executionLog -TargetXPath "/testResults"
	}
	$exceptionXml = [xml]"<exception><![CDATA[$Message]]></exception>"
	$stackTraceXml = [xml]"<stackTrace><![CDATA[$StackTraceMessage]]></stackTrace>"
	AddNode -Base $xml -Source $exceptionXml -TargetXPath $xPath
	AddNode -Base $xml -Source $stackTraceXml -TargetXPath $xPath
}

function SaveXml([string]$xml, [string]$OutFile) {
	$xmlObject = [xml]$xml
	$xmlObject.Save($OutFile)
}

function TestAllTestsPassed([string]$FitNesseOutput) {
	$counts = ([xml]$fitNesseOutput).testResults.finalCounts
	return (([int]$counts.wrong + [int]$counts.exceptions) -eq 0) -and ([int]$counts.right -gt 0)
}

function TestMissedError([xml]$InputXml) {
	return (!$InputXml.testResults.result) -and (!$InputXml.testResults.executionLog.exception)
}

function TestTcpPortAvailable([int]$Port) {
    $ipGlobalProperties = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    return 0 -eq ($ipGlobalProperties.GetActiveTcpListeners() | where-object {$_.Port -eq $Port}).Count
}

function InvokeMainTask() {
	$parameters = Get-TaskParameter -ParameterNames "command", "testSpec", "includeHtml", "resultFolder", "extraParam", # All
		"port", "dataFolder", "appSearchRoot",  # Execute
		"baseUri", "timeoutSeconds" # Call

	New-FolderIfNeeded -Path $parameters.ResultFolder
	Out-Log -Message "Invoking FitNesse" -Debug
	$xml = Invoke-FitNesse -Parameters $parameters
	if (!$parameters.testSpec) {
		$procInfo = [xml]$xml
		Write-OutputVariable -Name "FitNesse.Port" -Value ($procInfo.root.port)
		Write-OutputVariable -Name "FitNesse.ProcessId" -Value ($procInfo.root.id)
		Out-Log -Message "##vso[task.complete result=Succeeded;]FitNesse started at port $($procInfo.root.port) with process id $($procInfo.root.id)"	
		return
	}
	if (!$xml) {
		Out-Log -Message "##vso[task.complete result=Succeeded]Operation succeeded (without generating output)"
		return;
	}
	$rawResultsFilePath = (Join-Path -Path $parameters.ResultFolder -ChildPath "fitnesse.xml")
	SaveXml -xml $xml -OutFile $rawResultsFilePath

	Out-Log -Message  "Transforming output to NUnit 3 format" -Debug
	$nUnitOutput = ConvertXml -InputXml $xml -XsltFile "FitNesseToNUnit3.xslt"
	$nUnitOutputWithEnvironment = [xml](EditEnvironment -NUnitXml $nUnitOutput)

	$detailsFilePath = $null
	if ($parameters.IncludeHtml -eq $true) {
		Out-Log -Message "Generating detailed results file" -Debug
		$details = (ConvertXml -InputXml $xml -XsltFile "FitNesseToDetailedResults.xslt")
		$detailsFilePath = (Join-Path -Path $parameters.ResultFolder -ChildPath "DetailedResults.html")
		$details | Out-File ($detailsFilePath)
	}
	$nUnitOutputComplete = [xml](EditAttachments -NUnitXml $nUnitOutputWithEnvironment -RawResults $rawResultsFilePath -Details $detailsFilePath)
	SaveXml -xml $nUnitOutputComplete.OuterXml -OutFile (Join-Path -Path $parameters.ResultFolder -ChildPath "results_nunit.xml")

	if (TestAllTestsPassed -FitNesseOutput $xml) {
		Out-Log -Message "##vso[task.complete result=Succeeded;]Test run successful"
	} else {
		Out-Log -Message "##vso[task.complete result=Failed;]Test run failed"
	}
}

######## Start of script ########
if (TestOnAgent) { InvokeMainTask } else { Exit-WithError -Message "Not running on an agent. Exiting." }