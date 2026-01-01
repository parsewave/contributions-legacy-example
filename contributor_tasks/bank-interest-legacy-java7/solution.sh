#!/bin/bash
set -euo pipefail
WORK=/tmp/bank_job
BUILD="$WORK/build"
SRC="$WORK/src"
rm -rf "$WORK"
mkdir -p "$BUILD" "$SRC"
cat >"$SRC/BankBatchJob.java" <<'JAVA'
import java.io.*;
import java.math.*;
import java.nio.charset.Charset;
import java.security.*;
import java.sql.*;
import java.text.*;
import java.util.*;
public class BankBatchJob {
  private static final Charset UTF8 = Charset.forName("UTF-8");
  private static final TimeZone UTC = TimeZone.getTimeZone("UTC");
  private static final SimpleDateFormat DF = new SimpleDateFormat("yyyy-MM-dd", Locale.US);
  private static final BigDecimal DAYS = new BigDecimal("365");
  private static final String JDBC_URL = "jdbc:h2:file:/app/output/bankdb;MODE=DB2";
  private static final String DB_USER = "sa";
  private static final String DB_PASS = "";
  private static final File ACCOUNTS = new File("/app/data/accounts.csv");
  private static final File TXS = new File("/app/data/transactions.csv");
  private static final File FX = new File("/app/data/fx_rates.csv");
  private static final File FX_PIVOTS = new File("/app/data/fx_pivots.csv");
  private static final File FEES = new File("/app/data/fee_rules.csv");
  private static final File BIZ_DATE = new File("/app/data/biz_date.txt");
  private static final File OUT_DIR = new File("/app/output");
  private static final File OUT_INTEREST = new File("/app/output/interest.csv");
  private static final File OUT_EXCEPTIONS = new File("/app/output/exceptions.csv");
  private static final File OUT_STATS = new File("/app/output/stats.json");
  static { DF.setLenient(false); DF.setTimeZone(UTC); }
  static final class Account {
    final String id, currency, feePlan;
    final java.util.Date opened;
    final BigDecimal start, base, promo, tierThr, tierApr;
    final int promoDays;
    Account(String id, java.util.Date opened, BigDecimal start, BigDecimal base, BigDecimal promo, int promoDays,
            BigDecimal tierThr, BigDecimal tierApr, String currency, String feePlan) {
      this.id=id; this.opened=opened; this.start=start; this.base=base; this.promo=promo; this.promoDays=promoDays;
      this.tierThr=tierThr; this.tierApr=tierApr; this.currency=currency; this.feePlan=feePlan;
    }
  }
  static final class TxnRow {
    final int row; final String txId, acct, currency, status, revOf; final java.util.Date eff; final BigDecimal amt;
    TxnRow(int row, String txId, String acct, java.util.Date eff, BigDecimal amt, String currency, String status, String revOf) {
      this.row=row; this.txId=txId; this.acct=acct; this.eff=eff; this.amt=amt; this.currency=currency; this.status=status; this.revOf=revOf;
    }
  }
  static final class Rate { final long day; final BigDecimal rate; Rate(long day, BigDecimal rate){this.day=day;this.rate=rate;} }
  static final class FeeRule {
    final String applies; final BigDecimal flat, pct, min, max;
    FeeRule(String applies, BigDecimal flat, BigDecimal pct, BigDecimal min, BigDecimal max){
      this.applies=applies; this.flat=flat; this.pct=pct; this.min=min; this.max=max;
    }
  }
  static final class Ex { final int row; final String txId, reason; Ex(int row,String txId,String reason){this.row=row;this.txId=txId;this.reason=reason;} }
  static final class Interest { final String md5; final BigDecimal total; Interest(String md5, BigDecimal total){this.md5=md5;this.total=total;} }
  public static void main(String[] args) throws Exception {
    TimeZone.setDefault(UTC);
    prepOut();
    String bizStr = readLine(BIZ_DATE);
    java.util.Date biz = parseDate(bizStr);
    List<Account> accounts = readAccounts();
    Map<String, Account> accountById = new HashMap<String, Account>();
    for (Account a : accounts) accountById.put(a.id, a);
    List<TxnRow> txs = readTxns();
    Map<String, List<Rate>> fxRates = readFxRates();
    List<String> pivots = readPivots();
    Map<String, FeeRule> feeRules = readFeeRules();
    Map<String, BigDecimal> sums = new HashMap<String, BigDecimal>();
    List<Ex> exs = new ArrayList<Ex>();
    int validTxs = applyRules(biz, txs, accountById, fxRates, pivots, feeRules, sums, exs);
    int skippedTxs = exs.size();
    writeExceptions(exs);
    Interest interest = writeInterest(bizStr, biz, accounts, sums);
    writeStats(bizStr, accounts.size(), validTxs, skippedTxs, interest.total, interest.md5);
    buildDb(bizStr, accounts, txs, validTxs, skippedTxs, interest.md5);
  }
  private static void prepOut() {
    OUT_DIR.mkdirs();
    File[] files = new File[] {
      OUT_INTEREST, OUT_EXCEPTIONS, OUT_STATS,
      new File("/app/output/bankdb.h2.db"),
      new File("/app/output/bankdb.lock.db"),
      new File("/app/output/bankdb.trace.db")
    };
    for (File f : files) if (f.exists()) f.delete();
  }
  private static int applyRules(java.util.Date biz, List<TxnRow> txs, Map<String, Account> accounts,
                                Map<String, List<Rate>> rates, List<String> pivots, Map<String, FeeRule> fees,
                                Map<String, BigDecimal> sums, List<Ex> exs) {
    Map<String, Integer> first = new HashMap<String, Integer>();
    for (TxnRow t : txs) if (!first.containsKey(t.txId)) first.put(t.txId, Integer.valueOf(t.row));
    Set<Integer> reversed = new HashSet<Integer>();
    Set<Integer> missing = new HashSet<Integer>();
    for (TxnRow t : txs) {
      if (t.revOf == null) continue;
      Integer ref = first.get(t.revOf);
      if (ref == null) missing.add(Integer.valueOf(t.row));
      else { reversed.add(Integer.valueOf(t.row)); reversed.add(ref); }
    }
    int valid = 0;
    for (TxnRow t : txs) {
      String reason = null;
      Integer firstRow = first.get(t.txId);
      if (reversed.contains(Integer.valueOf(t.row))) reason = "REVERSED";
      else if (missing.contains(Integer.valueOf(t.row))) reason = "REVERSAL_MISSING";
      Account a = accounts.get(t.acct);
      BigDecimal amt = t.amt;
      if (reason == null) {
        if (a == null) {
          reason = "FX_MISSING";
        } else if (!t.currency.equals(a.currency)) {
          BigDecimal rate = fxRate(rates, pivots, t.currency, a.currency, t.eff);
          if (rate == null) reason = "FX_MISSING";
          else amt = amt.multiply(rate);
        }
      }
      if (reason == null) {
        if (t.eff.after(biz)) reason = "AFTER_BIZ_DATE";
        else if (!"POSTED".equals(t.status)) reason = t.status;
        else if (firstRow != null && firstRow.intValue() != t.row) reason = "DUPLICATE";
      }
      if (reason != null) { exs.add(new Ex(t.row, t.txId, reason)); continue; }
      FeeRule rule = a == null ? null : fees.get(a.feePlan);
      BigDecimal adj = applyFee(amt, rule);
      BigDecimal cur = sums.get(t.acct); if (cur == null) cur = BigDecimal.ZERO;
      sums.put(t.acct, cur.add(adj));
      valid++;
    }
    Collections.sort(exs, new Comparator<Ex>() { public int compare(Ex a, Ex b){ return a.row - b.row; } });
    return valid;
  }
  private static BigDecimal bestRate(Map<String, List<Rate>> rates, String from, String to, java.util.Date eff) {
    long day = day(eff);
    BigDecimal direct = null;
    long directDay = Long.MIN_VALUE;
    List<Rate> list = rates.get(from + "->" + to);
    if (list != null) {
      for (Rate r : list) {
        if (r.day <= day) { direct = r.rate; directDay = r.day; }
        else break;
      }
    }
    BigDecimal reverse = null;
    long reverseDay = Long.MIN_VALUE;
    list = rates.get(to + "->" + from);
    if (list != null) {
      for (Rate r : list) {
        if (r.day <= day) { reverse = r.rate; reverseDay = r.day; }
        else break;
      }
    }
    if (direct == null && reverse == null) return null;
    if (reverse == null || (direct != null && directDay >= reverseDay)) return direct;
    if (reverse.compareTo(BigDecimal.ZERO) == 0) return null;
    return BigDecimal.ONE.divide(reverse, 10, RoundingMode.HALF_EVEN);
  }
  private static BigDecimal fxRate(Map<String, List<Rate>> rates, List<String> pivots,
                                   String from, String to, java.util.Date eff) {
    if (from.equals(to)) return BigDecimal.ONE;
    BigDecimal out = bestRate(rates, from, to, eff);
    if (out != null) return out;
    for (String pivot : pivots) {
      if (pivot.equals(from) || pivot.equals(to)) continue;
      BigDecimal leg1 = bestRate(rates, from, pivot, eff);
      if (leg1 == null) continue;
      BigDecimal leg2 = bestRate(rates, pivot, to, eff);
      if (leg2 == null) continue;
      return leg1.multiply(leg2).setScale(10, RoundingMode.HALF_EVEN);
    }
    return null;
  }
  private static BigDecimal applyFee(BigDecimal amt, FeeRule rule) {
    if (rule == null) return amt.setScale(2, RoundingMode.HALF_EVEN);
    int sign = amt.compareTo(BigDecimal.ZERO);
    boolean applies = false;
    if ("ALL".equals(rule.applies)) applies = sign != 0;
    else if ("DEBIT".equals(rule.applies)) applies = sign < 0;
    else if ("CREDIT".equals(rule.applies)) applies = sign > 0;
    if (!applies) return amt.setScale(2, RoundingMode.HALF_EVEN);
    BigDecimal fee = rule.flat.add(amt.abs().multiply(rule.pct)).setScale(2, RoundingMode.HALF_EVEN);
    if (fee.compareTo(rule.min) < 0) fee = rule.min;
    if (fee.compareTo(rule.max) > 0) fee = rule.max;
    fee = fee.setScale(2, RoundingMode.HALF_EVEN);
    return amt.subtract(fee).setScale(2, RoundingMode.HALF_EVEN);
  }
  private static void writeExceptions(List<Ex> exs) throws Exception {
    BufferedWriter w = new BufferedWriter(new OutputStreamWriter(new FileOutputStream(OUT_EXCEPTIONS), UTF8));
    try {
      w.write("row_num,tx_id,reason\n");
      for (Ex e : exs) w.write(e.row + "," + e.txId + "," + e.reason + "\n");
    } finally { w.close(); }
  }
  private static Interest writeInterest(String bizStr, java.util.Date biz, List<Account> accounts, Map<String, BigDecimal> sums) throws Exception {
    List<Account> sorted = new ArrayList<Account>(accounts);
    Collections.sort(sorted, new Comparator<Account>() { public int compare(Account a, Account b){ return a.id.compareTo(b.id); } });
    MessageDigest md = MessageDigest.getInstance("MD5");
    DigestOutputStream dos = new DigestOutputStream(new FileOutputStream(OUT_INTEREST), md);
    BufferedWriter w = new BufferedWriter(new OutputStreamWriter(dos, UTF8));
    BigDecimal total = BigDecimal.ZERO;
    try {
      w.write("account_id,biz_date,eod_balance,apr,daily_interest\n");
      for (Account a : sorted) {
        BigDecimal delta = sums.get(a.id); if (delta == null) delta = BigDecimal.ZERO;
        BigDecimal eod = a.start.add(delta).setScale(2, RoundingMode.HALF_EVEN);
        BigDecimal apr = computeApr(a, eod, biz).setScale(6, RoundingMode.HALF_EVEN);
        BigDecimal dailyRaw = dailyInterestRaw(eod, apr);
        BigDecimal daily = dailyRaw.setScale(2, RoundingMode.HALF_EVEN);
        total = total.add(dailyRaw);
        w.write(a.id + "," + bizStr + "," + eod.toPlainString() + "," + apr.toPlainString() + "," + daily.toPlainString() + "\n");
      }
    } finally { w.close(); }
    return new Interest(toHex(md.digest()), total.setScale(2, RoundingMode.HALF_EVEN));
  }
  private static void writeStats(String biz, int accounts, int valid, int skipped, BigDecimal total, String md5) throws Exception {
    String j = "{\"biz_date\":\"" + biz + "\",\"accounts\":" + accounts + ",\"valid_txs\":" + valid + ",\"skipped_txs\":" + skipped
        + ",\"total_interest\":\"" + total.setScale(2, RoundingMode.HALF_EVEN).toPlainString() + "\",\"report_md5\":\"" + md5 + "\"}";
    FileOutputStream out = new FileOutputStream(OUT_STATS);
    try { out.write(j.getBytes(UTF8)); } finally { out.close(); }
  }
  private static void buildDb(String biz, List<Account> accounts, List<TxnRow> txs, int valid, int skipped, String md5) throws Exception {
    Class.forName("org.h2.Driver");
    Connection c = DriverManager.getConnection(JDBC_URL, DB_USER, DB_PASS);
    try {
      c.setAutoCommit(false);
      Statement st = c.createStatement();
      st.execute("DROP TABLE IF EXISTS RUN_AUDIT");
      st.execute("DROP TABLE IF EXISTS TXNS");
      st.execute("DROP TABLE IF EXISTS ACCOUNTS");
      st.execute("CREATE TABLE ACCOUNTS (account_id VARCHAR PRIMARY KEY, opened_at DATE, start_balance DECIMAL(18,2), base_apr DECIMAL(18,6), promo_apr DECIMAL(18,6), promo_days INT, tier_threshold DECIMAL(18,2), tier_apr DECIMAL(18,6), currency VARCHAR, fee_plan VARCHAR)");
      st.execute("CREATE TABLE TXNS (row_num INT PRIMARY KEY, tx_id VARCHAR, account_id VARCHAR, effective_date DATE, amount DECIMAL(18,2), currency VARCHAR, status VARCHAR, reversal_of VARCHAR)");
      st.execute("CREATE TABLE RUN_AUDIT (jdbc_url VARCHAR, biz_date VARCHAR, accounts INT, valid_txs INT, skipped_txs INT, report_md5 VARCHAR)");
      PreparedStatement pa = c.prepareStatement("INSERT INTO ACCOUNTS(account_id,opened_at,start_balance,base_apr,promo_apr,promo_days,tier_threshold,tier_apr,currency,fee_plan) VALUES(?,?,?,?,?,?,?,?,?,?)");
      for (Account a : accounts) {
        pa.setString(1, a.id); pa.setDate(2, new java.sql.Date(a.opened.getTime()));
        pa.setBigDecimal(3, a.start.setScale(2, RoundingMode.HALF_EVEN));
        pa.setBigDecimal(4, a.base.setScale(6, RoundingMode.HALF_EVEN));
        pa.setBigDecimal(5, a.promo.setScale(6, RoundingMode.HALF_EVEN));
        pa.setInt(6, a.promoDays);
        pa.setBigDecimal(7, a.tierThr.setScale(2, RoundingMode.HALF_EVEN));
        pa.setBigDecimal(8, a.tierApr.setScale(6, RoundingMode.HALF_EVEN));
        pa.setString(9, a.currency);
        pa.setString(10, a.feePlan);
        pa.addBatch();
      }
      pa.executeBatch(); pa.close();
      PreparedStatement pt = c.prepareStatement("INSERT INTO TXNS(row_num,tx_id,account_id,effective_date,amount,currency,status,reversal_of) VALUES(?,?,?,?,?,?,?,?)");
      for (TxnRow t : txs) {
        pt.setInt(1, t.row); pt.setString(2, t.txId); pt.setString(3, t.acct); pt.setDate(4, new java.sql.Date(t.eff.getTime()));
        pt.setBigDecimal(5, t.amt.setScale(2, RoundingMode.HALF_EVEN)); pt.setString(6, t.currency);
        pt.setString(7, t.status);
        if (t.revOf == null) pt.setNull(8, Types.VARCHAR); else pt.setString(8, t.revOf);
        pt.addBatch();
      }
      pt.executeBatch(); pt.close();
      PreparedStatement pr = c.prepareStatement("INSERT INTO RUN_AUDIT(jdbc_url,biz_date,accounts,valid_txs,skipped_txs,report_md5) VALUES(?,?,?,?,?,?)");
      pr.setString(1, JDBC_URL); pr.setString(2, biz); pr.setInt(3, accounts.size()); pr.setInt(4, valid); pr.setInt(5, skipped); pr.setString(6, md5);
      pr.executeUpdate(); pr.close();
      c.commit();
    } finally { c.close(); }
  }
  private static BigDecimal computeApr(Account a, BigDecimal eod, java.util.Date biz) {
    BigDecimal apr = a.base;
    if (eod.compareTo(a.tierThr) >= 0) apr = apr.add(a.tierApr);
    if (a.promoDays > 0 && daysBetween(a.opened, biz) < a.promoDays) apr = apr.add(a.promo);
    return apr;
  }
  private static BigDecimal dailyInterestRaw(BigDecimal eod, BigDecimal apr) {
    if (eod.compareTo(BigDecimal.ZERO) <= 0) return BigDecimal.ZERO.setScale(10, RoundingMode.HALF_EVEN);
    return eod.multiply(apr).divide(DAYS, 10, RoundingMode.HALF_EVEN);
  }
  private static int daysBetween(java.util.Date open, java.util.Date biz) { return (int) ((biz.getTime() - open.getTime()) / 86400000L); }
  private static long day(java.util.Date d) { return d.getTime() / 86400000L; }
  private static List<Account> readAccounts() throws Exception {
    BufferedReader r = new BufferedReader(new InputStreamReader(new FileInputStream(ACCOUNTS), UTF8));
    try {
      String header = r.readLine(); if (header == null) return new ArrayList<Account>();
      assertHeader(header, "account_id","opened_at","start_balance","base_apr","promo_apr","promo_days","tier_threshold","tier_apr","currency","fee_plan");
      List<Account> out = new ArrayList<Account>();
      String line;
      while ((line = r.readLine()) != null) {
        if (line.trim().isEmpty()) continue;
        String[] p = split(line, 10);
        out.add(new Account(p[0], parseDate(p[1]), new BigDecimal(p[2]), new BigDecimal(p[3]), new BigDecimal(p[4]),
            Integer.parseInt(p[5]), new BigDecimal(p[6]), new BigDecimal(p[7]), p[8], p[9]));
      }
      return out;
    } finally { r.close(); }
  }
  private static List<TxnRow> readTxns() throws Exception {
    BufferedReader r = new BufferedReader(new InputStreamReader(new FileInputStream(TXS), UTF8));
    try {
      String header = r.readLine(); if (header == null) return new ArrayList<TxnRow>();
      assertHeader(header, "tx_id","account_id","effective_date","amount","currency","status","reversal_of");
      List<TxnRow> out = new ArrayList<TxnRow>();
      String line; int row = 0;
      while ((line = r.readLine()) != null) {
        if (line.trim().isEmpty()) continue;
        row++;
        String[] p = split(line, 7);
        String revOf = p[6].isEmpty() ? null : p[6];
        out.add(new TxnRow(row, p[0], p[1], parseDate(p[2]), new BigDecimal(p[3]), p[4], p[5], revOf));
      }
      return out;
    } finally { r.close(); }
  }
  private static Map<String, List<Rate>> readFxRates() throws Exception {
    BufferedReader r = new BufferedReader(new InputStreamReader(new FileInputStream(FX), UTF8));
    try {
      String header = r.readLine(); if (header == null) return new HashMap<String, List<Rate>>();
      assertHeader(header, "rate_date","from_ccy","to_ccy","rate");
      Map<String, List<Rate>> out = new HashMap<String, List<Rate>>();
      String line;
      while ((line = r.readLine()) != null) {
        if (line.trim().isEmpty()) continue;
        String[] p = split(line, 4);
        long day = day(parseDate(p[0]));
        String key = p[1] + "->" + p[2];
        List<Rate> list = out.get(key);
        if (list == null) { list = new ArrayList<Rate>(); out.put(key, list); }
        list.add(new Rate(day, new BigDecimal(p[3])));
      }
      for (List<Rate> list : out.values()) {
        Collections.sort(list, new Comparator<Rate>() { public int compare(Rate a, Rate b){ return (a.day < b.day) ? -1 : (a.day == b.day ? 0 : 1); } });
      }
      return out;
    } finally { r.close(); }
  }
  private static List<String> readPivots() throws Exception {
    BufferedReader r = new BufferedReader(new InputStreamReader(new FileInputStream(FX_PIVOTS), UTF8));
    try {
      String header = r.readLine(); if (header == null) return new ArrayList<String>();
      assertHeader(header, "pivot");
      List<String> out = new ArrayList<String>();
      String line;
      while ((line = r.readLine()) != null) {
        if (line.trim().isEmpty()) continue;
        String[] p = split(line, 1);
        out.add(p[0]);
      }
      return out;
    } finally { r.close(); }
  }
  private static Map<String, FeeRule> readFeeRules() throws Exception {
    BufferedReader r = new BufferedReader(new InputStreamReader(new FileInputStream(FEES), UTF8));
    try {
      String header = r.readLine(); if (header == null) return new HashMap<String, FeeRule>();
      assertHeader(header, "fee_plan","applies_to","flat_fee","pct_fee","min_fee","max_fee");
      Map<String, FeeRule> out = new HashMap<String, FeeRule>();
      String line;
      while ((line = r.readLine()) != null) {
        if (line.trim().isEmpty()) continue;
        String[] p = split(line, 6);
        out.put(p[0], new FeeRule(p[1], new BigDecimal(p[2]), new BigDecimal(p[3]), new BigDecimal(p[4]), new BigDecimal(p[5])));
      }
      return out;
    } finally { r.close(); }
  }
  private static void assertHeader(String headerLine, String... cols) {
    String[] got = headerLine.split(",", -1);
    if (got.length != cols.length) die("bad CSV header");
    for (int i = 0; i < cols.length; i++) if (!cols[i].equals(got[i].trim())) die("bad CSV header col " + i);
  }
  private static String[] split(String line, int expected) { String[] p = line.split(",", -1); if (p.length != expected) die("bad CSV row"); return p; }
  private static String readLine(File f) throws Exception {
    BufferedReader r = new BufferedReader(new InputStreamReader(new FileInputStream(f), UTF8));
    try { String s = r.readLine(); if (s == null) die("missing biz_date"); return s.trim(); } finally { r.close(); }
  }
  private static java.util.Date parseDate(String s) throws Exception { synchronized (DF) { return DF.parse(s); } }
  private static String toHex(byte[] b) { StringBuilder sb = new StringBuilder(); for (int i = 0; i < b.length; i++){ int x = b[i] & 0xff; if (x < 16) sb.append('0'); sb.append(Integer.toHexString(x)); } return sb.toString(); }
  private static void die(String msg) { System.err.println(msg); System.exit(1); }
}
JAVA
javac -source 1.7 -target 1.7 -cp "/opt/legacy-lib/*" -d "$BUILD" "$SRC/BankBatchJob.java"
jar cf /app/job.jar -C "$BUILD" .
rm -rf /app/output
mkdir -p /app/output
java -cp "/app/job.jar:/opt/legacy-lib/*" BankBatchJob
