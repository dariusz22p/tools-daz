#!/usr/bin/env python3
"""Download videos from SharePoint using browser cookies for authentication.

Handles download-blocked SharePoint tenants by downloading DASH streaming
segments through Microsoft's media proxy and muxing with ffmpeg.

Downloads go into a 'downloads/' subfolder next to this script, gitignored.
When a subfolder exceeds 100 files, a new date-based subfolder is created.

Supported platforms: macOS, Linux, Windows.
Supported browsers: opera (default), chrome, edge, firefox, brave.

Usage:
    python sharepoint_dl.py [--browser BROWSER] <sharepoint_stream_url> [output_filename]

Requirements:
    pip install requests cryptography
    ffmpeg must be installed (brew install ffmpeg / apt install ffmpeg / choco install ffmpeg)
    On Windows: pip install pywin32
"""

import json
import os
import platform
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime
from urllib.parse import parse_qs, quote, unquote, urlparse


SUPPORTED_BROWSERS = ["opera", "chrome", "edge", "brave", "firefox"]
DEFAULT_BROWSER = "opera"

# --- Browser cookie paths per platform ---
_BROWSER_COOKIE_PATHS = {
    "Darwin": {
        "opera": "~/Library/Application Support/com.operasoftware.Opera/Default/Cookies",
        "chrome": "~/Library/Application Support/Google/Chrome/Default/Cookies",
        "edge": "~/Library/Application Support/Microsoft Edge/Default/Cookies",
        "brave": "~/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies",
        "firefox": "~/Library/Application Support/Firefox/Profiles",
    },
    "Linux": {
        "opera": "~/.config/opera/Default/Cookies",
        "chrome": "~/.config/google-chrome/Default/Cookies",
        "edge": "~/.config/microsoft-edge/Default/Cookies",
        "brave": "~/.config/BraveSoftware/Brave-Browser/Default/Cookies",
        "firefox": "~/.mozilla/firefox",
    },
    "Windows": {
        "opera": r"Opera Software\Opera Stable\Default\Cookies",
        "chrome": r"Google\Chrome\User Data\Default\Cookies",
        "edge": r"Microsoft\Edge\User Data\Default\Cookies",
        "brave": r"BraveSoftware\Brave-Browser\User Data\Default\Cookies",
        "firefox": "",  # resolved dynamically
    },
}

# Keychain service names for Chromium-based browsers (macOS)
_KEYCHAIN_SERVICES = {
    "opera": "Opera Safe Storage",
    "chrome": "Chrome Safe Storage",
    "edge": "Microsoft Edge Safe Storage",
    "brave": "Brave Safe Storage",
}

# Local State paths for Windows DPAPI key
_LOCAL_STATE_PATHS = {
    "opera": r"Opera Software\Opera Stable\Local State",
    "chrome": r"Google\Chrome\User Data\Local State",
    "edge": r"Microsoft\Edge\User Data\Local State",
    "brave": r"BraveSoftware\Brave-Browser\User Data\Local State",
}


def _get_firefox_cookie_db():
    """Find the default Firefox profile's cookies.sqlite."""
    plat = platform.system()
    if plat == "Darwin":
        profiles_dir = os.path.expanduser(
            "~/Library/Application Support/Firefox/Profiles"
        )
    elif plat == "Linux":
        profiles_dir = os.path.expanduser("~/.mozilla/firefox")
    elif plat == "Windows":
        profiles_dir = os.path.join(
            os.environ.get("APPDATA", ""), "Mozilla", "Firefox", "Profiles"
        )
    else:
        return ""

    if not os.path.isdir(profiles_dir):
        return ""

    # Look for profiles.ini to find the default profile
    _ = os.path.join(os.path.dirname(profiles_dir)
                            if plat != "Linux" else profiles_dir,
                            "..", "profiles.ini") if False else ""

    # Simpler: find the first *.default-release or *.default profile dir
    for entry in sorted(os.listdir(profiles_dir)):
        if entry.endswith(".default-release") or entry.endswith(".default"):
            candidate = os.path.join(profiles_dir, entry, "cookies.sqlite")
            if os.path.exists(candidate):
                return candidate

    # Fallback: any profile with cookies.sqlite
    for entry in os.listdir(profiles_dir):
        candidate = os.path.join(profiles_dir, entry, "cookies.sqlite")
        if os.path.exists(candidate):
            return candidate
    return ""


def _get_cookie_db(browser="opera"):
    """Return the cookie database path for the given browser and platform."""
    if browser == "firefox":
        return _get_firefox_cookie_db()

    plat = platform.system()
    paths = _BROWSER_COOKIE_PATHS.get(plat, {})
    path_tmpl = paths.get(browser, "")

    if plat == "Windows":
        return os.path.join(os.environ.get("LOCALAPPDATA", ""), path_tmpl)
    return os.path.expanduser(path_tmpl)


def _get_chromium_key(browser="opera"):
    """Retrieve the cookie encryption key for a Chromium-based browser."""
    plat = platform.system()
    if plat == "Darwin":
        service = _KEYCHAIN_SERVICES.get(browser, "")
        result = subprocess.run(
            ["security", "find-generic-password", "-w", "-s", service],
            capture_output=True, text=True,
        )
        return result.stdout.strip().encode("utf-8")
    elif plat == "Linux":
        try:
            import secretstorage
            service = _KEYCHAIN_SERVICES.get(browser, "")
            bus = secretstorage.dbus_init()
            collection = secretstorage.get_default_collection(bus)
            for item in collection.get_all_items():
                if item.get_label() == service:
                    return item.get_secret()
        except Exception:
            pass
        return b"peanuts"  # Chromium default on Linux
    elif plat == "Windows":
        local_state_rel = _LOCAL_STATE_PATHS.get(browser, "")
        local_state_path = os.path.join(
            os.environ.get("LOCALAPPDATA", ""), local_state_rel,
        )
        with open(local_state_path, "r") as f:
            local_state = json.load(f)
        import base64
        encrypted_key = base64.b64decode(local_state["os_crypt"]["encrypted_key"])
        encrypted_key = encrypted_key[5:]  # Remove DPAPI prefix
        import win32crypt
        return win32crypt.CryptUnprotectData(encrypted_key, None, None, None, 0)[1]
    raise RuntimeError(f"Unsupported platform: {plat}")


def check_requirements(browser="opera"):
    """Verify all dependencies are available, exit cleanly if not."""
    errors = []

    if browser not in SUPPORTED_BROWSERS:
        errors.append(
            f"Unsupported browser '{browser}'. Choose from: {', '.join(SUPPORTED_BROWSERS)}"
        )

    if sys.version_info < (3, 7):
        errors.append(f"Python 3.7+ required (found {platform.python_version()})")

    for pkg in ["requests", "cryptography"]:
        try:
            __import__(pkg)
        except ImportError:
            errors.append(f"Python package '{pkg}' not found. Install: pip install {pkg}")

    if not shutil.which("ffmpeg"):
        plat = platform.system()
        hint = {
            "Darwin": "brew install ffmpeg",
            "Linux": "sudo apt install ffmpeg  # or: sudo dnf install ffmpeg",
            "Windows": "choco install ffmpeg  # or: winget install ffmpeg",
        }.get(plat, "install ffmpeg for your platform")
        errors.append(f"ffmpeg not found in PATH. Install: {hint}")

    cookie_db = _get_cookie_db(browser)
    if not cookie_db or not os.path.exists(cookie_db):
        errors.append(
            f"{browser.capitalize()} cookie database not found"
            + (f" at:\n  {cookie_db}" if cookie_db else "")
            + f"\n  Make sure {browser.capitalize()} is installed and you have logged into SharePoint."
        )

    plat = platform.system()
    if browser != "firefox":
        if plat == "Darwin":
            if not shutil.which("security"):
                errors.append("macOS 'security' command not found (needed for Keychain access).")
        elif plat == "Windows":
            try:
                import win32crypt  # noqa: F401
            except ImportError:
                errors.append(
                    "Python package 'pywin32' not found (needed for Windows cookie decryption).\n"
                    "  Install: pip install pywin32"
                )

    if errors:
        print("\n[ERROR] Missing requirements:\n", file=sys.stderr)
        for i, err in enumerate(errors, 1):
            print(f"  {i}. {err}\n", file=sys.stderr)
        print("Fix the above and try again.", file=sys.stderr)
        sys.exit(1)


import requests
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.hashes import SHA1
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

DASH_NS = {"mpd": "urn:mpeg:DASH:schema:MPD:2011"}

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DOWNLOADS_ROOT = os.path.join(SCRIPT_DIR, "downloads")
MAX_FILES_PER_DIR = 100


def get_download_dir():
    """Return the current download directory, creating it if needed.

    Files go into DOWNLOADS_ROOT. When a subfolder reaches MAX_FILES_PER_DIR
    files, a new date-stamped subfolder (e.g. downloads/2026-04/) is created.
    """
    os.makedirs(DOWNLOADS_ROOT, exist_ok=True)

    # Count only files (not dirs) directly in downloads/
    top_files = [f for f in os.listdir(DOWNLOADS_ROOT)
                 if os.path.isfile(os.path.join(DOWNLOADS_ROOT, f))]

    if len(top_files) < MAX_FILES_PER_DIR:
        return DOWNLOADS_ROOT

    # Overflow: use a year-month subfolder
    sub = os.path.join(DOWNLOADS_ROOT, datetime.now().strftime("%Y-%m"))
    os.makedirs(sub, exist_ok=True)

    sub_files = [f for f in os.listdir(sub)
                 if os.path.isfile(os.path.join(sub, f))]
    if len(sub_files) < MAX_FILES_PER_DIR:
        return sub

    # Still full — add a numeric suffix
    idx = 2
    while True:
        candidate = f"{sub}-{idx}"
        os.makedirs(candidate, exist_ok=True)
        count = sum(1 for f in os.listdir(candidate)
                    if os.path.isfile(os.path.join(candidate, f)))
        if count < MAX_FILES_PER_DIR:
            return candidate
        idx += 1


def decrypt_cookie_value(encrypted_value, password):
    if not encrypted_value or len(encrypted_value) < 4:
        return ""
    if encrypted_value[:3] != b"v10":
        return encrypted_value.decode("utf-8", errors="replace")
    ciphertext = encrypted_value[3:]
    kdf = PBKDF2HMAC(
        algorithm=SHA1(), length=16, salt=b"saltysalt",
        iterations=1003, backend=default_backend(),
    )
    derived_key = kdf.derive(password)
    cipher = Cipher(
        algorithms.AES(derived_key), modes.CBC(b" " * 16),
        backend=default_backend(),
    )
    decrypted = cipher.decryptor().update(ciphertext) + cipher.decryptor().finalize()
    # Re-do properly (decryptor is single-use)
    decryptor = Cipher(
        algorithms.AES(derived_key), modes.CBC(b" " * 16),
        backend=default_backend(),
    ).decryptor()
    decrypted = decryptor.update(ciphertext) + decryptor.finalize()
    pad = decrypted[-1]
    if 1 <= pad <= 16:
        decrypted = decrypted[:-pad]
    if len(decrypted) > 32:
        return decrypted[32:].decode("utf-8", errors="replace")
    return ""


def _build_firefox_session(cookie_db):
    """Build a requests session from Firefox cookies (unencrypted SQLite)."""
    tmp_fd, tmp_path = tempfile.mkstemp(suffix=".db")
    os.close(tmp_fd)
    try:
        shutil.copy2(cookie_db, tmp_path)
        for ext in ["-wal", "-shm"]:
            src = cookie_db + ext
            if os.path.exists(src):
                shutil.copy2(src, tmp_path + ext)
        conn = sqlite3.connect(tmp_path)
        conn.execute("PRAGMA journal_mode=wal")
        cur = conn.cursor()
        cur.execute(
            "SELECT host, name, value FROM moz_cookies "
            "WHERE host LIKE '%sharepoint%'"
        )
        session = requests.Session()
        count = 0
        has_fedauth = False
        for host, name, value in cur.fetchall():
            if value:
                session.cookies.set(name, value, domain=host)
                count += 1
                if name == "FedAuth":
                    has_fedauth = True
        conn.close()
    finally:
        for ext in ["", "-wal", "-shm"]:
            p = tmp_path + ext
            if os.path.exists(p):
                os.unlink(p)
    return session, count, has_fedauth


def _build_chromium_session(cookie_db, browser):
    """Build a requests session from a Chromium-based browser's encrypted cookies."""
    tmp_fd, tmp_path = tempfile.mkstemp(suffix=".db")
    os.close(tmp_fd)
    try:
        shutil.copy2(cookie_db, tmp_path)
        for ext in ["-wal", "-shm"]:
            src = cookie_db + ext
            if os.path.exists(src):
                shutil.copy2(src, tmp_path + ext)
        password = _get_chromium_key(browser)
        conn = sqlite3.connect(tmp_path)
        conn.execute("PRAGMA journal_mode=wal")
        cur = conn.cursor()
        cur.execute(
            "SELECT host_key, name, encrypted_value FROM cookies "
            "WHERE host_key LIKE '%sharepoint%'"
        )
        session = requests.Session()
        count = 0
        has_fedauth = False
        for host_key, name, enc in cur.fetchall():
            if enc:
                try:
                    value = decrypt_cookie_value(enc, password)
                    if value:
                        session.cookies.set(name, value, domain=host_key)
                        count += 1
                        if name == "FedAuth":
                            has_fedauth = True
                except Exception:
                    pass
        conn.close()
    finally:
        for ext in ["", "-wal", "-shm"]:
            p = tmp_path + ext
            if os.path.exists(p):
                os.unlink(p)
    return session, count, has_fedauth


def build_session(browser="opera"):
    """Build a requests session with decrypted browser SharePoint cookies."""
    cookie_db = _get_cookie_db(browser)
    if not cookie_db or not os.path.exists(cookie_db):
        raise FileNotFoundError(
            f"{browser.capitalize()} cookie database not found at {cookie_db}"
        )

    if browser == "firefox":
        session, count, has_fedauth = _build_firefox_session(cookie_db)
    else:
        session, count, has_fedauth = _build_chromium_session(cookie_db, browser)
    if not has_fedauth:
        raise RuntimeError(
            f"FedAuth cookie not found — session expired. "
            f"Log in to SharePoint via {browser.capitalize()} and retry."
        )
    session.headers["User-Agent"] = (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    )
    print(f"Loaded {count} cookies (FedAuth: OK)")
    return session


def get_video_info(session, stream_url):
    """Get drive/item IDs and tempauth from the stream page."""
    parsed = urlparse(stream_url)
    base_url = f"{parsed.scheme}://{parsed.netloc}"

    path_parts = parsed.path.split("/")
    site_prefix = ""
    if "personal" in path_parts:
        idx = path_parts.index("personal")
        if idx + 1 < len(path_parts):
            site_prefix = "/".join(path_parts[: idx + 2])

    resp = session.get(stream_url, allow_redirects=True)
    if resp.status_code != 200:
        raise RuntimeError(f"Failed to load stream page: HTTP {resp.status_code}")
    if "Access required" in resp.text:
        raise RuntimeError("SharePoint returned 'Access required'. Session expired.")

    # Extract drive/item IDs
    m = re.search(r'drives/(b![^/]+)/items/([^/?&"\\]+)', resp.text)
    if not m:
        raise RuntimeError("Could not find drive/item IDs in stream page")
    drive_id, item_id = m.group(1), m.group(2)

    # Extract media proxy host
    m = re.search(r'(https://[\w-]+-mediap\.svc\.ms)', resp.text)
    if not m:
        raise RuntimeError("Could not find media proxy host in stream page")
    media_host = m.group(1)

    # Extract file info
    m = re.search(r"g_fileInfo\s*=\s*(\{.*?\});", resp.text, re.DOTALL)
    file_info = json.loads(m.group(1)) if m else {}

    # Get tempauth via thumbnails API
    api_url = f"{base_url}{site_prefix}/_api/v2.0/drives/{drive_id}/items/{item_id}/thumbnails"
    resp = session.get(api_url, headers={"Accept": "application/json"})
    if resp.status_code != 200:
        raise RuntimeError(f"Thumbnails API failed: HTTP {resp.status_code}")
    data = resp.json()
    thumb_url = data["value"][0]["large"]["url"]
    docid = parse_qs(urlparse(thumb_url).query)["docid"][0]

    return {
        "drive_id": drive_id,
        "item_id": item_id,
        "media_host": media_host,
        "docid": docid,
        "file_info": file_info,
    }


def get_dash_manifest(media_host, docid):
    """Fetch and parse the DASH manifest."""
    docid_encoded = quote(docid, safe="")
    manifest_url = (
        f"{media_host}/transform/videomanifest"
        f"?provider=spo&farmid=190893&inputFormat=mp4&cs=fFNQTw"
        f"&docid={docid_encoded}&part=index&format=dash"
    )
    resp = requests.get(manifest_url, timeout=30)
    if resp.status_code != 200:
        raise RuntimeError(f"DASH manifest failed: HTTP {resp.status_code}")
    return ET.fromstring(resp.content)


def parse_segments(manifest):
    """Parse DASH manifest and return segment URLs for audio and video."""
    base_url_el = manifest.find("mpd:BaseURL", DASH_NS)
    base_url = base_url_el.text if base_url_el is not None else ""

    tracks = {}
    for period in manifest.findall("mpd:Period", DASH_NS):
        for adapt_set in period.findall("mpd:AdaptationSet", DASH_NS):
            content_type = adapt_set.get("contentType", "unknown")
            # Get the best representation (highest bandwidth)
            reps = adapt_set.findall("mpd:Representation", DASH_NS)
            best_rep = max(reps, key=lambda r: int(r.get("bandwidth", "0")))
            rep_id = best_rep.get("id", "")

            seg_tmpl = best_rep.find("mpd:SegmentTemplate", DASH_NS)
            if seg_tmpl is None:
                seg_tmpl = adapt_set.find("mpd:SegmentTemplate", DASH_NS)
            if seg_tmpl is None:
                continue

            init_url = base_url + seg_tmpl.get("initialization", "").replace(
                "$RepresentationID$", rep_id
            )
            media_tmpl = seg_tmpl.get("media", "")
            _ = int(seg_tmpl.get("timescale", "1"))

            # Parse segment timeline
            timeline = seg_tmpl.find("mpd:SegmentTimeline", DASH_NS)
            segments = []
            current_time = 0
            if timeline is not None:
                for s in timeline.findall("mpd:S", DASH_NS):
                    t = int(s.get("t", str(current_time)))
                    d = int(s.get("d"))
                    r = int(s.get("r", "0"))
                    current_time = t
                    for _ in range(r + 1):
                        url = base_url + media_tmpl.replace(
                            "$RepresentationID$", rep_id
                        ).replace("$Time$", str(current_time))
                        segments.append(url)
                        current_time += d

            tracks[content_type] = {
                "init_url": init_url,
                "segments": segments,
                "rep_id": rep_id,
                "bandwidth": int(best_rep.get("bandwidth", "0")),
            }

    return tracks


def download_track(track_info, output_path, label, workers=4):
    """Download all segments of a track and concatenate to a file."""
    init_url = track_info["init_url"]
    segments = track_info["segments"]
    total = len(segments) + 1  # +1 for init

    print(f"  {label}: {total} segments ({track_info['bandwidth'] // 1000} kbps)")

    # Download init segment
    resp = requests.get(init_url, timeout=30)
    resp.raise_for_status()

    with open(output_path, "wb") as f:
        f.write(resp.content)

    # Download media segments in order (must be sequential for correct file)
    downloaded = 1
    for i, seg_url in enumerate(segments):
        resp = requests.get(seg_url, timeout=60)
        resp.raise_for_status()
        with open(output_path, "ab") as f:
            f.write(resp.content)
        downloaded += 1
        if downloaded % 50 == 0 or downloaded == total:
            pct = downloaded / total * 100
            mb = os.path.getsize(output_path) / (1024 * 1024)
            print(f"\r    {label}: {pct:.0f}% ({mb:.1f} MB)", end="", flush=True)

    mb = os.path.getsize(output_path) / (1024 * 1024)
    print(f"\r    {label}: 100% ({mb:.1f} MB)")


def mux_tracks(video_path, audio_path, output_path):
    """Mux video and audio tracks using ffmpeg."""
    cmd = [
        "ffmpeg", "-y",
        "-i", video_path,
        "-i", audio_path,
        "-c", "copy",
        "-movflags", "+faststart",
        output_path,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg muxing failed:\n{proc.stderr[-1000:]}")


def download_sharepoint_video(stream_url, output_path=None, browser="opera"):
    """Download a video from a SharePoint stream URL."""
    params = parse_qs(urlparse(stream_url).query)
    file_path = params.get("id", [None])[0]
    if file_path:
        file_path = unquote(file_path)

    if not output_path:
        filename = os.path.basename(file_path) if file_path else "sharepoint_video.mp4"
        dl_dir = get_download_dir()
        output_path = os.path.join(dl_dir, filename)

    print(f"Output: {output_path}\n")

    # Build authenticated session
    print(f"Extracting {browser.capitalize()} cookies...")
    session = build_session(browser)

    # Get video metadata and tempauth
    print("\nGetting video info...")
    info = get_video_info(session, stream_url)
    fi = info["file_info"]
    print(f"  Name: {fi.get('name', 'unknown')}")
    size = fi.get("size", 0)
    if size:
        print(f"  Size: {size / (1024 * 1024):.1f} MB (original)")

    # Get DASH manifest
    print("\nFetching DASH manifest...")
    manifest = get_dash_manifest(info["media_host"], info["docid"])
    tracks = parse_segments(manifest)

    if "video" not in tracks or "audio" not in tracks:
        raise RuntimeError(
            f"Expected video and audio tracks, got: {list(tracks.keys())}"
        )

    # Download segments to temp files
    tmp_dir = tempfile.mkdtemp(prefix="sp_dl_")
    try:
        video_tmp = os.path.join(tmp_dir, "video.mp4")
        audio_tmp = os.path.join(tmp_dir, "audio.mp4")

        print("\nDownloading segments...")
        download_track(tracks["video"], video_tmp, "video")
        download_track(tracks["audio"], audio_tmp, "audio")

        # Mux into final output
        print(f"\nMuxing to {output_path}...")
        mux_tracks(video_tmp, audio_tmp, output_path)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)

    final_size = os.path.getsize(output_path)
    print(f"\nDone: {output_path} ({final_size / (1024 * 1024):.1f} MB)")


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Download videos from SharePoint using browser cookies.",
    )
    parser.add_argument(
        "--browser", "-b",
        choices=SUPPORTED_BROWSERS,
        default=DEFAULT_BROWSER,
        help=f"Browser to read cookies from (default: {DEFAULT_BROWSER})",
    )
    parser.add_argument("url", help="SharePoint stream URL")
    parser.add_argument("output", nargs="?", default=None, help="Output filename (optional)")

    args = parser.parse_args()

    check_requirements(args.browser)
    download_sharepoint_video(args.url, args.output, args.browser)


if __name__ == "__main__":
    main()
