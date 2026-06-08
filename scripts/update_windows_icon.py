from pathlib import Path
import struct


ROOT = Path(__file__).resolve().parents[1]
PNG_PATH = ROOT / "android" / "app" / "src" / "main" / "res" / "mipmap-xxxhdpi" / "ic_launcher.png"
ICO_PATH = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"


def read_png_size(data: bytes) -> tuple[int, int]:
    signature = b"\x89PNG\r\n\x1a\n"
    if not data.startswith(signature):
        raise ValueError("Source file is not a PNG.")
    width = struct.unpack(">I", data[16:20])[0]
    height = struct.unpack(">I", data[20:24])[0]
    return width, height


def ico_dimension(value: int) -> int:
    return 0 if value >= 256 else value


def build_ico(png_bytes: bytes) -> bytes:
    width, height = read_png_size(png_bytes)
    header = struct.pack("<HHH", 0, 1, 1)
    entry = struct.pack(
        "<BBBBHHII",
        ico_dimension(width),
        ico_dimension(height),
        0,
        0,
        1,
        32,
        len(png_bytes),
        22,
    )
    return header + entry + png_bytes


def main() -> None:
    png_bytes = PNG_PATH.read_bytes()
    ICO_PATH.write_bytes(build_ico(png_bytes))
    print(f"updated {ICO_PATH}")


if __name__ == "__main__":
    main()
