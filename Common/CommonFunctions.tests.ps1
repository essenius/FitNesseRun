# Copyright 2018-2021 Rik Essenius
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

Get-Module -Name "CommonFunctions" | Remove-Module
Import-Module -Name "$PSScriptRoot\CommonFunctions.psm1"

InModuleScope CommonFunctions { 
    Mock -CommandName "ExitScript" -MockWith {}

    Describe "CommonFunctions-Add-ToPath" {
        Mock -CommandName Write-Information -MockWith { $script:Message = $MessageData }
        It "should write the correct message in the log" {
            $script:Message = ""
            Add-ToPath -Path "c:\apps"
            $script:Message | Should -Be "##vso[task.prependpath]c:\apps"
        } 
    }
    
    Describe "CommonFunctions-Assert-IsPositive" {
        Mock -CommandName "Exit-WithError" -MockWith { throw $Message }    

        It "should allow postive numbers" {
            { Assert-IsPositive -Value 10 } | Should -Not -Throw
            { Assert-IsPositive -Value 0 } | Should -Not -Throw
        }

        it "should throw if the list contains non-numeric or negative values" {
            Mock -CommandName Exit-WithError -MockWith { throw $Message }
            { Assert-IsPositive } | Should -Throw "'' is no positive number"
            { Assert-IsPositive -Value "a" } | Should -Throw "'a' is no positive number"
            { Assert-IsPositive -Value "-1" -Parameter "Port" } | Should -Throw "Port: '-1' is no positive number"
        }
        Assert-MockCalled -CommandName "Exit-WithError" -Times 3 -Exactly -Scope Describe
    }

    Describe "CommonFunctions-Copy-Folders" {
        It "should create the right files and folders in the temp directory" {
            $targetPath = Join-Path -Path "Testdrive:" -ChildPath "FitNesseDeploy_CopyFolders"
            $source = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath "TestData"
            Copy-Folder -SourcePath $source -TargetPath $targetPath -TargetFolder $target
            Test-Path -Path $targetPath | Should -Be $true
            Test-Path -Path "$targetPath\packages.config" | Should -Be $true
            Test-Path -Path "$targetPath\test\Win32\testfile.txt" | Should -Be $true
            Assert-MockCalled -CommandName "ExitScript" -Times 0 -Exactly
        }
    }

    Describe "CommonFunctions-Copy-FromPackages" {
        It "should copy the right data from the packages folder" {
            $targetPath = Join-Path -Path "Testdrive:" -ChildPath "FitNesseDeploy_CopyFromPackages"
            $source = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath "TestData"
            Copy-FromPackage -TargetPath $targetPath -SourceBase $source -SourceFolder "folderToSearch"        
            Test-Path -Path $targetPath | Should -Be $true
            Test-Path -Path "$targetPath\test1\test1.txt" | Should -Be $true
            Test-Path -Path "$targetPath\test2.txt" | Should -Be $false
            (Get-ChildItem "$targetPath" ).Count | Should -Be 1
            Assert-MockCalled -CommandName ExitScript -Times 0 -Exactly
        }
    }

    Describe "CommonFunctions-Exit-WithError" {
        It "should exit with a message" {
            Mock -CommandName "Out-Log" -MockWith { $script:Message += "<$Message>" }
            $script:Message = ""
            Exit-WithError -Message "My Message"
            Assert-MockCalled -CommandName "ExitScript" -Times 1 -Exactly
            $script:Message | Should -Be "<##vso[task.logissue type=error;]My Message><##vso[task.complete result=Failed;]ABORTED>"
        }
    }

    Describe "CommonFunctions-Exit-if" {
        It "should do nothing if the condition is not met" {
            Exit-If -Condition $false
            Assert-MockCalled -CommandName "ExitScript" -Times 0 -Exactly
        }
        It "Should exit with an error message if the condition is met" {
            Mock -CommandName "Exit-WithError" -MockWith { $script:Message = $Message }
            Exit-If -Condition $True -Message "My Message"
            $script:Message | should be "My Message"
        }
    }

    Describe "CommonFunctions-Find-InPath" {
        Mock -CommandName "Exit-WithError" -MockWith { throw $Message }    
        It "can find cmd.exe" {
            { $path = Find-InPath -Command "cmd.exe" -Assert 
            $path | Should -Not -BeNullOrEmpty
            } | Should -Not -Throw
        }
        It "can't find a nonexisting executable" {
            #making the test a lot quicker by emptying the PATH environment variable
            try {
                $path = $Env:Path
                $Env:Path = ""	
                { Find-InPath -Command "qpr2nonexisting.exe" -Description "non-existing command" -Assert } | Should -Throw "Could not find 'qpr2nonexisting.exe'"
            } finally {
                $Env:Path = $path
            }
        }
    }

    Describe "CommonFunctions-Find-UnderFolder" {
        Mock -CommandName "Exit-WithError" -MockWith { throw $Message }    
        It "can find FitNesseRun.ps1 under current folder" {
            { Find-UnderFolder -FileName "CommonFunctions.psm1" -SearchRoot $PSScriptRoot -Assert } | Should -Not -Throw
            Find-UnderFolder -FileName "CommonFunctions.psm1" -SearchRoot $PSScriptRoot -Assert | Should -Not -BeNull
        }
        It "cannot find non-existing file under current folder" {
            { Find-UnderFolder -FileName "qpr2nonexisting.txt" -SearchRoot '.' -Assert } | Should -Throw "Could not find 'qpr2nonexisting.txt' under '.'"
            Find-UnderFolder -FileName "qpr2nonexisting.txt" -SearchRoot '.' | Should -BeNull
        }
    }

    Describe "CommonFunctions-Get-EnvironmentVariable" {
        it "should get values from a specified environment variable" {
            Get-EnvironmentVariable -Key "PATHEXT" | Should -BeLike "*EXE*"
        }
    }

    Describe "CommonFunctions-Get-TaskParameter" {
    # not using mocks here as I don't want to take a dependency on the *-Vsts-* functions
        Function Get-VstsInput([string]$Name)  { return $Name }
        Function Import-VstsLocStrings {}
        Function Trace-VstsEnteringInvocation {}
        Function Trace-VstsLeavingInvocation {}

        It "gets parameters correctly and applies the right casing" {
            $params= Get-TaskParameter -ParameterNames "targetFolder","port","slimPoolSize"
            $params.Count | should be 3
            $keys = $params.Keys.Split('`n')
            $keys -ccontains "Port" | Should -BeTrue 
            #$keys[0] | Should -BeExactly "Port" 
            $params.Port | Should -BeExactly "port"
            $keys -ccontains "SlimPoolSize" | Should -BeTrue
            #$keys[1] | Should -BeExactly "SlimPoolSize" 
            $params.SlimPoolSize | Should -BeExactly "slimPoolSize"
            $keys -ccontains "TargetFolder" | Should -BeTrue 
            #$keys[2] | Should -BeExactly "TargetFolder" 
            $params.TargetFolder | Should -BeExactly "targetFolder"
        }
    }

    Describe "CommonFunctions-Move-FolderContent" {
        Mock -CommandName "Exit-WithError" -MockWith { throw $Message }
        $source = "TestDrive:\source"
        $target = "TestDrive:\Target"
        Context "destination does not exist" {
            it "moves the folder" {
                new-item -Path "$source\file1" -Force
                new-item -Path "$source\Folder\file2" -Force
                (Get-ChildItem -Path $source -Recurse).Count | Should -Be 3
                Move-FolderContent -Path $source -Destination $target
                (Test-Path -Path $source -PathType Container) | Should -Be $false
                (Get-ChildItem -Path $target -Recurse).Count | Should -Be 3
            }
        }
        Context "destination folder contains files" {
            it "merges the folder" {
                (Get-ChildItem -Path $source -Recurse).Count | Should -Be 0
                (Get-ChildItem -Path $target -Recurse).Count | Should -Be 0
                new-item -Path "$source\file1" -Force
                new-item -Path "$source\Folder\file2" -Force
                new-item -Path "$target\file3" -Force
                Move-FolderContent -Path $source -Destination $target
                (Test-Path -Path $source -PathType Container) | Should -Be $false
                (Get-ChildItem -Path $target -Recurse).Count | Should -Be 4
            }
        }
        Context "Destination folder is file" {
            it "throws when tryin to move to a file" {
                new-item -Path "$source\file1" -Force
                new-item -Path "$source\Folder\file2" -Force
                (Get-ChildItem -Path $source -Recurse).Count | Should -Be 3
                new-item -Path $target
                { Move-FolderContent -Path $source -Destination $target } | Should Throw "already exists as a file"
                (Get-ChildItem -Path $source -Recurse).Count | Should -Be 3
                (Test-Path -Path $target -PathType Container) | should -Be $false
            }
        }
        Context "Could not complete move" {
            it "should log a warning" {
                Mock -CommandName Out-Log -MockWith { $script:message = $Message}
                Mock -CommandName Get-ChildItem -ModuleName CommonFunctions -MockWith { return "non-null" }
                new-item -Path "$source\file1" -Force
                new-item -Path "$source\Folder\file2" -Force
                #Set-ItemProperty -Path "$source\file1" -Name "Attributes" -Value "Hidden"
                Move-FolderContent -Path $source -Destination $target 
                # need the backticks because the brackets are special characters for the Like operator
                $script:Message | Should -BeLike "##vso``[task.logissue type=warning;``]Could not remove * after moving contents to *"
            }
        }
    }

    Describe "CommonFunctions-New-FolderIfNeeded" {
        Mock -CommandName New-Item -MockWith {}
        it "should create a new folder if it does not exist" {
            $location = "TestDrive:\testfolder"
            Test-Path -Path $location | Should -Be $false
            New-FolderIfNeeded -Path $location
            Assert-MockCalled -CommandName New-Item -Times 1 -Exactly -Scope It
        }
        it "should not create a new folder if it exists already" {
            $location = "TestDrive:\"
            Test-Path -Path $location | Should -Be $true
            New-FolderIfNeeded -Path $location
            Assert-MockCalled -CommandName New-Item -Times 0 -Exactly -Scope It
        }
    }

    Describe "CommonFunctions-Out-Log" {
        Mock -CommandName "Write-Information" -MockWith { $script:Message = $MessageData}
        it "should not show a debug prefix if the Debug parameter is not used" {
            Out-Log -Message "hello"
            $script:Message | Should -Be "hello"
        }
        it "should show a debug prefix if the Debug parameter is used" {
            Out-Log -Message "hello" -Debug
            $script:Message | Should -Be "##[debug]hello"
        }
        it "should show a Command prefix if the Command parameter is used" {
            Out-Log -Message "hello" -Command
            $script:Message | Should -Be "##[Command]hello"
        }
    }

    Describe "CommonFunctions-Out-Issue" {
        Mock -CommandName Out-Log -MockWith { $script:Message = $Message }
        it "should use an error prefix if Warning parameter is not used" {
            $script:Message = ""
            Out-Issue -Message "My Error Message" 
            $script:Message | Should be "##vso[task.logissue type=error;]My Error Message"
        }
        it "should use a warning prefix if Warning parameter is used" {
            Out-Issue -Message "My Warning Message" -Warning 
            $script:Message | Should be "##vso[task.logissue type=warning;]My Warning Message"
        }
    }

    Describe "CommonFunctions-Test-IsPositive" {
        it "should identify numbers" {
            Test-IsPositive -Value 123 | Should -Be $true
            Test-IsPositive -Value -123 | Should -Be $false
            Test-IsPositive -Value 0 | Should -Be $true
            Test-IsPositive -Value 1ac | Should -Be $false
            Test-IsPositive -Value $null | Should -Be $false
        }
    }
    
    
    Describe "CommonFunctions-Write-OutputVariable" {
        Mock -CommandName Out-Log -MockWith { $script:Message = $Message }
        it "should write the right message" {
            Write-OutputVariable -Name "FitNesse.AppLocation" -Value "c:\apps"
            $Message | Should -Be "##vso[task.setvariable variable=FitNesse.AppLocation;]c:\apps" 
        }
    }
}
