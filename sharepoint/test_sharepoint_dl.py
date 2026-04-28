#!/usr/bin/env python3
"""Unit tests for sharepoint_dl.py."""

import json
import os
import sqlite3
import tempfile
import xml.etree.ElementTree as ET
from unittest.mock import MagicMock, patch, PropertyMock

import pytest

import sharepoint_dl


# ---------------------------------------------------------------------------
# get_download_dir
# ---------------------------------------------------------------------------

class TestGetDownloadDir:
    """Tests for download directory selection with overflow logic."""

    def test_creates_downloads_root(self, tmp_path):
        root = str(tmp_path / "downloads")
        with patch.object(sharepoint_dl, "DOWNLOADS_ROOT", root):
            result = sharepoint_dl.get_download_dir()
        assert result == root
        assert os.path.isdir(root)

    def test_returns_root_when_under_limit(self, tmp_path):
        root = str(tmp_path / "downloads")
        os.makedirs(root)
        for i in range(50):
            (tmp_path / "downloads" / f"file{i}.mp4").touch()
        with patch.object(sharepoint_dl, "DOWNLOADS_ROOT", root):
            assert sharepoint_dl.get_download_dir() == root

    def test_creates_dated_subfolder_at_limit(self, tmp_path):
        root = str(tmp_path / "downloads")
        os.makedirs(root)
        for i in range(100):
            (tmp_path / "downloads" / f"file{i}.mp4").touch()
        with patch.object(sharepoint_dl, "DOWNLOADS_ROOT", root):
            result = sharepoint_dl.get_download_dir()
        from datetime import datetime
        expected_sub = os.path.join(root, datetime.now().strftime("%Y-%m"))
        assert result == expected_sub
        assert os.path.isdir(expected_sub)

    def test_numbered_suffix_when_subfolder_full(self, tmp_path):
        root = str(tmp_path / "downloads")
        os.makedirs(root)
        # Fill root
        for i in range(100):
            (tmp_path / "downloads" / f"file{i}.mp4").touch()
        # Fill the dated subfolder too
        from datetime import datetime
        sub = os.path.join(root, datetime.now().strftime("%Y-%m"))
        os.makedirs(sub)
        for i in range(100):
            open(os.path.join(sub, f"file{i}.mp4"), "w").close()
        with patch.object(sharepoint_dl, "DOWNLOADS_ROOT", root):
            result = sharepoint_dl.get_download_dir()
        assert result == f"{sub}-2"
        assert os.path.isdir(result)

    def test_dirs_inside_root_not_counted(self, tmp_path):
        """Subdirectories should not count toward the 100-file limit."""
        root = str(tmp_path / "downloads")
        os.makedirs(root)
        for i in range(99):
            (tmp_path / "downloads" / f"file{i}.mp4").touch()
        os.makedirs(tmp_path / "downloads" / "subfolder")
        with patch.object(sharepoint_dl, "DOWNLOADS_ROOT", root):
            assert sharepoint_dl.get_download_dir() == root


# ---------------------------------------------------------------------------
# decrypt_cookie_value
# ---------------------------------------------------------------------------

class TestDecryptCookieValue:
    """Tests for the cookie decryption function."""

    def test_empty_value_returns_empty(self):
        assert sharepoint_dl.decrypt_cookie_value(b"", b"password") == ""

    def test_none_value_returns_empty(self):
        assert sharepoint_dl.decrypt_cookie_value(None, b"password") == ""

    def test_short_value_returns_empty(self):
        assert sharepoint_dl.decrypt_cookie_value(b"ab", b"password") == ""

    def test_non_v10_returns_plaintext(self):
        result = sharepoint_dl.decrypt_cookie_value(b"hello world", b"password")
        assert result == "hello world"

    def test_v10_decryption_roundtrip(self):
        """Encrypt a known value with the same scheme and verify decryption."""
        from cryptography.hazmat.backends import default_backend
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives.hashes import SHA1
        from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

        password = b"test_password"
        plaintext_value = "test_cookie_value"

        # Derive key same way as the function
        kdf = PBKDF2HMAC(
            algorithm=SHA1(), length=16, salt=b"saltysalt",
            iterations=1003, backend=default_backend(),
        )
        derived_key = kdf.derive(password)

        # Build plaintext: 32-byte prefix + actual value
        prefix = b"\x00" * 32
        data = prefix + plaintext_value.encode("utf-8")

        # PKCS7 pad to 16 bytes
        pad_len = 16 - (len(data) % 16)
        data += bytes([pad_len]) * pad_len

        # Encrypt
        encryptor = Cipher(
            algorithms.AES(derived_key), modes.CBC(b" " * 16),
            backend=default_backend(),
        ).encryptor()
        ciphertext = encryptor.update(data) + encryptor.finalize()
        encrypted_value = b"v10" + ciphertext

        result = sharepoint_dl.decrypt_cookie_value(encrypted_value, password)
        assert result == plaintext_value

    def test_v10_short_decrypted_returns_empty(self):
        """If decrypted data is ≤32 bytes, return empty (it's just the hash)."""
        from cryptography.hazmat.backends import default_backend
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives.hashes import SHA1
        from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

        password = b"test_password"
        kdf = PBKDF2HMAC(
            algorithm=SHA1(), length=16, salt=b"saltysalt",
            iterations=1003, backend=default_backend(),
        )
        derived_key = kdf.derive(password)

        # 16 bytes of data — after unpadding ≤32, should return ""
        data = b"\x00" * 16
        pad_len = 16 - (len(data) % 16)
        if pad_len == 0:
            pad_len = 16
        data += bytes([pad_len]) * pad_len

        encryptor = Cipher(
            algorithms.AES(derived_key), modes.CBC(b" " * 16),
            backend=default_backend(),
        ).encryptor()
        ciphertext = encryptor.update(data) + encryptor.finalize()
        encrypted_value = b"v10" + ciphertext

        result = sharepoint_dl.decrypt_cookie_value(encrypted_value, password)
        assert result == ""


# ---------------------------------------------------------------------------
# parse_segments
# ---------------------------------------------------------------------------

SAMPLE_MPD = """\
<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:DASH:schema:MPD:2011" type="static">
  <BaseURL>https://media.example.com/transform/</BaseURL>
  <Period>
    <AdaptationSet contentType="video">
      <Representation id="vcopy" bandwidth="500000">
        <SegmentTemplate
          initialization="init?rep=$RepresentationID$"
          media="seg?rep=$RepresentationID$&amp;t=$Time$"
          timescale="1000">
          <SegmentTimeline>
            <S t="0" d="6000" r="2" />
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
    <AdaptationSet contentType="audio">
      <Representation id="audcopy" bandwidth="128000">
        <SegmentTemplate
          initialization="init?rep=$RepresentationID$"
          media="seg?rep=$RepresentationID$&amp;t=$Time$"
          timescale="1000">
          <SegmentTimeline>
            <S t="0" d="6000" r="1" />
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
"""


class TestParseSegments:
    """Tests for DASH manifest segment parsing."""

    def test_parses_video_and_audio(self):
        manifest = ET.fromstring(SAMPLE_MPD)
        tracks = sharepoint_dl.parse_segments(manifest)
        assert "video" in tracks
        assert "audio" in tracks

    def test_video_segment_count(self):
        manifest = ET.fromstring(SAMPLE_MPD)
        tracks = sharepoint_dl.parse_segments(manifest)
        # r="2" means 3 segments total (0, 6000, 12000)
        assert len(tracks["video"]["segments"]) == 3

    def test_audio_segment_count(self):
        manifest = ET.fromstring(SAMPLE_MPD)
        tracks = sharepoint_dl.parse_segments(manifest)
        # r="1" means 2 segments total
        assert len(tracks["audio"]["segments"]) == 2

    def test_segment_urls_contain_base_url(self):
        manifest = ET.fromstring(SAMPLE_MPD)
        tracks = sharepoint_dl.parse_segments(manifest)
        for url in tracks["video"]["segments"]:
            assert url.startswith("https://media.example.com/transform/")

    def test_segment_urls_replace_representation_id(self):
        manifest = ET.fromstring(SAMPLE_MPD)
        tracks = sharepoint_dl.parse_segments(manifest)
        for url in tracks["video"]["segments"]:
            assert "vcopy" in url
            assert "$RepresentationID$" not in url

    def test_segment_urls_replace_time(self):
        manifest = ET.fromstring(SAMPLE_MPD)
        tracks = sharepoint_dl.parse_segments(manifest)
        segs = tracks["video"]["segments"]
        assert "t=0" in segs[0]
        assert "t=6000" in segs[1]
        assert "t=12000" in segs[2]

    def test_init_url(self):
        manifest = ET.fromstring(SAMPLE_MPD)
        tracks = sharepoint_dl.parse_segments(manifest)
        assert "init?rep=vcopy" in tracks["video"]["init_url"]
        assert "init?rep=audcopy" in tracks["audio"]["init_url"]

    def test_bandwidth(self):
        manifest = ET.fromstring(SAMPLE_MPD)
        tracks = sharepoint_dl.parse_segments(manifest)
        assert tracks["video"]["bandwidth"] == 500000
        assert tracks["audio"]["bandwidth"] == 128000

    def test_picks_highest_bandwidth(self):
        mpd = """\
<?xml version="1.0"?>
<MPD xmlns="urn:mpeg:DASH:schema:MPD:2011" type="static">
  <BaseURL>https://example.com/</BaseURL>
  <Period>
    <AdaptationSet contentType="video">
      <Representation id="low" bandwidth="100000">
        <SegmentTemplate initialization="init-$RepresentationID$"
                         media="seg-$RepresentationID$-$Time$" timescale="1000">
          <SegmentTimeline><S t="0" d="5000"/></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
      <Representation id="high" bandwidth="900000">
        <SegmentTemplate initialization="init-$RepresentationID$"
                         media="seg-$RepresentationID$-$Time$" timescale="1000">
          <SegmentTimeline><S t="0" d="5000"/></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
"""
        manifest = ET.fromstring(mpd)
        tracks = sharepoint_dl.parse_segments(manifest)
        assert tracks["video"]["rep_id"] == "high"
        assert tracks["video"]["bandwidth"] == 900000

    def test_empty_manifest(self):
        mpd = """\
<?xml version="1.0"?>
<MPD xmlns="urn:mpeg:DASH:schema:MPD:2011" type="static">
  <Period/>
</MPD>
"""
        manifest = ET.fromstring(mpd)
        tracks = sharepoint_dl.parse_segments(manifest)
        assert tracks == {}

    def test_no_base_url(self):
        mpd = """\
<?xml version="1.0"?>
<MPD xmlns="urn:mpeg:DASH:schema:MPD:2011" type="static">
  <Period>
    <AdaptationSet contentType="video">
      <Representation id="v" bandwidth="100">
        <SegmentTemplate initialization="init" media="seg-$Time$" timescale="1">
          <SegmentTimeline><S t="0" d="1"/></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
"""
        manifest = ET.fromstring(mpd)
        tracks = sharepoint_dl.parse_segments(manifest)
        assert tracks["video"]["init_url"] == "init"
        assert tracks["video"]["segments"] == ["seg-0"]


# ---------------------------------------------------------------------------
# get_video_info
# ---------------------------------------------------------------------------

FAKE_STREAM_HTML = """
<html>
<script>
var someData = {
  "url": "https://host.sharepoint.com/_api/v2.0/drives/b!DRIVEID123/items/ITEMID456?version=Published"
};
</script>
<script>
g_fileInfo = {"name":"video.mp4","size":100000000};
</script>
<link href="https://westeurope1-mediap.svc.ms/something" />
</html>
"""


class TestGetVideoInfo:
    """Tests for the get_video_info function."""

    def test_extracts_drive_and_item_ids(self):
        mock_session = MagicMock()
        # First call: stream page
        stream_resp = MagicMock()
        stream_resp.status_code = 200
        stream_resp.text = FAKE_STREAM_HTML
        # Second call: thumbnails API
        thumb_resp = MagicMock()
        thumb_resp.status_code = 200
        thumb_resp.json.return_value = {
            "value": [{
                "large": {
                    "url": "https://media.svc.ms/transform/thumbnail?docid=https%3A%2F%2Fhost%2F_api%2Fv2.0%2Fdrives%2Fd1%2Fitems%2Fi1%3Ftempauth%3Dtoken123"
                }
            }]
        }
        mock_session.get.side_effect = [stream_resp, thumb_resp]

        url = "https://host-my.sharepoint.com/personal/user_domain/_layouts/15/stream.aspx?id=%2Ftest.mp4"
        info = sharepoint_dl.get_video_info(mock_session, url)

        assert info["drive_id"] == "b!DRIVEID123"
        assert info["item_id"] == "ITEMID456"
        assert info["media_host"] == "https://westeurope1-mediap.svc.ms"
        assert info["file_info"]["name"] == "video.mp4"

    def test_raises_on_access_required(self):
        mock_session = MagicMock()
        resp = MagicMock()
        resp.status_code = 200
        resp.text = "<html><title>Access required</title></html>"
        mock_session.get.return_value = resp

        url = "https://host-my.sharepoint.com/personal/user/_layouts/15/stream.aspx?id=%2Ftest.mp4"
        with pytest.raises(RuntimeError, match="Access required"):
            sharepoint_dl.get_video_info(mock_session, url)

    def test_raises_on_http_error(self):
        mock_session = MagicMock()
        resp = MagicMock()
        resp.status_code = 500
        mock_session.get.return_value = resp

        url = "https://host-my.sharepoint.com/personal/user/_layouts/15/stream.aspx?id=%2Ftest.mp4"
        with pytest.raises(RuntimeError, match="HTTP 500"):
            sharepoint_dl.get_video_info(mock_session, url)

    def test_raises_when_no_drive_ids(self):
        mock_session = MagicMock()
        resp = MagicMock()
        resp.status_code = 200
        resp.text = "<html>no drive ids here</html>"
        mock_session.get.return_value = resp

        url = "https://host-my.sharepoint.com/personal/user/_layouts/15/stream.aspx?id=%2Ftest.mp4"
        with pytest.raises(RuntimeError, match="drive/item IDs"):
            sharepoint_dl.get_video_info(mock_session, url)

    def test_raises_when_no_media_host(self):
        """Raises when no media proxy host is found in stream page."""
        html = '<html>drives/b!ABC/items/XYZ</html><script>g_fileInfo = {};</script>'
        mock_session = MagicMock()
        stream_resp = MagicMock()
        stream_resp.status_code = 200
        stream_resp.text = html
        mock_session.get.return_value = stream_resp

        url = "https://host-my.sharepoint.com/personal/user/_layouts/15/stream.aspx?id=%2Ft.mp4"
        with pytest.raises(RuntimeError, match="media proxy host"):
            sharepoint_dl.get_video_info(mock_session, url)


# ---------------------------------------------------------------------------
# get_dash_manifest
# ---------------------------------------------------------------------------

class TestGetDashManifest:
    """Tests for DASH manifest fetching."""

    @patch("sharepoint_dl.requests.get")
    def test_returns_parsed_xml(self, mock_get):
        mock_get.return_value = MagicMock(
            status_code=200,
            content=SAMPLE_MPD.encode("utf-8"),
        )
        result = sharepoint_dl.get_dash_manifest("https://media.host", "docid123")
        assert result.tag == "{urn:mpeg:DASH:schema:MPD:2011}MPD"

    @patch("sharepoint_dl.requests.get")
    def test_raises_on_error(self, mock_get):
        mock_get.return_value = MagicMock(status_code=403)
        with pytest.raises(RuntimeError, match="DASH manifest failed"):
            sharepoint_dl.get_dash_manifest("https://media.host", "docid123")

    @patch("sharepoint_dl.requests.get")
    def test_encodes_docid(self, mock_get):
        mock_get.return_value = MagicMock(
            status_code=200,
            content=SAMPLE_MPD.encode("utf-8"),
        )
        sharepoint_dl.get_dash_manifest("https://host", "https://sp/api?auth=tok&v=1")
        call_url = mock_get.call_args[0][0]
        # The docid with special chars should be percent-encoded
        assert "https%3A%2F%2Fsp%2Fapi" in call_url


# ---------------------------------------------------------------------------
# mux_tracks
# ---------------------------------------------------------------------------

class TestMuxTracks:
    """Tests for the ffmpeg muxing wrapper."""

    @patch("sharepoint_dl.subprocess.run")
    def test_calls_ffmpeg_correctly(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0)
        sharepoint_dl.mux_tracks("/tmp/v.mp4", "/tmp/a.mp4", "/tmp/out.mp4")
        args = mock_run.call_args[0][0]
        assert args[0] == "ffmpeg"
        assert "-i" in args
        assert "/tmp/v.mp4" in args
        assert "/tmp/a.mp4" in args
        assert "/tmp/out.mp4" in args
        assert "-c" in args and "copy" in args

    @patch("sharepoint_dl.subprocess.run")
    def test_raises_on_failure(self, mock_run):
        mock_run.return_value = MagicMock(returncode=1, stderr="encoder error")
        with pytest.raises(RuntimeError, match="ffmpeg muxing failed"):
            sharepoint_dl.mux_tracks("/tmp/v.mp4", "/tmp/a.mp4", "/tmp/out.mp4")


# ---------------------------------------------------------------------------
# download_track
# ---------------------------------------------------------------------------

class TestDownloadTrack:
    """Tests for segment downloading."""

    @patch("sharepoint_dl.requests.get")
    def test_downloads_init_and_segments(self, mock_get, tmp_path):
        init_data = b"\x00\x00\x00\x1cftypisom"
        seg1_data = b"segment1_data"
        seg2_data = b"segment2_data"

        responses = []
        for data in [init_data, seg1_data, seg2_data]:
            resp = MagicMock()
            resp.content = data
            resp.raise_for_status = MagicMock()
            responses.append(resp)
        mock_get.side_effect = responses

        track_info = {
            "init_url": "https://example.com/init",
            "segments": ["https://example.com/seg1", "https://example.com/seg2"],
            "bandwidth": 500000,
        }
        out = str(tmp_path / "track.mp4")
        sharepoint_dl.download_track(track_info, out, "video")

        with open(out, "rb") as f:
            content = f.read()
        assert content == init_data + seg1_data + seg2_data
        assert mock_get.call_count == 3

    @patch("sharepoint_dl.requests.get")
    def test_raises_on_segment_error(self, mock_get, tmp_path):
        init_resp = MagicMock()
        init_resp.content = b"init"
        init_resp.raise_for_status = MagicMock()

        err_resp = MagicMock()
        err_resp.raise_for_status.side_effect = Exception("HTTP 500")
        mock_get.side_effect = [init_resp, err_resp]

        track_info = {
            "init_url": "https://example.com/init",
            "segments": ["https://example.com/seg1"],
            "bandwidth": 100,
        }
        with pytest.raises(Exception, match="HTTP 500"):
            sharepoint_dl.download_track(
                track_info, str(tmp_path / "track.mp4"), "video"
            )


# ---------------------------------------------------------------------------
# download_sharepoint_video (integration-level, mocked)
# ---------------------------------------------------------------------------

class TestDownloadSharepointVideo:
    """Tests for the main orchestration function."""

    def test_default_output_from_url(self):
        """Verifies output filename is derived from the URL id parameter."""
        url = "https://host.sharepoint.com/personal/user/_layouts/15/stream.aspx?id=%2Fpersonal%2Fuser%2FDocuments%2Fvideo.mp4"
        with patch.object(sharepoint_dl, "build_session"), \
             patch.object(sharepoint_dl, "get_video_info") as mock_info, \
             patch.object(sharepoint_dl, "get_dash_manifest") as mock_manifest, \
             patch.object(sharepoint_dl, "parse_segments") as mock_parse, \
             patch.object(sharepoint_dl, "download_track"), \
             patch.object(sharepoint_dl, "mux_tracks") as mock_mux, \
             patch.object(sharepoint_dl, "get_download_dir", return_value="/tmp/dl"), \
             patch("shutil.rmtree"), \
             patch("os.path.getsize", return_value=1000):
            mock_info.return_value = {
                "media_host": "https://h",
                "docid": "d",
                "file_info": {"name": "video.mp4", "size": 1000},
            }
            mock_manifest.return_value = MagicMock()
            mock_parse.return_value = {
                "video": {"init_url": "", "segments": [], "bandwidth": 0, "rep_id": "v"},
                "audio": {"init_url": "", "segments": [], "bandwidth": 0, "rep_id": "a"},
            }
            sharepoint_dl.download_sharepoint_video(url)
            # output_path passed to mux_tracks should be inside download dir
            assert mock_mux.call_args[0][2] == "/tmp/dl/video.mp4"

    def test_fallback_output_name(self):
        """If no id param, defaults to sharepoint_video.mp4."""
        url = "https://host.sharepoint.com/stream.aspx"
        with patch.object(sharepoint_dl, "build_session"), \
             patch.object(sharepoint_dl, "get_video_info") as mock_info, \
             patch.object(sharepoint_dl, "get_dash_manifest"), \
             patch.object(sharepoint_dl, "parse_segments") as mock_parse, \
             patch.object(sharepoint_dl, "download_track"), \
             patch.object(sharepoint_dl, "mux_tracks") as mock_mux, \
             patch.object(sharepoint_dl, "get_download_dir", return_value="/tmp/dl"), \
             patch("shutil.rmtree"), \
             patch("os.path.getsize", return_value=500):
            mock_info.return_value = {
                "media_host": "h", "docid": "d",
                "file_info": {},
            }
            mock_parse.return_value = {
                "video": {"init_url": "", "segments": [], "bandwidth": 0, "rep_id": "v"},
                "audio": {"init_url": "", "segments": [], "bandwidth": 0, "rep_id": "a"},
            }
            sharepoint_dl.download_sharepoint_video(url)
            assert mock_mux.call_args[0][2] == "/tmp/dl/sharepoint_video.mp4"

    def test_explicit_output_skips_download_dir(self):
        """When output_path is given explicitly, download dir is not used."""
        url = "https://host.sharepoint.com/stream.aspx?id=%2Fvideo.mp4"
        with patch.object(sharepoint_dl, "build_session"), \
             patch.object(sharepoint_dl, "get_video_info") as mock_info, \
             patch.object(sharepoint_dl, "get_dash_manifest"), \
             patch.object(sharepoint_dl, "parse_segments") as mock_parse, \
             patch.object(sharepoint_dl, "download_track"), \
             patch.object(sharepoint_dl, "mux_tracks") as mock_mux, \
             patch("shutil.rmtree"), \
             patch("os.path.getsize", return_value=500):
            mock_info.return_value = {
                "media_host": "h", "docid": "d", "file_info": {},
            }
            mock_parse.return_value = {
                "video": {"init_url": "", "segments": [], "bandwidth": 0, "rep_id": "v"},
                "audio": {"init_url": "", "segments": [], "bandwidth": 0, "rep_id": "a"},
            }
            sharepoint_dl.download_sharepoint_video(url, output_path="/my/path.mp4")
            assert mock_mux.call_args[0][2] == "/my/path.mp4"


# ---------------------------------------------------------------------------
# build_session (with mocked DB and keychain)
# ---------------------------------------------------------------------------

class TestBuildSession:
    """Tests for the browser cookie session builder."""

    @patch("sharepoint_dl._get_cookie_db", return_value="/nonexistent/path/Cookies")
    def test_raises_when_db_missing(self, mock_db):
        with pytest.raises(FileNotFoundError):
            sharepoint_dl.build_session()

    def test_raises_when_no_fedauth(self, tmp_path):
        """If cookie DB exists but has no FedAuth, raises RuntimeError."""
        db_path = str(tmp_path / "Cookies")
        conn = sqlite3.connect(db_path)
        conn.execute(
            "CREATE TABLE cookies (host_key TEXT, name TEXT, encrypted_value BLOB)"
        )
        conn.execute(
            "INSERT INTO cookies VALUES (?, ?, ?)",
            (".sharepoint.com", "other", b"not_encrypted"),
        )
        conn.commit()
        conn.close()

        with patch("sharepoint_dl._get_cookie_db", return_value=db_path), \
             patch("sharepoint_dl._get_chromium_key", return_value=b"fakepassword"):
            with pytest.raises(RuntimeError, match="FedAuth cookie not found"):
                sharepoint_dl.build_session()

    def test_raises_when_firefox_db_missing(self):
        with patch("sharepoint_dl._get_cookie_db", return_value="/nonexistent/cookies.sqlite"):
            with pytest.raises(FileNotFoundError):
                sharepoint_dl.build_session(browser="firefox")

    def test_firefox_no_fedauth(self, tmp_path):
        """Firefox DB exists but has no FedAuth."""
        db_path = str(tmp_path / "cookies.sqlite")
        conn = sqlite3.connect(db_path)
        conn.execute(
            "CREATE TABLE moz_cookies (host TEXT, name TEXT, value TEXT)"
        )
        conn.execute(
            "INSERT INTO moz_cookies VALUES (?, ?, ?)",
            (".sharepoint.com", "other", "someval"),
        )
        conn.commit()
        conn.close()

        with patch("sharepoint_dl._get_cookie_db", return_value=db_path):
            with pytest.raises(RuntimeError, match="FedAuth cookie not found"):
                sharepoint_dl.build_session(browser="firefox")
