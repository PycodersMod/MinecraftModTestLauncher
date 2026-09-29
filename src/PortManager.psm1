function Get-MmtlPort {
    param([ValidateRange(1,65535)][int]$Port=0)
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
    try { $listener.Start(); return [int]$listener.LocalEndpoint.Port }
    finally { $listener.Stop() }
}
Export-ModuleMember -Function Get-MmtlPort
