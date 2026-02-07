# Telegram Bot

Telegram-based notification and prompting system for AI agents. Agents can send one-way alerts or block waiting for a human reply.

## Commands

### `alertme`

Send a one-way Telegram notification.

```bash
alertme --title "Build Complete" --status success
alertme -t "Error" -d "Something went wrong" -s error
alertme -t "Output" -c "$(cat output.txt)" -s info
```

| Option | Description |
|--------|-------------|
| `--title, -t` | Alert title (required) |
| `--description, -d` | Alert description |
| `--codeblock, -c` | Code block to include |
| `--status, -s` | `success`, `info`, `warning`, `error` (default: `info`) |

### `promptme`

Send a Telegram prompt and block until the user replies.

```bash
REPLY=$(promptme --title "Confirm" --description "Proceed?" --timeout 60)
promptme -t "Choose option" -d "1, 2, or 3?" | xargs echo "You chose:"
```

| Option | Description |
|--------|-------------|
| `--title, -t` | Prompt title (required) |
| `--description, -d` | Prompt description |
| `--codeblock, -c` | Code block to include |
| `--status, -s` | `success`, `info`, `warning`, `error` (default: `info`) |
| `--timeout, -T` | Timeout in seconds (default: 300) |

Exit codes: `0` success, `1` error, `2` timeout.

### `tgsetup`

Interactive setup wizard for the Telegram bot.

```bash
sudo tgsetup
```

Walks through:
1. Creating a bot via @BotFather
2. Setting a binding phrase
3. Starting the systemd service
4. Binding the bot to your chat

## Architecture

- **`agent_telegram_bot.py`** — Python daemon that listens on a Unix socket (`/tmp/agent_telegram_bot.sock`)
- **`agent-telegram-bot.service`** — systemd unit file
- **`alertme` / `promptme`** — bash clients that send JSON over the socket
- Config stored in `/etc/hive/telegram_config.json`
