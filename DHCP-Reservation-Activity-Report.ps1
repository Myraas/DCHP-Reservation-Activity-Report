<#
.SYNOPSIS
    Reports recent activity for DHCP reservations by parsing local DHCP server logs.

.DESCRIPTION
    Windows DHCP servers do not show last activity for reserved clients. This script analyzes local DHCP audit logs 
    (up to 7 days old) to report the last lease request or renewal per reservation.

    - Only checks the DHCP server it's run on.
    - Lease activity must fall within the 7-day log retention window.
    - Results are shown in Out-GridView.

    Ping results indicate if the reserved IP is online (True/False), but do not verify MAC address. 
    If LeaseState is "InactiveReservation" and Ping is True, use `arp -a` to check for possible IP overlap or static assignment.

.NOTES
    Author: Kody Myraas
    Tested on: Windows Server 2012 R2 DHCP
    Requirements: Run on a Windows DHCP server with access to audit logs.
#>

function Import-DhcpAuditLogs {
  $LocalServer = $env:COMPUTERNAME
  
  if(Get-Command Get-DhcpServerAuditLog -ErrorAction SilentlyContinue) {
    $LogPath = (Get-DhcpServerAuditLog).Path
  }
  else {
    $LogPath = "C:\Windows\System32"
  }
 
  $LogFiles = Get-ChildItem -Path $LogPath | Where-Object { $_.Name -like 'DhcpSrvLog-*' -and $_.Length -gt 0 } | Sort-Object -Property LastWriteTime
  
  foreach($LogFile in $LogFiles) {
    Write-Verbose "Reading Log file $($logfile.Name)"
    $RawLogContent = Get-Content $LogFile.FullName
    
    $LogContent = $RawLogContent[32..$($RawLogContent.Length-1)]
    
    $ParsedContent = ConvertFrom-Csv -Delimiter ',' -InputObject $LogContent
    $ParsedContent
  }
}

function Find-DhcpReservationStatus {
  param (
    [Switch]$CheckOnlineState
  )
  
  $LocalServer = $env:COMPUTERNAME
  
  Write-Verbose "Getting DHCP Server Reservation Activity for server $LocalServer"

  Write-Verbose 'Getting scopes'
  $Scopes = Get-DhcpServerv4Scope
  $Logs = Import-DhcpAuditLogs
  
  $TotalReservations = 0
  foreach ($Scope in $Scopes) {
    $ScopeReservations = Get-DhcpServerv4Reservation -ScopeId $Scope.ScopeId
    $TotalReservations += $ScopeReservations.Count
  }
  
  Write-Verbose "Total reservations found: $TotalReservations"
  $CurrentReservation = 0
  
  foreach ($Scope in $Scopes) {
    Write-Verbose "Processing scope: $($Scope.Name)"
    $Reservations = Get-DhcpServerv4Reservation -ScopeId $Scope.ScopeId
    
    foreach($Reservation in $Reservations) {
      $CurrentReservation++
      
      Write-Verbose "Processing reservation: $($Reservation.Name) [$CurrentReservation/$TotalReservations]"
      $MacAddress = $Reservation.clientID.replace('-','')

      try {
          $lastActivity = $Logs | Where-Object { $_.'MAC Address' -eq $MacAddress } | Select-Object -Last 1
      }
      catch {
          Write-Warning "Could not find MAC address property in logs. Check log format."
          $lastActivity = $null
      }
      
      $Online = Test-Connection -Quiet -Count 1 -ComputerName $Reservation.IPAddress -ErrorAction SilentlyContinue
      
      $LeaseState = $Reservation.AddressState.ToString()
      
      $Object = New-Object -TypeName PSObject -Property @{
        'ProgressCounter' = "$CurrentReservation/$TotalReservations"
        'ClientName' = $Reservation.Name
        'IpAddress' = $Reservation.IPAddress
        'Scope' = $Reservation.ScopeId
        'DHCPServer'= $LocalServer
        'MacAddress' = $Reservation.clientID
        'LastActivity' = $LastActivity
        'IsOnline' = $Online
        'LeaseState' = $LeaseState
      } 
      
      $Object 
    }
  }
}

$LocalServer = $env:COMPUTERNAME
Write-Host "Running DHCP reservation activity check on $LocalServer"

Find-DhcpReservationStatus | 
    Select-Object ProgressCounter, ClientName, IpAddress, Scope, DHCPServer, MacAddress, LeaseState, IsOnline, @{
        Name = 'LastActivityDate'; 
        Expression = { 
            if ($_.LastActivity) {
                try {
                    if ($_.LastActivity.Date) {
                        $_.LastActivity.Date
                    } else {
                        "No date found"
                    }
                } catch {
                    "No date found"
                }
            } else {
                "No activity found"
            }
        }
    } | 
    Out-GridView -Title "DHCP Reservation Activity for $LocalServer"
