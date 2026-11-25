#!/usr/bin/env python3
"""Unit and HTTP integration tests for ai-card-beta-api."""

import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

from app import AscClient, BetaService, BetaStore, Config, MailError, create_server


class FakeMailer:
    def __init__(self, fail_next: bool = False) -> None:
        self.is_configured = True
        self.fail_next = fail_next
        self.otp_calls: list[tuple[str, str, str, str]] = []
        self.confirm_calls: list[tuple[str, str, str, str]] = []

    def send_verification_code(
        self, email: str, code: str, platform: str, locale: str
    ) -> None:
        if self.fail_next:
            self.fail_next = False
            raise MailError("simulated smtp error")
        self.otp_calls.append((email, code, platform, locale))

    def send_confirmation(
        self, email: str, platform: str, status: str, locale: str
    ) -> None:
        self.confirm_calls.append((email, platform, status, locale))


class FakeAscClient:
    def __init__(self, review_state: str = "WAITING_FOR_BETA_REVIEW") -> None:
        self.is_configured = True
        self.review_state = review_state
        self.fail_next = False
        self.installed_emails: set[str] = set()
        self.invites: list[tuple[str, bool]] = []

    def get_group_external_review_state(self, force_refresh: bool = False) -> str:
        return self.review_state

    def invite_external_tester(self, email: str, resend: bool = False) -> tuple[str, str]:
        if self.fail_next:
            self.fail_next = False
            raise RuntimeError("simulated asc failure")
        self.invites.append((email, resend))
        if email in self.installed_emails:
            return f"tester-{len(self.invites)}", "already_installed"
        status = (
            "invited"
            if self.review_state == "IN_BETA_TESTING"
            else "queued_pending_review"
        )
        return f"tester-{len(self.invites)}", status


class BetaApiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()
        db_path = os.path.join(self.tmpdir.name, "test.sqlite3")
        self.cfg = Config(
            host="127.0.0.1",
            port=0,
            db_path=db_path,
            code_pepper="test-pepper-123",
            ip_hash_salt="test-salt-456",
            code_ttl_seconds=600,
            cooldown_seconds=60,
            max_verify_attempts=5,
        )
        self.store = BetaStore(db_path)
        self.mailer = FakeMailer()
        self.asc = FakeAscClient(review_state="WAITING_FOR_BETA_REVIEW")
        self.service = BetaService(self.cfg, self.store, self.mailer, self.asc)
        self.server = create_server(self.cfg, self.service)
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.store.close()
        self.tmpdir.cleanup()

    def _http(self, method: str, path: str, body=None, headers=None):
        req_headers = {"Content-Type": "application/json"}
        if headers:
            req_headers.update(headers)
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(
            f"{self.base_url}{path}", data=data, headers=req_headers, method=method
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            try:
                return exc.code, json.loads(exc.read().decode("utf-8"))
            finally:
                exc.close()

    def test_health_endpoint(self) -> None:
        st, body = self._http("GET", "/api/beta/health")
        self.assertEqual(st, 200)
        self.assertTrue(body["ok"])
        self.assertEqual(body["service"], "ai-card-beta-api")
        self.assertTrue(body["smtpConfigured"])
        self.assertTrue(body["ascConfigured"])
        self.assertEqual(body["iosBetaReviewState"], "WAITING_FOR_BETA_REVIEW")
        self.assertEqual(body["verifiedCount"], 0)

    def test_validation_and_honeypot(self) -> None:
        st, body = self._http("POST", "/api/beta/request-code", {"email": "not-an-email"})
        self.assertEqual(st, 400)
        self.assertEqual(body["code"], "INVALID_EMAIL")

        st, body = self._http(
            "POST",
            "/api/beta/request-code",
            {"email": "bad\r\ncc:x@y.com@example.com"},
        )
        self.assertEqual(st, 400)
        self.assertEqual(body["code"], "INVALID_EMAIL")

        st, body = self._http(
            "POST",
            "/api/beta/request-code",
            {"email": "ok@example.com", "website": "spam-bot"},
        )
        self.assertEqual(st, 400)
        self.assertEqual(body["code"], "INVALID_REQUEST")
        self.assertEqual(len(self.mailer.otp_calls), 0)

    def test_ios_queued_pending_review_end_to_end_and_replay_protection(self) -> None:
        st, body = self._http(
            "POST",
            "/api/beta/request-code",
            {"email": "Alice@Example.com", "platform": "iOS + Watch", "source": "inline"},
        )
        self.assertEqual(st, 200)
        self.assertEqual(body["email"], "alice@example.com")
        self.assertEqual(body["platform"], "ios")
        self.assertEqual(len(self.mailer.otp_calls), 1)
        sent_email, code, platform, _ = self.mailer.otp_calls[0]
        self.assertEqual(sent_email, "alice@example.com")
        self.assertEqual(platform, "ios")

        # Cooldown blocks immediate second request
        st2, body2 = self._http(
            "POST",
            "/api/beta/request-code",
            {"email": "alice@example.com", "platform": "ios"},
        )
        self.assertEqual(st2, 429)
        self.assertEqual(body2["code"], "COOLDOWN")

        # Wrong code fails
        st_bad, bad_body = self._http(
            "POST",
            "/api/beta/verify",
            {"email": "alice@example.com", "code": "000000" if code != "000000" else "111111"},
        )
        self.assertEqual(st_bad, 400)
        self.assertEqual(bad_body["code"], "INVALID_CODE")

        # Correct code succeeds and calls ASC
        st_ok, ok_body = self._http(
            "POST",
            "/api/beta/verify",
            {"email": "alice@example.com", "code": code},
        )
        self.assertEqual(st_ok, 200)
        self.assertTrue(ok_body["ok"])
        self.assertEqual(ok_body["status"], "queued_pending_review")
        self.assertTrue(ok_body["canResendInvite"])
        self.assertEqual(ok_body["position"], 1)
        self.assertEqual(self.asc.invites, [("alice@example.com", False)])
        self.assertEqual(
            self.mailer.confirm_calls,
            [("alice@example.com", "ios", "queued_pending_review", "zh-Hans")],
        )

        # Replay of same code fails
        st_replay, replay_body = self._http(
            "POST",
            "/api/beta/verify",
            {"email": "alice@example.com", "code": code},
        )
        self.assertEqual(st_replay, 400)
        self.assertEqual(replay_body["code"], "CODE_NOT_FOUND")

    def test_ios_invited_when_approved_and_resend(self) -> None:
        self.asc.review_state = "IN_BETA_TESTING"
        now = 1_800_000_000
        st, _ = self.service.request_code(
            {"email": "bob@example.com", "platform": "ios", "source": "modal", "locale": "en"},
            "1.2.3.4",
            now=now,
        )
        self.assertEqual(st, 200)
        code = self.mailer.otp_calls[-1][1]

        st_v, body_v = self.service.verify_code(
            {"email": "bob@example.com", "code": code}, "1.2.3.4", now=now + 10
        )
        self.assertEqual(st_v, 200)
        self.assertEqual(body_v["status"], "invited")
        self.assertTrue(body_v["canResendInvite"])

        # Immediate resend blocked by 300s cooldown
        st_cd, body_cd = self.service.resend_invite(
            {"email": "bob@example.com"}, "1.2.3.4", now=now + 20
        )
        self.assertEqual(st_cd, 429)
        self.assertEqual(body_cd["code"], "COOLDOWN")

        # After 301s resend succeeds
        st_rs, body_rs = self.service.resend_invite(
            {"email": "bob@example.com", "locale": "en"}, "1.2.3.4", now=now + 320
        )
        self.assertEqual(st_rs, 200)
        self.assertEqual(body_rs["status"], "invited")
        self.assertEqual(
            self.asc.invites, [("bob@example.com", False), ("bob@example.com", True)]
        )

    def test_ios_already_installed_returns_distinct_status(self) -> None:
        self.asc.review_state = "IN_BETA_TESTING"
        self.asc.installed_emails.add("installed@example.com")
        now = 1_810_000_000
        st, _ = self.service.request_code(
            {"email": "installed@example.com", "platform": "ios", "source": "inline"},
            "3.3.3.3",
            now=now,
        )
        self.assertEqual(st, 200)
        code = self.mailer.otp_calls[-1][1]

        st_v, body_v = self.service.verify_code(
            {"email": "installed@example.com", "code": code}, "3.3.3.3", now=now + 5
        )
        self.assertEqual(st_v, 200)
        self.assertEqual(body_v["status"], "already_installed")
        self.assertFalse(body_v["canResendInvite"])
        self.assertEqual(
            body_v["publicTestFlightUrl"],
            "https://testflight.apple.com/join/fMWkZSv5",
        )
        self.assertEqual(
            self.mailer.confirm_calls[-1],
            ("installed@example.com", "ios", "already_installed", "zh-Hans"),
        )

    def test_android_waitlist_flow(self) -> None:
        st, _ = self._http(
            "POST",
            "/api/beta/request-code",
            {"email": "droid@example.com", "platform": "Android", "source": "inline"},
        )
        self.assertEqual(st, 200)
        code = self.mailer.otp_calls[-1][1]

        st_v, body_v = self._http(
            "POST",
            "/api/beta/verify",
            {"email": "droid@example.com", "code": code},
        )
        self.assertEqual(st_v, 200)
        self.assertEqual(body_v["platform"], "android")
        self.assertEqual(body_v["status"], "android_waitlist")
        self.assertFalse(body_v["canResendInvite"])
        self.assertEqual(self.asc.invites, [])
        self.assertEqual(
            self.mailer.confirm_calls[-1],
            ("droid@example.com", "android", "android_waitlist", "zh-Hans"),
        )

    def test_expired_and_too_many_attempts(self) -> None:
        t0 = 1_700_000_000
        st, _ = self.service.request_code(
            {"email": "exp@example.com", "platform": "ios"}, "9.9.9.9", now=t0
        )
        self.assertEqual(st, 200)
        code = self.mailer.otp_calls[-1][1]

        st_exp, body_exp = self.service.verify_code(
            {"email": "exp@example.com", "code": code}, "9.9.9.9", now=t0 + 601
        )
        self.assertEqual(st_exp, 400)
        self.assertEqual(body_exp["code"], "CODE_EXPIRED")

        st2, _ = self.service.request_code(
            {"email": "tries@example.com", "platform": "ios"}, "9.9.9.8", now=t0
        )
        self.assertEqual(st2, 200)
        real_code = self.mailer.otp_calls[-1][1]
        wrong = "999999" if real_code != "999999" else "888888"
        for i in range(4):
            s, b = self.service.verify_code(
                {"email": "tries@example.com", "code": wrong}, "9.9.9.8", now=t0 + i + 1
            )
            self.assertEqual(s, 400)
            self.assertEqual(b["code"], "INVALID_CODE")
        s5, b5 = self.service.verify_code(
            {"email": "tries@example.com", "code": wrong}, "9.9.9.8", now=t0 + 5
        )
        self.assertEqual(s5, 400)
        self.assertEqual(b5["code"], "TOO_MANY_ATTEMPTS")

        # Even real code is now locked out
        s6, b6 = self.service.verify_code(
            {"email": "tries@example.com", "code": real_code}, "9.9.9.8", now=t0 + 6
        )
        self.assertEqual(s6, 400)
        self.assertEqual(b6["code"], "TOO_MANY_ATTEMPTS")

    def test_smtp_failure_rolls_back_code_so_user_can_retry(self) -> None:
        self.mailer.fail_next = True
        t0 = 1_750_000_000
        st, body = self.service.request_code(
            {"email": "retry@example.com", "platform": "ios"}, "2.2.2.2", now=t0
        )
        self.assertEqual(st, 502)
        self.assertEqual(body["code"], "MAIL_SEND_FAILED")

        # Immediately allowed again because mail failed before email cooldown recorded
        st2, _ = self.service.request_code(
            {"email": "retry@example.com", "platform": "ios"}, "2.2.2.2", now=t0 + 1
        )
        self.assertEqual(st2, 200)


class AscClientUnitTests(unittest.TestCase):
    def test_group_review_state_and_app_scoped_tester_lookup(self) -> None:
        cfg = Config(
            asc_app_id="6834316655",
            asc_external_group_id="group-123",
            asc_key_id="K",
            asc_issuer_id="I",
            asc_key_path="/dev/null",
        )
        client = AscClient(cfg)
        calls: list[tuple[str, str, object]] = []

        def fake_request(method: str, path: str, body=None):
            calls.append((method, path, body))
            if path.startswith("/v1/builds?filter[betaGroups]=group-123"):
                return 200, {
                    "data": [{"type": "builds", "id": "b1"}],
                    "included": [
                        {
                            "type": "buildBetaDetails",
                            "id": "b1",
                            "attributes": {"externalBuildState": "WAITING_FOR_BETA_REVIEW"},
                        }
                    ],
                }
            if path.startswith("/v1/betaTesters?filter[apps]=6834316655&filter[email]="):
                return 200, {"data": []}
            if method == "POST" and path == "/v1/betaTesters":
                return 201, {"data": {"type": "betaTesters", "id": "tester-new-1"}}
            raise AssertionError(f"Unexpected ASC call: {method} {path}")

        client._request = fake_request  # type: ignore[method-assign]
        tid, status = client.invite_external_tester("user@example.com")
        self.assertEqual(tid, "tester-new-1")
        self.assertEqual(status, "queued_pending_review")
        self.assertIn(
            "/v1/builds?filter[betaGroups]=group-123&limit=5&include=buildBetaDetail",
            [c[1] for c in calls],
        )
        self.assertTrue(
            any(
                c[1].startswith("/v1/betaTesters?filter[apps]=6834316655&filter[email]=")
                for c in calls
            )
        )

    def test_group_review_state_prefers_in_beta_testing(self) -> None:
        cfg = Config(asc_app_id="6834316655", asc_external_group_id="group-123")
        client = AscClient(cfg)

        def fake_request(method: str, path: str, body=None):
            return 200, {
                "included": [
                    {
                        "type": "buildBetaDetails",
                        "id": "b1",
                        "attributes": {"externalBuildState": "WAITING_FOR_BETA_REVIEW"},
                    },
                    {
                        "type": "buildBetaDetails",
                        "id": "b2",
                        "attributes": {"externalBuildState": "IN_BETA_TESTING"},
                    },
                ]
            }

        client._request = fake_request  # type: ignore[method-assign]
        self.assertEqual(
            client.get_group_external_review_state(force_refresh=True),
            "IN_BETA_TESTING",
        )

    def test_existing_installed_tester_returns_already_installed(self) -> None:
        cfg = Config(
            asc_app_id="6834316655",
            asc_external_group_id="group-123",
            asc_key_id="K",
            asc_issuer_id="I",
            asc_key_path="/dev/null",
        )
        client = AscClient(cfg)

        def fake_request(method: str, path: str, body=None):
            if path.startswith("/v1/betaTesters?filter[apps]=6834316655&filter[email]="):
                return 200, {
                    "data": [
                        {
                            "type": "betaTesters",
                            "id": "tester-existing-1",
                            "attributes": {"state": "INSTALLED"},
                        }
                    ]
                }
            if method == "POST" and path == "/v1/betaGroups/group-123/relationships/betaTesters":
                return 204, {}
            if path.startswith("/v1/builds?filter[betaGroups]=group-123"):
                return 200, {
                    "included": [
                        {
                            "type": "buildBetaDetails",
                            "id": "b1",
                            "attributes": {"externalBuildState": "IN_BETA_TESTING"},
                        }
                    ]
                }
            if method == "POST" and path == "/v1/betaTesterInvitations":
                return 409, {
                    "errors": [
                        {
                            "code": "STATE_ERROR.TESTER_INVITE.ALREADY_ACCEPTED",
                            "detail": "Tester has already accepted invitation.",
                        }
                    ]
                }
            raise AssertionError(f"Unexpected ASC call: {method} {path}")

        client._request = fake_request  # type: ignore[method-assign]
        tid, status = client.invite_external_tester("installed@example.com")
        self.assertEqual(tid, "tester-existing-1")
        self.assertEqual(status, "already_installed")


if __name__ == "__main__":
    unittest.main()
