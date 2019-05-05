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

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sut = (Split-Path -Leaf $MyInvocation.MyCommand.Path) -replace '\.Tests\.', '.'

. "$here\$sut"

Describe "CommonFunctions-Exit-WithError" {
    It "should exit with a message" {
        Mock -CommandName "ExitScript" -MockWith {}
        Mock -CommandName "Out-Log" -MockWith { $script:Message = "<$Message>" }
        Exit-WithError -Message "My Message"
        Assert-MockCalled -CommandName "ExitScript" -Times 1 -Exactly
        Assert-MockCalled -CommandName "Out-Log" -Times 1 -Exactly
        $script:Message | Should -Be "<My Message>"
    }
}

Describe "RunTestsAndPackage-Get-Version" {
    Out-File -InputObject '{"name":"FitNesseRun","version":"0.4.15","publisher":"rikessenius"}' -FilePath "TestDrive:\test.json"
    it "shoud correctly extract the version" {
        (Get-Version -FilePath "TestDrive:\test.json").ToString() | Should -Be "0.4.15"
    }
}

Describe "RunTestsAndPackage-Get-NextVersion" {
    it "shoud correctly get the nextversion" {
        $current = New-Object -TypeName System.Version -ArgumentList "1.2.3"
        (Get-NextVersion -Version $current).ToString() | Should -Be "1.2.4"
    }
}

Describe "RunTestsAndPackage-Invoke-Tests" {
    Mock -CommandName Exit-WithError -MockWith { throw $Message }
    $script:TestResult = @{'FailedCount'='0';'PassedCount'='1';'CodeCoverage'=@{'NumberOfCommandsExecuted'='96';'NumberOfCommandsAnalyzed'='100'}}
    Mock -CommandName Invoke-Pester -MockWith { 
        $script:Script = $Script
        $script:CodeCoverage = $CodeCoverage
        return $script:TestResult 
    }
    it "shoud default the CodeCoverage file, invoke Pester, and not throw" {
        Invoke-Tests -Folder "qq"
        $script:Script | Should -Be "qq\*.tests.ps1"
        $script:CodeCoverage | Should -Be "qq\qq.ps1"
    }
    it "shoud use specified CodeCoverage file, invoke Pester and throw because of test failure" {
        $Script:TestResult.FailedCount = 1
        try {
            { Invoke-Tests -Folder "pp" -CodeCoverage "pp\pp.ps1","pp\qq.ps1" } | Should -Throw "pp: 1 test(s) failed"
        } finally {
            $script:Script | Should -Be "pp\*.tests.ps1"
            "$($script:CodeCoverage)" | Should -Be "pp\pp.ps1 pp\qq.ps1"
            $Script:TestResult.FailedCount = 0
        }
    }
    it "shoud use specified CodeCoverage file, invoke Pester and throw because of no pass count" {
        $Script:TestResult.PassedCount = 0
        try {
            { Invoke-Tests -Folder "rr" -CodeCoverage "rr\pp.ps1" } | Should -Throw "rr: no passing tests"
        } finally {
            $script:Script | Should -Be "rr\*.tests.ps1"
            "$($script:CodeCoverage)" | Should -Be "rr\pp.ps1"
            $Script:TestResult.PassedCount = 1
        }
    }
    it "shoud default the CodeCoverage file, invoke Pester and throw because of insuffficient coverage" {
        $Script:TestResult.CodeCoverage.NumberOfCommandsExecuted = 87
        try {
            { Invoke-Tests -Folder "ss" } | Should -Throw "ss: Missed 13 (more than 5) commands; code coverage is 87%"
        } finally {
            $script:Script | Should -Be "ss\*.tests.ps1"
            $script:CodeCoverage | Should -Be "ss\ss.ps1"
            $Script:TestResult.CodeCoverage.NumberOfCommandsExecuted = 96
        }
	}

	it "shoud find the right version if specified" {
		Invoke-Tests -Folder "tt" -MainVersion 0
		$script:Script | Should -Be "tt\ttV0\*.tests.ps1"
		$script:CodeCoverage | Should -Be "tt\ttV0\tt.ps1"
    }
}

Describe "RunTestsAndPackage-Save-ToJson" {
    $object = @{'id'='FitNesseRun';'version'='1.2.3'}
    $expected = '{"id":"FitNesseRun","version":"1.2.3"}'
    Context "Pre-existing file and backup file" {
        Out-File -InputObject "json file"  -FilePath "TestDrive:\test1.json" 
        Out-File -InputObject "backup file"  -FilePath "TestDrive:\test1.backup" 
        it "shoud correctly save to Json" {
            Save-ToJson -Object $object -FilePath "TestDrive:\test1.json"
            "TestDrive:\test1.backup" | Should -FileContentMatch "json file"
            "$(Get-Content -Path "TestDrive:\test1.json")".replace(' ','').replace("`n",'').replace("`r",'') | Should -Be $expected 
        }
    }
    Context "Pre-existing file, no backup file" {
        Out-File -InputObject "json file"  -FilePath "TestDrive:\test2.json" 
        it "shoud correctly save to Json" {
            Save-ToJson -Object $object -FilePath "TestDrive:\test2.json"
            "TestDrive:\test2.backup" | Should -FileContentMatch "json file"
            "$(Get-Content -Raw -Path "TestDrive:\test2.json")".replace(' ','').replace("`n",'').replace("`r",'') | Should -Be $expected
        }
    }
    Context "No pre-existing file, no backup file" {
        it "shoud correctly save to Json" {
            Save-ToJson -Object $object -FilePath "TestDrive:\test3.json"
            Test-Path -Path "TestDrive:\test3.backup" | should -Be $false
            "$(Get-Content -Path "TestDrive:\test3.json")".replace(' ','').replace("`n",'').replace("`r",'') | Should -Be $expected
        }
    }
}

Describe "RunTestsAndPackage-Set-VersionInExtension" {
    it "shoud correctly set the version in vssextension.json" {
        $jsonFile = "TestDrive:\test.json"
        Out-File -InputObject '{"name":"FitNesseRun","version":"0.4.15","publisher":"rikessenius"}' -FilePath $jsonFile
        (Get-Version -FilePath $jsonFile).ToString() | Should -Be "0.4.15"
        $version = New-Object -TypeName "System.Version" -ArgumentList "3.4.5"
        Set-VersionInextension -FilePath $jsonFile -Version $version
        (Get-Version -FilePath $jsonFile).ToString() | Should -Be "3.4.5"
    }
}

Describe "RunTestsAndPackage-Set-VersionInTask" {
    it "shoud correctly set the version in vssextension.json" {
        $jsonIn='{"name": "FitNesseRun","author": "Rik Essenius","helpMarkDown": "Version 0.4.15","category": "Test",' +
               '"version": {"Major": "0","Minor": "4","Patch": "15"},"minimumAgentVersion": "1.95.0"}'
        New-Item -Path "TestDrive:\Test" -ItemType "Directory"
        $jsonFile = "TestDrive:\Test\task.json"
        Out-File -InputObject $jsonIn -FilePath $jsonFile
        $version = New-Object -TypeName "System.Version" -ArgumentList "6.7.8"
        Set-VersionInTask -TaskName "TestDrive:\Test" -Version $version
        $task = Get-Content -Raw -Path $jsonFile | convertfrom-json
        $task.Version.Major | should -be 6
        $task.Version.Minor | should -be 7
        $task.Version.Patch | should -be 8
        $task.helpMarkDown | should -be "Version 6.7.8"
        $task.name | Should -Be "FitNesseRun"
        $task.minimumAgentVersion | Should -Be "1.95.0"
    }
	    it "shoud correctly set the version in task.json with main version" {
        $jsonIn='{"name": "FitNesseRun","author": "Rik Essenius","helpMarkDown": "Version 0.4.15","category": "Test",' +
               '"version": {"Major": "0","Minor": "4","Patch": "15"},"minimumAgentVersion": "1.95.0"}'
        New-Item -Path "TestDrive:\Test1\Test1V0" -ItemType "Directory" 
        $jsonFile = "TestDrive:\Test1\Test1V0\task.json"
        Out-File -InputObject $jsonIn -FilePath $jsonFile
        $version = New-Object -TypeName "System.Version" -ArgumentList "9.10.11"
        Set-VersionInTask -TaskName "TestDrive:\Test1" -Version $version -MainVersion 0
        $task = Get-Content -Raw -Path $jsonFile | convertfrom-json
        $task.Version.Major | should -be 9
        $task.Version.Minor | should -be 10
        $task.Version.Patch | should -be 11
        $task.helpMarkDown | should -be "Version 9.10.11"
        $task.name | Should -Be "FitNesseRun"
        $task.minimumAgentVersion | Should -Be "1.95.0"
    }
}

Describe "RunTestsAndPackage-MainHelper" {
    Mock -CommandName Invoke-Tests -MockWith { }
    Mock -CommandName Get-Version -MockWith { return New-Object -TypeName System.Version -ArgumentList "12.13.14" }
    Mock -CommandName Set-VersionInExtension -MockWith { $script:newVersion = $Version}
    Mock -CommandName Set-VersionInTask -MockWith { }
    Mock -CommandName Invoke-Tfx -MockWith { }

    it "should run tests if NoTest is false, and invoke Tfx but not update the version if VersionAction is Ignore" {
        MainHelper -VersionAction "Ignore" -NoTest $False -NoPackage $false
        Assert-MockCalled -CommandName Invoke-Tests -Times 3 -Exactly -Scope It
        Assert-MockCalled -CommandName Set-VersionInExtension -Times 0 -Exactly -Scope It
        Assert-MockCalled -CommandName Invoke-Tfx -Times 1 -Exactly -Scope It
    }
    it "shoud not run tests if NoTest is true, update the version and invoke Tfx if VersionAction is Next" {
        MainHelper -VersionAction "Next" -NoTest $True -NoPackage $false
        Assert-MockCalled -CommandName Invoke-Tests -Times 0 -Exactly -Scope It
        Assert-MockCalled -CommandName Get-Version -Times 1 -Exactly -Scope It
        "$script:newVersion" | should be "12.13.15"
        Assert-MockCalled -CommandName Set-VersionInextension -Times 1 -Exactly -Scope It
        Assert-MockCalled -CommandName Set-VersionInTask -Times 2 -Exactly -Scope It
        Assert-MockCalled -CommandName Invoke-Tfx -Times 1 -Exactly -Scope It
    }
    it "shoud not run tests if NoTest is true, not update the version and not invoke Tfx if VersionAction is Sync and NoPackage is set" {
        MainHelper -VersionAction "Sync" -NoTest $true -NoPackage $true
        Assert-MockCalled -CommandName Invoke-Tests -Times 0 -Exactly -Scope It
        Assert-MockCalled -CommandName Get-Version -Times 1 -Exactly -Scope It
        "$script:newVersion" | should be "12.13.14"
        Assert-MockCalled -CommandName Set-VersionInextension -Times 1 -Exactly -Scope It
        Assert-MockCalled -CommandName Set-VersionInTask -Times 2 -Exactly -Scope It
        Assert-MockCalled -CommandName Invoke-Tfx -Times 0 -Exactly -Scope It
    }
}