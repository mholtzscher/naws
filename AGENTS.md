# AGENTS.md - Development Guidelines for NAWS

## Build/Test Commands
- **Run module**: `use mod.nu *; naws` (load and test the main module)
- **Test single command**: `use mod.nu *; naws s3 list` (test specific domain/command)
- **Health check**: `naws health` (verify all dependencies)
- **No formal test suite** - validation is done through interactive testing with real AWS services

## Code Style & Conventions

### File Structure
- **Main entry**: `mod.nu` contains dispatcher, domain registry, and version info
- **Domain modules**: `{domain}.nu` files (s3, sqs, logs, batch, events) export domain info and command functions
- **Shared utilities**: `shared.nu` for common helpers (authentication, confirmations, tool checks, editor)

### Naming Conventions
- **Exported functions**: `naws_{domain}_{command}` (e.g., `naws_s3_upload`, `naws_sqs_send`)
- **Domain info**: `naws_{domain}_domain_info` returns registry metadata with name, desc, and subcmds array
- **Private helpers**: prefix with `_` (e.g., `_select_bucket`, `_require_tool`, `_confirm`)
- **Constants**: SCREAMING_SNAKE_CASE (e.g., `NAWS_VERSION`, `NAWS_NAME_PADDING`)

### Import Style
- Use relative imports: `use ./shared.nu *` for all functions, `use ./shared.nu authenticate` for specific
- Import `use std/log` at top of file for logging (required in all domain modules)
- Standard library imports before relative imports

### Error Handling & Logging
- Use `log error/warning/info` for user messages, NOT `print` (except in help/display functions)
- Helpers return exit codes (0=success, 1=failure) for composition; callers propagate with `return`
- Always use `complete` for external commands, check `exit_code` before proceeding
- Use `try/catch` for parsing operations that might fail (e.g., JSON parsing)
- Log errors with context: `log error $"Failed: ($key)"; log error $dr.stderr`

### Domain Module Pattern
Each domain module must export a `naws_{domain}_domain_info` function returning:
```nu
{ name: "domain", desc: "Description", subcmds: [
  { name: "cmd", desc: "Command description", run: { |rest| naws_domain_cmd ...$rest } }
]}
```
Then export wrapper functions that call private implementations and add to `_naws_domains` in mod.nu

### Interactive UI Patterns
- Use `fzf` for all selections with descriptive prompts: `fzf --prompt="Select bucket: " --height=40% --border`
- Use `_confirm` helper for destructive operations with clear, specific prompts
- Use `input` for text input with clear prompts and defaults: `input "Optional prefix (blank = all): " | str trim`
- Provide feedback: `log info` before operations, success/failure after
- For batch operations, track individual success/failure and report summary
