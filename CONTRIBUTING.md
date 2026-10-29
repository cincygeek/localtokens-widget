# Contributing

Issues and pull requests are welcome.

- **Bug reports:** include your Windows version, LM Studio version, and the lines of
  `%LOCALAPPDATA%\LocalTokens\error.log` if there are any. If the numbers look wrong, a few
  lines of the server log around one request help most. **Remove your prompts first**,
  because LM Studio logs request bodies.
- **Before a pull request:** run `tests\Test-LocalTokens.ps1` in Windows PowerShell 5.1.
  CI runs it on every push.
- **New log formats:** if your LM Studio writes timing lines differently, add a small
  made-up sample under `tests\fixtures` and a check in the test script.
- **Keep it dependency-free:** Windows PowerShell 5.1, WPF and WinForms only. `LogReader.cs`
  must compile as C# 5, the version Windows PowerShell 5.1's `Add-Type` uses.
