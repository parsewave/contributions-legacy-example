"""Runs BankBatchJob and validates inputs, outputs, and DB state."""
import hashlib
import os
import secrets
import shutil
import subprocess
import zipfile
from datetime import date
from decimal import Decimal, ROUND_HALF_EVEN
from pathlib import Path
TWOP = Decimal("0.01")
SIXP = Decimal("0.000001")
TENP = Decimal("0.0000000001")
DAYS = Decimal("365")
def _classfile_utf8_strings(raw: bytes) -> list[str]:
    if raw[:4] != b"\xCA\xFE\xBA\xBE":
        return []
    out = []
    cp_count = int.from_bytes(raw[8:10], "big")
    i = 1
    p = 10
    while i < cp_count:
        tag = raw[p]
        p += 1
        if tag == 1:  # Utf8
            ln = int.from_bytes(raw[p:p + 2], "big")
            p += 2
            out.append(raw[p:p + ln].decode("utf-8", "replace"))
            p += ln
        elif tag in (3, 4):  # Integer, Float
            p += 4
        elif tag in (5, 6):  # Long, Double (take two entries)
            p += 8
            i += 1
        elif tag in (7, 8, 16, 19, 20):  # Class, String, MethodType, Module, Package
            p += 2
        elif tag in (9, 10, 11, 12, 18):  # Field/Method/Interface/NameAndType/InvokeDynamic
            p += 4
        elif tag == 15:  # MethodHandle
            p += 3
        else:
            break
        i += 1
    return out
def _build_jdbc_probe_agent(build_dir: Path) -> Path:
    agent_src_dir = build_dir / "src"
    agent_classes_dir = build_dir / "classes"
    agent_src_dir.mkdir(parents=True, exist_ok=True)
    agent_classes_dir.mkdir(parents=True, exist_ok=True)
    src = agent_src_dir / "JdbcProbeAgent.java"
    src.write_text(
        "package tbprobe; import java.io.FileOutputStream; import java.io.IOException; import java.lang.instrument.Instrumentation; import java.sql.Connection; import java.sql.Driver; import java.sql.DriverManager; import java.sql.DriverPropertyInfo; import java.sql.SQLException; import java.sql.SQLFeatureNotSupportedException; import java.util.Enumeration; import java.util.Properties; import java.util.logging.Logger;\n"
        "public final class JdbcProbeAgent { public static void premain(String agentArgs, Instrumentation inst) throws Exception { String markerPath = (agentArgs==null||agentArgs.length()==0)?\"/tmp/jdbc_probe.txt\":agentArgs; Enumeration<Driver> drivers = DriverManager.getDrivers(); while (drivers.hasMoreElements()) { Driver d = drivers.nextElement(); if (\"org.h2.Driver\".equals(d.getClass().getName())) { DriverManager.deregisterDriver(d); } } DriverManager.registerDriver(new RecordingH2Driver(markerPath)); }\n"
        "private static final class RecordingH2Driver implements Driver { private final String markerPath; private final org.h2.Driver delegate = new org.h2.Driver(); RecordingH2Driver(String markerPath){this.markerPath=markerPath;} public boolean acceptsURL(String url) throws SQLException { return url!=null && url.startsWith(\"jdbc:h2:\"); }\n"
        "public Connection connect(String url, Properties info) throws SQLException { if (!acceptsURL(url)) return null; String user = info==null?null:info.getProperty(\"user\"); String pass = info==null?null:info.getProperty(\"password\"); record(url,user,pass); return delegate.connect(url, info);} public DriverPropertyInfo[] getPropertyInfo(String url, Properties info) throws SQLException { return delegate.getPropertyInfo(url, info);} public int getMajorVersion(){return delegate.getMajorVersion();} public int getMinorVersion(){return delegate.getMinorVersion();} public boolean jdbcCompliant(){return delegate.jdbcCompliant();} public Logger getParentLogger() throws SQLFeatureNotSupportedException { return Logger.getLogger(\"global\"); }\n"
        "private void record(String url,String user,String pass){ FileOutputStream out=null; try{ out=new FileOutputStream(markerPath); out.write(url.getBytes(\"UTF-8\")); out.write('\\n'); out.write((user==null?\"\":user).getBytes(\"UTF-8\")); out.write('\\n'); out.write((pass==null?\"\":pass).getBytes(\"UTF-8\")); } catch(IOException ignored){} finally{ if(out!=null){ try{out.close();}catch(IOException ignored2){} } } } } }\n",
        encoding="utf-8",
    )
    manifest = build_dir / "MANIFEST.MF"
    manifest.write_text(
        "Manifest-Version: 1.0\nPremain-Class: tbprobe.JdbcProbeAgent\n",
        encoding="utf-8",
    )
    subprocess.check_call(
        [
            "javac",
            "-source",
            "1.7",
            "-target",
            "1.7",
            "-encoding",
            "UTF-8",
            "-cp",
            "/opt/legacy-lib/*",
            "-d",
            str(agent_classes_dir),
            str(src),
        ]
    )
    agent_jar = build_dir / "jdbc-probe-agent.jar"
    if agent_jar.exists():
        agent_jar.unlink()
    subprocess.check_call(["jar", "cfm", str(agent_jar), str(manifest), "-C", str(agent_classes_dir), "."])
    return agent_jar
def _build_db_audit_check(build_dir: Path) -> Path:
    src_dir = build_dir / "src"
    classes_dir = build_dir / "classes"
    src_dir.mkdir(parents=True, exist_ok=True)
    classes_dir.mkdir(parents=True, exist_ok=True)
    src = src_dir / "DbAuditCheck.java"
    src.write_text(
        "import java.sql.Connection; import java.sql.DatabaseMetaData; import java.sql.DriverManager; import java.sql.ResultSet; import java.sql.Statement;\n"
        "public final class DbAuditCheck { public static void main(String[] args) throws Exception { if (args.length != 5) throw new IllegalArgumentException(\"expected 5 args\"); String expectedBizDate = args[0]; int expectedAccounts = Integer.parseInt(args[1]); int expectedValidTxs = Integer.parseInt(args[2]); int expectedSkippedTxs = Integer.parseInt(args[3]); String expectedMd5 = args[4]; Class.forName(\"org.h2.Driver\"); Connection conn = DriverManager.getConnection(\"jdbc:h2:/app/output/bankdb;MODE=DB2;IFEXISTS=TRUE\", \"sa\", \"\"); try { assertTable(conn,\"ACCOUNTS\"); assertTable(conn,\"TXNS\"); assertTable(conn,\"RUN_AUDIT\"); assertCount(conn,\"ACCOUNTS\", expectedAccounts); int txCount = count(conn, \"TXNS\"); Statement st = conn.createStatement(); ResultSet rs = st.executeQuery(\"SELECT MIN(row_num), MAX(row_num), COUNT(DISTINCT row_num) FROM TXNS\"); rs.next(); int minRow = rs.getInt(1); int maxRow = rs.getInt(2); int distinctRow = rs.getInt(3); rs.close(); st.close(); if (minRow != 1 || maxRow != txCount || distinctRow != txCount) throw new RuntimeException(\"TXNS row_num must be 1..N without gaps\"); st = conn.createStatement(); rs = st.executeQuery(\"SELECT jdbc_url,biz_date,accounts,valid_txs,skipped_txs,report_md5 FROM RUN_AUDIT\"); if (!rs.next()) throw new RuntimeException(\"RUN_AUDIT missing row\"); String jdbcUrl = rs.getString(1); String bizDate = rs.getString(2); int accounts = rs.getInt(3); int validTxs = rs.getInt(4); int skippedTxs = rs.getInt(5); String md5 = rs.getString(6); if (jdbcUrl == null || jdbcUrl.indexOf(\"jdbc:h2:\") != 0 || jdbcUrl.indexOf(\"/app/output/bankdb\") < 0 || jdbcUrl.indexOf(\"MODE=DB2\") < 0) throw new RuntimeException(\"RUN_AUDIT.jdbc_url must include jdbc:h2:, /app/output/bankdb, and MODE=DB2\"); if (!expectedBizDate.equals(bizDate)) throw new RuntimeException(\"RUN_AUDIT.biz_date mismatch\"); if (accounts != expectedAccounts) throw new RuntimeException(\"RUN_AUDIT.accounts mismatch\"); if (validTxs != expectedValidTxs) throw new RuntimeException(\"RUN_AUDIT.valid_txs mismatch\"); if (skippedTxs != expectedSkippedTxs) throw new RuntimeException(\"RUN_AUDIT.skipped_txs mismatch\"); if (!expectedMd5.equals(md5)) throw new RuntimeException(\"RUN_AUDIT.report_md5 mismatch\"); if (rs.next()) throw new RuntimeException(\"RUN_AUDIT must have exactly one row\"); rs.close(); st.close(); } finally { conn.close(); } }\n"
        "private static void assertTable(Connection conn, String name) throws Exception { DatabaseMetaData md = conn.getMetaData(); ResultSet rs = md.getTables(null, null, name, null); try { if (!rs.next()) throw new RuntimeException(\"missing table: \" + name); } finally { rs.close(); } }\n"
        "private static int count(Connection conn, String table) throws Exception { Statement st = conn.createStatement(); ResultSet rs = st.executeQuery(\"SELECT COUNT(*) FROM \" + table); rs.next(); int out = rs.getInt(1); rs.close(); st.close(); return out; }\n"
        "private static void assertCount(Connection conn, String table, int expected) throws Exception { int got = count(conn, table); if (got != expected) throw new RuntimeException(table + \" row count mismatch\"); } }\n",
        encoding="utf-8",
    )
    subprocess.check_call(
        [
            "javac",
            "-source",
            "1.7",
            "-target",
            "1.7",
            "-encoding",
            "UTF-8",
            "-cp",
            "/opt/legacy-lib/*",
            "-d",
            str(classes_dir),
            str(src),
        ]
    )
    return classes_dir
def _read_csv(path: Path) -> tuple[list[str], list[list[str]]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    header = lines[0].split(",")
    rows = [ln.split(",", -1) for ln in lines[1:] if ln.strip()]
    return header, rows
def _parse_date(value: str) -> date:
    return date.fromisoformat(value)
def _best_rate(rates: dict[str, list[tuple[date, Decimal]]], from_ccy: str, to_ccy: str, eff: date) -> Decimal | None:
    direct = None
    direct_date = None
    for d, r in rates.get(f"{from_ccy}->{to_ccy}", []):
        if d <= eff:
            direct = r
            direct_date = d
        else:
            break
    reverse = None
    reverse_date = None
    for d, r in rates.get(f"{to_ccy}->{from_ccy}", []):
        if d <= eff:
            reverse = r
            reverse_date = d
        else:
            break
    if direct is None and reverse is None:
        return None
    if reverse is None or (direct is not None and direct_date >= reverse_date):
        return direct
    if reverse == 0:
        return None
    return (Decimal("1") / reverse).quantize(TENP, rounding=ROUND_HALF_EVEN)


def _fx_rate(
    rates: dict[str, list[tuple[date, Decimal]]],
    pivots: list[str],
    from_ccy: str,
    to_ccy: str,
    eff: date,
) -> Decimal | None:
    if from_ccy == to_ccy:
        return Decimal("1")
    out = _best_rate(rates, from_ccy, to_ccy, eff)
    if out is not None:
        return out
    for pivot in pivots:
        if pivot in (from_ccy, to_ccy):
            continue
        leg1 = _best_rate(rates, from_ccy, pivot, eff)
        if leg1 is None:
            continue
        leg2 = _best_rate(rates, pivot, to_ccy, eff)
        if leg2 is None:
            continue
        return (leg1 * leg2).quantize(TENP, rounding=ROUND_HALF_EVEN)
    return None
def _apply_fee(amt: Decimal, rule: dict | None) -> Decimal:
    if rule is None:
        return amt.quantize(TWOP, rounding=ROUND_HALF_EVEN)
    sign = amt.compare(Decimal("0"))
    applies = rule["applies_to"] == "ALL" and sign != 0
    applies = applies or (rule["applies_to"] == "DEBIT" and sign < 0)
    applies = applies or (rule["applies_to"] == "CREDIT" and sign > 0)
    if not applies:
        return amt.quantize(TWOP, rounding=ROUND_HALF_EVEN)
    fee = (rule["flat_fee"] + amt.copy_abs() * rule["pct_fee"]).quantize(TWOP, rounding=ROUND_HALF_EVEN)
    if fee < rule["min_fee"]:
        fee = rule["min_fee"]
    if fee > rule["max_fee"]:
        fee = rule["max_fee"]
    fee = fee.quantize(TWOP, rounding=ROUND_HALF_EVEN)
    return (amt - fee).quantize(TWOP, rounding=ROUND_HALF_EVEN)
def _compute_expected() -> tuple[str, str, str, int, int, str, int, str]:
    biz_date = Path("/app/data/biz_date.txt").read_text(encoding="utf-8").strip()
    biz = _parse_date(biz_date)
    acc_header, acc_rows = _read_csv(Path("/app/data/accounts.csv"))
    assert acc_header == [
        "account_id",
        "opened_at",
        "start_balance",
        "base_apr",
        "promo_apr",
        "promo_days",
        "tier_threshold",
        "tier_apr",
        "currency",
        "fee_plan",
    ]
    accounts: dict[str, dict] = {}
    for row in acc_rows:
        accounts[row[0]] = {
            "opened_at": _parse_date(row[1]),
            "start_balance": Decimal(row[2]),
            "base_apr": Decimal(row[3]),
            "promo_apr": Decimal(row[4]),
            "promo_days": int(row[5]),
            "tier_threshold": Decimal(row[6]),
            "tier_apr": Decimal(row[7]),
            "currency": row[8],
            "fee_plan": row[9],
        }
    tx_header, tx_rows = _read_csv(Path("/app/data/transactions.csv"))
    assert tx_header == ["tx_id", "account_id", "effective_date", "amount", "currency", "status", "reversal_of"]
    txs = []
    for i, row in enumerate(tx_rows, start=1):
        txs.append(
            {
                "row_num": i,
                "tx_id": row[0],
                "account_id": row[1],
                "effective_date": _parse_date(row[2]),
                "amount": Decimal(row[3]),
                "currency": row[4],
                "status": row[5],
                "reversal_of": row[6] or None,
            }
        )
    fx_header, fx_rows = _read_csv(Path("/app/data/fx_rates.csv"))
    assert fx_header == ["rate_date", "from_ccy", "to_ccy", "rate"]
    rates: dict[str, list[tuple[date, Decimal]]] = {}
    for row in fx_rows:
        rates.setdefault(f"{row[1]}->{row[2]}", []).append((_parse_date(row[0]), Decimal(row[3])))
    for key in rates:
        rates[key].sort(key=lambda x: x[0])
    pivot_header, pivot_rows = _read_csv(Path("/app/data/fx_pivots.csv"))
    assert pivot_header == ["pivot"]
    pivots = [row[0] for row in pivot_rows if row[0]]
    fee_header, fee_rows = _read_csv(Path("/app/data/fee_rules.csv"))
    assert fee_header == ["fee_plan", "applies_to", "flat_fee", "pct_fee", "min_fee", "max_fee"]
    fees: dict[str, dict] = {}
    for row in fee_rows:
        fees[row[0]] = {
            "applies_to": row[1],
            "flat_fee": Decimal(row[2]),
            "pct_fee": Decimal(row[3]),
            "min_fee": Decimal(row[4]),
            "max_fee": Decimal(row[5]),
        }
    first_row_by_tx_id: dict[str, int] = {}
    for row in txs:
        first_row_by_tx_id.setdefault(row["tx_id"], row["row_num"])
    reversed_rows: set[int] = set()
    reversal_missing_rows: set[int] = set()
    for row in txs:
        if not row["reversal_of"]:
            continue
        ref = first_row_by_tx_id.get(row["reversal_of"])
        if ref is None:
            reversal_missing_rows.add(row["row_num"])
        else:
            reversed_rows.add(row["row_num"])
            reversed_rows.add(ref)
    sums: dict[str, Decimal] = {}
    exceptions: list[tuple[int, str, str]] = []
    valid = 0
    for row in txs:
        reason = None
        first_row = first_row_by_tx_id.get(row["tx_id"])
        if row["row_num"] in reversed_rows:
            reason = "REVERSED"
        elif row["row_num"] in reversal_missing_rows:
            reason = "REVERSAL_MISSING"
        acct = accounts.get(row["account_id"])
        amount = row["amount"]
        if reason is None:
            if acct is None:
                reason = "FX_MISSING"
            elif row["currency"] != acct["currency"]:
                rate = _fx_rate(rates, pivots, row["currency"], acct["currency"], row["effective_date"])
                if rate is None:
                    reason = "FX_MISSING"
                else:
                    amount = amount * rate
        if reason is None:
            if row["effective_date"] > biz:
                reason = "AFTER_BIZ_DATE"
            elif row["status"] != "POSTED":
                reason = row["status"]
            elif first_row is not None and first_row != row["row_num"]:
                reason = "DUPLICATE"
        if reason is not None:
            exceptions.append((row["row_num"], row["tx_id"], reason))
            continue
        adjusted = _apply_fee(amount, fees.get(acct["fee_plan"]))
        sums[row["account_id"]] = sums.get(row["account_id"], Decimal("0.00")) + adjusted
        valid += 1
    exceptions.sort(key=lambda x: x[0])
    ex_lines = ["row_num,tx_id,reason"]
    ex_lines.extend([f"{r},{t},{reason}" for r, t, reason in exceptions])
    exceptions_csv = "\n".join(ex_lines) + "\n"
    total_interest = Decimal("0.00")
    interest_lines = ["account_id,biz_date,eod_balance,apr,daily_interest"]
    for account_id in sorted(accounts.keys()):
        acc = accounts[account_id]
        delta = sums.get(account_id, Decimal("0.00"))
        eod = (acc["start_balance"] + delta).quantize(TWOP, rounding=ROUND_HALF_EVEN)
        apr = acc["base_apr"]
        if eod >= acc["tier_threshold"]:
            apr += acc["tier_apr"]
        if acc["promo_days"] > 0 and (biz - acc["opened_at"]).days < acc["promo_days"]:
            apr += acc["promo_apr"]
        apr_out = apr.quantize(SIXP, rounding=ROUND_HALF_EVEN)
        principal = eod if eod >= 0 else Decimal("0.00")
        daily_raw = (principal * apr_out / DAYS).quantize(TENP, rounding=ROUND_HALF_EVEN)
        daily = daily_raw.quantize(TWOP, rounding=ROUND_HALF_EVEN)
        total_interest += daily_raw
        interest_lines.append(
            f"{account_id},{biz_date},{eod:.2f},{apr_out:.6f},{daily:.2f}"
        )
    interest_csv = "\n".join(interest_lines) + "\n"
    total_interest = total_interest.quantize(TWOP, rounding=ROUND_HALF_EVEN)
    report_md5 = hashlib.md5(interest_csv.encode("utf-8")).hexdigest()
    stats_json = (
        f'{{"biz_date":"{biz_date}","accounts":{len(accounts)},"valid_txs":{valid},'
        f'"skipped_txs":{len(exceptions)},"total_interest":"{total_interest:.2f}",'
        f'"report_md5":"{report_md5}"}}'
    )
    return interest_csv, exceptions_csv, stats_json, valid, len(exceptions), biz_date, len(accounts), report_md5
def test_outputs_via_java_validator():
    """Runs the job end-to-end and validates outputs + key runtime constraints."""
    out_dir = Path("/app/output")
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    data_files = {
        "/app/data/accounts.csv": "505829c96c9fa568cf70abf7c52247d5",
        "/app/data/transactions.csv": "ad100f16f2e9b52929da8eca55b3edad",
        "/app/data/biz_date.txt": "4a58c5b49dafc91047e9f999ede44581",
        "/app/data/fx_rates.csv": "d351af4cc717a6d8d9353f53d8616c05",
        "/app/data/fx_pivots.csv": "31e9e031a576af3d943424f47d9f9390",
        "/app/data/fee_rules.csv": "a2a8a66a3db722b2f4a051612c8e8bd7",
    }
    for path, expected_md5 in data_files.items():
        got = hashlib.md5(Path(path).read_bytes()).hexdigest()
        assert got == expected_md5, f"input modified before run: {path}"
    job_jar = Path("/app/job.jar")
    assert job_jar.exists(), "/app/job.jar is missing"
    assert job_jar.stat().st_size > 0, "/app/job.jar is empty"
    with zipfile.ZipFile(job_jar, "r") as zf:
        class_entries = [n for n in zf.namelist() if n.endswith(".class")]
        assert class_entries, "/app/job.jar has no class files"
        class_bytes = []
        for entry in class_entries:
            raw = zf.read(entry)
            assert raw[:4] == b"\xCA\xFE\xBA\xBE", "invalid class file in /app/job.jar"
            major = int.from_bytes(raw[6:8], "big")
            assert major == 51, f"/app/job.jar must be Java 7 bytecode (major=51), got {major}"
            class_bytes.append(raw)
        literals = []
        for blob in class_bytes:
            literals.extend(_classfile_utf8_strings(blob))
        jdbc_literals = [
            s for s in literals
            if s.startswith("jdbc:h2:") and "/app/output/bankdb" in s and "MODE=DB2" in s
        ]
        assert jdbc_literals, "jar must include a JDBC URL literal with /app/output/bankdb and MODE=DB2"
        assert len(set(jdbc_literals)) == 1, "jar must include exactly one JDBC URL literal value"
        assert len(jdbc_literals) == 1, "jar must include the JDBC URL literal only once"
    agent_build = Path("/tmp/jdbc_probe_agent")
    if agent_build.exists():
        shutil.rmtree(agent_build)
    agent_build.mkdir(parents=True, exist_ok=True)
    agent_jar = _build_jdbc_probe_agent(agent_build)
    legacy_cp = "/opt/legacy-lib/*"
    env = os.environ.copy()

    def run_job(marker_path: Path) -> None:
        env["JAVA_TOOL_OPTIONS"] = f"-javaagent:{agent_jar}={marker_path}"
        subprocess.check_call(["java", "-cp", f"{job_jar}:{legacy_cp}", "BankBatchJob"], cwd="/app", env=env)
        marker_text = marker_path.read_text(encoding="utf-8") if marker_path.exists() else ""
        marker_lines = marker_text.splitlines()
        url = marker_lines[0] if len(marker_lines) > 0 else ""
        user = marker_lines[1] if len(marker_lines) > 1 else ""
        password = marker_lines[2] if len(marker_lines) > 2 else ""
        assert url.startswith("jdbc:h2:"), "job must open an H2 JDBC connection at runtime"
        assert "MODE=DB2" in url, "opened JDBC URL must include MODE=DB2"
        assert "/app/output/bankdb" in url, "opened JDBC URL must use the /app/output/bankdb database file"
        assert url in jdbc_literals, "opened JDBC URL must match a single literal in the jar"
        assert user == "sa", "H2 connection user must be 'sa'"
        assert password == "", "H2 connection password must be empty"
    run_job(agent_build / f"marker_{secrets.token_hex(8)}.txt")
    first_interest = Path("/app/output/interest.csv").read_bytes()
    first_ex = Path("/app/output/exceptions.csv").read_bytes()
    first_stats = Path("/app/output/stats.json").read_bytes()
    run_job(agent_build / f"marker_{secrets.token_hex(8)}.txt")
    assert Path("/app/output/interest.csv").read_bytes() == first_interest, "interest.csv must be identical across re-runs"
    assert Path("/app/output/exceptions.csv").read_bytes() == first_ex, "exceptions.csv must be identical across re-runs"
    assert Path("/app/output/stats.json").read_bytes() == first_stats, "stats.json must be identical across re-runs"
    (
        expected_interest,
        expected_exceptions,
        expected_stats,
        expected_valid,
        expected_skipped,
        expected_biz,
        expected_accounts,
        expected_report_md5,
    ) = _compute_expected()
    assert Path("/app/output/interest.csv").read_text(encoding="utf-8") == expected_interest, "interest.csv mismatch"
    assert Path("/app/output/exceptions.csv").read_text(encoding="utf-8") == expected_exceptions, "exceptions.csv mismatch"
    assert Path("/app/output/stats.json").read_text(encoding="utf-8") == expected_stats, "stats.json mismatch"
    db_file = Path("/app/output/bankdb.h2.db")
    assert db_file.exists(), "/app/output/bankdb.h2.db is missing"
    assert db_file.stat().st_size > 0, "/app/output/bankdb.h2.db is empty"
    actual_md5 = hashlib.md5(Path("/app/output/interest.csv").read_bytes()).hexdigest()
    assert actual_md5 == expected_report_md5, "report_md5 mismatch"
    audit_build = Path("/tmp/db_audit_check")
    if audit_build.exists():
        shutil.rmtree(audit_build)
    audit_build.mkdir(parents=True, exist_ok=True)
    audit_classes = _build_db_audit_check(audit_build)
    subprocess.check_call(
        [
            "java",
            "-cp",
            f"{audit_classes}:{legacy_cp}",
            "DbAuditCheck",
            expected_biz,
            str(expected_accounts),
            str(expected_valid),
            str(expected_skipped),
            expected_report_md5,
        ]
    )
    for path, expected_md5 in data_files.items():
        got = hashlib.md5(Path(path).read_bytes()).hexdigest()
        assert got == expected_md5, f"input modified after run: {path}"
    src = Path(__file__).with_name("OutputValidator.java")
    assert src.exists(), "OutputValidator.java missing"
    build = Path("/tmp/validator")
    if build.exists():
        shutil.rmtree(build)
    build.mkdir(parents=True, exist_ok=True)
    subprocess.check_call(
        ["javac", "-source", "1.7", "-target", "1.7", "-encoding", "UTF-8", "-cp", legacy_cp, "-d", str(build), str(src)]
    )
    subprocess.check_call(["java", "-cp", f"{build}:{legacy_cp}", "OutputValidator"])
