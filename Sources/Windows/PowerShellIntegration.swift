import Foundation
import WinSDK

/// What `ShellIntegration` does for bash and zsh on the Mac, for PowerShell: marks the prompt, the command and its exit
/// status (OSC 133) and reports the folder (OSC 1337), so blocks and the sidebar can follow along. Sets UTF-8 as well.
enum PowerShellIntegration {
    /// Runs after the user's profile, so it wraps whatever prompt that set up. `PSConsoleHostReadLine` returns as a
    /// command is entered, the one moment PowerShell offers before the command runs. Without PSReadLine it doesn't
    /// exist, and blocks then have no command or status, only prompts and folders.
    static let hook = #"""
    if (-not $global:__solanum_hooked) {
        $global:__solanum_hooked = $true
        # UTF-8 both ways, for this shell's own output and for what it exchanges with other programs.
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        [Console]::InputEncoding = [Console]::OutputEncoding
        $global:OutputEncoding = [Console]::OutputEncoding
        $global:__solanum_running = $false
        $global:__solanum_prompt = $function:prompt
        function global:__solanum_osc([string]$text) { [char]27 + ']' + $text + [char]7 }
        function global:prompt {
            $ok = $?
            $code = $global:LASTEXITCODE
            $marks = ''
            if ($global:__solanum_running) {
                $status = if ($ok) { 0 } elseif ($code) { $code } else { 1 }
                $marks += __solanum_osc "133;D;$status"
            }
            $global:__solanum_running = $false
            if ($PWD.Provider.Name -eq 'FileSystem') { $marks += __solanum_osc "1337;CurrentDir=$($PWD.ProviderPath)" }
            $text = & $global:__solanum_prompt
            $global:LASTEXITCODE = $code
            $marks + (__solanum_osc '133;A') + $text + (__solanum_osc '133;B')
        }
        if (Test-Path Function:\PSConsoleHostReadLine) {
            $global:__solanum_readline = $function:PSConsoleHostReadLine
            function global:PSConsoleHostReadLine {
                $line = & $global:__solanum_readline
                if ($line.Trim().Length -gt 0) {
                    $global:__solanum_running = $true
                    [Console]::Write((__solanum_osc '133;C'))
                }
                $line
            }
        }
    }
    """#

    /// PowerShell 7 if it's installed, otherwise the Windows PowerShell every Windows has.
    static func executable() -> String {
        var path = [UInt16](repeating: 0, count: Int(MAX_PATH))
        let found = SearchPathW(nil, Array("pwsh.exe".utf16) + [0], nil, DWORD(path.count), &path, nil)
        return found > 0 ? "pwsh.exe" : "powershell.exe"
    }

    /// The command line for an interactive shell with the hook. Encoded rather than a script file, because the default
    /// execution policy on Windows refuses to run script files.
    static func commandLine(executable: String = executable(), loadProfile: Bool = true) -> String {
        let bytes = hook.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let encoded = Data(bytes).base64EncodedString()
        return "\(executable) -NoLogo -NoExit \(loadProfile ? "" : "-NoProfile ")-EncodedCommand \(encoded)"
    }
}
