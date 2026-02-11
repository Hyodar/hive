#!/usr/bin/env python3
"""
Agent Telegram Bot Service
Provides alertme and promptme functionality for agentic workflows.
"""

import asyncio
import json
import logging
import os
import sys
import socket
import time
from pathlib import Path
from datetime import datetime
from typing import Optional

from telegram import Update
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes

# Configuration
CONFIG_DIR = Path("/etc/hive")
CONFIG_FILE = CONFIG_DIR / "telegram_config.json"
SOCKET_PATH = "/tmp/agent_telegram_bot.sock"
PENDING_DIR = CONFIG_DIR / "pending_prompts"

# Logging setup
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

# Status emoji mapping
STATUS_EMOJI = {
    "success": "\u2705",  # Green check
    "info": "\u2139\ufe0f",      # Info
    "warning": "\u26a0\ufe0f",   # Warning
    "error": "\u274c",           # Red X
}

class AgentTelegramBot:
    def __init__(self):
        self.config = self.load_config()
        self.application: Optional[Application] = None
        self.pending_responses: dict = {}

    def load_config(self) -> dict:
        """Load configuration from JSON file."""
        if CONFIG_FILE.exists():
            with open(CONFIG_FILE, 'r') as f:
                return json.load(f)
        return {
            "bot_token": "",
            "chat_id": "",
            "bound": False
        }

    def save_config(self):
        """Save configuration to JSON file."""
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        with open(CONFIG_FILE, 'w') as f:
            json.dump(self.config, f, indent=2)

    async def start_command(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Handle /start command."""
        await update.message.reply_text(
            "Agent Telegram Bot\n\n"
            f"Status: {'Bound' if self.config['bound'] else 'Not bound'}"
        )

    async def handle_message(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Handle incoming messages."""
        if not update.message or not update.message.text:
            return

        text = update.message.text.strip()
        chat_id = str(update.message.chat_id)
        reply_to = update.message.reply_to_message

        # Handle replies to prompt messages
        if reply_to and reply_to.message_id:
            prompt_id = str(reply_to.message_id)
            response_file = PENDING_DIR / f"{prompt_id}.response"

            # Write response to file
            PENDING_DIR.mkdir(parents=True, exist_ok=True)
            with open(response_file, 'w') as f:
                f.write(text)

            await update.message.reply_text("\u2705 Response recorded!")
            logger.info(f"Response recorded for prompt {prompt_id}")

    async def send_alert(self, title: str, description: str, codeblock: str, status: str) -> dict:
        """Send an alert message to the bound chat."""
        if not self.config["bound"]:
            return {"success": False, "error": "Bot not bound to any chat"}

        emoji = STATUS_EMOJI.get(status, "\u2139\ufe0f")
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

        message = f"{emoji} *{title}*\n\n"
        message += f"\u23f0 {timestamp}\n\n"

        if description:
            message += f"{description}\n\n"

        if codeblock:
            message += f"```\n{codeblock}\n```"

        try:
            await self.application.bot.send_message(
                chat_id=self.config["chat_id"],
                text=message,
                parse_mode="Markdown"
            )
            return {"success": True}
        except Exception as e:
            logger.error(f"Failed to send alert: {e}")
            return {"success": False, "error": str(e)}

    async def send_prompt(self, title: str, description: str, codeblock: str, status: str, timeout: int) -> dict:
        """Send a prompt message and wait for reply."""
        if not self.config["bound"]:
            return {"success": False, "error": "Bot not bound to any chat"}

        emoji = STATUS_EMOJI.get(status, "\u2139\ufe0f")
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

        message = f"{emoji} *{title}* (Reply required)\n\n"
        message += f"\u23f0 {timestamp}\n"
        message += f"\u23f3 Timeout: {timeout}s\n\n"

        if description:
            message += f"{description}\n\n"

        if codeblock:
            message += f"```\n{codeblock}\n```\n\n"

        message += "_Reply to this message with your response_"

        try:
            sent_message = await self.application.bot.send_message(
                chat_id=self.config["chat_id"],
                text=message,
                parse_mode="Markdown"
            )

            prompt_id = str(sent_message.message_id)
            response_file = PENDING_DIR / f"{prompt_id}.response"

            # Wait for response with timeout
            start_time = time.time()
            while time.time() - start_time < timeout:
                if response_file.exists():
                    with open(response_file, 'r') as f:
                        response = f.read()
                    response_file.unlink()  # Clean up
                    return {"success": True, "response": response}
                await asyncio.sleep(1)

            return {"success": False, "error": "Timeout waiting for response", "timeout": True}

        except Exception as e:
            logger.error(f"Failed to send prompt: {e}")
            return {"success": False, "error": str(e)}

    async def handle_socket_request(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        """Handle incoming socket requests from alertme/promptme scripts."""
        try:
            data = await reader.read(65536)
            if not data:
                return

            request = json.loads(data.decode())
            action = request.get("action")

            if action == "alert":
                result = await self.send_alert(
                    request.get("title", "Alert"),
                    request.get("description", ""),
                    request.get("codeblock", ""),
                    request.get("status", "info")
                )
            elif action == "prompt":
                result = await self.send_prompt(
                    request.get("title", "Prompt"),
                    request.get("description", ""),
                    request.get("codeblock", ""),
                    request.get("status", "info"),
                    request.get("timeout", 300)
                )
            elif action == "status":
                result = {
                    "success": True,
                    "bound": self.config["bound"],
                    "chat_id": self.config.get("chat_id", "")
                }
            else:
                result = {"success": False, "error": f"Unknown action: {action}"}

            writer.write(json.dumps(result).encode())
            await writer.drain()

        except Exception as e:
            logger.error(f"Socket request error: {e}")
            try:
                writer.write(json.dumps({"success": False, "error": str(e)}).encode())
                await writer.drain()
            except:
                pass
        finally:
            writer.close()
            await writer.wait_closed()

    async def start_socket_server(self):
        """Start Unix socket server for IPC."""
        # Remove existing socket
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)

        server = await asyncio.start_unix_server(
            self.handle_socket_request,
            path=SOCKET_PATH
        )

        # Make socket accessible
        os.chmod(SOCKET_PATH, 0o666)

        logger.info(f"Socket server started at {SOCKET_PATH}")

        async with server:
            await server.serve_forever()

    async def run(self):
        """Run the bot."""
        if not self.config["bot_token"]:
            logger.error("No bot token configured. Run telegram-bot-setup first.")
            sys.exit(1)

        # Create pending prompts directory
        PENDING_DIR.mkdir(parents=True, exist_ok=True)

        # Build application
        self.application = Application.builder().token(self.config["bot_token"]).build()

        # Add handlers
        self.application.add_handler(CommandHandler("start", self.start_command))
        self.application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, self.handle_message))

        # Start socket server in background
        socket_task = asyncio.create_task(self.start_socket_server())

        # Start bot
        logger.info("Starting Agent Telegram Bot...")
        await self.application.initialize()
        await self.application.start()
        await self.application.updater.start_polling()

        logger.info("Bot is running. Press Ctrl+C to stop.")

        try:
            # Keep running
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            pass
        finally:
            logger.info("Shutting down...")
            socket_task.cancel()
            await self.application.updater.stop()
            await self.application.stop()
            await self.application.shutdown()

            # Clean up socket
            if os.path.exists(SOCKET_PATH):
                os.unlink(SOCKET_PATH)


def main():
    bot = AgentTelegramBot()
    asyncio.run(bot.run())


if __name__ == "__main__":
    main()
