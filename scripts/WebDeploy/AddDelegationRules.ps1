# Web Deploy: Powershell script to set up delegated deployments with Web Deploy
# Copyright (C) Microsoft Corp. 2010
#
# Requirements: IIS 7, Windows Server 2008 (or higher)
#
# elevatedUsername/elevatedPassword: Credentials of a user that has write access to applicationHost.config. Used for createApp, appPoolNetFx, appPoolPipeline delegation rules.
# adminUsername/adminPassword: Credentials of a user that is in the Administrators security group on this server. Used for recycleApp delegation rule.



param(
    $elevatedUsername,

    $elevatedPassword,

    $adminUsername,

    $adminPassword,

    [switch]$ignorePasswordResetErrors
)

# ==================================

Import-LocalizedData -BindingVariable Resources -FileName Resources.psd1

 #constants
 $SCRIPTERROR = 0
 $logfile = ".\HostingLog-$(get-date -format MMddyyHHmmss).log"
 $WARNING = 1
 $INFO = 2

# ================ METHODS =======================

# this function does logging
function write-log([int]$type, [string]$info){

    $message = $info -f $args
    $logMessage = get-date -format HH:mm:ss

    Switch($type){
        $SCRIPTERROR{
            $logMessage = $logMessage + "`t" + $Resources.Error + "`t" +  $message
            write-host -foregroundcolor white -backgroundcolor red $logMessage
        }
        $WARNING{
            $logMessage = $logMessage + "`t" + $Resources.Warning + "`t" +  $message
            write-host -foregroundcolor black -backgroundcolor yellow $logMessage
        }
        default{
            $logMessage = $logMessage + "`t" + $Resources.Info + "`t" +  $message
            write-host -foregroundcolor black -backgroundcolor green  $logMessage
        }
    }

    $logMessage >> $logfile
}

# returns false if OS is not server SKU
 function NotServerOS
 {
    $sku = $((gwmi win32_operatingsystem).OperatingSystemSKU)
    $server_skus = @(7,8,9,10,12,13,14,15,17,18,19,20,21,22,23,24,25)

    return ($server_skus -notcontains $sku)
 }

 function CheckHandlerInstalled
 {
    trap [Exception]
    {
        return $false
    }
    $serverManager = (New-Object Microsoft.Web.Administration.ServerManager)
    $serverManager.GetAdministrationConfiguration().GetSection("system.webServer/management/delegation").GetCollection()
    return $true
 }

 # gives a user permissions to a file on disk
 function GrantPermissionsOnDisk($username, $path, $type, $options)
 {
    trap [Exception]{
        write-log $SCRIPTERROR $Resources.NotGrantedPermissions $type $username $path
    }

    $acl = (Get-Item $path).GetAccessControl("Access")
    $accessrule = New-Object system.security.AccessControl.FileSystemAccessRule($username, $type, $options, "None", "Allow")
    $acl.AddAccessRule($accessrule)
    set-acl -aclobject $acl $path
    $message =
    write-log $INFO $Resources.GrantedPermissions $type $username $path
}

 function GetOrCreateUser($username)
 {
    if(-not (CheckLocalUserExists($username) -eq $true))
    {
        $comp = [adsi] "WinNT://$env:computername,computer"
        $user = $comp.Create("User", $username)
        write-log $INFO $Resources.CreatedUser $username
    }
    else
    {
        $user = [adsi] "WinNT://$env:computername/$username, user"
    }
    return $user
 }

 function GetAdminGroupName()
 {
    $securityIdentifier = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $adminName = $securityIdentifier.Translate([System.Type]::GetType("System.Security.Principal.NTAccount")).ToString()
    $array = $adminName -split "\\"
    if($array.Count -eq 2)
    {
        return $array[1]
    }

    return "Administrators"
 }

 function CreateLocalUser($username, $password, $isAdmin)
 {
    $user = GetOrCreateUser($username)
    $user.SetPassword($password)
    $user.SetInfo()

    if($isAdmin)
    {
        $adminGroupName = GetAdminGroupName
        if(-not((CheckIfUserIsAdmin $adminGroupName $username) -eq $true))
        {
            $group = [ADSI]"WinNT://$env:computername/$adminGroupName,group"
            $group.add("WinNT://$env:computername/$username")
            write-log $INFO $Resources.AddedUserAsAdmin $username
        }
        else
        {
            write-log $INFO $Resources.IsAdmin $username
        }
    }

    return $true
 }

 function CheckLocalUserExists($username)
 {
    $objComputer = [ADSI]("WinNT://$env:computername")
    $colUsers = ($objComputer.psbase.children | Where-Object {$_.psBase.schemaClassName -eq "User"} | Select-Object -expand Name)

    $blnFound = $colUsers -contains $username

    if ($blnFound){
        return $true
    }
    else{
        return $false
    }
 }

 function CheckIfUserIsAdmin($adminGroupName, $username)
 {
    $computer = [ADSI]("WinNT://$env:computername,computer")
    $group = $computer.psbase.children.find($adminGroupName)

    $colMembers = $group.psbase.invoke("Members") | %{$_.GetType().InvokeMember("Name",'GetProperty',$null,$_,$null)}

    $bIsMember = $colMembers -contains $username
    if($bIsMember)
    {
        return $true
    }
    else
    {
        return $false
    }
 }

 function GenerateStrongPassword()
 {
    [System.Reflection.Assembly]::LoadWithPartialName("System.Web") > $null
    return [System.Web.Security.Membership]::GeneratePassword(12,4)
 }

 function Initialize
 {
    trap [Exception]
    {
        write-log $SCRIPTERROR $Resources.CheckIIS7Installed
        break
    }

    [System.Reflection.Assembly]::LoadFrom( ${env:windir} + "\system32\inetsrv\Microsoft.Web.Administration.dll" ) > $null
 }

 # gets path of applicationHost.config
 function GetApplicationHostConfigPath
 {
    return (${env:windir} + "\system32\inetsrv\config\applicationHost.config")
 }
 
function GetValidWebDeployInstallPath()
{
    foreach($number in 3..1)
    {
        $keyPath = "HKLM:\Software\Microsoft\IIS Extensions\MSDeploy\" + $number
        if(Test-Path($keypath))
        {
            return $keypath
        }
    }
    return $null
}

function IsWebDeployInstalled()
 {
    $webDeployKeyPath = GetValidWebDeployInstallpath

    if($webDeployKeyPath)
    {
        $value = (get-item($webDeployKeyPath)).GetValue("Install")
        if($value -eq 1)
        {
            return $true
        }
    }
    return $false
 }

 function CheckRuleExistsAndUpdateRunAs($serverManager, $path, $providers, $identityType, $userName, $password)
 {
    for($i=0;$i-lt $delegationRulesCollection.Count;$i++)
    {
        $providerValue = $delegationRulesCollection[$i].Attributes["providers"].Value
        $pathValue = $delegationRulesCollection[$i].Attributes["path"].Value
        $enabled = $delegationRulesCollection[$i].Attributes["enabled"].Value

        if( $providerValue -eq $providers -AND
            $pathValue -eq $path)
        {
            if($identityType -eq "SpecificUser")
            {
                $runAsElement = $delegationRulesCollection[$i].ChildElements["runAs"];
                $runAsElement.Attributes["userName"].Value = $userName
                $runAsElement.Attributes["password"].Value = $password
                $serverManager.CommitChanges()
                write-log $INFO $Resources.UpdatedRunAsForSpecificUser $providers $username
            }

            if($enabled -eq $false)
            {
                $delegationRulesCollection[$i].Attributes["enabled"].Value = $true
                $serverManager.CommitChanges()
            }
            return $true
        }
    }
    return $false
 }

function CheckSharedConfigNotInUse()
{
    $serverManager = (New-Object Microsoft.Web.Administration.ServerManager)
    $section = $serverManager.GetRedirectionConfiguration().GetSection("configurationRedirection")
    $enabled = [bool]$section["enabled"]
    if ($enabled -eq $true)
    {
        return $false
    }
    return $true
}

 function CreateDelegationRule($providers, $path, $pathType, $identityType, $userName, $password, $enabled)
 {
    $serverManager = (New-Object Microsoft.Web.Administration.ServerManager)
    $delegationRulesCollection = $serverManager.GetAdministrationConfiguration().GetSection("system.webServer/management/delegation").GetCollection()
    if(CheckRuleExistsAndUpdateRunAs $serverManager $path $providers $identityType $userName $password )
    {
        write-log $INFO $Resources.RuleNotCreated $providers
        return
    }

    $newRule = $delegationRulesCollection.CreateElement("rule")
    $newRule.Attributes["providers"].Value = $providers
    $newRule.Attributes["actions"].Value = "*"
    $newRule.Attributes["path"].Value = $path
    $newRule.Attributes["pathType"].Value = $pathType
    $newRule.Attributes["enabled"].Value = $enabled

    $runAs = $newRule.GetChildElement("runAs")

    if($identityType -eq "SpecificUser")
    {
        $runAs.Attributes["identityType"].Value = "SpecificUser"
        $runAs.Attributes["userName"].Value = $userName
        $runAs.Attributes["password"].Value = $password
    }
    else
    {
        $runAs.Attributes["identityType"].Value = "CurrentUser"
    }

    $permissions = $newRule.GetCollection("permissions")
    $user = $permissions.CreateElement("user")
    $user.Attributes["name"].Value = "*"
    $user.Attributes["accessType"].Value = "Allow"
    $user.Attributes["isRole"].Value = "False"
    $permissions.Add($user) | out-null

    $delegationRulesCollection.Add($newRule) | out-null
    $serverManager.CommitChanges()

    write-log $INFO $Resources.CreatedRule $providers
 }

 function CheckUserViaLogon($username, $password)
 {

 $signature = @'
    [DllImport("advapi32.dll")]
    public static extern int LogonUser(
        string lpszUserName,
        string lpszDomain,
        string lpszPassword,
        int dwLogonType,
        int dwLogonProvider,
        ref IntPtr phToken);
'@

    $type = Add-Type -MemberDefinition $signature  -Name Win32Utils -Namespace LogOnUser  -PassThru

    [IntPtr]$token = [IntPtr]::Zero

    $value = $type::LogOnUser($username, $env:computername, $password, 2, 0, [ref] $token)

    if($value -eq 0)
    {
        return $false
    }

    return $true
 }

 function CheckUsernamePasswordCombination($user, $password)
 {
    if($user -AND !$password)
    {
        if(CheckLocalUserExists($user) -eq $true)
        {
            if(!$ignorePasswordResetErrors)
            {
                write-log $SCRIPTERROR $Resources.NoPasswordForGivenUser $user
                return $false
            }
            else
            {
                write-Log $INFO $Resources.PasswordWillBeReset $user
                return $true
            }
        }
    }

    if(($user) -AND ($password))
    {
        if(CheckLocalUserExists($user) -eq $true)
        {
            if(CheckUserViaLogon $user $password)
            {
                return $true
            }
            else
            {
                write-Log $SCRIPTERROR $Resources.FailedToValidateUserWithSpecifiedPassword $user
                return $false
            }
        }
    }

    return $true
 }

#================= Main Script =================

 if(NotServerOS)
 {
    write-log $SCRIPTERROR $Resources.NotServerOS
    break
 }

 Initialize
 if(CheckSharedConfigNotInUse)
 {
     if(IsWebDeployInstalled)
     {
        if(CheckHandlerInstalled)
        {
            if((CheckUsernamePasswordCombination $elevatedUsername $elevatedPassword) -AND
                (CheckUsernamePasswordCombination $adminUsername $adminPassword))
            {

                if(!$elevatedUsername)
                {
                    $elevatedUsername = "WDeployConfigWriter"
                }

                if(!$adminUsername)
                {
                    $adminUsername = "WDeployAdmin"
                }

                if(!$elevatedPassword)
                {
                    $elevatedPassword = GenerateStrongPassword
                }

                if(!$adminPassword)
                {
                    $adminPassword = GenerateStrongPassword
                }

                # create local user which has write access to applicationHost.config and administration.config
                if(CreateLocalUser $elevatedUsername $elevatedPassword $false)
                {
                    # create local admin user which can recycle application pools
                    if(CreateLocalUser $adminUsername $adminPassword $true)
                    {
                        $applicationHostConfigPath = GetApplicationHostConfigPath
                        GrantPermissionsOnDisk $elevatedUsername $applicationHostConfigPath "ReadAndExecute,Write" "None"
                        
                        CreateDelegationRule "contentPath, iisApp" "{userScope}" "PathPrefix" "CurrentUser" "" "" "true"
                        CreateDelegationRule "dbFullSql" "Data Source=" "ConnectionString" "CurrentUser" "" "" "true"
                        CreateDelegationRule "dbDacFx" "Data Source=" "ConnectionString" "CurrentUser" "" "" "true"
                        CreateDelegationRule "dbMySql" "Server=" "ConnectionString" "CurrentUser" "" "" "true"
                        CreateDelegationRule "createApp" "{userScope}" "PathPrefix" "SpecificUser" $elevatedUsername $elevatedPassword "true"
                        CreateDelegationRule "setAcl" "{userScope}" "PathPrefix" "CurrentUser" "" "" "true"
                        CreateDelegationRule "recycleApp" "{userScope}" "PathPrefix" "SpecificUser" $adminUsername $adminPassword "true"
                        CreateDelegationRule "appPoolPipeline,appPoolNetFx" "{userScope}" "PathPrefix" "SpecificUser" $elevatedUsername $elevatedPassword "true"
                        CreateDelegationRule "backupSettings" "{userScope}" "PathPrefix" "SpecificUser" $elevatedUsername $elevatedPassword "true"
                        CreateDelegationRule "backupManager" "{userScope}" "PathPrefix" "CurrentUser" "" "" "true"
                    }
                    else
                    {
                        break
                    }
                }
                else
                {
                    break
                }
            }
            else
            {
                break
            }
        }
        else
        {
            write-log $SCRIPTERROR $Resources.HandlerNotInstalledQ
            break
        }
     }
     else
     {
        write-log $SCRIPTERROR $Resources.WDeployNotInstalled
     }
 }
 else
 {
    write-log $SCRIPTERROR $Resources.SharedConfigInUse
 }

# SIG # Begin signature block
# MIIanQYJKoZIhvcNAQcCoIIajjCCGooCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUox0gcc81IcXowrtqNSzd2fvt
# a+ugghWCMIIEwzCCA6ugAwIBAgITMwAAAHGzLoprgqofTgAAAAAAcTANBgkqhkiG
# 9w0BAQUFADB3MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSEw
# HwYDVQQDExhNaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EwHhcNMTUwMzIwMTczMjAz
# WhcNMTYwNjIwMTczMjAzWjCBszELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjENMAsGA1UECxMETU9QUjEnMCUGA1UECxMebkNpcGhlciBEU0UgRVNO
# OkI4RUMtMzBBNC03MTQ0MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBT
# ZXJ2aWNlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA6pG9soj9FG8h
# NigDZjM6Zgj7W0ukq6AoNEpDMgjAhuXJPdUlvHs+YofWfe8PdFOj8ZFjiHR/6CTN
# A1DF8coAFnulObAGHDxEfvnrxLKBvBcjuv1lOBmFf8qgKf32OsALL2j04DROfW8X
# wG6Zqvp/YSXRJnDSdH3fYXNczlQqOVEDMwn4UK14x4kIttSFKj/X2B9R6u/8aF61
# wecHaDKNL3JR/gMxR1HF0utyB68glfjaavh3Z+RgmnBMq0XLfgiv5YHUV886zBN1
# nSbNoKJpULw6iJTfsFQ43ok5zYYypZAPfr/tzJQlpkGGYSbH3Td+XA3oF8o3f+gk
# tk60+Bsj6wIDAQABo4IBCTCCAQUwHQYDVR0OBBYEFPj9I4cFlIBWzTOlQcJszAg2
# yLKiMB8GA1UdIwQYMBaAFCM0+NlSRnAK7UD7dvuzK7DDNbMPMFQGA1UdHwRNMEsw
# SaBHoEWGQ2h0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3Rz
# L01pY3Jvc29mdFRpbWVTdGFtcFBDQS5jcmwwWAYIKwYBBQUHAQEETDBKMEgGCCsG
# AQUFBzAChjxodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY3Jv
# c29mdFRpbWVTdGFtcFBDQS5jcnQwEwYDVR0lBAwwCgYIKwYBBQUHAwgwDQYJKoZI
# hvcNAQEFBQADggEBAC0EtMopC1n8Luqgr0xOaAT4ku0pwmbMa3DJh+i+h/xd9N1P
# pRpveJetawU4UUFynTnkGhvDbXH8cLbTzLaQWAQoP9Ye74OzFBgMlQv3pRETmMaF
# Vl7uM7QMN7WA6vUSaNkue4YIcjsUe9TZ0BZPwC8LHy3K5RvQrumEsI8LXXO4FoFA
# I1gs6mGq/r1/041acPx5zWaWZWO1BRJ24io7K+2CrJrsJ0Gnlw4jFp9ByE5tUxFA
# BMxgmdqY7Cuul/vgffW6iwD0JRd/Ynq7UVfB8PDNnBthc62VjCt2IqircDi0ASh9
# ZkJT3p/0B3xaMA6CA1n2hIa5FSVisAvSz/HblkUwggTsMIID1KADAgECAhMzAAAB
# Cix5rtd5e6asAAEAAAEKMA0GCSqGSIb3DQEBBQUAMHkxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xIzAhBgNVBAMTGk1pY3Jvc29mdCBDb2RlIFNp
# Z25pbmcgUENBMB4XDTE1MDYwNDE3NDI0NVoXDTE2MDkwNDE3NDI0NVowgYMxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xDTALBgNVBAsTBE1PUFIx
# HjAcBgNVBAMTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjCCASIwDQYJKoZIhvcNAQEB
# BQADggEPADCCAQoCggEBAJL8bza74QO5KNZG0aJhuqVG+2MWPi75R9LH7O3HmbEm
# UXW92swPBhQRpGwZnsBfTVSJ5E1Q2I3NoWGldxOaHKftDXT3p1Z56Cj3U9KxemPg
# 9ZSXt+zZR/hsPfMliLO8CsUEp458hUh2HGFGqhnEemKLwcI1qvtYb8VjC5NJMIEb
# e99/fE+0R21feByvtveWE1LvudFNOeVz3khOPBSqlw05zItR4VzRO/COZ+owYKlN
# Wp1DvdsjusAP10sQnZxN8FGihKrknKc91qPvChhIqPqxTqWYDku/8BTzAMiwSNZb
# /jjXiREtBbpDAk8iAJYlrX01boRoqyAYOCj+HKIQsaUCAwEAAaOCAWAwggFcMBMG
# A1UdJQQMMAoGCCsGAQUFBwMDMB0GA1UdDgQWBBSJ/gox6ibN5m3HkZG5lIyiGGE3
# NDBRBgNVHREESjBIpEYwRDENMAsGA1UECxMETU9QUjEzMDEGA1UEBRMqMzE1OTUr
# MDQwNzkzNTAtMTZmYS00YzYwLWI2YmYtOWQyYjFjZDA1OTg0MB8GA1UdIwQYMBaA
# FMsR6MrStBZYAck3LjMWFrlMmgofMFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9j
# cmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY0NvZFNpZ1BDQV8w
# OC0zMS0yMDEwLmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljQ29kU2lnUENBXzA4LTMx
# LTIwMTAuY3J0MA0GCSqGSIb3DQEBBQUAA4IBAQCmqFOR3zsB/mFdBlrrZvAM2PfZ
# hNMAUQ4Q0aTRFyjnjDM4K9hDxgOLdeszkvSp4mf9AtulHU5DRV0bSePgTxbwfo/w
# iBHKgq2k+6apX/WXYMh7xL98m2ntH4LB8c2OeEti9dcNHNdTEtaWUu81vRmOoECT
# oQqlLRacwkZ0COvb9NilSTZUEhFVA7N7FvtH/vto/MBFXOI/Enkzou+Cxd5AGQfu
# FcUKm1kFQanQl56BngNb/ErjGi4FrFBHL4z6edgeIPgF+ylrGBT6cgS3C6eaZOwR
# XU9FSY0pGi370LYJU180lOAWxLnqczXoV+/h6xbDGMcGszvPYYTitkSJlKOGMIIF
# vDCCA6SgAwIBAgIKYTMmGgAAAAAAMTANBgkqhkiG9w0BAQUFADBfMRMwEQYKCZIm
# iZPyLGQBGRYDY29tMRkwFwYKCZImiZPyLGQBGRYJbWljcm9zb2Z0MS0wKwYDVQQD
# EyRNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkwHhcNMTAwODMx
# MjIxOTMyWhcNMjAwODMxMjIyOTMyWjB5MQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSMwIQYDVQQDExpNaWNyb3NvZnQgQ29kZSBTaWduaW5nIFBD
# QTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALJyWVwZMGS/HZpgICBC
# mXZTbD4b1m/My/Hqa/6XFhDg3zp0gxq3L6Ay7P/ewkJOI9VyANs1VwqJyq4gSfTw
# aKxNS42lvXlLcZtHB9r9Jd+ddYjPqnNEf9eB2/O98jakyVxF3K+tPeAoaJcap6Vy
# c1bxF5Tk/TWUcqDWdl8ed0WDhTgW0HNbBbpnUo2lsmkv2hkL/pJ0KeJ2L1TdFDBZ
# +NKNYv3LyV9GMVC5JxPkQDDPcikQKCLHN049oDI9kM2hOAaFXE5WgigqBTK3S9dP
# Y+fSLWLxRT3nrAgA9kahntFbjCZT6HqqSvJGzzc8OJ60d1ylF56NyxGPVjzBrAlf
# A9MCAwEAAaOCAV4wggFaMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFMsR6MrS
# tBZYAck3LjMWFrlMmgofMAsGA1UdDwQEAwIBhjASBgkrBgEEAYI3FQEEBQIDAQAB
# MCMGCSsGAQQBgjcVAgQWBBT90TFO0yaKleGYYDuoMW+mPLzYLTAZBgkrBgEEAYI3
# FAIEDB4KAFMAdQBiAEMAQTAfBgNVHSMEGDAWgBQOrIJgQFYnl+UlE/wq4QpTlVnk
# pDBQBgNVHR8ESTBHMEWgQ6BBhj9odHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtp
# L2NybC9wcm9kdWN0cy9taWNyb3NvZnRyb290Y2VydC5jcmwwVAYIKwYBBQUHAQEE
# SDBGMEQGCCsGAQUFBzAChjhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2Nl
# cnRzL01pY3Jvc29mdFJvb3RDZXJ0LmNydDANBgkqhkiG9w0BAQUFAAOCAgEAWTk+
# fyZGr+tvQLEytWrrDi9uqEn361917Uw7LddDrQv+y+ktMaMjzHxQmIAhXaw9L0y6
# oqhWnONwu7i0+Hm1SXL3PupBf8rhDBdpy6WcIC36C1DEVs0t40rSvHDnqA2iA6VW
# 4LiKS1fylUKc8fPv7uOGHzQ8uFaa8FMjhSqkghyT4pQHHfLiTviMocroE6WRTsgb
# 0o9ylSpxbZsa+BzwU9ZnzCL/XB3Nooy9J7J5Y1ZEolHN+emjWFbdmwJFRC9f9Nqu
# 1IIybvyklRPk62nnqaIsvsgrEA5ljpnb9aL6EiYJZTiU8XofSrvR4Vbo0HiWGFzJ
# NRZf3ZMdSY4tvq00RBzuEBUaAF3dNVshzpjHCe6FDoxPbQ4TTj18KUicctHzbMrB
# 7HCjV5JXfZSNoBtIA1r3z6NnCnSlNu0tLxfI5nI3EvRvsTxngvlSso0zFmUeDord
# EN5k9G/ORtTTF+l5xAS00/ss3x+KnqwK+xMnQK3k+eGpf0a7B2BHZWBATrBC7E7t
# s3Z52Ao0CW0cgDEf4g5U3eWh++VHEK1kmP9QFi58vwUheuKVQSdpw5OPlcmN2Jsh
# rg1cnPCiroZogwxqLbt2awAdlq3yFnv2FoMkuYjPaqhHMS+a3ONxPdcAfmJH0c6I
# ybgY+g5yjcGjPa8CQGr/aZuW4hCoELQ3UAjWwz0wggYHMIID76ADAgECAgphFmg0
# AAAAAAAcMA0GCSqGSIb3DQEBBQUAMF8xEzARBgoJkiaJk/IsZAEZFgNjb20xGTAX
# BgoJkiaJk/IsZAEZFgltaWNyb3NvZnQxLTArBgNVBAMTJE1pY3Jvc29mdCBSb290
# IENlcnRpZmljYXRlIEF1dGhvcml0eTAeFw0wNzA0MDMxMjUzMDlaFw0yMTA0MDMx
# MzAzMDlaMHcxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xITAf
# BgNVBAMTGE1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQTCCASIwDQYJKoZIhvcNAQEB
# BQADggEPADCCAQoCggEBAJ+hbLHf20iSKnxrLhnhveLjxZlRI1Ctzt0YTiQP7tGn
# 0UytdDAgEesH1VSVFUmUG0KSrphcMCbaAGvoe73siQcP9w4EmPCJzB/LMySHnfL0
# Zxws/HvniB3q506jocEjU8qN+kXPCdBer9CwQgSi+aZsk2fXKNxGU7CG0OUoRi4n
# rIZPVVIM5AMs+2qQkDBuh/NZMJ36ftaXs+ghl3740hPzCLdTbVK0RZCfSABKR2YR
# JylmqJfk0waBSqL5hKcRRxQJgp+E7VV4/gGaHVAIhQAQMEbtt94jRrvELVSfrx54
# QTF3zJvfO4OToWECtR0Nsfz3m7IBziJLVP/5BcPCIAsCAwEAAaOCAaswggGnMA8G
# A1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFCM0+NlSRnAK7UD7dvuzK7DDNbMPMAsG
# A1UdDwQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADCBmAYDVR0jBIGQMIGNgBQOrIJg
# QFYnl+UlE/wq4QpTlVnkpKFjpGEwXzETMBEGCgmSJomT8ixkARkWA2NvbTEZMBcG
# CgmSJomT8ixkARkWCW1pY3Jvc29mdDEtMCsGA1UEAxMkTWljcm9zb2Z0IFJvb3Qg
# Q2VydGlmaWNhdGUgQXV0aG9yaXR5ghB5rRahSqClrUxzWPQHEy5lMFAGA1UdHwRJ
# MEcwRaBDoEGGP2h0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1
# Y3RzL21pY3Jvc29mdHJvb3RjZXJ0LmNybDBUBggrBgEFBQcBAQRIMEYwRAYIKwYB
# BQUHMAKGOGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljcm9z
# b2Z0Um9vdENlcnQuY3J0MBMGA1UdJQQMMAoGCCsGAQUFBwMIMA0GCSqGSIb3DQEB
# BQUAA4ICAQAQl4rDXANENt3ptK132855UU0BsS50cVttDBOrzr57j7gu1BKijG1i
# uFcCy04gE1CZ3XpA4le7r1iaHOEdAYasu3jyi9DsOwHu4r6PCgXIjUji8FMV3U+r
# kuTnjWrVgMHmlPIGL4UD6ZEqJCJw+/b85HiZLg33B+JwvBhOnY5rCnKVuKE5nGct
# xVEO6mJcPxaYiyA/4gcaMvnMMUp2MT0rcgvI6nA9/4UKE9/CCmGO8Ne4F+tOi3/F
# NSteo7/rvH0LQnvUU3Ih7jDKu3hlXFsBFwoUDtLaFJj1PLlmWLMtL+f5hYbMUVbo
# nXCUbKw5TNT2eb+qGHpiKe+imyk0BncaYsk9Hm0fgvALxyy7z0Oz5fnsfbXjpKh0
# NbhOxXEjEiZ2CzxSjHFaRkMUvLOzsE1nyJ9C/4B5IYCeFTBm6EISXhrIniIh0EPp
# K+m79EjMLNTYMoBMJipIJF9a6lbvpt6Znco6b72BJ3QGEe52Ib+bgsEnVLaxaj2J
# oXZhtG6hE6a/qkfwEm/9ijJssv7fUciMI8lmvZ0dhxJkAj0tr1mPuOQh5bWwymO0
# eFQF1EEuUKyUsKV4q7OglnUa2ZKHE3UiLzKoCG6gW4wlv6DvhMoh1useT8ma7kng
# 9wFlb4kLfchpyOZu6qeXzjEp/w7FW1zYTRuh2Povnj8uVRZryROj/TGCBIUwggSB
# AgEBMIGQMHkxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xIzAh
# BgNVBAMTGk1pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBAhMzAAABCix5rtd5e6as
# AAEAAAEKMAkGBSsOAwIaBQCggZ4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQw
# HAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFDkC
# 3WxwLxJQISDk04WNJYXGKA8+MD4GCisGAQQBgjcCAQwxMDAuoBaAFABXAGUAYgAg
# AEQAZQBwAGwAbwB5oRSAEmh0dHA6Ly93d3cuaWlzLm5ldDANBgkqhkiG9w0BAQEF
# AASCAQBUBpV0TRZZrwiDzXfrakOhwNoAp6ODucjWsGRlBCSf+DZtEnoCq4ghA5tU
# zIua403g6iK4aHlsIYhE9bj3dAIZhlRIa20urxvG2iLblUF91ORjjIrUrFTLJmw3
# 07VW9Txmwol3ZxJmqmoLAFNg76sc2Tfp3YDL/gtLFpnd4ilV+X4YXBO7BlpeOELN
# W1MYau7vrDRquyATrCBzG5uR0gYGbtsuEkBFZ2a/5dXTlDKBky5bL+Bai+27S/+N
# ZeHopkXzuWBmjysKJqrtgfx8EhCVSy+Xc3MdGbOlL1xVWZRlsEnr3/eayJOnSCq3
# 9iMavfJ7Re5cjIUSz5j7j0qgT6ihoYICKDCCAiQGCSqGSIb3DQEJBjGCAhUwggIR
# AgEBMIGOMHcxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xITAf
# BgNVBAMTGE1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQQITMwAAAHGzLoprgqofTgAA
# AAAAcTAJBgUrDgMCGgUAoF0wGAYJKoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkq
# hkiG9w0BCQUxDxcNMTUwNjE5MTgwNTQ0WjAjBgkqhkiG9w0BCQQxFgQUzTe2k2gA
# djnPjjBeN10p5m7a0fgwDQYJKoZIhvcNAQEFBQAEggEA4usRjkW8JRDHK+izpGjh
# yt7hbHuY0D/YgJ1SbO/p7WTl+4nbDPgRN5AuEBWTLCCTmQvoV6gpQDA9e413XsUz
# pzHTruFgR2IytENkuVOxZXPO7rXxMdOzdGIcxBoesD9OLpsO55kWyrVbsqYE8cKF
# f57eTtlZdyJhWsAGsgN4jbXToSQH4EaGbCFEY0qq00ifTTgYTpi32TYRW6sSklHp
# JXyQf4XIxCrVGcGw2osYgMlhEFx6xJndWwKPdXEJZRM1cvTbmZRaHAI0Di+jcE27
# YBjAnrRNPpt/LCJ93ogyxg8CaLUk97bEAPJ6g2FbT2pXvKzikHTCsq5aqSpICF3p
# ew==
# SIG # End signature block
