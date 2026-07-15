from __future__ import annotations

import base64
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

from PIL import Image, UnidentifiedImageError
from pypdf import PdfReader

PROTOCOL_VERSION = 1


class WorkerError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def probe_image(payload: dict[str, Any]) -> dict[str, Any]:
    path = Path(payload["path"])
    if not path.is_file():
        raise WorkerError("file_not_found", f"File does not exist: {path}")

    try:
        with Image.open(path) as image:
            image.verify()
        with Image.open(path) as image:
            return {
                "width": image.width,
                "height": image.height,
                "format": image.format,
                "mode": image.mode,
            }
    except (UnidentifiedImageError, OSError, SyntaxError) as error:
        raise WorkerError("invalid_image", str(error)) from error


def probe_video(payload: dict[str, Any]) -> dict[str, Any]:
    path = Path(payload["path"])
    if not path.is_file():
        raise WorkerError("file_not_found", f"File does not exist: {path}")

    ffprobe = payload.get("ffprobe_path", "ffprobe")
    process = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-show_streams",
            "-show_format",
            "-of",
            "json",
            str(path),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    if process.returncode != 0:
        raise WorkerError("invalid_video", process.stderr.strip() or "ffprobe failed")
    return json.loads(process.stdout)


def extract_pdf_text(payload: dict[str, Any]) -> dict[str, Any]:
    path = Path(payload["path"])
    if not path.is_file():
        raise WorkerError("file_not_found", f"File does not exist: {path}")

    try:
        reader = PdfReader(str(path))
        pages: list[dict[str, Any]] = []
        offset = 0
        combined: list[str] = []

        for page_number, page in enumerate(reader.pages, start=1):
            text = page.extract_text() or ""
            start = offset
            combined.append(text)
            offset += len(text)
            pages.append(
                {
                    "page": page_number,
                    "text": text,
                    "start_offset": start,
                    "end_offset": offset,
                }
            )

        full_text = "\n".join(combined)
        if not full_text.strip():
            raise WorkerError("text_layer_required", "PDF has no usable text layer")

        return {"text": full_text, "pages": pages}
    except WorkerError:
        raise
    except Exception as error:
        raise WorkerError("invalid_pdf", str(error)) from error


COMMANDS = {
    "probe_image": probe_image,
    "probe_video": probe_video,
    "extract_pdf_text": extract_pdf_text,
}


def respond(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))


def main() -> None:
    try:
        command = sys.argv[1]
        encoded_request = sys.argv[2]
        padding = "=" * (-len(encoded_request) % 4)
        request = json.loads(base64.urlsafe_b64decode(encoded_request + padding))

        if request.get("protocol_version") != PROTOCOL_VERSION:
            raise WorkerError("unsupported_protocol", "Unsupported media protocol version")
        if command not in COMMANDS:
            raise WorkerError("unknown_command", f"Unknown media command: {command}")

        result = COMMANDS[command](request.get("payload", {}))
        respond({"protocol_version": PROTOCOL_VERSION, "ok": True, "result": result})
    except WorkerError as error:
        respond(
            {
                "protocol_version": PROTOCOL_VERSION,
                "ok": False,
                "error": {"code": error.code, "message": error.message},
            }
        )
    except Exception as error:
        respond(
            {
                "protocol_version": PROTOCOL_VERSION,
                "ok": False,
                "error": {"code": "worker_error", "message": str(error)},
            }
        )


if __name__ == "__main__":
    main()
