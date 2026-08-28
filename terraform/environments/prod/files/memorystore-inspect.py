#!/usr/bin/env python3
"""Small read-only RESP client for inspecting the production Memorystore instance."""

from __future__ import annotations

import argparse
import getpass
import json
import os
import socket
import sys
from typing import BinaryIO, NoReturn


READ_ONLY_COMMANDS = {
    "BITCOUNT",
    "BITFIELD_RO",
    "DBSIZE",
    "ECHO",
    "EXISTS",
    "EXPIRETIME",
    "GET",
    "GETBIT",
    "GETRANGE",
    "HEXISTS",
    "HGET",
    "HGETALL",
    "HKEYS",
    "HLEN",
    "HMGET",
    "HRANDFIELD",
    "HSCAN",
    "HSTRLEN",
    "HVALS",
    "INFO",
    "LINDEX",
    "LLEN",
    "LPOS",
    "LRANGE",
    "MGET",
    "OBJECT",
    "PEXPIRETIME",
    "PING",
    "PTTL",
    "RANDOMKEY",
    "ROLE",
    "SCARD",
    "SCAN",
    "SDIFF",
    "SINTER",
    "SINTERCARD",
    "SISMEMBER",
    "SMEMBERS",
    "SMISMEMBER",
    "SORT_RO",
    "SRANDMEMBER",
    "SSCAN",
    "STRLEN",
    "SUNION",
    "TIME",
    "TTL",
    "TYPE",
    "ZCARD",
    "ZCOUNT",
    "ZDIFF",
    "ZINTER",
    "ZINTERCARD",
    "ZLEXCOUNT",
    "ZMSCORE",
    "ZRANDMEMBER",
    "ZRANGE",
    "ZRANGEBYLEX",
    "ZRANGEBYSCORE",
    "ZRANK",
    "ZREVRANGE",
    "ZREVRANGEBYLEX",
    "ZREVRANGEBYSCORE",
    "ZREVRANK",
    "ZSCAN",
    "ZSCORE",
    "ZUNION",
}


class RedisError(RuntimeError):
    """Redis error response."""


def fail(message: str) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def encode_command(parts: list[str]) -> bytes:
    encoded = [part.encode("utf-8") for part in parts]
    request = [f"*{len(encoded)}\r\n".encode("ascii")]
    for part in encoded:
        request.extend(
            [f"${len(part)}\r\n".encode("ascii"), part, b"\r\n"]
        )
    return b"".join(request)


def read_line(stream: BinaryIO) -> bytes:
    line = stream.readline()
    if not line.endswith(b"\r\n"):
        raise ConnectionError("Redis connection closed while reading a response")
    return line[:-2]


def read_response(stream: BinaryIO) -> object:
    prefix = stream.read(1)
    if prefix == b"+":
        return read_line(stream).decode("utf-8", "backslashreplace")
    if prefix == b"-":
        raise RedisError(read_line(stream).decode("utf-8", "backslashreplace"))
    if prefix == b":":
        return int(read_line(stream))
    if prefix == b"$":
        length = int(read_line(stream))
        if length == -1:
            return None
        value = stream.read(length)
        if len(value) != length or stream.read(2) != b"\r\n":
            raise ConnectionError("Redis connection closed while reading bulk data")
        return value
    if prefix == b"*":
        length = int(read_line(stream))
        if length == -1:
            return None
        return [read_response(stream) for _ in range(length)]
    if not prefix:
        raise ConnectionError("Redis connection closed before returning a response")
    raise ConnectionError(f"unsupported RESP prefix: {prefix!r}")


def json_value(value: object) -> object:
    if isinstance(value, bytes):
        return value.decode("utf-8", "backslashreplace")
    if isinstance(value, list):
        return [json_value(item) for item in value]
    return value


def print_response(value: object) -> None:
    if isinstance(value, bytes):
        print(value.decode("utf-8", "backslashreplace"))
        return
    if isinstance(value, list):
        print(json.dumps(json_value(value), ensure_ascii=False, indent=2))
        return
    if value is None:
        print("(nil)")
        return
    print(value)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run an allow-listed read-only command against Memorystore.",
        epilog="Use SCAN instead of the blocking KEYS command.",
    )
    parser.add_argument("--host", default=os.environ.get("REDIS_HOST", ""))
    parser.add_argument(
        "--port", type=int, default=int(os.environ.get("REDIS_PORT", "6379"))
    )
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not args.host:
        fail("REDIS_HOST is not set; reconnect or pass --host")
    if not args.command:
        fail("specify a Redis command, for example: memorystore-inspect PING")

    command = args.command[0].upper()
    if command not in READ_ONLY_COMMANDS:
        allowed = ", ".join(sorted(READ_ONLY_COMMANDS))
        fail(f"{command} is not in the read-only allowlist\nallowed: {allowed}")

    password = os.environ.get("REDISCLI_AUTH")
    if password is None:
        password = getpass.getpass("Memorystore AUTH string: ")
    if not password:
        fail("the Memorystore AUTH string is required")

    try:
        with socket.create_connection((args.host, args.port), args.timeout) as connection:
            connection.settimeout(args.timeout)
            with connection.makefile("rwb", buffering=0) as stream:
                stream.write(encode_command(["AUTH", password]))
                auth_response = read_response(stream)
                if auth_response != "OK":
                    raise RedisError(f"unexpected AUTH response: {auth_response!r}")

                stream.write(encode_command([command, *args.command[1:]]))
                print_response(read_response(stream))
    except (ConnectionError, OSError, RedisError, ValueError) as error:
        fail(str(error))


if __name__ == "__main__":
    main()
