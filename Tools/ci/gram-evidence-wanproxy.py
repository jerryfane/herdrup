#!/usr/bin/env python3
"""Loopback-only, per-direction 120ms RTT / 100Mbit userspace WAN emulator.

Adapted from gram-transfer-speed-20261029/wanproxy.py. This is an emulated
Linux link, not a phone, relay, kernel qdisc, or measured Internet connection.
"""
import asyncio
import sys
import time

LISTEN, TARGET = int(sys.argv[1]), int(sys.argv[2])
ONE_WAY = float(sys.argv[3]) / 2000.0
RATE = float(sys.argv[4]) * 1e6 / 8.0


async def pump(reader, writer):
    queue = asyncio.Queue()
    free_at = 0.0

    async def deliver():
        while True:
            at, data = await queue.get()
            if data is None:
                break
            delay = at - time.monotonic()
            if delay > 0:
                await asyncio.sleep(delay)
            writer.write(data)
            await writer.drain()
        try:
            writer.write_eof()
        except OSError:
            pass

    task = asyncio.create_task(deliver())
    try:
        while True:
            data = await reader.read(16384)
            if not data:
                break
            start = max(time.monotonic(), free_at)
            free_at = start + len(data) / RATE
            queue.put_nowait((free_at + ONE_WAY, data))
        queue.put_nowait((0, None))
        await task
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)


async def handle(client_reader, client_writer):
    server_writer = None
    tasks = []
    try:
        server_reader, server_writer = await asyncio.open_connection("127.0.0.1", TARGET)
        tasks = [asyncio.create_task(pump(client_reader, server_writer)),
                 asyncio.create_task(pump(server_reader, client_writer))]
        await asyncio.gather(*tasks)
    except (OSError, asyncio.IncompleteReadError):
        pass
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        for writer in (client_writer, server_writer):
            if writer is not None:
                writer.close()
                try:
                    await writer.wait_closed()
                except OSError:
                    pass


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", LISTEN)
    async with server:
        await server.serve_forever()


asyncio.run(main())
