from __future__ import annotations

import base64
import hashlib
import io
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, UnidentifiedImageError
from pypdf import PdfReader

PROTOCOL_VERSION = 1


class WorkerError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def normalize_text(text: str) -> str:
    return text.removeprefix("\ufeff").replace("\r\n", "\n").replace("\r", "\n")


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
    raw = json.loads(process.stdout)
    video = next((stream for stream in raw.get("streams", []) if stream.get("codec_type") == "video"), {})
    audio = next((stream for stream in raw.get("streams", []) if stream.get("codec_type") == "audio"), {})
    duration = raw.get("format", {}).get("duration") or video.get("duration") or audio.get("duration")

    ffmpeg = payload.get("ffmpeg_path", "ffmpeg")
    volume = subprocess.run(
        [ffmpeg, "-v", "info", "-i", str(path), "-map", "0:a:0", "-af", "volumedetect", "-f", "null", "-"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    volume_output = volume.stderr + volume.stdout
    match = re.search(r"mean_volume:\s+(-?inf|-?[0-9.]+) dB", volume_output)
    mean_volume_db: float | None = None
    audio_is_silence = False
    if match:
        if match.group(1) == "-inf":
            audio_is_silence = True
        else:
            mean_volume_db = float(match.group(1))
            audio_is_silence = mean_volume_db <= -80.0

    return {
        "width": video.get("width"),
        "height": video.get("height"),
        "duration_ms": round(float(duration) * 1000) if duration is not None else None,
        "video_codec": video.get("codec_name"),
        "pixel_format": video.get("pix_fmt"),
        "audio_codec": audio.get("codec_name"),
        "audio_channels": audio.get("channels"),
        "audio_is_silence": audio_is_silence,
        "mean_volume_db": mean_volume_db,
        "raw": raw,
    }


def _seconds(milliseconds: int) -> str:
    return f"{milliseconds / 1000:.3f}"


def _subtitle_filter_path(path: Path) -> str:
    value = path.resolve().as_posix()
    value = value.replace("\\", "/").replace(":", r"\:").replace("'", r"\'")
    return value


def _clip_filter(index: int, clip: dict[str, Any], width: int, height: int, fps: int) -> str:
    duration_ms = int(clip["duration_ms"])
    duration = _seconds(duration_ms)
    frames = max(1, round(duration_ms * fps / 1000))
    motion = clip.get("motion", "static")
    base = f"[{index}:v]scale={width}:{height}:force_original_aspect_ratio=increase,crop={width}:{height},setsar=1"

    if motion in {"push_in", "pull_out"}:
        if motion == "push_in":
            zoom = f"1+0.08*on/{max(1, frames - 1)}"
        else:
            zoom = f"1.08-0.08*on/{max(1, frames - 1)}"
        base += (
            f",zoompan=z='{zoom}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'"
            f":d={frames}:s={width}x{height}:fps={fps}"
        )
    elif motion in {"pan_left", "pan_right", "pan_up", "pan_down"}:
        enlarged_width = round(width * 1.08)
        enlarged_height = round(height * 1.08)
        if motion == "pan_left":
            x_expr, y_expr = f"(iw-ow)*(1-on/{max(1, frames - 1)})", "(ih-oh)/2"
        elif motion == "pan_right":
            x_expr, y_expr = f"(iw-ow)*on/{max(1, frames - 1)}", "(ih-oh)/2"
        elif motion == "pan_up":
            x_expr, y_expr = "(iw-ow)/2", f"(ih-oh)*(1-on/{max(1, frames - 1)})"
        else:
            x_expr, y_expr = "(iw-ow)/2", f"(ih-oh)*on/{max(1, frames - 1)}"
        base = (
            f"[{index}:v]scale={enlarged_width}:{enlarged_height}:force_original_aspect_ratio=increase,"
            f"zoompan=z=1:x='{x_expr}':y='{y_expr}':d={frames}:s={width}x{height}:fps={fps},setsar=1"
        )
    else:
        base += f",fps={fps}"

    return f"{base},trim=duration={duration},setpts=PTS-STARTPTS,format=yuv420p[v{index}]"


def render_animatic(payload: dict[str, Any]) -> dict[str, Any]:
    clips = payload.get("clips", [])
    if not clips:
        raise WorkerError("empty_timeline", "At least one clip is required")

    width = int(payload["width"])
    height = int(payload["height"])
    fps = int(payload.get("fps", 24))
    duration_ms = int(payload["duration_ms"])
    output_path = Path(payload["output_path"])
    srt_path = Path(payload["srt_path"])
    ffmpeg = payload.get("ffmpeg_path", "ffmpeg")
    output_path.parent.mkdir(parents=True, exist_ok=True)

    command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y"]
    for clip in clips:
        clip_duration = _seconds(int(clip["duration_ms"]))
        path = clip.get("path")
        if path:
            command.extend(["-loop", "1", "-t", clip_duration, "-i", str(path)])
        else:
            command.extend(
                [
                    "-f",
                    "lavfi",
                    "-t",
                    clip_duration,
                    "-i",
                    f"color=c=0x1f2937:s={width}x{height}:r={fps}",
                ]
            )

    command.extend(
        [
            "-f",
            "lavfi",
            "-t",
            _seconds(duration_ms),
            "-i",
            "anullsrc=channel_layout=stereo:sample_rate=48000",
        ]
    )

    filters = [_clip_filter(index, clip, width, height, fps) for index, clip in enumerate(clips)]
    if len(clips) == 1:
        current = "v0"
    elif all(clip.get("transition_after", "hard_cut") == "hard_cut" for clip in clips[:-1]):
        joined = "".join(f"[v{index}]" for index in range(len(clips)))
        filters.append(f"{joined}concat=n={len(clips)}:v=1:a=0[joined]")
        current = "joined"
    else:
        current = "v0"
        elapsed_ms = int(clips[0]["duration_ms"])
        for index in range(1, len(clips)):
            previous = clips[index - 1]
            transition_ms = (
                int(previous.get("transition_duration_ms", 0))
                if previous.get("transition_after") == "cross_dissolve"
                else 1
            )
            transition_ms = max(1, transition_ms)
            offset_ms = max(0, elapsed_ms - transition_ms)
            output = f"joined{index}"
            filters.append(
                f"[{current}][v{index}]xfade=transition=fade:duration={_seconds(transition_ms)}:"
                f"offset={_seconds(offset_ms)}[{output}]"
            )
            current = output
            elapsed_ms = offset_ms + int(clips[index]["duration_ms"])

    if payload.get("subtitle_burn_in", True) and srt_path.is_file() and srt_path.stat().st_size:
        subtitle_path = _subtitle_filter_path(srt_path)
        margin_v = max(36, round(height * 0.08))
        font_size = max(18, round(height * 0.031))
        filters.append(
            f"[{current}]subtitles=filename='{subtitle_path}':"
            f"force_style='Alignment=2,MarginV={margin_v},FontSize={font_size},Outline=2,Shadow=0'[video]"
        )
        current = "video"

    audio_index = len(clips)
    command.extend(
        [
            "-filter_complex",
            ";".join(filters),
            "-map",
            f"[{current}]",
            "-map",
            f"{audio_index}:a:0",
            "-t",
            _seconds(duration_ms),
            "-r",
            str(fps),
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "23",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-ac",
            "2",
            "-ar",
            "48000",
            "-b:a",
            "128k",
            "-movflags",
            "+faststart",
            str(output_path),
        ]
    )

    process = subprocess.run(
        command,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if process.returncode != 0:
        raise WorkerError("ffmpeg_render_failed", process.stderr.strip() or process.stdout.strip())

    return probe_video(
        {
            "path": str(output_path),
            "ffprobe_path": payload.get("ffprobe_path", "ffprobe"),
            "ffmpeg_path": ffmpeg,
        }
    )


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
            text = normalize_text(page.extract_text() or "")
            if page_number > 1:
                combined.append("\n")
                offset += 1
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

        full_text = "".join(combined)
        if not full_text.strip():
            raise WorkerError("text_layer_required", "PDF has no usable text layer")

        return {"text": full_text, "pages": pages}
    except WorkerError:
        raise
    except Exception as error:
        raise WorkerError("invalid_pdf", str(error)) from error


def generate_fake_image(payload: dict[str, Any]) -> dict[str, Any]:
    width = int(payload.get("width", 540))
    height = int(payload.get("height", 960))
    seed = str(payload.get("seed", "fake"))

    if width <= 0 or height <= 0 or width > 4096 or height > 4096:
        raise WorkerError("invalid_dimensions", "Fake image dimensions are out of range")

    digest = hashlib.sha256(seed.encode("utf-8")).digest()
    background = tuple(32 + component % 160 for component in digest[:3])
    accent = tuple(64 + component % 192 for component in digest[3:6])
    image = Image.new("RGB", (width, height), background)
    draw = ImageDraw.Draw(image)

    margin = max(8, min(width, height) // 18)
    draw.rounded_rectangle(
        (margin, margin, width - margin, height - margin),
        radius=max(6, margin // 2),
        outline=accent,
        width=max(2, margin // 5),
    )

    for index in range(3):
        left = margin * 2 + index * max(1, (width - margin * 4) // 3)
        top = height // 3 + digest[6 + index] % max(1, height // 6)
        radius = max(6, min(width, height) // (12 + index * 2))
        draw.ellipse((left - radius, top - radius, left + radius, top + radius), fill=accent)

    draw.text((margin * 2, height - margin * 3), digest.hex()[:16], fill=(245, 245, 245))
    output = io.BytesIO()
    image.save(output, format="PNG", optimize=False, compress_level=6)
    png = output.getvalue()

    return {
        "png_base64": base64.b64encode(png).decode("ascii"),
        "width": width,
        "height": height,
        "format": "PNG",
    }


COMMANDS = {
    "probe_image": probe_image,
    "probe_video": probe_video,
    "extract_pdf_text": extract_pdf_text,
    "generate_fake_image": generate_fake_image,
    "render_animatic": render_animatic,
}


def respond(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=True, separators=(",", ":")))


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
