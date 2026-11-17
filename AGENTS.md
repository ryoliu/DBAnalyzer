# Coding Standards

- Use English for all source code, identifiers, functions, and comments.
- Keep scripts short, simple, and readable.
- Avoid advanced techniques and unnecessary abstractions.
- Keep validation minimal and relevant to the task.
- Preserve checks needed to prevent data loss or incorrect results.
- Do not install third-party libraries or CLI tools unless explicitly requested.
- Prefer built-in system features and existing dependencies.

# SQL Server Windows Authentication

- For SQL Server testing from this computer, use the verified Windows authentication method: `LogonUser` followed by .NET `SqlConnection` under impersonation.
- Default instance: `WIN2019LAB`, endpoint `tcp:192.168.56.202,1433`, Windows account `WIN2019LAB\Administrator`.
- Call `LogonUser` with `LOGON32_LOGON_NEW_CREDENTIALS` (9) and `LOGON32_PROVIDER_WINNT50` (3), then use `WindowsIdentity.RunImpersonated` to open and use the SQL connection within that scope.
- Use `Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Pooling=False` for this lab connection. Dispose the SQL connection and token after use.
- Obtain the password from the user or an explicitly authorized credential store. Never put passwords in source files, documentation, command-line arguments, logs, or Git.
- Start with a read-only query that confirms `SERVERPROPERTY('ServerName')`, `ORIGINAL_LOGIN()`, and access to `DBAnalyzer`. A successful connection does not itself authorize deployment or data changes.
- A separate `runas /netonly` window does not automatically share its network credentials with the agent's existing process. Failure of plain `sqlcmd -E` does not prove that the verified impersonation method is unavailable.

- The user authorized Windows Credential Manager target `DBAnalyzer/WIN2019LAB/Administrator`. Dot-source `Tools/LabCredential.ps1` and call `[DBAnalyzerLabCredential]::Load()` to obtain the saved credential in memory. Never print its password. Use the saved credential with the impersonation method above. Save credentials only under the original local Windows identity, outside impersonation.
- The lab IP was verified as `192.168.56.202` on 2026-11-17. If it changes, inspect VirtualBox guest properties before requesting credentials again.
