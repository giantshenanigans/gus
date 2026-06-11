# CLAUDE.md

## Secrets & Credentials — HARD RULE (Zack, 2026-06-10)
- **NEVER** read, cat, grep, diff, or search through `Default.toml`, production `.env` files, or ANY `.env` variant other than `.env.example`/`env.example` — locally or on any remote host.
- **NEVER** dig for credentials, tokens, API keys, passwords, or connection strings — in configs, env files, journals, process environments, or anywhere else — unless Zack explicitly asks for that specific lookup. Ever.
- These files hold live credentials. Printing one into a conversation publishes it (2026-06-10: a raw diff of sauron's deployed `Default.toml` exposed fleet credentials and forced a full rotation).
- If a task appears to need a value from one of these files, STOP and ask Zack for the specific key instead.
