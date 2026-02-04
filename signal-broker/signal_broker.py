#!/usr/bin/env python3
"""
Signal Broker Service
Provides internal pub/sub signaling for agentic workflows.
signalme publishes signals, listento subscribes and blocks until signals arrive.
"""

import asyncio
import json
import logging
import os
import sys
from pathlib import Path
from datetime import datetime
from typing import Dict, List
from collections import defaultdict

# Configuration
CONFIG_DIR = Path("/etc/agent-setup")
SOCKET_PATH = "/tmp/signal_broker.sock"

# Logging setup
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)


class SignalBroker:
    def __init__(self):
        # Queues for each signal ID - subscribers wait on these
        self.subscribers: Dict[str, List[asyncio.Queue]] = defaultdict(list)
        # Lock for thread-safe queue management
        self.lock = asyncio.Lock()

    async def publish(self, signal_id: str, content: str) -> dict:
        """Publish a signal with the given ID and content."""
        async with self.lock:
            queues = self.subscribers.get(signal_id, [])
            if not queues:
                logger.info(f"Signal '{signal_id}' published but no subscribers")
            else:
                logger.info(f"Signal '{signal_id}' published to {len(queues)} subscriber(s)")

            # Notify all waiting subscribers
            for queue in queues:
                await queue.put({
                    "id": signal_id,
                    "content": content,
                    "timestamp": datetime.now().isoformat()
                })

        return {"success": True, "subscribers": len(queues)}

    async def subscribe(self, signal_id: str, timeout: float = None) -> dict:
        """Subscribe to a signal ID and wait for it to arrive."""
        queue = asyncio.Queue()

        async with self.lock:
            self.subscribers[signal_id].append(queue)
            logger.info(f"New subscriber for signal '{signal_id}' (total: {len(self.subscribers[signal_id])})")

        try:
            if timeout:
                signal = await asyncio.wait_for(queue.get(), timeout=timeout)
            else:
                signal = await queue.get()
            return {"success": True, "signal": signal}
        except asyncio.TimeoutError:
            return {"success": False, "error": "Timeout waiting for signal", "timeout": True}
        finally:
            async with self.lock:
                if queue in self.subscribers[signal_id]:
                    self.subscribers[signal_id].remove(queue)
                # Clean up empty lists
                if not self.subscribers[signal_id]:
                    del self.subscribers[signal_id]

    async def status(self) -> dict:
        """Get current broker status."""
        async with self.lock:
            return {
                "success": True,
                "active_subscriptions": {
                    signal_id: len(queues)
                    for signal_id, queues in self.subscribers.items()
                }
            }

    async def handle_socket_request(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        """Handle incoming socket requests from signalme/listento scripts."""
        try:
            data = await reader.read(65536)
            if not data:
                return

            request = json.loads(data.decode())
            action = request.get("action")

            if action == "publish":
                result = await self.publish(
                    request.get("id", ""),
                    request.get("content", "")
                )
            elif action == "subscribe":
                result = await self.subscribe(
                    request.get("id", ""),
                    request.get("timeout")
                )
            elif action == "status":
                result = await self.status()
            else:
                result = {"success": False, "error": f"Unknown action: {action}"}

            writer.write(json.dumps(result).encode())
            await writer.drain()

        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON: {e}")
            try:
                writer.write(json.dumps({"success": False, "error": "Invalid JSON"}).encode())
                await writer.drain()
            except:
                pass
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

        logger.info(f"Signal Broker started at {SOCKET_PATH}")

        async with server:
            await server.serve_forever()

    async def run(self):
        """Run the broker."""
        logger.info("Starting Signal Broker Service...")

        try:
            await self.start_socket_server()
        except asyncio.CancelledError:
            pass
        finally:
            logger.info("Shutting down...")
            # Clean up socket
            if os.path.exists(SOCKET_PATH):
                os.unlink(SOCKET_PATH)


def main():
    broker = SignalBroker()
    try:
        asyncio.run(broker.run())
    except KeyboardInterrupt:
        logger.info("Interrupted")


if __name__ == "__main__":
    main()
