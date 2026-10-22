#!/usr/bin/env python3
"""End-to-end acceptance for the Mailu -> Stalwart move (stdlib only; dkimpy for dkim_*).

  op run --env-file scripts/mail_acceptance.env -- python3 scripts/mail_acceptance.py --mode staged
  op run --env-file scripts/mail_acceptance.env -- python3 scripts/mail_acceptance.py --mode public

Prints one `PASS|FAIL|SKIP <check>` line per check (plus `WARN autoconfig`, which never fails
the run) and exits 1 on any FAIL. Delivery checks submit on 465 as jason@<domain>, poll the
destination INBOX over IMAP for --wait seconds by a unique Subject token, then delete the
message. Spam checks need unauthenticated port 25 from where you run this.

Alias/catch-all/plus/mixed-case checks assert the Delivered-To header Stalwart writes (the matched
recipient: an alias keeps its own address, a catch-all hit shows the mailbox), so a missing alias
that falls into the catch-all FAILs. Limitation: `jason+acc@` and `Jason@` resolve to the same
mailbox as the catch-all, so those two are also sent as `contact+acc@` / `Contact@`, which only
resolve correctly with sub-addressing / case-folding on.

Passwords come from the environment: MAIL_PW_<ADDRESS> (address upper-cased, @ and . as _),
and STALWART_ADMIN_PASSWORD for admin_public_blocked.
"""
import argparse
import imaplib
import os
import re
import secrets
import smtplib
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request
from email.utils import formatdate, make_msgid

DOMAINS = ["jasonernst.com", "sair.run", "rustd.xyz", "darksearch.xyz"]
HOSTS = [f"mail.{d}" for d in DOMAINS]
PRIMARY = "mail.jasonernst.com"
MAILBOXES = [f"jason@{d}" for d in DOMAINS] + ["kai@jasonernst.com"] + [
    f"noreply@{d}" for d in ("jasonernst.com", "sair.run", "rustd.xyz")]
IMAP_ACCOUNTS = [f"jason@{d}" for d in DOMAINS] + ["kai@jasonernst.com"]
ALIASES = {  # alias -> destination (spec "Current state" table, plus admin@ per "Calls I made")
    **{f"postmaster@{d}": f"jason@{d}" for d in DOMAINS},
    "contact@rustd.xyz": "jason@rustd.xyz",
    "abuse@darksearch.xyz": "jason@darksearch.xyz",
    "dmca@darksearch.xyz": "jason@darksearch.xyz",
    "admin@jasonernst.com": "jason@jasonernst.com",
}
GTUBE = "XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X"
JUNK_SUBJECT = "iac-junk-probe"


class Fail(Exception):
    pass


class Skip(Exception):
    pass


class Warn(Exception):
    pass


A = None  # parsed args
PLAIN = False  # webmail/admin over plain HTTP on --http-port (staged, or --plain-http)
CTX = None  # TLS context for every connection


def pw(addr):
    var = "MAIL_PW_" + re.sub(r"[@.]", "_", addr.upper())
    if not os.environ.get(var):
        raise Fail(f"{var} is unset")
    return os.environ[var]


def domain_of(addr):
    return addr.rsplit("@", 1)[1].lower()


def message(frm, to, subject):
    return (f"From: <{frm}>\r\nTo: <{to}>\r\nSubject: {subject}\r\nDate: {formatdate()}\r\n"
            f"Message-ID: {make_msgid(domain=domain_of(frm))}\r\n\r\nacceptance test message\r\n").encode()


def submit(sender, rcpt, subject):
    """Authenticated send on the submission port (what the apps do)."""
    s = smtplib.SMTP_SSL(f"mail.{domain_of(sender)}", A.smtps_port, context=CTX, timeout=30,
                         local_hostname="acceptance.invalid")
    try:
        s.login(sender, pw(sender))
        s.sendmail(sender, [rcpt], message(sender, rcpt, subject))
    finally:
        s.close()


def inbound(rcpt, subject):
    """Unauthenticated port-25 delivery, like a remote MTA."""
    s = smtplib.SMTP(PRIMARY, A.smtp_port, timeout=30, local_hostname="acceptance.invalid")
    try:
        s.sendmail(A.sender, [rcpt], message(A.sender, rcpt, subject))
    finally:
        s.close()


def imap(acct):
    m = imaplib.IMAP4_SSL(f"mail.{domain_of(acct)}", A.imaps_port, ssl_context=CTX, timeout=30)
    m.login(acct, pw(acct))
    return m


def junk_folder(m):
    """The folder with the IMAP SPECIAL-USE \\Junk attribute, never found by name."""
    for line in m.list()[1]:
        if line and re.search(rb"\\Junk\b", line.split(b")", 1)[0], re.I):
            return re.search(rb'"?([^"]+)"?\s*$', line).group(1).decode()
    raise Fail("no mailbox has the \\Junk special-use attribute")


def fetch(acct, token, folder="INBOX", delete=True, wait=None):
    """Raw message whose Subject contains token, polled for --wait seconds; None on timeout."""
    deadline = time.time() + (A.wait if wait is None else wait)
    while True:
        m = imap(acct)
        try:
            f = junk_folder(m) if folder == "JUNK" else folder
            quoted = '"' + f.replace("\\", "\\\\").replace('"', '\\"') + '"'  # names may contain spaces
            if m.select(quoted)[0] == "OK":
                ids = m.search(None, "SUBJECT", token)[1][0].split()
                if ids:
                    raw = m.fetch(ids[-1], "(BODY.PEEK[])")[1][0][1]
                    if delete:
                        m.store(ids[-1], "+FLAGS", "\\Deleted")
                        m.expunge()
                    return raw
        finally:
            try:
                m.logout()
            except Exception:
                pass
        if time.time() > deadline:
            return None
        time.sleep(2)


def tok(label):
    return f"iac-{label}-{secrets.token_hex(4)}"


def delivered_to(raw):
    m = re.search(rb"(?im)^Delivered-To:[ \t]*(\S+)", raw)
    return m.group(1).decode().lower() if m else None


def delivers(sends, dest, label):
    """sends: [(rcpt, Delivered-To it must produce)]. Sender is the destination's own jason@."""
    def check():
        for rcpt, want in sends:
            t = tok(label)
            submit(dest, rcpt, t)
            raw = fetch(dest, t)
            if raw is None:
                raise Fail(f"{t} to {rcpt} not in {dest} INBOX after {A.wait}s")
            if delivered_to(raw) != want:
                raise Fail(f"to {rcpt}: Delivered-To is {delivered_to(raw)}, want {want}")
    return check


def get(url, auth=None, follow=False, data=None):
    """(status, headers, body); redirects are returned, not followed, unless follow."""
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None
    handlers = [urllib.request.HTTPSHandler(context=CTX)] + ([] if follow else [NoRedirect])
    req = urllib.request.Request(url, data=data)
    if data:
        req.add_header("Content-Type", "application/json")
    if auth:
        import base64
        req.add_header("Authorization", "Basic " + base64.b64encode(f"{auth[0]}:{auth[1]}".encode()).decode())
    try:
        r = urllib.request.build_opener(*handlers).open(req, timeout=30)
    except urllib.error.HTTPError as e:
        r = e
    return r.status, r.headers, r.read(200000).decode("utf-8", "replace")


def base(host):
    return f"https://{host}" if not PLAIN else f"http://{host}:{A.http_port}"


def tls_cert(host, port, real_port):
    def check():
        if real_port == 443 and PLAIN:
            raise Skip("no HTTPS listener (staged or --plain-http)")
        with socket.create_connection((host, port), timeout=30) as raw:
            with CTX.wrap_socket(raw, server_hostname=host) as s:
                cert = s.getpeercert()
        sans = {v.lower() for k, v in cert.get("subjectAltName", ()) if k == "DNS"}
        if missing := [h for h in HOSTS if h not in sans]:
            raise Fail(f"SANs lack {missing}")
        issuer = " ".join(v for rdn in cert["issuer"] for _, v in rdn)
        if A.issuer and A.issuer.lower() not in issuer.lower():
            raise Fail(f"issuer {issuer!r} does not contain {A.issuer!r}")
    return check


def smtp_auth(addr):
    def check():
        s = smtplib.SMTP_SSL(f"mail.{domain_of(addr)}", A.smtps_port, context=CTX, timeout=30,
                             local_hostname="acceptance.invalid")
        try:
            code, _ = s.login(addr, pw(addr))
        finally:
            s.close()
        if code != 235:
            raise Fail(f"AUTH answered {code}")
    return check


def imap_login(addr):
    def check():
        imap(addr).logout()
    return check


def dkim_check(dom):
    def check():
        try:
            import dkim  # dkimpy, imported lazily; never installed for you
        except ImportError:
            raise Skip("dkimpy not installed (pip install dkimpy dnspython)")
        sender = f"noreply@{dom}" if dom != "darksearch.xyz" else "jason@darksearch.xyz"
        dest = f"jason@{dom}"
        t = tok(f"dkim-{dom.split('.')[0]}")
        submit(sender, dest, t)
        raw = fetch(dest, t)
        if raw is None:
            raise Fail(f"{t} not delivered to {dest}")
        sig = re.search(rb"(?im)^DKIM-Signature:(?:[^\r\n]|\r?\n[ \t])*", raw)
        if not sig:
            raise Fail("message carries no DKIM-Signature")
        tags = dict(re.findall(r"(?:^|;)\s*(\w+)=([^;]*)", re.sub(r"\s+", "", sig.group().decode().split(":", 1)[1])))
        if tags.get("s") != "dkim" or tags.get("d") != dom:
            raise Fail(f"signature has s={tags.get('s')} d={tags.get('d')}, want s=dkim d={dom}")
        try:
            ok = dkim.verify(raw)
        except Exception as e:  # no DNS library, DNS failure, malformed key
            raise Fail(f"{type(e).__name__}: {e}")
        if not ok:
            raise Fail("dkim.verify() is False against live DNS")
    return check


def webmail_primary():
    status, _, body = get(f"{base(PRIMARY)}/webmail/", follow=True)
    if status != 200 or "bulwark" not in body.lower():
        raise Fail(f"status {status}, no Bulwark marker in body")


def webmail_redirect(host):
    def check():
        if A.mode == "staged":
            raise Skip("redirect is nginx-proxy's, not present in staged")
        status, h, _ = get(f"{base(host)}/webmail/")
        want = f"https://{PRIMARY}/webmail/"
        if status not in (301, 302) or not (h.get("Location") or "").startswith(want):
            raise Fail(f"status {status}, Location {h.get('Location')!r}, want redirect to {want}")
    return check


JMAP_ADMIN_CALL = (b'{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],'
                   b'"methodCalls":[["x:Domain/query",{},"0"]]}')


def admin_public_blocked():
    if A.mode == "staged":
        raise Skip("public only")
    user, password = A.admin_user, os.environ.get("STALWART_ADMIN_PASSWORD")
    if not password:
        raise Fail("STALWART_ADMIN_PASSWORD is unset; cannot prove the admin credential is refused")
    # positive control: the same call must work on the tailnet admin listener
    status, _, body = get(f"http://{A.admin_ip}:{A.admin_port}/jmap", auth=(user, password), data=JMAP_ADMIN_CALL)
    if status != 200 or '"x:Domain/query"' not in body:
        raise Fail(f"control failed: admin x:Domain/query on {A.admin_ip}:{A.admin_port} answered {status}")
    bad = []
    for host in HOSTS:
        status, _, _ = get(f"{base(host)}/jmap", auth=(user, password), data=JMAP_ADMIN_CALL)
        if status not in (401, 403):
            bad.append(f"admin call on {host} answered {status}, want 401/403")
        status, _, _ = get(f"{base(host)}/admin")
        if status not in (403, 404):
            bad.append(f"{host}/admin answered {status}, want 403/404")
        # control for a typo'd host or path: the host is routed and serves webmail
        status, _, _ = get(f"{base(host)}/webmail/")
        if status not in ((200,) if host == PRIMARY else (301, 302)):
            bad.append(f"control: {host}/webmail/ answered {status}")
    if bad:
        raise Fail("; ".join(bad))


def admin_tailnet_ok():
    status, _, _ = get(f"http://{A.admin_ip}:{A.admin_port}/admin", follow=True)
    if status != 200:
        raise Fail(f"status {status}")


def webmail_login(addr):
    def check():
        status, _, body = get(f"{base(PRIMARY)}/jmap/session", auth=(addr, pw(addr)))
        if status != 200 or addr.lower() not in body.lower():
            raise Fail(f"/jmap/session as {addr} answered {status}, body does not name the account")
    return check


def spam_junk():
    t = tok(f"{JUNK_SUBJECT}")
    inbound(A.spam_rcpt, t)  # an SMTP error here (bounce/reject) is a failure
    raw = fetch(A.spam_rcpt, t, "JUNK")
    if raw is None:
        left = fetch(A.spam_rcpt, t, "INBOX")
        raise Fail("landed in INBOX, not Junk" if left else f"{t} in neither Junk nor INBOX")


def spam_reject_gtube():
    # control: a clean message from the same sender to the same recipient is accepted
    t = tok("clean")
    try:
        inbound(A.spam_rcpt, t)
    except smtplib.SMTPException as e:
        raise Fail(f"control failed: clean message refused: {e}")
    for f in ("INBOX", "JUNK"):  # tidy up
        if fetch(A.spam_rcpt, t, f, wait=0):
            break
    try:
        inbound(A.spam_rcpt, GTUBE)  # GTUBE only matches in the Subject
    except smtplib.SMTPResponseException as e:
        text = e.smtp_error.decode("utf-8", "replace")
        if not 500 <= e.smtp_code < 600:
            raise Fail(f"answered {e.smtp_code}, want 5xx")
        if "spam" not in text.lower():
            raise Fail(f"{e.smtp_code} but the reply does not mention spam: {text!r}")
        return
    raise Fail("GTUBE was accepted")


def autoconfig():
    if A.mode == "staged":
        raise Skip("public only")
    for url in ("https://autoconfig.jasonernst.com/mail/config-v1.1.xml",
                f"https://{PRIMARY}/.well-known/autoconfig/mail/config-v1.1.xml"):
        try:
            status, _, body = get(url, follow=True)
        except Exception as e:
            raise Warn(f"{url}: {type(e).__name__}: {e}")
        if status != 200 or PRIMARY not in body or "465" not in body or "993" not in body:
            raise Warn(f"{url}: status {status}, no {PRIMARY} on 465/993")


def checks():
    out = []
    for h in HOSTS:
        for real, port in ((465, A.smtps_port), (993, A.imaps_port), (443, 443)):
            out.append((f"tls_cert_{h}_{real}", tls_cert(h, port, real)))
    out += [(f"smtp_auth_{a}", smtp_auth(a)) for a in MAILBOXES]
    out += [(f"imap_login_{a}", imap_login(a)) for a in IMAP_ACCOUNTS]
    out += [(f"alias_{a}", delivers([(a, a)], d, "alias")) for a, d in ALIASES.items()]
    # the random local part is no account or alias: Delivered-To is the catch-all mailbox, not it
    out += [(f"catchall_{d}", delivers([(f"zz-{secrets.token_hex(6)}@{d}", f"jason@{d}")], f"jason@{d}", "catchall")) for d in DOMAINS]
    out += [("plus_address", delivers([("jason+acc@rustd.xyz", "jason@rustd.xyz"), ("contact+acc@rustd.xyz", "contact@rustd.xyz")],
                                      "jason@rustd.xyz", "plus")),
            ("mixed_case", delivers([("Jason@RustD.xyz", "jason@rustd.xyz"), ("Contact@RustD.xyz", "contact@rustd.xyz")],
                                    "jason@rustd.xyz", "case"))]
    out += [(f"dkim_{d}", dkim_check(d)) for d in DOMAINS]
    out += [("webmail_primary", webmail_primary)]
    out += [(f"webmail_login_jason@{d}", webmail_login(f"jason@{d}")) for d in DOMAINS]
    out += [(f"webmail_redirect_{h}", webmail_redirect(h)) for h in HOSTS[1:]]
    out += [("admin_public_blocked", admin_public_blocked), ("admin_tailnet_ok", admin_tailnet_ok),
            ("spam_junk", spam_junk), ("spam_reject_gtube", spam_reject_gtube), ("autoconfig", autoconfig)]
    return out


def main():
    global A, CTX, PLAIN
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mode", choices=["staged", "public"], required=True,
                   help="staged: tailnet IP, ports 2525/4465/9993, http on 8080/8081; public: DNS, 25/465/993, https")
    p.add_argument("--only", nargs="+", metavar="CHECK", help="run checks whose name equals or starts with one of these")
    p.add_argument("--connect", metavar="IP",
                   help="send every mail.* name to this IP (staged default 100.98.223.44, the tailnet IP; public default DNS)")
    p.add_argument("--ports", metavar="SMTP,SUBMISSIONS,IMAPS", help="override the mode's mail ports, e.g. 2525,4465,9993")
    p.add_argument("--plain-http", action="store_true", help="public mode over plain HTTP on --http-port (local fixture only)")
    p.add_argument("--admin-ip", metavar="IP", help="host of the admin listener (default: --connect)")
    p.add_argument("--http-port", type=int, default=8080, help="staged plain-HTTP listener (default %(default)s)")
    p.add_argument("--admin-port", type=int, default=8081, help="admin listener on --connect (default %(default)s)")
    p.add_argument("--admin-user", default="stalwart-admin@rustd.xyz", help="Stalwart admin login for admin_public_blocked (default %(default)s)")
    p.add_argument("--cafile", help="trust this PEM instead of the system CAs (local self-signed fixture)")
    p.add_argument("--issuer", default="Let's Encrypt", help="substring the cert issuer must contain; '' skips (default %(default)s)")
    p.add_argument("--sender", default="acceptance@example.org", help="MAIL FROM for the port-25 spam checks (default %(default)s)")
    p.add_argument("--spam-rcpt", default="jason@jasonernst.com", help="mailbox the spam checks target (default %(default)s)")
    p.add_argument("--wait", type=int, default=90, help="seconds to poll IMAP for each delivery (default %(default)s)")
    A = p.parse_args()
    ports = [int(x) for x in A.ports.split(",")] if A.ports else ([25, 465, 993] if A.mode == "public" else [2525, 4465, 9993])
    A.smtp_port, A.smtps_port, A.imaps_port = ports
    CTX = ssl.create_default_context(cafile=A.cafile)
    A.connect = A.connect or ("100.98.223.44" if A.mode == "staged" else None)
    A.admin_ip = A.admin_ip or A.connect or "100.98.223.44"
    PLAIN = A.mode == "staged" or A.plain_http
    if A.connect:  # real names for SNI/Host/cert checks, the chosen IP for the socket
        real = socket.getaddrinfo
        socket.getaddrinfo = lambda h, *a, **k: real(A.connect if h in HOSTS else h, *a, **k)
    todo = checks()
    if A.only:
        todo = [(n, f) for n, f in todo if any(n == o or n.startswith(o) for o in A.only)]
        if not todo:
            sys.exit(f"no check matches {A.only}")
    failed = False
    for name, fn in todo:
        try:
            fn()
            print(f"PASS {name}")
        except Skip as e:
            print(f"SKIP {name}: {e}")
        except Warn as e:
            print(f"WARN {name}: {e}")
        except Exception as e:
            failed = True
            print(f"FAIL {name}: {e if isinstance(e, Fail) else f'{type(e).__name__}: {e}'}")
        sys.stdout.flush()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
