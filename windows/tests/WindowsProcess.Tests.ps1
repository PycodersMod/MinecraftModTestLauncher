BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Windows.Process.psm1') -Force
}

Describe 'Windows process tree snapshot' {
    It 'builds a large process tree in one indexed traversal and preserves depth' {
        InModuleScope Windows.Process {
            $created=[datetime]'2026-10-12T00:00:00Z'
            $records=[Collections.Generic.List[object]]::new()
            for($id=1;$id -le 1500;$id++){
                $parent=if($id -eq 1){0}else{$id-1}
                $records.Add([pscustomobject]@{ProcessId=$id;ParentProcessId=$parent;CreationDate=$created;ExecutablePath='pwsh.exe';CommandLine="pwsh fixture $id";SessionId=1})
            }
            $snapshot=Get-MmtlWindowsProcessSnapshotFromRecords -Processes @($records.ToArray()) -RootProcessId 1
            $snapshot.Count | Should -Be 1500
            $snapshot[0].PID | Should -Be 1
            $snapshot[0].Depth | Should -Be 0
            $snapshot[-1].PID | Should -Be 1500
            $snapshot[-1].Depth | Should -Be 1499
        }
    }
}
