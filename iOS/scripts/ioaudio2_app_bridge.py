#!/usr/bin/env python3
"""Bridge AudioRepeater iOS requests to the validated IOAudio2 ring injector."""

from __future__ import annotations

import json
import logging
import pathlib
import queue
import socket
import subprocess
import tempfile
import threading
import time
import wave
from typing import Any


PHONE_HOST = "your-device-host"
FRIDA_ENDPOINT = ("127.0.0.1", 27043)
REMOTE_DOCUMENTS = "/var/mobile/Documents"
REMOTE_AUDIO = f"{REMOTE_DOCUMENTS}/RemoteAudio"
REMOTE_REQUEST = f"{REMOTE_DOCUMENTS}/ioaudio2-playback-request.json"
REMOTE_RUNNING = f"{REMOTE_DOCUMENTS}/ioaudio2-playback-request.running.json"
REMOTE_STATUS = f"{REMOTE_DOCUMENTS}/ioaudio2-playback-status.json"
REMOTE_CANCEL = f"{REMOTE_DOCUMENTS}/ioaudio2-playback-cancel.json"
KEEPALIVE = "/var/jb/usr/local/bin/a2m_c0004_audiorepeater_keepalive"

BRIDGE_ROOT = pathlib.Path(__file__).resolve().parent
SSH_KEY = pathlib.Path("~/.ssh/id_ed25519").expanduser()
PYTHON = pathlib.Path("~/.venvs/a2m-frida/bin/python").expanduser()
INJECTOR = BRIDGE_ROOT / "inject_wav_ioaudio2.py"
INJECTOR_SCRIPT = BRIDGE_ROOT / "inject_wav_ioaudio2.js"
VOLUME_SCRIPT = BRIDGE_ROOT / "set_media_volume.js"
RUNS = BRIDGE_ROOT / "runs"
SSH_CONTROL_PATH = BRIDGE_ROOT / "ssh-control-%r@%h:%p"

STATIC_RING_FRAMES = 15_840
STATIC_SOURCE_OFFSET_FRAMES = 4_096
SAMPLE_RATE = 48_000
RING_SECONDS = STATIC_RING_FRAMES / SAMPLE_RATE
SOURCE_OFFSET_SECONDS = STATIC_SOURCE_OFFSET_FRAMES / SAMPLE_RATE


def ssh_args(remote_command: str) -> list[str]:
    return [
        "ssh",
        "-i",
        str(SSH_KEY),
        "-o",
        "ControlMaster=auto",
        "-o",
        "ControlPersist=60",
        "-o",
        f"ControlPath={SSH_CONTROL_PATH}",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=5",
        f"root@{PHONE_HOST}",
        remote_command,
    ]


def run_ssh(
    remote_command: str,
    *,
    input_text: str | None = None,
    check: bool = True,
    timeout: float = 15,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ssh_args(remote_command),
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=check,
        timeout=timeout,
    )


def ensure_frida_tunnel() -> None:
    try:
        with socket.create_connection(FRIDA_ENDPOINT, timeout=1):
            return
    except OSError:
        pass

    subprocess.run(
        [
            "ssh",
            "-f",
            "-N",
            "-L",
            "127.0.0.1:27043:127.0.0.1:27042",
            "-i",
            str(SSH_KEY),
            "-o",
            "BatchMode=yes",
            "-o",
            "ExitOnForwardFailure=yes",
            f"root@{PHONE_HOST}",
        ],
        check=True,
        timeout=15,
    )
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(FRIDA_ENDPOINT, timeout=1):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("Frida tunnel did not become ready")


def claim_request() -> dict[str, Any] | None:
    command = (
        f"if [ -s '{REMOTE_REQUEST}' ]; then "
        f"mv '{REMOTE_REQUEST}' '{REMOTE_RUNNING}'; "
        f"cat '{REMOTE_RUNNING}'; "
        f"elif [ -s '{REMOTE_RUNNING}' ]; then cat '{REMOTE_RUNNING}'; fi"
    )
    result = run_ssh(command, check=False)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "request read failed")
    payload = result.stdout.strip()
    return json.loads(payload) if payload else None


def write_status(request_id: str, state: str, **values: Any) -> None:
    payload = {
        "schema": "audiorepeater_ioaudio2_status_v1",
        "requestID": request_id,
        "state": state,
        "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        **values,
    }
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    command = (
        "umask 022; "
        "cat > /tmp/a2m-ioaudio2-status.json; "
        f"mv /tmp/a2m-ioaudio2-status.json '{REMOTE_STATUS}'; "
        f"chown mobile:mobile '{REMOTE_STATUS}'"
    )
    run_ssh(command, input_text=data)
    logging.info(
        "status request=%s state=%s item=%s repeat=%s/%s",
        request_id,
        state,
        values.get("itemKey", "-"),
        values.get("currentRepeat", "-"),
        values.get("totalRepeats", "-"),
    )


def read_cancel_request(request_id: str) -> bool:
    command = (
        f"if [ -s '{REMOTE_CANCEL}' ]; then cat '{REMOTE_CANCEL}'; fi"
    )
    result = run_ssh(command, check=False)
    if result.returncode != 0 or not result.stdout.strip():
        return False
    try:
        cancel = json.loads(result.stdout)
    except json.JSONDecodeError:
        return False
    return cancel.get("requestID") == request_id


def cleanup_remote_request() -> None:
    run_ssh(
        f"rm -f '{REMOTE_RUNNING}' '{REMOTE_CANCEL}'",
        check=False,
    )


def fetch_wav(file_name: str, destination: pathlib.Path) -> None:
    if (
        not file_name
        or pathlib.PurePosixPath(file_name).name != file_name
        or ".." in file_name
        or not file_name.lower().endswith(".wav")
    ):
        raise ValueError(f"unsafe WAV file name: {file_name!r}")
    subprocess.run(
        [
            "scp",
            "-i",
            str(SSH_KEY),
            "-o",
            "ControlMaster=auto",
            "-o",
            "ControlPersist=60",
            "-o",
            f"ControlPath={SSH_CONTROL_PATH}",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=5",
            f"root@{PHONE_HOST}:{REMOTE_AUDIO}/{file_name}",
            str(destination),
        ],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )


def wav_frames(path: pathlib.Path) -> int:
    with wave.open(str(path), "rb") as source:
        if (
            source.getframerate() != SAMPLE_RATE
            or source.getnchannels() not in (1, 2)
            or source.getsampwidth() not in (2, 3, 4)
            or source.getcomptype() != "NONE"
        ):
            raise ValueError(
                "IOAudio2 requires uncompressed 48 kHz PCM WAV"
            )
        return source.getnframes()


def stream_output(
    process: subprocess.Popen[str],
    output_queue: queue.Queue[str],
    output_log: pathlib.Path,
) -> None:
    assert process.stdout is not None
    with output_log.open("w", encoding="utf-8", newline="\n") as log:
        for line in process.stdout:
            log.write(line)
            log.flush()
            output_queue.put(line)


def injector_command(
    wav: pathlib.Path,
    repeat_count: int,
    injector_log: pathlib.Path,
) -> list[str]:
    return [
        str(PYTHON),
        str(INJECTOR),
        str(wav),
        "--script",
        str(INJECTOR_SCRIPT),
        "--volume-script",
        str(VOLUME_SCRIPT),
        "--endpoint",
        f"{FRIDA_ENDPOINT[0]}:{FRIDA_ENDPOINT[1]}",
        "--iphone-host",
        PHONE_HOST,
        "--ssh-key",
        str(SSH_KEY),
        "--repeat-count",
        str(repeat_count),
        "--gap-seconds",
        "0",
        "--gain",
        "1",
        "--media-volume",
        "1",
        "--overwrite-interval-ms",
        "1",
        "--static-ring-frames",
        str(STATIC_RING_FRAMES),
        "--static-source-offset-frames",
        str(STATIC_SOURCE_OFFSET_FRAMES),
        "--keepalive-path",
        KEEPALIVE,
        "--emit-keepalive-output",
        "--log",
        str(injector_log),
    ]


def play_item(
    request_id: str,
    item: dict[str, Any],
    local_wav: pathlib.Path,
    run_directory: pathlib.Path,
) -> bool:
    item_key = str(item["itemKey"])
    display_name = str(item["displayName"])
    repeat_count = int(item["repeatCount"])
    if repeat_count <= 0:
        raise ValueError("repeatCount must be positive")
    source_frames = wav_frames(local_wav)
    if STATIC_SOURCE_OFFSET_FRAMES + source_frames > STATIC_RING_FRAMES:
        raise ValueError(
            f"{display_name}: optimized c0004 ring capacity exceeded"
        )

    injector_log = run_directory / f"{item_key}.injector.jsonl"
    stdout_log = run_directory / f"{item_key}.stdout.log"
    process = subprocess.Popen(
        injector_command(local_wav, repeat_count, injector_log),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    output_queue: queue.Queue[str] = queue.Queue()
    output_thread = threading.Thread(
        target=stream_output,
        args=(process, output_queue, stdout_log),
        daemon=True,
    )
    output_thread.start()

    started_at: float | None = None
    started_epoch: float | None = None
    last_repeat = 0
    last_cancel_poll = 0.0
    try:
        while process.poll() is None:
            now = time.monotonic()
            try:
                while True:
                    line = output_queue.get_nowait()
                    if (
                        '"event":"started"' in line
                        and started_at is None
                    ):
                        started_at = time.monotonic()
                        started_epoch = time.time()
            except queue.Empty:
                pass

            if now - last_cancel_poll >= 0.5:
                last_cancel_poll = now
                if read_cancel_request(request_id):
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                    return False

            if started_at is not None:
                assert started_epoch is not None
                elapsed = max(
                    0.0,
                    now - started_at - SOURCE_OFFSET_SECONDS,
                )
                current_repeat = min(
                    repeat_count,
                    int(elapsed / RING_SECONDS) + 1,
                )
                if current_repeat != last_repeat:
                    last_repeat = current_repeat
                    write_status(
                        request_id,
                        "playing",
                        itemKey=item_key,
                        displayName=display_name,
                        currentRepeat=current_repeat,
                        totalRepeats=repeat_count,
                        startedAtUnixSeconds=started_epoch,
                        repeatIntervalSeconds=RING_SECONDS,
                        message=(
                            f"{display_name} "
                            f"{current_repeat}/{repeat_count}"
                        ),
                    )
            time.sleep(0.03)
    finally:
        if process.poll() is None:
            process.kill()
        output_thread.join(timeout=2)

    if process.returncode != 0:
        detail = stdout_log.read_text(
            encoding="utf-8",
            errors="replace",
        )[-2_000:]
        raise RuntimeError(
            f"IOAudio2 injector failed ({process.returncode}): {detail}"
        )
    return True


def validate_request(request: dict[str, Any]) -> None:
    if request.get("schema") != "audiorepeater_ioaudio2_request_v1":
        raise ValueError("unsupported request schema")
    if not request.get("requestID"):
        raise ValueError("missing requestID")
    items = request.get("items")
    if not isinstance(items, list) or not items:
        raise ValueError("empty item list")
    for item in items:
        for key in ("itemKey", "fileName", "displayName", "repeatCount"):
            if key not in item:
                raise ValueError(f"item is missing {key}")


def process_request(request: dict[str, Any]) -> None:
    validate_request(request)
    request_id = str(request["requestID"])
    run_directory = RUNS / (
        time.strftime("%Y%m%d_%H%M%S") + "_" + request_id
    )
    run_directory.mkdir(parents=True, exist_ok=True)
    (run_directory / "request.json").write_text(
        json.dumps(request, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    write_status(
        request_id,
        "accepted",
        message="c0004 IOAudio2 ring 준비 중",
    )
    ensure_frida_tunnel()

    with tempfile.TemporaryDirectory(
        prefix="a2m-ioaudio2-",
        dir=run_directory,
    ) as temporary:
        temporary_root = pathlib.Path(temporary)
        for index, item in enumerate(request["items"]):
            if read_cancel_request(request_id):
                write_status(request_id, "cancelled", message="재생 정지됨")
                return

            local_wav = temporary_root / f"{index:02d}.wav"
            fetch_wav(str(item["fileName"]), local_wav)
            if not play_item(
                request_id,
                item,
                local_wav,
                run_directory,
            ):
                write_status(request_id, "cancelled", message="재생 정지됨")
                return

            if index < len(request["items"]) - 1:
                delay = max(
                    0.0,
                    float(request.get("differentFileDelaySeconds", 0)),
                )
                deadline = time.monotonic() + delay
                while time.monotonic() < deadline:
                    if read_cancel_request(request_id):
                        write_status(
                            request_id,
                            "cancelled",
                            message="재생 정지됨",
                        )
                        return
                    time.sleep(min(0.1, deadline - time.monotonic()))

    write_status(request_id, "complete", message="재생 완료")


def preflight() -> None:
    required = (
        SSH_KEY,
        PYTHON,
        INJECTOR,
        INJECTOR_SCRIPT,
        VOLUME_SCRIPT,
    )
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise FileNotFoundError(", ".join(missing))
    RUNS.mkdir(parents=True, exist_ok=True)


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    preflight()
    logging.info("AudioRepeater IOAudio2 bridge started")
    consecutive_errors = 0

    while True:
        request: dict[str, Any] | None = None
        try:
            request = claim_request()
            consecutive_errors = 0
            if request is None:
                time.sleep(0.25)
                continue
            process_request(request)
        except KeyboardInterrupt:
            return 0
        except Exception as error:
            logging.exception("bridge request failed")
            if request and request.get("requestID"):
                try:
                    write_status(
                        str(request["requestID"]),
                        "error",
                        message=str(error),
                    )
                except Exception:
                    logging.exception("failed to publish bridge error")
            consecutive_errors += 1
            time.sleep(min(5.0, 0.5 * consecutive_errors))
        finally:
            if request is not None:
                cleanup_remote_request()


if __name__ == "__main__":
    raise SystemExit(main())
