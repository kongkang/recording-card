#!/usr/bin/env python3
"""Recording Card (录音卡) official website beta email verification & TestFlight invite API.

Zero third-party Python dependencies (Python 3.10+ stdlib + openssl CLI for ES256).
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import html
import json
import logging
import os
import re
import secrets
import smtplib
import sqlite3
import ssl
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from email.headerregistry import Address
from email.message import EmailMessage
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("ai-card-beta-api")

MAX_BODY_BYTES = 8192
EMAIL_RE = re.compile(
    r"^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    r"(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$"
)
ALLOWED_SOURCES = {"inline", "modal", "web", "smoke"}


@dataclass(frozen=True)
class Config:
    host: str = "127.0.0.1"
    port: int = 8790
    db_path: str = "/var/lib/ai-card-beta-api/beta.sqlite3"
    code_pepper: str = ""
    ip_hash_salt: str = ""
    code_ttl_seconds: int = 600
    cooldown_seconds: int = 60
    max_verify_attempts: int = 5
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_use_ssl: bool = False
    smtp_user: str = ""
    smtp_pass: str = ""
    smtp_from_name: str = "录音卡"
    smtp_from_email: str = "noreply@wainao.ai"
    smtp_reply_to: str = "support@reai.chat"
    asc_app_id: str = "6834316655"
    asc_external_group_id: str = "4fc99575-cdf1-4295-9535-0ba901375c32"
    asc_key_id: str = ""
    asc_issuer_id: str = ""
    asc_key_path: str = ""
    asc_base_url: str = "https://api.appstoreconnect.apple.com"
    public_testflight_url: str = "https://testflight.apple.com/join/fMWkZSv5"

    @classmethod
    def from_env(cls) -> "Config":
        pepper = os.environ.get("CODE_PEPPER", "").strip()
        salt = os.environ.get("IP_HASH_SALT", "").strip()
        if not pepper:
            pepper = secrets.token_hex(32)
            logger.warning("CODE_PEPPER not set; generated ephemeral runtime pepper")
        if not salt:
            salt = secrets.token_hex(32)
            logger.warning("IP_HASH_SALT not set; generated ephemeral runtime salt")

        port_val = int(os.environ.get("PORT", "8790"))
        smtp_port = int(os.environ.get("SMTP_PORT", "587"))
        use_ssl_raw = os.environ.get("SMTP_USE_SSL", "").strip().lower()
        smtp_use_ssl = use_ssl_raw in {"1", "true", "yes"} or smtp_port == 465

        return cls(
            host=os.environ.get("HOST", "127.0.0.1").strip() or "127.0.0.1",
            port=port_val,
            db_path=os.environ.get(
                "DB_PATH", "/var/lib/ai-card-beta-api/beta.sqlite3"
            ).strip(),
            code_pepper=pepper,
            ip_hash_salt=salt,
            code_ttl_seconds=int(os.environ.get("CODE_TTL_SECONDS", "600")),
            cooldown_seconds=int(os.environ.get("COOLDOWN_SECONDS", "60")),
            max_verify_attempts=int(os.environ.get("MAX_VERIFY_ATTEMPTS", "5")),
            smtp_host=os.environ.get("SMTP_HOST", "").strip(),
            smtp_port=smtp_port,
            smtp_use_ssl=smtp_use_ssl,
            smtp_user=os.environ.get("SMTP_USER", "").strip(),
            smtp_pass=os.environ.get("SMTP_PASS", ""),
            smtp_from_name=os.environ.get("SMTP_FROM_NAME", "录音卡").strip()
            or "录音卡",
            smtp_from_email=os.environ.get(
                "SMTP_FROM_EMAIL", os.environ.get("SMTP_USER", "noreply@wainao.ai")
            ).strip(),
            smtp_reply_to=os.environ.get("SMTP_REPLY_TO", "support@reai.chat").strip(),
            asc_app_id=os.environ.get("ASC_APP_ID", "6834316655").strip(),
            asc_external_group_id=os.environ.get(
                "ASC_EXTERNAL_GROUP_ID", "4fc99575-cdf1-4295-9535-0ba901375c32"
            ).strip(),
            asc_key_id=os.environ.get("ASC_KEY_ID", "").strip(),
            asc_issuer_id=os.environ.get("ASC_ISSUER_ID", "").strip(),
            asc_key_path=os.environ.get("ASC_KEY_PATH", "").strip(),
            asc_base_url=os.environ.get(
                "ASC_BASE_URL", "https://api.appstoreconnect.apple.com"
            ).rstrip("/"),
            public_testflight_url=os.environ.get(
                "PUBLIC_TESTFLIGHT_URL", "https://testflight.apple.com/join/fMWkZSv5"
            ).strip(),
        )


def normalize_email(raw: Any) -> str | None:
    if not isinstance(raw, str):
        return None
    if any(ord(ch) < 32 or ch == "\x7f" for ch in raw):
        return None
    email = raw.strip().lower()
    if not email or len(email) > 254:
        return None
    if not EMAIL_RE.match(email):
        return None
    local, _ = email.split("@", 1)
    if len(local) > 64 or local.startswith(".") or local.endswith(".") or ".." in local:
        return None
    return email


def normalize_platform(raw: Any) -> str | None:
    if raw is None or raw == "":
        return "ios"
    if not isinstance(raw, str):
        return None
    val = re.sub(r"\s+", " ", raw.strip().lower())
    if val in {"ios", "iphone", "ipad", "ios + watch", "ios+watch", "ios_watch"}:
        return "ios"
    if val == "android":
        return "android"
    return None


def normalize_source(raw: Any) -> str:
    if not isinstance(raw, str):
        return "web"
    val = raw.strip().lower()
    return val if val in ALLOWED_SOURCES else "web"


def normalize_locale(raw: Any) -> str:
    if isinstance(raw, str) and raw.strip().lower().startswith("en"):
        return "en"
    return "zh-Hans"


def normalize_code(raw: Any) -> str | None:
    if not isinstance(raw, str):
        return None
    cleaned = raw.strip()
    if re.fullmatch(r"\d{6}", cleaned):
        return cleaned
    return None


def hash_otp(pepper: str, email: str, code: str) -> str:
    return hmac.new(
        pepper.encode("utf-8"), f"{email}:{code}".encode("utf-8"), hashlib.sha256
    ).hexdigest()


def hash_ip(salt: str, ip: str) -> str:
    return hmac.new(
        salt.encode("utf-8"), ip.encode("utf-8"), hashlib.sha256
    ).hexdigest()


class BetaStore:
    """Thread-safe SQLite storage for beta verification codes, signups, and rate limits."""

    def __init__(self, db_path: str) -> None:
        self.db_path = db_path
        parent = os.path.dirname(db_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(db_path, timeout=10.0, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        with self._lock:
            self._conn.execute("PRAGMA journal_mode=WAL;")
            self._conn.execute("PRAGMA busy_timeout=5000;")
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS beta_signups (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    email TEXT NOT NULL UNIQUE,
                    platform TEXT NOT NULL,
                    source TEXT NOT NULL,
                    locale TEXT NOT NULL,
                    status TEXT NOT NULL,
                    verified_at INTEGER,
                    asc_tester_id TEXT,
                    asc_invite_status TEXT,
                    asc_last_error TEXT,
                    last_invite_sent_at INTEGER,
                    ip_hash TEXT,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                """
            )
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS verification_codes (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    email TEXT NOT NULL,
                    platform TEXT NOT NULL,
                    source TEXT NOT NULL,
                    locale TEXT NOT NULL,
                    code_hash TEXT NOT NULL,
                    expires_at INTEGER NOT NULL,
                    consumed_at INTEGER,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    ip_hash TEXT,
                    created_at INTEGER NOT NULL
                );
                """
            )
            self._conn.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_codes_email_created
                ON verification_codes(email, created_at);
                """
            )
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS rate_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    bucket_key TEXT NOT NULL,
                    created_at INTEGER NOT NULL
                );
                """
            )
            self._conn.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_rate_bucket_time
                ON rate_events(bucket_key, created_at);
                """
            )
            self._conn.commit()

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    def check_rate(self, bucket_key: str, window_seconds: int, max_count: int, now: int) -> int:
        """Returns 0 if allowed, or retry-after seconds (>0) if limit reached."""
        cutoff = now - window_seconds
        with self._lock:
            rows = self._conn.execute(
                "SELECT created_at FROM rate_events WHERE bucket_key = ? AND created_at > ? ORDER BY created_at ASC",
                (bucket_key, cutoff),
            ).fetchall()
            if len(rows) < max_count:
                return 0
            oldest = int(rows[0]["created_at"])
            return max(1, oldest + window_seconds - now)

    def record_rate(self, bucket_key: str, now: int) -> None:
        prune_before = now - 86400
        with self._lock:
            self._conn.execute(
                "INSERT INTO rate_events(bucket_key, created_at) VALUES (?, ?)",
                (bucket_key, now),
            )
            self._conn.execute(
                "DELETE FROM rate_events WHERE created_at < ?",
                (prune_before,),
            )
            self._conn.commit()

    def create_code_and_pending_signup(
        self,
        *,
        email: str,
        platform: str,
        source: str,
        locale: str,
        code_hash: str,
        expires_at: int,
        ip_hash: str,
        now: int,
    ) -> int:
        with self._lock:
            cur = self._conn.execute(
                """
                INSERT INTO verification_codes(
                    email, platform, source, locale, code_hash, expires_at, ip_hash, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (email, platform, source, locale, code_hash, expires_at, ip_hash, now),
            )
            code_id = int(cur.lastrowid)
            existing = self._conn.execute(
                "SELECT id, verified_at, status FROM beta_signups WHERE email = ?",
                (email,),
            ).fetchone()
            if existing is None:
                self._conn.execute(
                    """
                    INSERT INTO beta_signups(
                        email, platform, source, locale, status, ip_hash, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, 'pending_verify', ?, ?, ?)
                    """,
                    (email, platform, source, locale, ip_hash, now, now),
                )
            elif existing["verified_at"] is None:
                self._conn.execute(
                    """
                    UPDATE beta_signups
                    SET platform = ?, source = ?, locale = ?, ip_hash = ?, updated_at = ?
                    WHERE email = ?
                    """,
                    (platform, source, locale, ip_hash, now, email),
                )
            self._conn.commit()
            return code_id

    def delete_code(self, code_id: int) -> None:
        with self._lock:
            self._conn.execute("DELETE FROM verification_codes WHERE id = ?", (code_id,))
            self._conn.commit()

    def verify_code(
        self,
        *,
        email: str,
        code_hash: str,
        max_attempts: int,
        now: int,
    ) -> tuple[bool, str, dict[str, Any] | None]:
        """Checks the latest active OTP for email.

        Returns (ok, error_code, code_row_dict).
        """
        with self._lock:
            row = self._conn.execute(
                """
                SELECT * FROM verification_codes
                WHERE email = ? AND consumed_at IS NULL
                ORDER BY id DESC LIMIT 1
                """,
                (email,),
            ).fetchone()
            if row is None:
                return False, "CODE_NOT_FOUND", None
            if int(row["expires_at"]) < now:
                return False, "CODE_EXPIRED", None
            attempts = int(row["attempts"])
            if attempts >= max_attempts:
                return False, "TOO_MANY_ATTEMPTS", None
            if not hmac.compare_digest(str(row["code_hash"]), code_hash):
                self._conn.execute(
                    "UPDATE verification_codes SET attempts = attempts + 1 WHERE id = ?",
                    (row["id"],),
                )
                self._conn.commit()
                if attempts + 1 >= max_attempts:
                    return False, "TOO_MANY_ATTEMPTS", None
                return False, "INVALID_CODE", None

            self._conn.execute(
                "UPDATE verification_codes SET consumed_at = ? WHERE id = ?",
                (now, row["id"]),
            )
            self._conn.commit()
            return True, "", dict(row)

    def get_signup(self, email: str) -> dict[str, Any] | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM beta_signups WHERE email = ?", (email,)
            ).fetchone()
            return dict(row) if row is not None else None

    def update_signup_after_verify(
        self,
        *,
        email: str,
        platform: str,
        source: str,
        locale: str,
        status: str,
        verified_at: int,
        asc_tester_id: str | None = None,
        asc_invite_status: str | None = None,
        asc_last_error: str | None = None,
        last_invite_sent_at: int | None = None,
        now: int,
    ) -> int:
        with self._lock:
            self._conn.execute(
                """
                UPDATE beta_signups
                SET platform = ?,
                    source = ?,
                    locale = ?,
                    status = ?,
                    verified_at = COALESCE(verified_at, ?),
                    asc_tester_id = COALESCE(?, asc_tester_id),
                    asc_invite_status = ?,
                    asc_last_error = ?,
                    last_invite_sent_at = COALESCE(?, last_invite_sent_at),
                    updated_at = ?
                WHERE email = ?
                """,
                (
                    platform,
                    source,
                    locale,
                    status,
                    verified_at,
                    asc_tester_id,
                    asc_invite_status,
                    asc_last_error,
                    last_invite_sent_at,
                    now,
                    email,
                ),
            )
            self._conn.commit()
            count_row = self._conn.execute(
                "SELECT COUNT(*) AS cnt FROM beta_signups WHERE verified_at IS NOT NULL"
            ).fetchone()
            return int(count_row["cnt"]) if count_row is not None else 1

    def verified_count(self) -> int:
        with self._lock:
            row = self._conn.execute(
                "SELECT COUNT(*) AS cnt FROM beta_signups WHERE verified_at IS NOT NULL"
            ).fetchone()
            return int(row["cnt"]) if row is not None else 0


class MailError(RuntimeError):
    pass


class SmtpMailer:
    """Sends HTML + plain-text transactional emails over SMTP (STARTTLS or SSL)."""

    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg

    @property
    def is_configured(self) -> bool:
        return bool(
            self.cfg.smtp_host
            and self.cfg.smtp_user
            and self.cfg.smtp_pass
            and self.cfg.smtp_from_email
        )

    def _send_message(self, to_email: str, subject: str, text_body: str, html_body: str) -> None:
        if not self.is_configured:
            raise MailError("SMTP is not configured")
        msg = EmailMessage()
        msg["Subject"] = subject
        msg["From"] = Address(
            display_name=self.cfg.smtp_from_name, addr_spec=self.cfg.smtp_from_email
        )
        msg["To"] = to_email
        if self.cfg.smtp_reply_to:
            msg["Reply-To"] = self.cfg.smtp_reply_to
        msg.set_content(text_body, subtype="plain", charset="utf-8")
        msg.add_alternative(html_body, subtype="html", charset="utf-8")

        context = ssl.create_default_context()
        try:
            if self.cfg.smtp_use_ssl:
                with smtplib.SMTP_SSL(
                    self.cfg.smtp_host, self.cfg.smtp_port, timeout=15, context=context
                ) as server:
                    server.login(self.cfg.smtp_user, self.cfg.smtp_pass)
                    server.send_message(msg)
            else:
                with smtplib.SMTP(
                    self.cfg.smtp_host, self.cfg.smtp_port, timeout=15
                ) as server:
                    server.ehlo()
                    server.starttls(context=context)
                    server.ehlo()
                    server.login(self.cfg.smtp_user, self.cfg.smtp_pass)
                    server.send_message(msg)
        except Exception as exc:
            raise MailError(f"SMTP delivery failed: {type(exc).__name__}") from exc

    def send_verification_code(
        self, email: str, code: str, platform: str, locale: str
    ) -> None:
        is_en = locale.startswith("en")
        plat_label = "iPhone / TestFlight" if platform == "ios" else "Android"
        if is_en:
            subject = f"[{code}] AI Card Early-Bird & TestFlight Verification Code"
            text_body = (
                f"Your AI Card verification code is: {code}\n\n"
                f"Selected platform: {plat_label}\n"
                f"This code expires in 10 minutes. Once verified, we will process your "
                f"{'TestFlight invitation & early-bird perks (1+ month membership + physical AI Card giveaway)' if platform == 'ios' else 'Android beta waitlist entry & early-bird perks'}.\n\n"
                f"If you did not request this, you can safely ignore this email.\n"
                f"— AI Card (https://ai-card.app.reai.com)"
            )
            html_body = (
                f"<div style='font-family:-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;"
                f"max-width:520px;margin:0 auto;padding:24px;color:#1D1D1F;background:#FAFAF8;"
                f"border:1px solid #E4E4E0;border-radius:14px'>"
                f"<p style='font-size:12px;letter-spacing:0.14em;color:#7A7A80;margin:0 0 8px'>AI CARD · TESTFLIGHT &amp; EARLY-BIRD</p>"
                f"<h2 style='margin:0 0 12px;font-size:20px'>Verify your email</h2>"
                f"<p style='margin:0 0 18px;font-size:14px;line-height:1.6'>Enter the 6-digit code below to confirm your <b>{html.escape(plat_label)}</b> TestFlight &amp; early-bird request:</p>"
                f"<div style='font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:30px;font-weight:700;"
                f"letter-spacing:0.22em;text-align:center;padding:16px 20px;background:#1D1D1F;color:#FAFAF8;border-radius:10px;margin:0 0 18px'>{html.escape(code)}</div>"
                f"<p style='margin:0;font-size:12.5px;color:#7A7A80;line-height:1.6'>Valid for 10 minutes. Ignore this message if you didn't request it.</p>"
                f"</div>"
            )
        else:
            subject = f"【录音卡】TestFlight 与早鸟验证码：{code}"
            next_step = (
                "验证通过后，系统将自动向你的邮箱发送苹果 TestFlight 邀请，并为你锁定至少 1 个月会员与实体录音卡抽奖资格。"
                if platform == "ios"
                else "验证通过后，系统会为你登记 Android 优先体验与早鸟福利（至少 1 个月会员与实体录音卡抽奖资格），出包后第一时间邮件通知你。"
            )
            text_body = (
                f"你的录音卡验证码是：{code}\n\n"
                f"选择平台：{plat_label}\n"
                f"有效期 10 分钟。{next_step}\n\n"
                f"如非本人操作，请忽略此邮件。\n"
                f"—— 录音卡（https://ai-card.app.reai.com）"
            )
            html_body = (
                f"<div style='font-family:-apple-system,BlinkMacSystemFont,PingFang SC,sans-serif;"
                f"max-width:520px;margin:0 auto;padding:24px;color:#1D1D1F;background:#FAFAF8;"
                f"border:1px solid #E4E4E0;border-radius:14px'>"
                f"<p style='font-size:12px;letter-spacing:0.14em;color:#7A7A80;margin:0 0 8px'>录音卡 · TESTFLIGHT 与早鸟验证</p>"
                f"<h2 style='margin:0 0 12px;font-size:20px'>请查收你的 6 位验证码</h2>"
                f"<p style='margin:0 0 18px;font-size:14px;line-height:1.6'>你正在申请 <b>{html.escape(plat_label)}</b> 体验资格。{html.escape(next_step)}</p>"
                f"<div style='font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:30px;font-weight:700;"
                f"letter-spacing:0.22em;text-align:center;padding:16px 20px;background:#1D1D1F;color:#FAFAF8;border-radius:10px;margin:0 0 18px'>{html.escape(code)}</div>"
                f"<p style='margin:0;font-size:12.5px;color:#7A7A80;line-height:1.6'>验证码 10 分钟内有效。如非本人操作，请直接忽略。</p>"
                f"</div>"
            )
        self._send_message(email, subject, text_body, html_body)

    def send_confirmation(
        self, email: str, platform: str, status: str, locale: str
    ) -> None:
        is_en = locale.startswith("en")
        if platform == "ios":
            if status == "invited":
                if is_en:
                    subject = "You're invited: AI Card TestFlight"
                    body_text = (
                        "Your email is verified and your AI Card TestFlight invite has been dispatched by Apple (early-bird perks locked in).\n\n"
                        "1. Install the official Apple TestFlight app on your iPhone (please accept on iPhone rather than Mac App Store).\n"
                        "2. Check this inbox (and Spam/Junk) for an email from Apple (no_reply@email.apple.com) and tap 'View in TestFlight'.\n"
                        "3. You can also join directly with your iPhone using the public TestFlight link: "
                        f"{self.cfg.public_testflight_url}\n\n"
                        f"Need help? Reply to {self.cfg.smtp_reply_to}."
                    )
                    headline = "TestFlight Invite Sent"
                    detail = (
                        "Your email is verified and early-bird perks are locked in. Apple has been triggered to send your "
                        "official TestFlight invitation email — please open it on your iPhone (check Spam if you don't see it within a couple minutes)."
                    )
                else:
                    subject = "【录音卡】邮箱已验证 · TestFlight 邀请已发送"
                    body_text = (
                        "你的邮箱已完成验证，早鸟福利（至少 1 个月会员 + 实体录音卡抽奖资格）已为你保留，且已通过苹果官方接口向你发送 TestFlight 邀请！\n\n"
                        "安装步骤（请使用 iPhone 操作）：\n"
                        "1. 先在 iPhone 的 App Store 安装苹果官方「TestFlight」App；\n"
                        "2. 在当前邮箱收件箱（如未看到请顺便检查垃圾箱/广告邮件）查收来自 Apple 的 TestFlight 邀请邮件，在 iPhone 上点击「View in TestFlight」接受并安装；\n"
                        f"3. 也可以直接用 iPhone Safari 打开公开测试链接加入：{self.cfg.public_testflight_url}\n\n"
                        f"如有问题随时联系 {self.cfg.smtp_reply_to}。"
                    )
                    headline = "已发送苹果 TestFlight 邀请"
                    detail = (
                        "请先在 iPhone 上安装官方「TestFlight」App，并在当前邮箱查收来自 Apple 的邀请邮件"
                        "（部分邮箱可能归入垃圾箱或推广邮件；请直接在 iPhone 上接受邀请，或打开下方公开链接）。"
                    )
            elif status == "already_installed":
                if is_en:
                    subject = "AI Card TestFlight · Already in Tester List"
                    body_text = (
                        "Your email is verified and early-bird perks are locked in.\n\n"
                        "This Apple ID is already in the AI Card TestFlight tester list. "
                        "Open the TestFlight app on your iPhone (signed in with the same Apple ID) to install, "
                        f"or open the public join link on iPhone: {self.cfg.public_testflight_url}\n\n"
                        f"Need help? Reply to {self.cfg.smtp_reply_to}."
                    )
                    headline = "Already in TestFlight Tester List"
                    detail = (
                        "Your email is already in the AI Card TestFlight tester list. "
                        "Open TestFlight on your iPhone or use the public TestFlight link below to install."
                    )
                else:
                    subject = "【录音卡】邮箱已验证 · 已在 TestFlight 测试名单中"
                    body_text = (
                        "你的邮箱已完成验证，早鸟福利已为你保留。\n\n"
                        "检测到该邮箱已在「录音卡」TestFlight 测试名单中，无需重复申请：\n"
                        "1. 请在 iPhone 上打开苹果官方「TestFlight」App（确认登录了对应的 Apple ID）直接安装；\n"
                        f"2. 如未看到测试项，可直接用 iPhone Safari 打开公开测试链接：{self.cfg.public_testflight_url}\n\n"
                        f"如有问题随时联系 {self.cfg.smtp_reply_to}。"
                    )
                    headline = "已在 TestFlight 测试名单中"
                    detail = (
                        "该邮箱已在「录音卡」TestFlight 测试名单中，可直接在 iPhone 的 TestFlight 中安装，"
                        "或用 iPhone 打开公开测试链接加入。"
                    )
            else:
                if is_en:
                    subject = "Email Verified · Registered for AI Card TestFlight"
                    body_text = (
                        "Your email is verified and has been added to our AI Card TestFlight external tester group (early-bird perks locked in).\n\n"
                        "Our latest TestFlight build is currently awaiting Apple's Beta App Review. "
                        "As soon as Apple approves the build, Apple will automatically send the official TestFlight installation email to this address.\n\n"
                        f"Install Apple's TestFlight app on your iPhone in advance so you're ready! Need help? Reply to {self.cfg.smtp_reply_to}."
                    )
                    headline = "Verified & Queued for TestFlight"
                    detail = (
                        "Your email has been added to our TestFlight external group. Our build is currently awaiting "
                        "Apple's Beta App Review — Apple will automatically email your install link as soon as it is approved."
                    )
                else:
                    subject = "【录音卡】邮箱已验证 · 已加入 TestFlight 邀请队列"
                    body_text = (
                        "你的邮箱已完成验证，并已成功写入「录音卡」TestFlight 测试名单（早鸟福利已保留）！\n\n"
                        "当前测试版本正处于苹果外测审核（Beta App Review）排队中，审核通过后苹果系统会自动向你这个邮箱发送官方 TestFlight 安装邀请邮件，无需重复申请。\n\n"
                        "建议先在 iPhone 上提前装好苹果官方「TestFlight」App 备用。\n"
                        f"如有问题随时联系 {self.cfg.smtp_reply_to}。"
                    )
                    headline = "已验证并加入 TestFlight 名单"
                    detail = (
                        "你的邮箱已成功同步到苹果 TestFlight 测试名单。当前构建正在等待苹果外测审核，"
                        "审核通过后苹果会自动向本邮箱发送安装邀请。"
                    )
        else:
            if is_en:
                subject = "Email Verified · AI Card Android Beta Waitlist"
                body_text = (
                    "Your email is verified! You are registered for priority Android access and early-bird perks "
                    "(1+ month membership + physical AI Card giveaway).\n\n"
                    "We will email your Android build link as soon as it is ready."
                )
                headline = "Android Waitlist Confirmed"
                detail = (
                    "Your email is verified and registered for priority access to the AI Card Android build, "
                    "with early-bird membership and giveaway perks locked in."
                )
            else:
                subject = "【录音卡】邮箱已验证 · Android 优先通知与早鸟福利已登记"
                body_text = (
                    "你的邮箱已完成验证！我们已为你登记 Android 优先通知名单，并锁定早鸟福利（赠送至少 1 个月正式版会员 + 自动参与抽取价值 ¥1,000 实体录音卡）。\n\n"
                    "Android 安装包发布后我们会第一时间通过邮件通知你。"
                )
                headline = "Android 优先通知已登记"
                detail = (
                    "你的邮箱已验证并加入 Android 优先队列，早鸟福利已为你保留。"
                    "Android 版本发布后将第一时间邮件通知你。"
                )

        if is_en:
            badge_text = "AI CARD · BETA & EARLY-BIRD"
            footer_html = (
                f"Website: <a href='https://ai-card.app.reai.com' style='color:#1D1D1F'>ai-card.app.reai.com</a>"
                f" · Support: {html.escape(self.cfg.smtp_reply_to)}"
            )
        else:
            badge_text = "录音卡 · TESTFLIGHT 与早鸟"
            footer_html = (
                f"官网：<a href='https://ai-card.app.reai.com' style='color:#1D1D1F'>ai-card.app.reai.com</a>"
                f" · 支持：{html.escape(self.cfg.smtp_reply_to)}"
            )

        html_body = (
            f"<div style='font-family:-apple-system,BlinkMacSystemFont,PingFang SC,sans-serif;"
            f"max-width:520px;margin:0 auto;padding:24px;color:#1D1D1F;background:#FAFAF8;"
            f"border:1px solid #E4E4E0;border-radius:14px'>"
            f"<p style='font-size:12px;letter-spacing:0.14em;color:#7A7A80;margin:0 0 8px'>{badge_text}</p>"
            f"<h2 style='margin:0 0 12px;font-size:20px'>{html.escape(headline)}</h2>"
            f"<p style='margin:0 0 16px;font-size:14px;line-height:1.7'>{html.escape(detail)}</p>"
            f"<p style='margin:0;font-size:12.5px;color:#7A7A80;line-height:1.6'>{footer_html}</p>"
            f"</div>"
        )
        self._send_message(email, subject, text_body, html_body)


class AscError(RuntimeError):
    pass


def _b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _der_to_raw_rs(der: bytes) -> bytes:
    idx = 0
    if der[idx] != 0x30:
        raise ValueError("Invalid DER sequence")
    idx += 1
    seq_len = der[idx]
    idx += 1
    if seq_len & 0x80:
        idx += seq_len & 0x7F
    if der[idx] != 0x02:
        raise ValueError("Invalid DER r integer")
    r_len = der[idx + 1]
    r = der[idx + 2 : idx + 2 + r_len]
    idx = idx + 2 + r_len
    if der[idx] != 0x02:
        raise ValueError("Invalid DER s integer")
    s_len = der[idx + 1]
    s = der[idx + 2 : idx + 2 + s_len]
    return r.lstrip(b"\x00").rjust(32, b"\x00") + s.lstrip(b"\x00").rjust(32, b"\x00")


class AscClient:
    """Minimal App Store Connect REST API client for TestFlight external invites."""

    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self._cache_lock = threading.Lock()
        self._review_state_cache: tuple[str, float] | None = None

    @property
    def is_configured(self) -> bool:
        return bool(
            self.cfg.asc_app_id
            and self.cfg.asc_external_group_id
            and self.cfg.asc_key_id
            and self.cfg.asc_issuer_id
            and self.cfg.asc_key_path
            and os.path.isfile(self.cfg.asc_key_path)
        )

    def _make_jwt(self) -> str:
        now = int(time.time())
        header = _b64u(
            json.dumps(
                {"alg": "ES256", "kid": self.cfg.asc_key_id, "typ": "JWT"},
                separators=(",", ":"),
            ).encode("utf-8")
        )
        payload = _b64u(
            json.dumps(
                {
                    "iss": self.cfg.asc_issuer_id,
                    "iat": now,
                    "exp": now + 600,
                    "aud": "appstoreconnect-v1",
                },
                separators=(",", ":"),
            ).encode("utf-8")
        )
        signing_input = f"{header}.{payload}".encode("ascii")
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", self.cfg.asc_key_path],
            input=signing_input,
            capture_output=True,
            check=True,
        )
        sig = _b64u(_der_to_raw_rs(proc.stdout))
        return f"{header}.{payload}.{sig}"

    def _request(self, method: str, path: str, body: dict[str, Any] | None = None) -> tuple[int, dict[str, Any]]:
        if not self.is_configured:
            raise AscError("App Store Connect API is not configured")
        token = self._make_jwt()
        headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(
            f"{self.cfg.asc_base_url}{path}", data=data, headers=headers, method=method
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                raw = resp.read().decode("utf-8")
                return resp.status, json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="replace")
            try:
                parsed = json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                parsed = {"raw": raw}
            return exc.code, parsed
        except Exception as exc:
            raise AscError(f"ASC request error: {type(exc).__name__}") from exc

    @staticmethod
    def _err_detail(res: dict[str, Any]) -> str:
        errs = res.get("errors")
        if isinstance(errs, list) and errs and isinstance(errs[0], dict):
            code = errs[0].get("code") or ""
            detail = errs[0].get("detail") or errs[0].get("title") or ""
            joined = f"{code}: {detail}".strip(": ")
            return joined[:180]
        return ""

    @staticmethod
    def _err_code(res: dict[str, Any]) -> str:
        errs = res.get("errors")
        if isinstance(errs, list) and errs and isinstance(errs[0], dict):
            return str(errs[0].get("code") or "")
        return ""

    def get_group_external_review_state(self, force_refresh: bool = False) -> str:
        now = time.monotonic()
        with self._cache_lock:
            if (
                not force_refresh
                and self._review_state_cache is not None
                and now - self._review_state_cache[1] < 60.0
            ):
                return self._review_state_cache[0]

        st, res = self._request(
            "GET",
            f"/v1/builds?filter[betaGroups]={self.cfg.asc_external_group_id}&limit=5&include=buildBetaDetail",
        )
        if st < 200 or st >= 300:
            detail = self._err_detail(res)
            raise AscError(f"ASC group builds check failed ({st}) {detail}".strip())

        details = [
            item
            for item in res.get("included", [])
            if item.get("type") == "buildBetaDetails"
        ]
        state = "NO_BUILD"
        for d in details:
            ext = (d.get("attributes") or {}).get("externalBuildState")
            if ext == "IN_BETA_TESTING":
                state = "IN_BETA_TESTING"
                break
        if state == "NO_BUILD" and details:
            state = (details[0].get("attributes") or {}).get("externalBuildState") or "UNKNOWN"

        with self._cache_lock:
            self._review_state_cache = (state, now)
        return state

    def _find_tester(self, email: str, any_app: bool = False) -> tuple[str | None, str | None]:
        encoded = urllib.parse.quote(email)
        if any_app:
            path = f"/v1/betaTesters?filter[email]={encoded}&limit=5"
        else:
            path = f"/v1/betaTesters?filter[apps]={self.cfg.asc_app_id}&filter[email]={encoded}&limit=5"
        st, res = self._request("GET", path)
        if st < 200 or st >= 300:
            detail = self._err_detail(res)
            raise AscError(f"ASC betaTesters lookup failed ({st}) {detail}".strip())
        data = res.get("data") or []
        if not data:
            return None, None
        first = data[0]
        state = (first.get("attributes") or {}).get("state")
        return str(first["id"]), str(state) if state else None

    def invite_external_tester(
        self, email: str, resend: bool = False
    ) -> tuple[str, str]:
        """Registers/attaches email to external betaGroup and triggers TestFlight invite if approved.

        Returns (tester_id, invite_status) where invite_status is one of:
        'invited', 'already_installed', or 'queued_pending_review'.
        """
        group_id = self.cfg.asc_external_group_id
        tester_id, tester_state = self._find_tester(email, any_app=False)
        existed = tester_id is not None

        if tester_id is None:
            st, res = self._request(
                "POST",
                "/v1/betaTesters",
                {
                    "data": {
                        "type": "betaTesters",
                        "attributes": {"email": email},
                        "relationships": {
                            "betaGroups": {
                                "data": [{"type": "betaGroups", "id": group_id}]
                            }
                        },
                    }
                },
            )
            if 200 <= st < 300 and res.get("data", {}).get("id"):
                tester_id = str(res["data"]["id"])
            elif st == 409:
                tester_id, tester_state = self._find_tester(email, any_app=False)
                if tester_id is None:
                    tester_id, tester_state = self._find_tester(email, any_app=True)
                existed = True
                if tester_id is None:
                    raise AscError("ASC tester conflict without lookup match")
            else:
                detail = self._err_detail(res)
                raise AscError(f"ASC create betaTester failed ({st}) {detail}".strip())

        if existed:
            st, res = self._request(
                "POST",
                f"/v1/betaGroups/{group_id}/relationships/betaTesters",
                {"data": [{"type": "betaTesters", "id": tester_id}]},
            )
            if st not in (200, 201, 204, 409):
                detail = self._err_detail(res)
                raise AscError(f"ASC attach tester to group failed ({st}) {detail}".strip())

        review_state = self.get_group_external_review_state()
        if review_state == "IN_BETA_TESTING":
            if existed or resend:
                st, res = self._request(
                    "POST",
                    "/v1/betaTesterInvitations",
                    {
                        "data": {
                            "type": "betaTesterInvitations",
                            "relationships": {
                                "app": {
                                    "data": {"type": "apps", "id": self.cfg.asc_app_id}
                                },
                                "betaTester": {
                                    "data": {"type": "betaTesters", "id": tester_id}
                                },
                            },
                        }
                    },
                )
                if 200 <= st < 300:
                    return tester_id, "invited"
                if st in (409, 422):
                    err_code = self._err_code(res)
                    _, latest_state = self._find_tester(email, any_app=False)
                    effective_state = latest_state or tester_state
                    if effective_state in ("INSTALLED", "ACCEPTED") or "ALREADY_ACCEPTED" in err_code:
                        return tester_id, "already_installed"
                    return tester_id, "queued_pending_review"
                detail = self._err_detail(res)
                raise AscError(f"ASC betaTesterInvitations failed ({st}) {detail}".strip())
            return tester_id, "invited"

        return tester_id, "queued_pending_review"


class BetaService:
    """Core business logic shared by HTTP handler and unit tests."""

    def __init__(
        self, cfg: Config, store: BetaStore, mailer: SmtpMailer, asc: AscClient
    ) -> None:
        self.cfg = cfg
        self.store = store
        self.mailer = mailer
        self.asc = asc

    def health(self) -> tuple[int, dict[str, Any]]:
        review_state = "UNCONFIGURED"
        if self.asc.is_configured:
            try:
                review_state = self.asc.get_group_external_review_state()
            except Exception as exc:
                logger.warning("ASC health state check failed: %s", exc)
                review_state = "UNKNOWN"
        return 200, {
            "ok": True,
            "service": "ai-card-beta-api",
            "smtpConfigured": self.mailer.is_configured,
            "ascConfigured": self.asc.is_configured,
            "iosBetaReviewState": review_state,
            "verifiedCount": self.store.verified_count(),
        }

    def request_code(
        self, payload: dict[str, Any], client_ip: str, now: int | None = None
    ) -> tuple[int, dict[str, Any]]:
        now = int(time.time()) if now is None else now
        if payload.get("website"):
            return 400, {
                "ok": False,
                "code": "INVALID_REQUEST",
                "message": "请求无效",
            }
        email = normalize_email(payload.get("email"))
        if email is None:
            return 400, {
                "ok": False,
                "code": "INVALID_EMAIL",
                "message": "请输入有效的邮箱地址",
            }
        platform = normalize_platform(payload.get("platform"))
        if platform is None:
            return 400, {
                "ok": False,
                "code": "INVALID_PLATFORM",
                "message": "不支持的设备平台",
            }
        source = normalize_source(payload.get("source"))
        locale = normalize_locale(payload.get("locale"))
        ip_digest = hash_ip(self.cfg.ip_hash_salt, client_ip)

        cooldown_wait = self.store.check_rate(
            f"req:email:{email}", self.cfg.cooldown_seconds, 1, now
        )
        if cooldown_wait > 0:
            return 429, {
                "ok": False,
                "code": "COOLDOWN",
                "retryAfter": cooldown_wait,
                "message": f"发送过于频繁，请 {cooldown_wait} 秒后再试",
            }

        email_hour_wait = self.store.check_rate(f"req:email:{email}", 3600, 5, now)
        if email_hour_wait > 0:
            return 429, {
                "ok": False,
                "code": "RATE_LIMITED",
                "retryAfter": email_hour_wait,
                "message": "该邮箱请求次数过多，请稍后再试",
            }

        ip_hour_wait = self.store.check_rate(f"req:ip:{ip_digest}", 3600, 12, now)
        if ip_hour_wait > 0:
            return 429, {
                "ok": False,
                "code": "RATE_LIMITED",
                "retryAfter": ip_hour_wait,
                "message": "当前网络请求过于频繁，请稍后再试",
            }

        code = f"{secrets.randbelow(1_000_000):06d}"
        code_digest = hash_otp(self.cfg.code_pepper, email, code)
        code_id = self.store.create_code_and_pending_signup(
            email=email,
            platform=platform,
            source=source,
            locale=locale,
            code_hash=code_digest,
            expires_at=now + self.cfg.code_ttl_seconds,
            ip_hash=ip_digest,
            now=now,
        )

        self.store.record_rate(f"req:ip:{ip_digest}", now)
        try:
            self.mailer.send_verification_code(email, code, platform, locale)
        except Exception as exc:
            logger.error("Failed to send OTP email to %s: %s", email, exc)
            self.store.delete_code(code_id)
            return 502, {
                "ok": False,
                "code": "MAIL_SEND_FAILED",
                "message": "验证码邮件发送失败，请稍后重试",
            }

        self.store.record_rate(f"req:email:{email}", now)
        return 200, {
            "ok": True,
            "email": email,
            "platform": platform,
            "expiresIn": self.cfg.code_ttl_seconds,
            "cooldown": self.cfg.cooldown_seconds,
            "message": "验证码已发送，请查收邮件",
        }

    def verify_code(
        self, payload: dict[str, Any], client_ip: str, now: int | None = None
    ) -> tuple[int, dict[str, Any]]:
        now = int(time.time()) if now is None else now
        if payload.get("website"):
            return 400, {
                "ok": False,
                "code": "INVALID_REQUEST",
                "message": "请求无效",
            }
        email = normalize_email(payload.get("email"))
        if email is None:
            return 400, {
                "ok": False,
                "code": "INVALID_EMAIL",
                "message": "请输入有效的邮箱地址",
            }
        code = normalize_code(payload.get("code"))
        if code is None:
            return 400, {
                "ok": False,
                "code": "INVALID_CODE",
                "message": "请输入 6 位数字验证码",
            }

        ip_digest = hash_ip(self.cfg.ip_hash_salt, client_ip)
        verify_wait = self.store.check_rate(f"verify:email:{email}", 900, 10, now)
        if verify_wait > 0:
            return 429, {
                "ok": False,
                "code": "RATE_LIMITED",
                "retryAfter": verify_wait,
                "message": "验证尝试过多，请稍后再试",
            }
        ip_wait = self.store.check_rate(f"verify:ip:{ip_digest}", 900, 30, now)
        if ip_wait > 0:
            return 429, {
                "ok": False,
                "code": "RATE_LIMITED",
                "retryAfter": ip_wait,
                "message": "当前网络验证请求过于频繁，请稍后再试",
            }
        self.store.record_rate(f"verify:email:{email}", now)
        self.store.record_rate(f"verify:ip:{ip_digest}", now)

        code_digest = hash_otp(self.cfg.code_pepper, email, code)
        ok, err_code, code_row = self.store.verify_code(
            email=email,
            code_hash=code_digest,
            max_attempts=self.cfg.max_verify_attempts,
            now=now,
        )
        if not ok or code_row is None:
            msg_map = {
                "CODE_NOT_FOUND": "请先获取邮箱验证码",
                "CODE_EXPIRED": "验证码已过期，请重新获取",
                "TOO_MANY_ATTEMPTS": "验证码错误次数过多，请重新获取",
                "INVALID_CODE": "验证码不正确，请检查后重试",
            }
            return 400, {
                "ok": False,
                "code": err_code,
                "message": msg_map.get(err_code, "验证码无效"),
            }

        platform = normalize_platform(payload.get("platform") or code_row["platform"]) or "ios"
        source = normalize_source(payload.get("source") or code_row["source"])
        locale = normalize_locale(payload.get("locale") or code_row["locale"])

        if platform == "android":
            pos = self.store.update_signup_after_verify(
                email=email,
                platform=platform,
                source=source,
                locale=locale,
                status="android_waitlist",
                verified_at=now,
                asc_invite_status=None,
                asc_last_error=None,
                now=now,
            )
            try:
                self.mailer.send_confirmation(email, "android", "android_waitlist", locale)
            except Exception as exc:
                logger.warning("Confirmation email failed for %s: %s", email, exc)
            return 200, {
                "ok": True,
                "email": email,
                "platform": "android",
                "status": "android_waitlist",
                "canResendInvite": False,
                "position": pos,
                "message": "邮箱已验证，已加入 Android 优先通知与早鸟名单",
            }

        try:
            tester_id, invite_status = self.asc.invite_external_tester(email, resend=False)
        except Exception as exc:
            logger.error("ASC invite failed for %s: %s", email, exc)
            pos = self.store.update_signup_after_verify(
                email=email,
                platform="ios",
                source=source,
                locale=locale,
                status="invite_failed",
                verified_at=now,
                asc_invite_status="invite_failed",
                asc_last_error=str(exc)[:240],
                now=now,
            )
            return 502, {
                "ok": False,
                "code": "ASC_INVITE_FAILED",
                "email": email,
                "platform": "ios",
                "canResendInvite": True,
                "position": pos,
                "message": "邮箱已验证，但同步 TestFlight 邀请时暂不可用，请点击重发邀请重试",
            }

        pos = self.store.update_signup_after_verify(
            email=email,
            platform="ios",
            source=source,
            locale=locale,
            status=invite_status,
            verified_at=now,
            asc_tester_id=tester_id,
            asc_invite_status=invite_status,
            asc_last_error=None,
            last_invite_sent_at=now if invite_status == "invited" else None,
            now=now,
        )
        self.store.record_rate(f"resend:email:{email}", now)
        try:
            self.mailer.send_confirmation(email, "ios", invite_status, locale)
        except Exception as exc:
            logger.warning("Confirmation email failed for %s: %s", email, exc)

        if invite_status == "invited":
            msg = "邮箱已验证！苹果官方 TestFlight 邀请已发送至你的邮箱，请在 iPhone 上查收"
            can_resend = True
        elif invite_status == "already_installed":
            msg = "该邮箱已在 TestFlight 测试名单中，可直接在 iPhone TestFlight 中安装或使用公开链接"
            can_resend = False
        else:
            msg = "邮箱已验证并加入 TestFlight 测试名单，苹果外测审核通过后将自动发送邀请邮件"
            can_resend = True

        return 200, {
            "ok": True,
            "email": email,
            "platform": "ios",
            "status": invite_status,
            "canResendInvite": can_resend,
            "position": pos,
            "publicTestFlightUrl": self.cfg.public_testflight_url,
            "message": msg,
        }

    def resend_invite(
        self, payload: dict[str, Any], client_ip: str, now: int | None = None
    ) -> tuple[int, dict[str, Any]]:
        now = int(time.time()) if now is None else now
        email = normalize_email(payload.get("email"))
        if email is None:
            return 400, {
                "ok": False,
                "code": "INVALID_EMAIL",
                "message": "请输入有效的邮箱地址",
            }

        signup = self.store.get_signup(email)
        if signup is None or signup.get("verified_at") is None:
            return 404, {
                "ok": False,
                "code": "NOT_VERIFIED",
                "message": "该邮箱尚未完成验证，请先验证邮箱",
            }
        if signup.get("platform") != "ios":
            return 400, {
                "ok": False,
                "code": "NOT_IOS_SIGNUP",
                "message": "Android 预约暂不支持发送 TestFlight 邀请",
            }

        ip_digest = hash_ip(self.cfg.ip_hash_salt, client_ip)
        cooldown = self.store.check_rate(f"resend:email:{email}", 300, 1, now)
        if cooldown > 0:
            return 429, {
                "ok": False,
                "code": "COOLDOWN",
                "retryAfter": cooldown,
                "message": f"重发过于频繁，请 {cooldown} 秒后再试",
            }
        daily = self.store.check_rate(f"resend:email:{email}", 86400, 3, now)
        if daily > 0:
            return 429, {
                "ok": False,
                "code": "RATE_LIMITED",
                "retryAfter": daily,
                "message": "今日重发次数已达上限，请明日再试",
            }
        ip_wait = self.store.check_rate(f"resend:ip:{ip_digest}", 3600, 15, now)
        if ip_wait > 0:
            return 429, {
                "ok": False,
                "code": "RATE_LIMITED",
                "retryAfter": ip_wait,
                "message": "当前网络请求过于频繁，请稍后再试",
            }

        self.store.record_rate(f"resend:ip:{ip_digest}", now)
        try:
            tester_id, invite_status = self.asc.invite_external_tester(email, resend=True)
        except Exception as exc:
            logger.error("ASC resend failed for %s: %s", email, exc)
            return 502, {
                "ok": False,
                "code": "ASC_INVITE_FAILED",
                "message": "TestFlight 邀请重发失败，请稍后重试",
            }

        self.store.record_rate(f"resend:email:{email}", now)
        locale = normalize_locale(payload.get("locale") or signup.get("locale"))
        pos = self.store.update_signup_after_verify(
            email=email,
            platform="ios",
            source=str(signup.get("source") or "web"),
            locale=locale,
            status=invite_status,
            verified_at=int(signup["verified_at"]),
            asc_tester_id=tester_id,
            asc_invite_status=invite_status,
            asc_last_error=None,
            last_invite_sent_at=now if invite_status == "invited" else None,
            now=now,
        )
        try:
            self.mailer.send_confirmation(email, "ios", invite_status, locale)
        except Exception as exc:
            logger.warning("Resend confirmation email failed for %s: %s", email, exc)

        if invite_status == "invited":
            msg = "已重新发送苹果 TestFlight 邀请邮件，请留意收件箱或垃圾箱"
            can_resend = True
        elif invite_status == "already_installed":
            msg = "该邮箱已在 TestFlight 测试名单中，可直接在 iPhone TestFlight 中安装或使用公开链接"
            can_resend = False
        else:
            msg = "你的邮箱已在 TestFlight 测试名单中，苹果外测审核通过后会自动发出邀请"
            can_resend = True

        return 200, {
            "ok": True,
            "email": email,
            "platform": "ios",
            "status": invite_status,
            "canResendInvite": can_resend,
            "position": pos,
            "publicTestFlightUrl": self.cfg.public_testflight_url,
            "message": msg,
        }


def make_handler(service: BetaService):
    class BetaRequestHandler(BaseHTTPRequestHandler):
        server_version = "AiCardBetaAPI/1.0"

        def log_message(self, format: str, *args: Any) -> None:
            logger.info("%s - %s", self._client_ip(), format % args)

        def _client_ip(self) -> str:
            real_ip = (self.headers.get("X-Real-IP") or "").strip()
            if real_ip:
                return real_ip
            xff = (self.headers.get("X-Forwarded-For") or "").strip()
            if xff:
                return xff.split(",")[0].strip()
            return str(self.client_address[0])

        def _send_json(self, status: int, body: dict[str, Any]) -> None:
            raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def _read_json(self) -> tuple[dict[str, Any] | None, tuple[int, dict[str, Any]] | None]:
            raw_len = self.headers.get("Content-Length")
            if raw_len is None:
                return None, (400, {"ok": False, "code": "BAD_REQUEST", "message": "缺少请求体"})
            try:
                length = int(raw_len)
            except ValueError:
                return None, (400, {"ok": False, "code": "BAD_REQUEST", "message": "无效的内容长度"})
            if length <= 0 or length > MAX_BODY_BYTES:
                return None, (413, {"ok": False, "code": "PAYLOAD_TOO_LARGE", "message": "请求体过大"})
            raw_bytes = self.rfile.read(length)
            try:
                parsed = json.loads(raw_bytes.decode("utf-8"))
            except Exception:
                return None, (400, {"ok": False, "code": "INVALID_JSON", "message": "JSON 格式无效"})
            if not isinstance(parsed, dict):
                return None, (400, {"ok": False, "code": "INVALID_JSON", "message": "JSON 须为对象"})
            return parsed, None

        def do_GET(self) -> None:
            path = urllib.parse.urlsplit(self.path).path
            if path == "/api/beta/health":
                st, body = service.health()
                self._send_json(st, body)
                return
            if path in {"/api/beta/request-code", "/api/beta/verify", "/api/beta/resend-invite"}:
                self._send_json(405, {"ok": False, "code": "METHOD_NOT_ALLOWED", "message": "请使用 POST 请求"})
                return
            self._send_json(404, {"ok": False, "code": "NOT_FOUND", "message": "接口不存在"})

        def do_POST(self) -> None:
            path = urllib.parse.urlsplit(self.path).path
            if path not in {"/api/beta/request-code", "/api/beta/verify", "/api/beta/resend-invite"}:
                self._send_json(404, {"ok": False, "code": "NOT_FOUND", "message": "接口不存在"})
                return
            payload, err = self._read_json()
            if err is not None or payload is None:
                assert err is not None
                self._send_json(err[0], err[1])
                return

            ip = self._client_ip()
            if path == "/api/beta/request-code":
                st, body = service.request_code(payload, ip)
            elif path == "/api/beta/verify":
                st, body = service.verify_code(payload, ip)
            else:
                st, body = service.resend_invite(payload, ip)
            self._send_json(st, body)

        def do_OPTIONS(self) -> None:
            self.send_response(204)
            self.send_header("Allow", "GET, POST, OPTIONS")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()

    return BetaRequestHandler


def create_server(cfg: Config, service: BetaService | None = None) -> ThreadingHTTPServer:
    if service is None:
        store = BetaStore(cfg.db_path)
        mailer = SmtpMailer(cfg)
        asc = AscClient(cfg)
        service = BetaService(cfg, store, mailer, asc)
    return ThreadingHTTPServer((cfg.host, cfg.port), make_handler(service))


def main() -> None:
    cfg = Config.from_env()
    server = create_server(cfg)
    logger.info("Starting ai-card-beta-api on http://%s:%s (db=%s)", cfg.host, cfg.port, cfg.db_path)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
