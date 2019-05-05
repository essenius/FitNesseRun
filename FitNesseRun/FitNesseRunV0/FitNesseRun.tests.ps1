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

set-psdebug -strict

#Get-Module -Name "VstsTaskSdk" | Remove-Module
#import-module -name .\ps_modules\VstsTaskSdk\VstsTaskSdk.psm1 -ArgumentList @{'NonInteractive'="$true"}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sut = (Split-Path -Leaf $MyInvocation.MyCommand.Path) -replace '\.Tests\.', '.'
. "$here\$sut"

Describe "FitNesseRun-GetModuleFolder" {
    Mock -CommandName RunningOnAgent -MockWith { return $true }
    it "should return $PSScriptRoot" {
        GetModuleFolder | Should -Be $PSScriptRoot
    }
}

Describe "FitNesseRun-CallRest" {
    it "executes a REST call to the ODATA test server" {
    $uri = "http://services.odata.org/OData/OData.svc/Products"
        $result = CallRest -Uri $uri
        $result | Should -Match '<title type="text">Products</title>'
    }
	Mock -CommandName GetDuration -MockWith { return 1234 }
	$resultTemplate = "<?xml version=`"1.0`"?><testResults><rootPath>Exception</rootPath>" +
	"<executionLog><exception><![CDATA[{0}]]></exception>" +
	"<stackTrace><![CDATA[$sut CallRest({{Uri={1}{2}}})]]></stackTrace>" +
	"</executionLog>" +
	"<finalCounts><exceptions>1</exceptions></finalCounts><totalRunTimeInMillis>1234</totalRunTimeInMillis></testResults>"

    it "inserts an exception message with bad requests, not adding inner exception" {
        $uri = "http://bad*%$*%$request"
        $result = CallRest -Uri $uri
        $expectedError = "Exception calling `"Create`" with `"1`" argument(s): " +
        "`"Invalid URI: The hostname could not be parsed.`" [Uri: http://bad*%$*%]"
        $expectedResult = ($resultTemplate -f $expectedError,$uri,"")
        $result | Should -Be $expectedResult
    }
    it "inserts an exception message with a connection issue, adding inner exception" {
        $emptyPort = NextFreePort -DesiredPort 8500
        $uri = "http://localhost:$($emptyPort)?a=b"
        $expectedError = "Exception calling `"GetResponse`" with `"0`" argument(s): `"Unable to connect to the remote server`"" + 
        ": No connection could be made because the target machine actively refused it 127.0.0.1:$($emptyPort) [Uri: http://localhost:$($emptyPort)?a=b]"
        $expectedResult = ($resultTemplate -f $expectedError,$uri,"")
        $result = CallRest -Uri $uri
        $result | Should -Be $expectedResult
    }
    it "sets the ReadWriteTimeout when the parameter is set" {
        $uri = "https://www.cnn.com" # a somewhat slower page,taking over a millisecond to get back
        $expectedError = "Exception calling `"ReadToEnd`" with `"0`" argument(s): " +
        "`"The operation has timed out.`" [Uri: https://www.cnn.com]"
        $expectedResult = ($resultTemplate -f $expectedError,$uri,", ReadWriteTimeoutSeconds=0.001")
        $result = CallRest -Uri $uri -ReadWriteTimeoutSeconds 0.001
        $result | Should -Be $expectedResult
    }
}

Describe "FitNesseRun-DidAllTestsPass" {
    function CheckPassFail($testcase) {
        it "checks pass/fail correctly for $($testcase.name)" {
            $testcase | Should -Not -BeNullOrEmpty
            $fitNesseOutput = $testcase.fitnesseInput.InnerXml
            $expectedOutcome = $testcase.expectedOutput.SummaryResult.TestResult
            $passed = DidAllTestsPass -FitNesseOutput $fitNesseOutput
            $passed | Should -Be ($expectedOutcome -eq "Passed")
        }
    }

    $testcases = new-object System.Xml.XmlDocument;
    [xml]$testcases = [xml](Get-Content "$PSScriptRoot\xslTests.xml")
    $testcase = $testcases.testcases.testcase
    $testcase | ForEach-Object { CheckPassFail $_ }    
}

Describe "FitNesseRun-ExtractTestSpec" {
    function TestExtractTestCommand($TestSpec, $expectedName, $expectedRuntype) {
        It "extracts correctly for '$TestSpec'" {
            $result = ExtractTestSpec -TestSpec $TestSpec
            $result.name | Should -Be $expectedName
            $result.runType | Should -Be $expectedRuntype
        }
    }

    $dataSets = (
        ("MyTestCase", "MyTestCase", "test"),
        ("MySuite.MyTestCase", "MySuite.MyTestCase", "test"),
        ("MySuite", "MySuite", "suite"),
        ("MySuiteExamples", "MySuiteExamples", "suite"),
        ("SuiteOne", "SuiteOne", "suite"),
        ("ExamplesOne", "ExamplesOne", "suite"),
        ("MySuite:test", "MySuite", "test"),
        ("MyTest:suite", "MyTest", "suite"),
        ("MySuite.MyTestCase:suite", "MySuite.MyTestCase", "suite"),
        ("", "", "test"),
        ("MyTestCase:wrongtype", "MyTestCase", "test")
    )
    $dataSets | ForEach-Object { TestExtractTestCommand @_ }
}

Describe "FitNesseRun-Execute" {
    It "executes java -version" {
        $result = Execute -Command "java.exe" -Arguments "-version"
        $result.ExitCode | Should -Be 0
        $result.output | Should -Be ""
        $result.error | Should -Match ".* version .*"
    }
    It "executes java --version" {
        $result = Execute -Command "java.exe" -Arguments "--unrecognized" 
        $result.ExitCode | Should -Be 1
        $result.output |  Should -Be ""
        $result.error  | Should -Match "unrecognized option: --unrecognized"
    }
    It "executes java WorkFolder" {
        $result = Execute -Command "java.exe" -Arguments ("-cp", "$PSScriptRoot", "WorkFolder") 
        $result.ExitCode | Should -Be 0
        $result.output |  Should -Be ((get-location).path + "\.`r`n")
        $result.error  | Should -Be ""
    }
    It "executes find to test multiple arguments" {
        $result = Execute -Command "find" -Arguments ("/c", '"java WorkFolder"', "$PSScriptRoot\FitNesseRun.tests.ps1" ) 
        $result.ExitCode | Should -Be 0
        $result.output |  Should -BeLike "*FITNESSERUN.TESTS.PS1: 2`r`n"
        $result.error  | Should -Be ""
    }
}

Describe "FitNesseRun-ExecuteFitNesse" {
    # Not called directly from ExecuteFitnesse, but via Exit-If in CommonFunctions
    Mock -CommandName Exit-WithError -ModuleName CommonFunctions -MockWith { throw $Message }
    it "can't find FitNesse under '.'" {
        { ExecuteFitNesse -AppSearchRoot "." } | Should -Throw "Could not find 'fitnesse*.jar' under '.'"
    }
    Mock -CommandName Find-UnderFolder -MockWith { return ".\fitnesse.jar" }
    it "can find FitNesse under E:\Apps, but cannot find fixture folder" {
        { ExecuteFitNesse -AppSearchRoot "." -FixtureFolder ".\nonexistingFolder" } | Should -Throw "Could not find fixture folder"
    }
    it "can find FitNesse under E:\Apps, can find fixture folder, but cannot find data folder" {
        { ExecuteFitNesse -AppSearchRoot "." -FixtureFolder "." -DataFolder ".\nonexistingFolder" } | 
            Should -Throw "Could not find data folder"
    }
}

Describe "FitNesseRun-ExtractResponse" {
    Mock -CommandName Exit-WithError -MockWith { throw $Message }
    Context "AcceptedResponses" {
        function TestExtractResponse([string]$OutputStream, [string]$ErrorStream, [int]$ExitCode, [string]$ExpectedOutput) {
            It "returns the right output for [$OutputStream][$ErrorStream][$ExitCode]]" {
                $execResult = new-object ExecutionResult
                $execResult.output = $OutputStream
                $execResult.error = $ErrorStream
                $execResult.exitCode = $ExitCode
                ExtractResponse -Result $execResult | Should -Be $ExpectedOutput
            }
        }

        $dataSets = (
            ("output", "", 0, "output"),
            ("output", "", 1, "output"),
            ("output", "error", 0, "output"),
            ("", "", 0, ""),
            ("", "error", 0, "error")
        )
        $dataSets | ForEach-Object { TestExtractResponse @_ }
    }

    Context "ErrorResponses" {
        function TestExtractResponse([string]$OutputStream, [string]$ErrorStream, [int]$ExitCode) {
            It "throws for [$OutputStream][$ErrorStream][$ExitCode]]" {
                $result = [ExecutionResult]@{output = $OutputStream; error = $ErrorStream; exitCode = $ExitCode}
                { ExtractResponse -Result $result } | Should -Throw "Java returned exit code ${ExitCode}. Error: ${ErrorStream}"
            }
        }

        $dataSets = ( ("", "", 1), ("", "error", 1) )
        $dataSets | ForEach-Object { TestExtractResponse @_ }   
    }
}

Describe "FitNesseRun-ExtractXmlOrHtml" {
    Mock -CommandName Exit-WithError -MockWith { throw $Message }
    Context "Invalid XML" {
        It "throws an exception with [$RawInput]" {
            $exceptionMessage = "Could not find an XML or HTML section in the result. Raw result: data without XML"
            { ExtractXmlOrHtml -RawInput "data without XML" } | Should -Throw $exceptionMessage
        }
    }
    Context "Valid XML" {
        It "Loads valid XML within a larger stream correctly" {
            $result = ExtractXmlOrHtml -RawInput "Heading<?xml version='1.0' encoding='utf-8'?><tag>value</tag> trailing data"
            $result | Should -Be "<?xml version='1.0' encoding='utf-8'?><tag>value</tag>"
        }
        It "Loads valid XML correctly" {
            $result = ExtractXmlOrHtml -RawInput "<?xml version='1.0' encoding='utf-8'?><tag>value</tag>"
            $result | Should -Be "<?xml version='1.0' encoding='utf-8'?><tag>value</tag>"
        }
        It "Loads empty XML root" {
            $result = ExtractXmlOrHtml -RawInput "<?xml version='1.0' encoding='utf-8'?>"
            $result | Should -Be "<?xml version='1.0' encoding='utf-8'?>"
        }
    }
    Context "Valid HTML" {
        it "Loads valid HTML within a larger stream correctly" {
            $result = ExtractXmlOrHtml -RawInput "Heading<!DOCTYPE html><html><body></body></html>trailing data"
            $result | Should -Be "<!DOCTYPE html><html><body></body></html>"
        }
    }
}

Describe "FitNesseRun-GetClrVersionInfo" {
    it "returns emtpy string for non-existing assembly" {
        GetClrVersionInfo -Assembly "c:\nonexisting.exe" | Should -BeNullOrEmpty
    }
    it "returns empty string for an existing assembly without manifest" {
        GetClrVersionInfo -Assembly (Get-Command "notepad.exe").Path | Should -BeNullOrEmpty
    }
}

Describe "FitNesseRun-GetDuration" {
	it "should have a really small duration" {
		$duration=GetDuration -StartTime (Get-Date)
		$duration | Should -Not -BeLessThan 0
		$duration | Should -BeLessThan 1000
	}
}

Describe "FitNesseRun-GetErrorFromHtmlString" {
    it "should return error string if there" {
        $html = "<html><body><span class=`"error`">Exception from FitNesse</span>" +
                "<span class=`"response`">Response</span></body></html>"
        GetErrorFromHtmlString -InputHtml $html | Should -Be "Exception from FitNesse"
    }    
    it "should return empty string if no error" {
        $html="<html><body><span class=`"response`">Response</span></body></html>"
        GetErrorFromHtmlString -InputHtml $html | Should -BeNullOrEmpty
    }
}

Describe "FitNesseRun-GetTimeout" {
    Mock -CommandName Out-Log -MockWith { $script:Message = $Message }
    $script:Message = ""
    it "returns the Infinity constant with the input 'infinite'" {
        GetTimeout -TimeoutSeconds "infinite" | Should -Be ([System.Threading.Timeout]::Infinite)
        $script:Message | Should -Be ""
    }
    it "passes on 'default'" {
        GetTimeout -TimeoutSeconds "default" | Should -Be "default"
        $script:Message | Should -Be ""
    }
    it "returns the value in milliseconds for numbers" {
        GetTimeout -TimeoutSeconds "300" | Should -Be 300000
        $script:Message | Should -Be ""
    }
    it "returns 'default' for other values" {
        GetTimeout -TimeoutSeconds "bogus" | Should -Be "default"
        $script:Message | Should -Be "Could not understand timeout value 'bogus'. Assuming default."
    }
}

Describe "FitNesseRun-GetVersionInfo" {
    it "returns emtpy string for non-existing assembly" {
        GetVersionInfo -Assembly "c:\nonexisting.exe" | Should -BeNullOrEmpty
    }
    it "returns a sensible response for an existing assembly" {
        GetVersionInfo -Assembly (Get-Command "notepad.exe").Path | Should -Match "Microsoft.*\d*\.\d*.\d*.\d*"
    }
}

Describe "FitNesseRun-InvokeFitNesse" {
    # Can be called directly as well as form CommonFunctions
    Mock -CommandName Exit-WithError -MockWith { throw $Message }
    Mock -CommandName Exit-WithError -ModuleName CommonFunctions -MockWith { throw $Message }
    Context "plain call" {
        Mock -CommandName CallRest -MockWith { $script:calledUri = $Uri; return [xml]$extractedResult }
        Mock -CommandName MayHaveMissedError -MockWith { return $false }
        it "executes a plain call right with html included" {
            $script:calledUri = ""
            $extractedResult = "<?xml version=`"1.0`"?><root><DetailedResultsFile>test.html</DetailedResultsFile></root>"      
            $parameters=@{'Command'='Call';'TestSpec'='JavaTest';'BaseUri'='http://localhost:8080';
                        'Resultfolder'='.';'ExtraParam'= 'param1=value1';'IncludeHtml' = $true}
            $xml = Invoke-FitNesse -Parameters $parameters
            Assert-MockCalled -CommandName CallRest -Times 1 -Exactly -Scope It
            $script:calledUri | Should -Be "http://localhost:8080/JavaTest?test&format=xml&nochunk&includehtml&param1=value1" 
            $xml | Should -Be $extractedResult
        }
    }
    Context "Call with missed error" {
        it "tries getting additional exception info when the call returns nothing" {
            $script:calledUri = ""
            $xmlResult = "<?xml version=`"1.0`"?><testResults><executionLog /></testResults>" 
            Mock -CommandName GetErrorFromHtmlString -MockWith { return "Exception Message" }
            Mock -CommandName CallRest -MockWith { $script:calledUri = $Uri; return [xml]$xmlResult }
            Mock -CommandName MayHaveMissedError -MockWith { return $true }
            $parameters=@{'Command'='Call';'TestSpec'='JavaTest';'BaseUri'='http://localhost:8080';'Resultfolder'='.'}
            $resultXml = Invoke-FitNesse -Parameters $parameters
			$expectedResult = "<?xml version=`"1.0`"?><testResults>" +
			"<executionLog><exception><![CDATA[Exception Message]]></exception>" +
			"<stackTrace><![CDATA[FitNesseRun.ps1 Invoke-FitNesse({Parameters=System.Collections.Hashtable})]]></stackTrace>" +
			"</executionLog></testResults>"
            $resultXml | Should -Be $expectedResult
            Assert-MockCalled -CommandName CallRest -Times 2 -Exactly -Scope It
            $script:calledUri | Should -Be "http://localhost:8080/JavaTest?test&format=html&nochunk&includehtml" 
        }
    }
    Context "plain execute" {
        $extractedResult = "<?xml version=`"1.0`"?><root><DetailedResultsFile>test.html</DetailedResultsFile></root>"   
        $rawResult = "aaa"+ $extractedResult + "bbb"
        Mock -CommandName Execute -MockWith { 
            $script:Command = $Command
            $script:Arguments = $Arguments
            return [ExecutionResult]@{ output = $rawResult; error = ""; exitCode = 0} }
        Mock -CommandName MayHaveMissedError -MockWith { return $false }
        Mock -CommandName Find-UnderFolder -MockWith { return "E:\My Apps\fitnesse.jar" }
        Mock -CommandName Find-InPath -MockWith { return "C:\Program Files\java.exe" }
        it "executes a plain execute right" {
            $script:command = ""
            $script:arguments = ""
            $parameters=@{'Command'='Execute'; 'TestSpec'='JavaTest'; 'Port'='9123';
                        'AppSearchRoot'='E:\My Apps'; 'FixtureFolder'='.'; 'DataFolder'='.'; 'ResultFolder'='.' }
            $xml = Invoke-FitNesse -Parameters $parameters
            $script:command | Should -Be "C:\Program Files\java.exe"
            $script:arguments | Should -Be "-jar `"E:\My Apps\fitnesse.jar`" -d `".`" -p 9123 -o -c `"JavaTest?test&format=xml&nochunk&includehtml`""
            $xml | Should -Be $extractedResult
        }
    }
    Context "execute with missed error" {
        $script:xmlContent = "<executionLog />"
        Mock -CommandName Execute -MockWith { 
            $script:Command = $Command
            $script:Arguments = $Arguments
            $xmlResult = "<?xml version=`"1.0`"?><testResults>$($script:xmlContent)</testResults>" 
            return [ExecutionResult]@{ output = $xmlResult; error = ""; exitCode = 0} 
        }
        $script:ExceptionMessage = "Exception Message" 
        Mock -CommandName Find-UnderFolder -MockWith { return "E:\My Apps\fitnesse.jar" }        
        Mock -CommandName GetErrorFromHtmlString -MockWith { return $script:ExceptionMessage }
        Mock -CommandName MayHaveMissedError -MockWith { return $true }
        $parameters=@{'Command'='Execute'; 'TestSpec'='JavaTest'; 'Port'='9123';'AppSearchRoot'='E:\My Apps';
        'FixtureFolder'='.'; 'DataFolder'='.'; 'ResultFolder'='.' }
        it "tries getting additional exception info when the execute returns nothing" {
            $resultXml = Invoke-FitNesse -Parameters $parameters
            $resultXml | Should -Be ("<?xml version=`"1.0`"?><testResults><executionLog><exception><![CDATA[Exception Message]]></exception>" +
			"<stackTrace><![CDATA[FitNesseRun.ps1 Invoke-FitNesse({Parameters=System.Collections.Hashtable})]]></stackTrace></executionLog></testResults>")
            $script:arguments | Should -Be "-jar `"E:\My Apps\fitnesse.jar`" -d `".`" -p 9123 -o -c `"JavaTest?test&format=html&nochunk&includehtml`""
            Assert-MockCalled -CommandName Execute -Times 2 -Exactly -Scope It
            Assert-MockCalled -CommandName GetErrorFromHtmlString -Times 1 -Exactly -Scope It
        }
        it "tries getting additional information and finds an exception while there was no exceptionLog. The subree is added" {
            $script:xmlContent = "<finalCounts/>"
            $resultXml = Invoke-FitNesse -Parameters $parameters
            $resultXml | Should -Be ("<?xml version=`"1.0`"?><testResults><finalCounts /><executionLog><exception><![CDATA[Exception Message]]></exception>" +
            "<stackTrace><![CDATA[FitNesseRun.ps1 Invoke-FitNesse({Parameters=System.Collections.Hashtable})]]></stackTrace></executionLog></testResults>")
        }
        it "tries getting additional information when the execute returns nothing, but finds nothing. Adds a notification" {
            $script:ExceptionMessage = $null
            $resultXml = Invoke-FitNesse -Parameters $parameters
            $resultXml | Should -Be ("<?xml version=`"1.0`"?><testResults><finalCounts /><executionLog><exception><![CDATA[No test results found]]></exception>" +
            "<stackTrace><![CDATA[FitNesseRun.ps1 Invoke-FitNesse({Parameters=System.Collections.Hashtable})]]></stackTrace></executionLog></testResults>")
        }
    }
}

Describe "FitNesseRun-MayHaveMissedError" {
    it "identifies a missed error" {
        $xml = [xml]"<testResults><executionLog /></testResults>"
        MayHaveMissedError -InputXml $xml | Should -Be $true
    }
    it "identifies an existing exception" {
        $xml = [xml]"<testResults><executionLog><exception>Exception</exception></executionLog></testResults>"
        MayHaveMissedError -InputXml $xml | Should -Be $false
    }
    it "identifies an good response" {
        $xml = [xml]"<testResults><result>result</result><executionLog/></testResults>"
        MayHaveMissedError -InputXml $xml | Should -Be $false
    }
}

Describe "FitNesseRun-Port Selection" {
    it "determines that port 139 is in use" {
        (TcpPortAvailable -Port 139 ) | Should -Be $false
    }
    it "determines that the next free port is > 139" {
        $nextPort = NextFreePort -DesiredPort 139
        $nextPort | Should -BeGreaterThan 139
    }
}

Describe "FitNesseRun-Transform To Detailed Results" {

    function TransformToDetailedResults($testcase)
    {
        it "Transforms details correctly for $($testcase.name)" {
            $testcase | Should -Not -BeNullOrEmpty
            $sourceXml = [xml]($testcase.fitnesseInput.InnerXml)
            $sourceXml | Should -Not -BeNullOrEmpty
            $expectedDetails = $testcase.expectedDetails.InnerText 
            $expectedDetails | Should -Not -BeNullOrEmpty
            $actualDetails = (Transform -InputXml $sourceXml -XsltFile "FitNesseToDetailedResults.xslt") -replace "`r`n", "`n"
            $actualDetails | Should -Be $expectedDetails
        }
    }

    $testcases = new-object System.Xml.XmlDocument;
    [xml]$testcases = [xml](Get-Content "$PSScriptRoot\xslTests.xml")
    $testcase = $testcases.testcases.testcase | where-object { $_.expectedDetails -ne $null }
    $testcase | ForEach-Object { TransformToDetailedResults $_ }    
}

Describe "FitNesseRun-Transform To NUnit 2 Results" {
    function TransformToNUnitResults($testcase) {
        it "Transforms to NUnit 2 format correctly for $($testcase.name)" {
            $testcase | Should -Not -BeNullOrEmpty
            $sourceXml = [xml]($testcase.fitnesseInput.InnerXml)
            $sourceXml | Should -Not -BeNullOrEmpty
            $transformed = [xml](Transform -InputXml $sourceXml -XsltFile "FitNesseToNUnit.xslt")
            $expectedXml = $testcase.expectedNUnitOutput.InnerXml
            $expectedXml | Should -Not -BeNullOrEmpty
            $transformed."test-results".OuterXml | Should -Be $expectedXml
        }
    }

    $testcases = new-object System.Xml.XmlDocument;
    [xml]$testcases = [xml](Get-Content "$PSScriptRoot\xslTests.xml")
    $testcase = $testcases.testcases.testcase
    $testcase | ForEach-Object { TransformToNUnitResults $_ }    
}

Describe "FitNesseRun-Transform To NUnit 3 Results" {
    function TransformToNUnit3Results($testcase) {
        it "Transforms to NUnit 3 format correctly for $($testcase.name)" {
            $Now = "2017-02-23T15:10:00.0000000Z"
            $testcase | Should -Not -BeNullOrEmpty
            $sourceXml = [xml]($testcase.fitnesseInput.InnerXml)
            $sourceXml | Should -Not -BeNullOrEmpty
            $transformed = [xml](Transform -InputXml $sourceXml -XsltFile "FitNesseToNUnit3.xslt" -Now $Now)
            $expectedXml = $testcase.expectedNUnit3Output.InnerXml
            $expectedXml | Should -Not -BeNullOrEmpty
            $transformed.DocumentElement.OuterXml | Should -Be $expectedXml
        }
    }

    $testcases = new-object System.Xml.XmlDocument;
    [xml]$testcases = [xml](Get-Content "$PSScriptRoot\xslTests.xml")
    $testcase = $testcases.testcases.testcase
    $testcase | ForEach-Object { TransformToNUnit3Results $_ }    
}

Describe "FitNesseRun-Transform To Summary Results" {
    function TransformToSummaryResults($testcase) {
        it "Transforms to generic test format correctly for $($testcase.name)" {
            $testcase | Should -Not -BeNullOrEmpty
            $sourceXml = [xml]($testcase.fitnesseInput.InnerXml)
            $sourceXml | Should -Not -BeNullOrEmpty
            $expectedXml = $testcase.expectedOutput.InnerXml
            $expectedXml | Should -Not -BeNullOrEmpty
            $transformed = [xml](Transform -InputXml $sourceXml -XsltFile "FitNesseToSummaryResult.xslt")
            $transformed.SummaryResult.OuterXml | Should -Be $expectedXml
        }
    }

    $testcases = new-object System.Xml.XmlDocument;
    [xml]$testcases = [xml](Get-Content "$PSScriptRoot\xslTests.xml")
    $testcase = $testcases.testcases.testcase
    $testcase | ForEach-Object { TransformToSummaryResults $_ }    
}

Describe "FitNesseRun-UpdateEnvironment" {
    it "should insert the right attributes in the environment element" {
        $settings="<settings><setting name=`"TestSystem`" value=`"slim:C:\Apps\FitNesse\fitsharp\Runner.exe`" /></settings>"
        $xml=[xml]"<?xml version=`"1.0`" encoding=`"utf-8`"?><test-run><command-line/><test-suite><environment/>$settings</test-suite></test-run>"
        [xml]$outXml = UpdateEnvironment -NUnitXml $xml
        $env = $outXml.SelectSingleNode("test-run/test-suite[1]").environment
        $env."framework-version" | Should -Match "fitSharp \d*\.\d*\.\d*\.\d*"
        $env."os-architecture" | Should -Match "\d{2}-bit"
        $env.user | Should -Match "[a-z]*\.[a-z]*"
        $env."machine-name" | Should -Matchexactly "[A-Z]*-[A-Z]*"
        $env.culture | Should -Match "[a-z]{2}-[a-z]{2}"
    }
}

Describe "FitNesseRun-Main Helper" {
    function GetNUnitResult($FileName) {
        if ($FileName) {
            $attachment="<attachments><attachment><filePath>$FileName</filePath>" +
                "<description>HTML log of all the executed tests and their results</description></attachment></attachments>"
        } else {
            $attachment = ""
        }
#        return "<?xml version=`"1.0`"?><test-run><test-suite><results><output /></results>$attachment</test-suite></test-run>"
        return "<?xml version=`"1.0`"?><test-run><test-suite>$attachment</test-suite></test-run>"
    }

    $extractedResult = "<?xml version=`"1.0`"?><root><DetailedResultsFile>test.html</DetailedResultsFile></root>"
    $nunitResultTransformed = GetNUnitResult
    $detailHtml = "<html><body /></html>"
 
    Mock -CommandName Invoke-FitNesse -MockWith { return $extractedResult }
    Mock -CommandName Transform -MockWith { return $InputXml.OuterXml } -ParameterFilter { $XsltFile -eq "FitNesseToSummaryResult.xslt" }
    Mock -CommandName Transform -MockWith { return $detailHtml } -ParameterFilter { $XsltFile -eq "FitNesseToDetailedResults.xslt" }
    Mock -CommandName Transform -MockWith { return $nunitResultTransformed } -ParameterFilter { $XsltFile -eq "FitNesseToNUnit3.xslt" }
    $savedFiles = [System.Collections.ArrayList]@()

    Context "include html" {
        Mock -CommandName Get-TaskParameter -MockWith { return @{'Resultfolder'='.'; 'IncludeHtml'=$true } }        
        Mock -CommandName Out-File -MockWith { $savedFiles.Add(($FilePath, $InputObject)) }
        Mock -CommandName SaveXml -MockWith { $savedFiles.Add(($OutFile, $xml)) }

        it "Invokes FitNesse and creates 4 result files, detail result name from summary result" {
            $nunitResultFinal=(GetNunitResult -FileName ".\test.html")
            $savedFiles.Clear()
            $savedFiles.Count | Should -Be 0
            MainHelper
            Assert-MockCalled -CommandName Invoke-FitNesse -Times 1 -Exactly -Scope It
            $savedFiles.Count | Should -Be 4
            $savedFiles[0][0] | Should -Be ".\FitNesse.xml"
            $savedFiles[0][1] | Should -Be $extractedResult
            $savedFiles[1][0] | Should -Be ".\Results.xml"
            $SavedFiles[1][1] | Should -Be $extractedResult
            $savedFiles[2][0] | Should -Be ".\test.html"
            $savedFiles[2][1] | Should -Be $detailHtml
            $savedFiles[3][0] | Should -Be ".\results_nunit.xml"
            $savedFiles[3][1] | Should -Be $nunitResultFinal
        }

        it "Invokes FitNesse and creates 4 result files, default detail result name" {
            $nunitResultFinal=(GetNunitResult -FileName ".\DetailedResults.html")
            $extractedResult = "<?xml version=`"1.0`"?><root />"
            $savedFiles.Clear()
            $savedFiles.Count | Should -Be 0
            MainHelper
            Assert-MockCalled -CommandName Invoke-FitNesse -Times 1 -Exactly -Scope It
            $savedFiles.Count | Should -Be 4
            $savedFiles[0][0] | Should -Be ".\FitNesse.xml"
            $savedFiles[0][1] | Should -Be $extractedResult
            $savedFiles[1][0] | Should -Be ".\Results.xml"
            $SavedFiles[1][1] | Should -Be $extractedResult
            $savedFiles[2][0] | Should -Be ".\DetailedResults.html"
            $savedFiles[2][1] | Should -Be $detailHtml
            $savedFiles[3][0] | Should -Be ".\results_nunit.xml"
            $savedFiles[3][1] | Should -Be $nunitResultFinal
        }
    }
    
	function TestXml([string]$ExpectedXml, [string]$ActualFile) {
		Test-Path -Path $ActualFile | Should -Be $true
		[xml]$actualXml = Get-Content -Path $ActualFile
		$actualXml.OuterXml | Should -Be $ExpectedXml 
	}

    Context "Do not include html" {
        $extractedResult = "<?xml version=`"1.0`"?><root />"
        $nunitResultFinal=GetNUnitResult
		# we need to use $TestDrive instead of "TestDrive:\" because we use .Net objects
		$script:resultFolder="$TestDrive\results"
        Mock -CommandName Get-TaskParameter -MockWith { return @{'ResultFolder'="$script:resultFolder"; 'IncludeHtml'=$false } }
		Mock -CommandName DidAllTestsPass -MockWith { return $true }
        it "Invokes FitNesse and creates 3 result files" {
            MainHelper
			Test-Path -Path "$script:resultFolder" | Should -Be $true
            Assert-MockCalled -CommandName Invoke-FitNesse -Times 1 -Exactly -Scope It
			(Get-ChildItem -Path "$script:resultFolder").Count | Should -Be 3
			TestXml -ExpectedXml $extractedResult -ActualFile "$script:resultFolder\FitNesse.xml"
			TestXml -ExpectedXml $extractedResult -ActualFile "$script:resultFolder\Results.xml"
			TestXml -ExpectedXml $nunitResultFinal -ActualFile "$script:resultFolder\\results_nunit.xml"
        }
    }
}

# Ad hoc functions below - generation of test case data based on a FitNesse result

Function Format-Xml([xml]$Content) {
    $StringWriter = New-Object System.IO.StringWriter 
    $XmlWriter = New-Object System.XMl.XmlTextWriter $StringWriter 
    $xmlWriter.Formatting = "indented" 
    $xmlWriter.Indentation = 2    
    $Content.WriteContentTo($XmlWriter) 
    $XmlWriter.Flush()
    $StringWriter.Flush() 
    return $StringWriter.ToString()
}

Function AddExpectation([xml]$InputXml, [Xml.XmlNode]$TargetNode, [string]$XsltFile, [string]$NodeXPath) {
    if (!($TargetNode.SelectSingleNode($NodeXPath))) { return }
    $transformedOutput = (Transform -InputXml $sourceXml -XsltFile $XsltFile)
    $nodeToAddTo = $TargetNode.SelectSingleNode($NodeXPath)
    $nodeToAddTo.RemoveAll()
    if ($nodeXPath -eq "expectedDetails") {
        $nodeToAdd = $TargetNode.OwnerDocument.CreateCDataSection($transformedOutput)
    } else {
        $transformedXml = [xml] $transformedOutput
        $nodeToAdd = $TargetNode.OwnerDocument.ImportNode($transformedXml.DocumentElement, $true)
    }
    $nodeToAddTo.AppendChild($nodeToAdd)
} 

# make this a describe block to enable
Function FitNesseRun-Save {
    it "runs" {
        [xml]$testcases = [xml](Get-Content "$PSScriptRoot\xslTests.xml")
        $testcase = $testcases.SelectSingleNode("/testcases/testcase[@name='XmlTagInContent']") 
        $testcase | Should -Not -BeNullOrEmpty
        $sourceXml = [xml]($testcase.fitnesseInput.InnerXml)
        $sourceXml | Should -Not -BeNullOrEmpty
        #AddExpectation -InputXml $sourceXml -TargetNode $testcase -XsltFile "FitNesseToSummaryResult.xslt" -NodeXPath "expectedOutput"
        #AddExpectation -InputXml $sourceXml -TargetNode $testcase -XsltFile "FitNesseToNunit.xslt" -NodeXPath "expectedNUnitOutput"
        #AddExpectation -InputXml $sourceXml -TargetNode $testcase -XsltFile "FitNesseToNunit3.xslt" -NodeXPath "expectedNUnit3Output"
        AddExpectation -InputXml $sourceXml -TargetNode $testcase -XsltFile "FitNesseToDetailedResults.xslt" -NodeXPath "expectedDetails"
        Write-Host (Format-Xml -Content $testcase.OuterXml)
        #$testcases.Save((join-path -Path (resolve-path ".") -ChildPath "xslTests.New.xml"))
        $testcases.Save("$PSScriptRoot\xslTests.New.xml")
    }
}