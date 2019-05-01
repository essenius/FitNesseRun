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

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sut = (Split-Path -Leaf $MyInvocation.MyCommand.Path) -replace '\.Tests\.', '.'

. "$here\$sut"

Describe "FitNesseConfigure-AddFirefoxBinaryToPath" {
    Context "Firefox in the path" {
        Mock -CommandName Find-InPath -MockWith { return "c:\firefox.exe" }
        Mock -CommandName GetFirefoxInstallFolderFromRegisty -MockWith {}
        Mock -CommandName Add-ToPath -MockWith {  }
        it "should not do anything" {
            AddFirefoxBinaryToPath
            Assert-MockCalled -CommandName GetFirefoxInstallFolderFromRegisty -Times 0 -Exactly -Scope It
            Assert-MockCalled -CommandName Add-ToPath -Times 0 -Exactly -Scope It
        }
    }
    Context "Firefox not in the path, and not found in registry" {
        Mock -CommandName Find-InPath -MockWith { return $null }
        Mock -CommandName GetFirefoxInstallFolderFromRegisty -MockWith {}
        Mock -CommandName Add-ToPath -MockWith {}
        It "should not do anything" {
            AddFirefoxBinaryToPath
            Assert-MockCalled -CommandName GetFirefoxInstallFolderFromRegisty -Times 1 -Exactly -Scope It
            Assert-MockCalled -CommandName Add-ToPath -Times 0 -Exactly -Scope It
        }
    }
    Context "Firefox not in the path, and found in registry" {
        Mock -CommandName Find-InPath -MockWith { return $null }
        Mock -CommandName GetFirefoxInstallFolderFromRegisty -MockWith { return "c:\firefox" }
        Mock -CommandName Add-ToPath  { $script:Path = $Path }
        It "should add Firefox installation folder to Path" {
            $script:Path = $null
            AddFirefoxBinaryToPath
            $Script:Path | Should -Be "c:\firefox"
        }
    }
}

Describe "FitNesseConfigure-GetModuleFolder" {
    Mock -CommandName RunningOnAgent -MockWith { return $true }
    it "should return $PSScriptRoot" {
        GetModuleFolder | Should -Be $PSScriptRoot
    }
}

Describe "FitNesseConfigure-ConvertToPortList" {
        # -ModuleName means that the mock is called from the context of the function (not where it's defined)
        Mock -ModuleName CommonFunctions -CommandName Exit-WithError -MockWith { throw $Message }
        it "should convert numerical port specs correctly"  {
            ConvertToPortList -PortSpec "3-7"  | Should -Be @('3','4','5','6','7')
            ConvertToPortList -PortSpec 3  | Should -Be @('3')
            ConvertToPortList -PortSpec @(3,"8-10","17-19")   | Should -Be @('3','8','9','10','17','18','19')
            ConvertToPortList -PortSpec "non-numeric"   | Should -Be @('non-numeric')
        }
}

Describe "FitNesseConfigure-ConvertToPortRange" {
        Mock -ModuleName CommonFunctions -CommandName Exit-WithError -MockWith { throw $Message }
        it "should throw if Port is not numeric" {
            { ConvertToPortRange -Port "a" }  | Should -Throw "Port: 'a' is no positive number"
            { ConvertToPortRange -Port 1 } | Should -Throw "PoolSize: '' is no positive number"
        }
        it "should convert numerical port specs correctly" {
            ConvertToPortRange -Port 3 -PoolSize 5  | Should -Be '3-7'
            ConvertToPortRange -Port 3 -PoolSize 1  | Should -Be '3'
        }
}

Describe "FitNesseConfigure-GetFirefoxInstallFolderFromRegisty" {
    Context "Firefox not installed" {
        Mock -CommandName Get-ChildItem -MockWith { return $null }
        it "should return null" {
            GetFirefoxInstallFolderFromRegisty | Should -BeNull
        }
    }
    Context "Firefox found in hklm, and tree is correct" {
        Mock -CommandName Get-ChildItem -MockWith { if ($path.StartsWith("hklm")) { return @{'Property'='Install Directory'} } else { return $null } }
        Mock -CommandName Get-ItemProperty -MockWith { return @{'Install Directory'='c:\firefox1'} }
        it "should return c:\firefox1" {
            GetFirefoxInstallFolderFromRegisty | Should -Be "c:\firefox1"
        }
    }
    Context "Firefox not found in hklm, found in hkcu, but tree is not correct" {
        Mock -CommandName Get-ChildItem -MockWith { if ($path.StartsWith("hkcu")) { return @{'Property'='Bogus'} } else { return $null } }
        Mock -CommandName Get-ItemProperty -MockWith { return @{'Bogus'='wrong'} }
        it "should return null" {
            GetFirefoxInstallFolderFromRegisty | Should -BeNull
        }
    }
}

Describe "FitNesseConfigure-GetIntersection" {
    it "should correctly calculate intersections of arrays" {
        GetIntersection -x @(1,2,3,4) -y (3,4,5,6) | Should -Be @(3,4)
        GetIntersection -x @(1,2,3,4) -y (5,6) | Should -BeNullOrEmpty
        GetIntersection -x @(1,7,8,23) -y (23,1) | Should -Be @(1,23)
    }
}

Describe "FitNesseConfigure-GetPropertyValues" {
    it "should join multiple occurrences of a property into one line separated by commas" {
        GetPropertyValues -Property "test" -Properties @("test=a","test=b","test=a,c","test1=c","q=e") | Should -Be @("a","b","c")
        GetPropertyValues -Property "test" -Properties @("test1=c","q=e") | Should -Be @()
    }
}

Describe "FitNesseConfigure-MergeProperties" {
    it "should join multiple occurrences of a property into one line separated by commas" {
        MergeProperties -Properties @() | Should -Be @()
        MergeProperties -Properties @("test=a") | Should -Be @("test=a")
        MergeProperties -Properties @("SymbolTypes=a","SymbolTypes=b","SymbolTypes=a,c","test1=c","SlimTables=3","q=e","SlimTables=q") | 
            Should -Be @("test1=c","q=e","SymbolTypes=a,b,c","SlimTables=3,q")
    }
}

Describe "FitNesseConfigure-ShowBlockedPorts" {
    Mock -CommandName Get-NetFirewallPortFilter -MockWith {
        # We need this to be able to pass it into a pipe
        $cim = New-CimInstance -Namespace "root/standardcimv2" -ClassName "MSFT_NetProtocolPortFilter" `
                               -ClientOnly -Property @{'InstanceID'='aa';'LocalPort'=@("1-3","7")}
        return @($cim)
    }
    Mock -CommandName Out-Issue -MockWith { $script:Message = $Message }
    Context "One rule" {
        Mock -CommandName Get-NetFirewallRule -MockWith {
            return @(@{'Enabled'='True';'Profile'='Domain'; 'Action'='Block'; 'Direction'='Inbound'; 'Protocol'='TCP'; 'DisplayName'='bb'})
        }
        it "should not output a message if there are no blocked ports in the port list" {
            $script:Message = ""
            ShowBlockedPorts -PortRange @("4")
            $script:Message | should -BeNullOrEmpty
        }
        it "should output a message if there are blocked ports in the port list" {
            $script:Message = ""
            ShowBlockedPorts -PortRange "3-5"
            $script:Message | should -Be ("There is already a firewall rule 'bb' blocking incoming traffic on ports in the range '3-5'." +
                " This overrules a firewall rule allowing it. Please resolve this manually.")
        }
    }

    Context "Two rules" {
        Mock -CommandName Get-NetFirewallRule -MockWith {
            return @(@{'Enabled'='True';'Profile'='Domain'; 'Action'='Block'; 'Direction'='Inbound'; 'Protocol'='TCP'; 'DisplayName'='bb'},
                     @{'Enabled'='True';'Profile'='Domain'; 'Action'='Block'; 'Direction'='Inbound'; 'Protocol'='TCP'; 'DisplayName'='aa'})
        }
        it "should output a message if there are blocked ports in the port list" {
            $script:Message = ""
            ShowBlockedPorts -PortRange @(1)
            $script:Message | should -Be ("There are already firewall rules 'bb, aa' blocking incoming traffic on ports in the range '1'." +
                " This overrules a firewall rule allowing it. Please resolve this manually.")
        }
    }
}

Describe "FitNesseConfigure-TestRuleAppliesTo" {
    it "determines correctly if a propertie applies" {
        TestRuleAppliesTo -RuleValue "All" -FilterValue "Domain" | Should -Be $True
        TestRuleAppliesTo -RuleValue "Any" -FilterValue "TCP" | Should -Be $True
        TestRuleAppliesTo -RuleValue "TCP" -FilterValue "TCP" | Should -Be $True
        TestRuleAppliesTo -RuleValue "UDP" -FilterValue "TCP" | Should -Be $False
    }
}

Describe "FitNesseConfigure-TestRuleOk" {
    it "determines correctly if a value is in scope" {
        TestRuleOk -Rule @{'Enabled'='True';'Profile'='Domain';'Direction'='Inbound'} | Should -Be $true
        TestRuleOk -Rule @{'Enabled'='True';'Profile'='All';'Direction'='Inbound'} | Should -Be $true
        TestRuleOk -Rule @{'Enabled'='False';'Profile'='Domain';'Direction'='Inbound'} | Should -Be $false
        TestRuleOk -Rule @{'Enabled'='True';'Profile'='Private';'Direction'='Inbound'} | Should -Be $false
        TestRuleOk -Rule @{'Enabled'='True';'Profile'='Domain';'Direction'='Outbound'} | Should -Be $false
    }
}

Describe "FitNesseConfigure-Unblock-IncomingTraffic" {
    Mock -CommandName ShowBlockedPorts -MockWith {}
    Mock -CommandName New-NetFirewallRule -MockWith {}
    Mock -CommandName Set-NetFirewallRule -MockWith {}
    Mock -CommandName Out-Log -MockWith  { $script:Message = $Message }
    Context "Found rule with right name" {
        it "should set the rule" {
            $script:Message = ""
            Mock -CommandName Get-NetFirewallRule -MockWith { return @{'Action'='Allow'} }
            Unblock-IncomingTraffic -Port 123 -Description "MyApp"
            $script:Message | Should -Be " Updating existing firewall rule 'MyApp (port 123)' to allow incoming traffic"
            Assert-MockCalled -CommandName New-NetFirewallRule -Times 0 -Exactly -Scope It
            Assert-MockCalled -CommandName Set-NetFirewallRule -Times 1 -Exactly -Scope It
            Assert-MockCalled -CommandName ShowBlockedPorts -Times 1 -Exactly -Scope It
        }
    }
    Context "Did not find rule" {
        it "should create the rule" {
            $script:Message=""
            Mock -CommandName Get-NetFirewallRule -MockWith { return $null }
            Unblock-IncomingTraffic -Port 123 -PoolSize 3 -Description "MyMultiPortApp"
            $script:Message | Should -Be " Creating new firewall rule 'MyMultiPortApp (port 123-125)' to allow incoming traffic"
            Assert-MockCalled -CommandName New-NetFirewallRule -Times 1 -Exactly -Scope It
            Assert-MockCalled -CommandName Set-NetFirewallRule -Times 0 -Exactly -Scope It
            Assert-MockCalled -CommandName ShowBlockedPorts -Times 1 -Exactly -Scope It
        }
    }
}

Describe "FitNesseConfigure-WritePropertiesFile" {
    $script:count = 0
    $parameters=@{'port'='9123';'slimPort'='8123';'slimTimeout'='30';'slimPoolSize'='7'}
    $propertiesFile = "TestDrive:\plugins.properties"
    it "should create a new properties file with the right content" {
        Test-Path -Path $propertiesFile | Should -Be $false
        Write-PropertiesFile -TargetFolder "TestDrive:\" -FitSharpFolder "D:\" -Parameters $parameters
        Test-Path -Path $propertiesFile | Should -Be $true
        $propertiesFile | Should -FileContentMatch "FITSHARP_PATH=D:\\"
        $propertiesFile | Should -FileContentMatch "Port=9123"
        $propertiesFile | Should -FileContentMatch "SLIM_PORT=8123"
        $propertiesFile | Should -FileContentMatch "slim.timeout=30"
        $propertiesFile | Should -FileContentMatch "slim.pool.size=7"
        $propertiesFile | Should -FileContentMatch 'FITNESSE_ROOT=\${FITNESSE_ROOTPATH}\\\\\${FitNesseRoot}'
        $propertiesFile | Should -FileContentMatch 'COMMAND_PATTERN=%m -r fitsharp\.Slim\.Service\.Runner,"\$\{FITSHARP_PATH\}\\\\fitsharp\.dll" %p'
        $script:count = (Get-Content -Path $propertiesFile).count
        $script:count | Should -Be 10

    }
    it "should overwrite an existing setting if it exists" {
        "FITSHARP_PATH=E:\\" | Out-File $propertiesFile -Encoding Default
        Write-PropertiesFile -TargetFolder "TestDrive:\" -FitSharpFolder "D:\" -Parameters $parameters
        Test-Path -Path $propertiesFile | Should -Be $true
        $propertiesFile | Should -FileContentMatch "FITSHARP_PATH=D:\\"
        $propertiesFile | Should -FileContentMatch "slim.timeout=30"
    }
    it "should include content of extra plugins.properties.* files" {
        Out-File -FilePath "TestDrive:\plugins.properties.1" -InputObject "SymbolTypes=PiSymbolType"
        Out-File -FilePath "TestDrive:\plugins.properties.2" -InputObject "SymbolTypes=InsertSymbolType,PiSymbolType"
        Out-File -FilePath "TestDrive:\plugins.properties.3" -InputObject "SymbolTypes=InsertSymbolType,FitNessePathSymbolType"
        Write-PropertiesFile -TargetFolder "TestDrive:\" -FitSharpFolder "D:\" -Parameters $parameters
        Test-Path -Path $propertiesFile | Should -Be $true
        $propertiesFile | Should -FileContentMatch "FITSHARP_PATH=D:\\"
        $propertiesFile | Should -FileContentMatch "SymbolTypes=FitNessePathSymbolType,InsertSymbolType,PiSymbolType"
        (Get-Content -Path $propertiesFile).Count | Should -Be ($script:count + 1)
    }
}

Describe "FitNesseConfigure-MainHelper" {
    Mock -CommandName AddFirefoxBinaryToPath -MockWith { }
    Mock -CommandName Find-UnderFolder -MockWith { return "c:\a\b.jar" }
    Mock -CommandName Write-OutputVariable -MockWith { $script:variable += "$Name = $Value;" }
    Mock -CommandName Get-NetFirewallPortFilter -MockWith { return $null }
    Mock -CommandName New-NetFirewallRule -MockWith { $script:Rule += $DisplayName }
    Mock -CommandName Set-NetFirewallRule -MockWith { $script:Rule += $DisplayName }

    $script:packagePath = Join-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -ChildPath "TestData"

    It "should not clean up if not told to, copy all folders and files to the right locations, and create new rules if not existing" {
        Mock Get-Parameters { return @{'TargetFolder'= "$($script:basePath)"; 'PackageFolder'="$($script:packagePath)";
            'Port'='1';'SlimPort'='2';'SlimPoolSize'='3';'SlimTimeout'='4';'CleanupTarget'='true';'UnblockPorts'='true' } }
        Mock -CommandName Get-NetFirewallRule -MockWith { return $null }
        $script:Rule = @()
        $script:basePath = 'Testdrive:\FitNesseDeploy_MainHelper'
        
        New-Item -Path $basePath\FitNesseRoot\test.txt -Force | out-null
        $script:variable = ""
        MainHelper
        (Test-Path -Path $basePath\FitNesseRoot\test.txt) | Should -Be $false
        $propertiesFile = "$script:basePath\plugins.properties"
        (Test-Path -Path $propertiesFile) | Should -Be $true
        $propertiesFile | Should -FileContentMatch "FITSHARP_PATH=c:\\\\a"
        (Get-ChildItem -Recurse -Path $basePath).Count | Should -Be 10
        (Get-ChildItem -Recurse -Path "$basePath\Fixtures").Count | Should -Be 4
        (Get-ChildItem -Recurse -Path "$basePath\FitNesseRoot").Count | Should -Be 1
        (Test-Path -Path "$basePath\Fixtures\fixtures.txt") | Should -Be $true
        (Test-Path -Path "$basePath\FitNesseRoot\wiki.txt") | Should -Be $true
        (Test-Path -Path "$basePath\Website\website.txt") | Should -Be $true
        (Test-Path -Path "$basePath\Fixtures\browser.txt") | Should -Be $true
        (Test-Path -Path "$basePath\Fixtures\tool1\tools.txt") | Should -Be $true
        $script:variable | Should -Be ("FitNesse.StartCommand = java -jar c:\a\b.jar -d $($script:basePath) -e 0 -o;"+
        "FitNesse.WorkFolder = $($script:basePath)\Fixtures;")
        Assert-MockCalled -CommandName AddFirefoxBinaryToPath -Times 1 -Exactly -Scope It
        Assert-MockCalled -CommandName New-NetFirewallRule -Times 2 -Exactly -Scope It
        $script:Rule | Should -be @('FitNesse (port 1)','FitSharp (port 2-4)')
    }
    it "should not clean up if told not to, and update existing rules" {
        Mock Get-Parameters { return @{'TargetFolder'= "$($script:basePath)"; 'PackageFolder'="$($script:packagePath)";
            'Port'='5';'SlimPort'='6';'SlimPoolSize'='7';'SlimTimeout'='8';'CleanupTarget'='false';'UnblockPorts'='true' } }
        Mock -CommandName Get-NetFirewallRule -MockWith { return "not null" }
        $script:Rule = @()
        New-Item -Path $basePath\FitNesseRoot\test.txt -Force | out-null
        MainHelper
        (Test-Path -Path $basePath\FitNesseRoot\test.txt) | Should -Be $true
        (Get-ChildItem -Recurse -Path $basePath).Count | Should -Be 11
        Assert-MockCalled -CommandName Set-NetFirewallRule -Times 2 -Exactly -Scope It
        $script:Rule | Should -be @('FitNesse (port 5)','FitSharp (port 6-12)')
    }
    it "should not try to unblock ports if not requested" {
        Mock Get-Parameters { return @{'TargetFolder'= "$($script:basePath)"; 'PackageFolder'="$($script:packagePath)";
            'Port'='5';'SlimPort'='6';'SlimPoolSize'='7';'SlimTimeout'='8';'CleanupTarget'='false';'UnblockPorts'='false' } }
        Mock -CommandName Unblock-IncomingTraffic -MockWith {}
        MainHelper
        Assert-MockCalled -CommandName Unblock-IncomingTraffic -Times 0 -Exactly -Scope It
    }
}