import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.Charset;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TimeZone;

public class OutputValidator {
    private static final Charset UTF8 = Charset.forName("UTF-8");
    private static final TimeZone UTC = TimeZone.getTimeZone("UTC");
    private static final SimpleDateFormat DF = new SimpleDateFormat("yyyy-MM-dd", Locale.US);
    private static final BigDecimal DAYS_IN_YEAR = new BigDecimal("365");

    private static final File ACCOUNTS = new File("/app/data/accounts.csv");
    private static final File TXS = new File("/app/data/transactions.csv");
    private static final File BIZ_DATE = new File("/app/data/biz_date.txt");
    private static final File FX = new File("/app/data/fx_rates.csv");
    private static final File FX_PIVOTS = new File("/app/data/fx_pivots.csv");
    private static final File FEES = new File("/app/data/fee_rules.csv");

    private static final File OUT_INTEREST = new File("/app/output/interest.csv");
    private static final File OUT_EXCEPTIONS = new File("/app/output/exceptions.csv");
    private static final File OUT_STATS = new File("/app/output/stats.json");
    private static final File OUT_DB = new File("/app/output/bankdb.h2.db");

    static {
        DF.setLenient(false);
        DF.setTimeZone(UTC);
    }

    static final class Account {
        final String accountId;
        final java.util.Date openedAt;
        final BigDecimal startBalance;
        final BigDecimal baseApr;
        final BigDecimal promoApr;
        final int promoDays;
        final BigDecimal tierThreshold;
        final BigDecimal tierApr;
        final String currency;
        final String feePlan;

        Account(String accountId, java.util.Date openedAt, BigDecimal startBalance, BigDecimal baseApr, BigDecimal promoApr,
                int promoDays, BigDecimal tierThreshold, BigDecimal tierApr, String currency, String feePlan) {
            this.accountId = accountId;
            this.openedAt = openedAt;
            this.startBalance = startBalance;
            this.baseApr = baseApr;
            this.promoApr = promoApr;
            this.promoDays = promoDays;
            this.tierThreshold = tierThreshold;
            this.tierApr = tierApr;
            this.currency = currency;
            this.feePlan = feePlan;
        }
    }

    static final class TxnRow {
        final int rowNum;
        final String txId;
        final String accountId;
        final java.util.Date effectiveDate;
        final BigDecimal amount;
        final String currency;
        final String status;
        final String reversalOf;

        TxnRow(int rowNum, String txId, String accountId, java.util.Date effectiveDate, BigDecimal amount,
               String currency, String status, String reversalOf) {
            this.rowNum = rowNum;
            this.txId = txId;
            this.accountId = accountId;
            this.effectiveDate = effectiveDate;
            this.amount = amount;
            this.currency = currency;
            this.status = status;
            this.reversalOf = reversalOf;
        }
    }

    static final class Rate {
        final long day;
        final BigDecimal rate;

        Rate(long day, BigDecimal rate) {
            this.day = day;
            this.rate = rate;
        }
    }

    static final class FeeRule {
        final String appliesTo;
        final BigDecimal flatFee;
        final BigDecimal pctFee;
        final BigDecimal minFee;
        final BigDecimal maxFee;

        FeeRule(String appliesTo, BigDecimal flatFee, BigDecimal pctFee, BigDecimal minFee, BigDecimal maxFee) {
            this.appliesTo = appliesTo;
            this.flatFee = flatFee;
            this.pctFee = pctFee;
            this.minFee = minFee;
            this.maxFee = maxFee;
        }
    }

    static final class ExceptionRow {
        final int rowNum;
        final String txId;
        final String reason;

        ExceptionRow(int rowNum, String txId, String reason) {
            this.rowNum = rowNum;
            this.txId = txId;
            this.reason = reason;
        }
    }

    static final class InterestOut {
        final String csv;
        final String md5;
        final BigDecimal total;

        InterestOut(String csv, String md5, BigDecimal total) {
            this.csv = csv;
            this.md5 = md5;
            this.total = total;
        }
    }

    public static void main(String[] args) throws Exception {
        TimeZone.setDefault(UTC);

        assertFile(ACCOUNTS, "accounts.csv missing");
        assertFile(TXS, "transactions.csv missing");
        assertFile(BIZ_DATE, "biz_date.txt missing");
        assertFile(FX, "fx_rates.csv missing");
        assertFile(FX_PIVOTS, "fx_pivots.csv missing");
        assertFile(FEES, "fee_rules.csv missing");
        assertFile(OUT_INTEREST, "interest.csv missing");
        assertFile(OUT_EXCEPTIONS, "exceptions.csv missing");
        assertFile(OUT_STATS, "stats.json missing");
        assertFile(OUT_DB, "bankdb.h2.db missing");

        assertMd5(ACCOUNTS, "505829c96c9fa568cf70abf7c52247d5");
        assertMd5(TXS, "ad100f16f2e9b52929da8eca55b3edad");
        assertMd5(BIZ_DATE, "4a58c5b49dafc91047e9f999ede44581");
        assertMd5(FX, "d351af4cc717a6d8d9353f53d8616c05");
        assertMd5(FX_PIVOTS, "31e9e031a576af3d943424f47d9f9390");
        assertMd5(FEES, "a2a8a66a3db722b2f4a051612c8e8bd7");

        String bizDate = readFirstLine(BIZ_DATE);
        java.util.Date biz = parseDate(bizDate);

        List<Account> accounts = readAccounts(ACCOUNTS);
        Map<String, Account> accountById = new HashMap<String, Account>();
        for (Account a : accounts) {
            accountById.put(a.accountId, a);
        }

        List<TxnRow> txs = readTransactions(TXS);
        Map<String, List<Rate>> fxRates = readFxRates(FX);
        List<String> pivots = readPivots(FX_PIVOTS);
        Map<String, FeeRule> feeRules = readFeeRules(FEES);

        Map<String, BigDecimal> sums = new HashMap<String, BigDecimal>();
        List<ExceptionRow> exceptions = new ArrayList<ExceptionRow>();
        int validTxs = applyTxnRulesAndBuildSums(biz, txs, accountById, fxRates, pivots, feeRules, sums, exceptions);
        int skippedTxs = exceptions.size();

        String expectedExceptionsCsv = buildExpectedExceptionsCsv(exceptions);
        byte[] gotExceptionsBytes = readAllBytes(OUT_EXCEPTIONS);
        assertLfOnly(gotExceptionsBytes, "exceptions.csv");
        if (!bytesEqual(expectedExceptionsCsv.getBytes(UTF8), gotExceptionsBytes)) {
            die("exceptions.csv mismatch");
        }

        InterestOut interest = buildExpectedInterestCsv(bizDate, biz, accounts, sums);
        byte[] expectedInterestBytes = interest.csv.getBytes(UTF8);
        byte[] gotInterestBytes = readAllBytes(OUT_INTEREST);
        assertLfOnly(gotInterestBytes, "interest.csv");
        if (!bytesEqual(expectedInterestBytes, gotInterestBytes)) {
            die("interest.csv mismatch");
        }

        String expectedStatsJson = buildExpectedStatsJson(bizDate, accounts.size(), validTxs, skippedTxs, interest.total, interest.md5);
        byte[] gotStatsBytes = readAllBytes(OUT_STATS);
        assertNoNewlines(gotStatsBytes, "stats.json");
        String gotStats = new String(gotStatsBytes, UTF8);
        if (!expectedStatsJson.equals(gotStats)) {
            die("stats.json mismatch");
        }

        validateDb(accounts.size(), txs.size(), bizDate, validTxs, skippedTxs, interest.md5);
    }

    private static int applyTxnRulesAndBuildSums(java.util.Date biz, List<TxnRow> txs,
                                                 Map<String, Account> accounts,
                                                 Map<String, List<Rate>> rates,
                                                 List<String> pivots,
                                                 Map<String, FeeRule> fees,
                                                 Map<String, BigDecimal> sums,
                                                 List<ExceptionRow> exceptions) {
        Map<String, Integer> firstRowByTxId = new HashMap<String, Integer>();
        for (int i = 0; i < txs.size(); i++) {
            TxnRow row = txs.get(i);
            if (!firstRowByTxId.containsKey(row.txId)) {
                firstRowByTxId.put(row.txId, Integer.valueOf(row.rowNum));
            }
        }

        Set<Integer> reversedRows = new HashSet<Integer>();
        Set<Integer> reversalMissingRows = new HashSet<Integer>();
        for (int i = 0; i < txs.size(); i++) {
            TxnRow row = txs.get(i);
            if (row.reversalOf == null) continue;
            Integer refRow = firstRowByTxId.get(row.reversalOf);
            if (refRow == null) {
                reversalMissingRows.add(Integer.valueOf(row.rowNum));
            } else {
                reversedRows.add(Integer.valueOf(row.rowNum));
                reversedRows.add(refRow);
            }
        }

        int valid = 0;
        for (int i = 0; i < txs.size(); i++) {
            TxnRow row = txs.get(i);
            String reason = null;
            Integer firstRow = firstRowByTxId.get(row.txId);

            if (reversedRows.contains(Integer.valueOf(row.rowNum))) {
                reason = "REVERSED";
            } else if (reversalMissingRows.contains(Integer.valueOf(row.rowNum))) {
                reason = "REVERSAL_MISSING";
            }

            Account account = accounts.get(row.accountId);
            BigDecimal amount = row.amount;
            if (reason == null) {
                if (account == null) {
                    reason = "FX_MISSING";
                } else if (!row.currency.equals(account.currency)) {
                    BigDecimal rate = fxRate(rates, pivots, row.currency, account.currency, row.effectiveDate);
                    if (rate == null) {
                        reason = "FX_MISSING";
                    } else {
                        amount = amount.multiply(rate);
                    }
                }
            }

            if (reason == null) {
                if (row.effectiveDate.after(biz)) {
                    reason = "AFTER_BIZ_DATE";
                } else if (!"POSTED".equals(row.status)) {
                    reason = row.status;
                } else if (firstRow != null && firstRow.intValue() != row.rowNum) {
                    reason = "DUPLICATE";
                }
            }

            if (reason != null) {
                exceptions.add(new ExceptionRow(row.rowNum, row.txId, reason));
                continue;
            }

            FeeRule rule = fees.get(account.feePlan);
            BigDecimal adjusted = applyFee(amount, rule);
            BigDecimal cur = sums.get(account.accountId);
            if (cur == null) cur = BigDecimal.ZERO;
            sums.put(account.accountId, cur.add(adjusted));
            valid += 1;
        }

        Collections.sort(exceptions, new Comparator<ExceptionRow>() {
            public int compare(ExceptionRow a, ExceptionRow b) { return a.rowNum - b.rowNum; }
        });
        return valid;
    }

    private static BigDecimal bestRate(Map<String, List<Rate>> rates, String from, String to, java.util.Date effective) {
        long day = day(effective);
        BigDecimal direct = null;
        long directDay = Long.MIN_VALUE;
        List<Rate> list = rates.get(from + "->" + to);
        if (list != null) {
            for (int i = 0; i < list.size(); i++) {
                Rate r = list.get(i);
                if (r.day <= day) { direct = r.rate; directDay = r.day; }
                else break;
            }
        }
        BigDecimal reverse = null;
        long reverseDay = Long.MIN_VALUE;
        list = rates.get(to + "->" + from);
        if (list != null) {
            for (int i = 0; i < list.size(); i++) {
                Rate r = list.get(i);
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
                                     String from, String to, java.util.Date effective) {
        if (from.equals(to)) return BigDecimal.ONE;
        BigDecimal out = bestRate(rates, from, to, effective);
        if (out != null) return out;
        for (int i = 0; i < pivots.size(); i++) {
            String pivot = pivots.get(i);
            if (pivot.equals(from) || pivot.equals(to)) continue;
            BigDecimal leg1 = bestRate(rates, from, pivot, effective);
            if (leg1 == null) continue;
            BigDecimal leg2 = bestRate(rates, pivot, to, effective);
            if (leg2 == null) continue;
            return leg1.multiply(leg2).setScale(10, RoundingMode.HALF_EVEN);
        }
        return null;
    }

    private static BigDecimal applyFee(BigDecimal amt, FeeRule rule) {
        if (rule == null) return amt.setScale(2, RoundingMode.HALF_EVEN);
        int sign = amt.compareTo(BigDecimal.ZERO);
        boolean applies = false;
        if ("ALL".equals(rule.appliesTo)) applies = sign != 0;
        else if ("DEBIT".equals(rule.appliesTo)) applies = sign < 0;
        else if ("CREDIT".equals(rule.appliesTo)) applies = sign > 0;
        if (!applies) return amt.setScale(2, RoundingMode.HALF_EVEN);
        BigDecimal fee = rule.flatFee.add(amt.abs().multiply(rule.pctFee)).setScale(2, RoundingMode.HALF_EVEN);
        if (fee.compareTo(rule.minFee) < 0) fee = rule.minFee;
        if (fee.compareTo(rule.maxFee) > 0) fee = rule.maxFee;
        fee = fee.setScale(2, RoundingMode.HALF_EVEN);
        return amt.subtract(fee).setScale(2, RoundingMode.HALF_EVEN);
    }

    private static InterestOut buildExpectedInterestCsv(String bizDate, java.util.Date biz,
                                                        List<Account> accounts, Map<String, BigDecimal> sums) throws Exception {
        List<Account> sorted = new ArrayList<Account>(accounts);
        Collections.sort(sorted, new Comparator<Account>() {
            public int compare(Account a, Account b) { return a.accountId.compareTo(b.accountId); }
        });

        StringBuilder sb = new StringBuilder();
        sb.append("account_id,biz_date,eod_balance,apr,daily_interest\n");
        BigDecimal total = BigDecimal.ZERO;
        for (int i = 0; i < sorted.size(); i++) {
            Account a = sorted.get(i);
            BigDecimal delta = sums.get(a.accountId);
            if (delta == null) delta = BigDecimal.ZERO;
            BigDecimal eod = a.startBalance.add(delta).setScale(2, RoundingMode.HALF_EVEN);
            BigDecimal apr = computeApr(a, eod, biz).setScale(6, RoundingMode.HALF_EVEN);
            BigDecimal dailyRaw = dailyInterest(eod, apr);
            BigDecimal daily = dailyRaw.setScale(2, RoundingMode.HALF_EVEN);
            total = total.add(dailyRaw);
            sb.append(a.accountId).append(',').append(bizDate).append(',')
              .append(eod.toPlainString()).append(',')
              .append(apr.toPlainString()).append(',')
              .append(daily.toPlainString()).append('\n');
        }
        byte[] bytes = sb.toString().getBytes(UTF8);
        return new InterestOut(sb.toString(), md5Hex(bytes), total.setScale(2, RoundingMode.HALF_EVEN));
    }

    private static String buildExpectedStatsJson(String bizDate, int accounts, int valid, int skipped,
                                                 BigDecimal total, String md5) {
        return "{\"biz_date\":\"" + bizDate + "\",\"accounts\":" + accounts
            + ",\"valid_txs\":" + valid + ",\"skipped_txs\":" + skipped
            + ",\"total_interest\":\"" + total.setScale(2, RoundingMode.HALF_EVEN).toPlainString() + "\""
            + ",\"report_md5\":\"" + md5 + "\"}";
    }

    private static void validateDb(int expectedAccounts, int expectedTxs, String bizDate,
                                   int validTxs, int skippedTxs, String expectedMd5) throws Exception {
        Class.forName("org.h2.Driver");
        Connection conn = DriverManager.getConnection("jdbc:h2:/app/output/bankdb;MODE=DB2;IFEXISTS=TRUE", "sa", "");
        try {
            assertTable(conn, "ACCOUNTS");
            assertTable(conn, "TXNS");
            assertTable(conn, "RUN_AUDIT");

            assertCount(conn, "ACCOUNTS", expectedAccounts);

            int txCount = count(conn, "TXNS");
            Statement st = conn.createStatement();
            ResultSet rs = st.executeQuery("SELECT MIN(row_num), MAX(row_num), COUNT(DISTINCT row_num) FROM TXNS");
            rs.next();
            int minRow = rs.getInt(1);
            int maxRow = rs.getInt(2);
            int distinctRow = rs.getInt(3);
            rs.close();
            st.close();
            if (minRow != 1 || maxRow != txCount || distinctRow != txCount || txCount != expectedTxs) {
                throw new RuntimeException("TXNS row_num must be 1..N without gaps");
            }

            st = conn.createStatement();
            rs = st.executeQuery("SELECT jdbc_url,biz_date,accounts,valid_txs,skipped_txs,report_md5 FROM RUN_AUDIT");
            if (!rs.next()) {
                throw new RuntimeException("RUN_AUDIT missing row");
            }
            String jdbcUrl = rs.getString(1);
            String gotBizDate = rs.getString(2);
            int accounts = rs.getInt(3);
            int gotValid = rs.getInt(4);
            int gotSkipped = rs.getInt(5);
            String md5 = rs.getString(6);

            if (jdbcUrl == null || jdbcUrl.indexOf("jdbc:h2:") != 0 || jdbcUrl.indexOf("/app/output/bankdb") < 0 || jdbcUrl.indexOf("MODE=DB2") < 0) {
                throw new RuntimeException("RUN_AUDIT.jdbc_url must include jdbc:h2:, /app/output/bankdb, and MODE=DB2");
            }
            if (!bizDate.equals(gotBizDate)) throw new RuntimeException("RUN_AUDIT.biz_date mismatch");
            if (accounts != expectedAccounts) throw new RuntimeException("RUN_AUDIT.accounts mismatch");
            if (gotValid != validTxs) throw new RuntimeException("RUN_AUDIT.valid_txs mismatch");
            if (gotSkipped != skippedTxs) throw new RuntimeException("RUN_AUDIT.skipped_txs mismatch");
            if (!expectedMd5.equals(md5)) throw new RuntimeException("RUN_AUDIT.report_md5 mismatch");

            if (rs.next()) throw new RuntimeException("RUN_AUDIT must have exactly one row");
            rs.close();
            st.close();
        } finally {
            conn.close();
        }
    }

    private static void assertTable(Connection conn, String name) throws Exception {
        DatabaseMetaData md = conn.getMetaData();
        ResultSet rs = md.getTables(null, null, name, null);
        try {
            if (!rs.next()) throw new RuntimeException("missing table: " + name);
        } finally {
            rs.close();
        }
    }

    private static int count(Connection conn, String table) throws Exception {
        Statement st = conn.createStatement();
        ResultSet rs = st.executeQuery("SELECT COUNT(*) FROM " + table);
        rs.next();
        int out = rs.getInt(1);
        rs.close();
        st.close();
        return out;
    }

    private static void assertCount(Connection conn, String table, int expected) throws Exception {
        int got = count(conn, table);
        if (got != expected) throw new RuntimeException(table + " row count mismatch");
    }

    private static List<Account> readAccounts(File file) throws Exception {
        List<Account> out = new ArrayList<Account>();
        BufferedReader r = new BufferedReader(new InputStreamReader(new java.io.FileInputStream(file), UTF8));
        try {
            String header = r.readLine();
            assertHeader(header, "account_id","opened_at","start_balance","base_apr","promo_apr","promo_days","tier_threshold","tier_apr","currency","fee_plan");
            String line;
            while ((line = r.readLine()) != null) {
                if (line.trim().length() == 0) continue;
                String[] parts = line.split(",", -1);
                out.add(new Account(
                        parts[0],
                        parseDate(parts[1]),
                        new BigDecimal(parts[2]),
                        new BigDecimal(parts[3]),
                        new BigDecimal(parts[4]),
                        Integer.parseInt(parts[5]),
                        new BigDecimal(parts[6]),
                        new BigDecimal(parts[7]),
                        parts[8],
                        parts[9]
                ));
            }
        } finally {
            r.close();
        }
        return out;
    }

    private static List<TxnRow> readTransactions(File file) throws Exception {
        List<TxnRow> out = new ArrayList<TxnRow>();
        BufferedReader r = new BufferedReader(new InputStreamReader(new java.io.FileInputStream(file), UTF8));
        try {
            String header = r.readLine();
            assertHeader(header, "tx_id","account_id","effective_date","amount","currency","status","reversal_of");
            String line;
            int row = 1;
            while ((line = r.readLine()) != null) {
                if (line.trim().length() == 0) continue;
                String[] parts = line.split(",", -1);
                String reversal = parts[6].length() == 0 ? null : parts[6];
                out.add(new TxnRow(
                        row,
                        parts[0],
                        parts[1],
                        parseDate(parts[2]),
                        new BigDecimal(parts[3]),
                        parts[4],
                        parts[5],
                        reversal
                ));
                row++;
            }
        } finally {
            r.close();
        }
        return out;
    }

    private static Map<String, List<Rate>> readFxRates(File file) throws Exception {
        Map<String, List<Rate>> out = new HashMap<String, List<Rate>>();
        BufferedReader r = new BufferedReader(new InputStreamReader(new java.io.FileInputStream(file), UTF8));
        try {
            String header = r.readLine();
            assertHeader(header, "rate_date","from_ccy","to_ccy","rate");
            String line;
            while ((line = r.readLine()) != null) {
                if (line.trim().length() == 0) continue;
                String[] parts = line.split(",", -1);
                long day = day(parseDate(parts[0]));
                String key = parts[1] + "->" + parts[2];
                List<Rate> list = out.get(key);
                if (list == null) {
                    list = new ArrayList<Rate>();
                    out.put(key, list);
                }
                list.add(new Rate(day, new BigDecimal(parts[3])));
            }
        } finally {
            r.close();
        }
        for (List<Rate> list : out.values()) {
            Collections.sort(list, new Comparator<Rate>() {
                public int compare(Rate a, Rate b) {
                    if (a.day < b.day) return -1;
                    if (a.day > b.day) return 1;
                    return 0;
                }
            });
        }
        return out;
    }

    private static List<String> readPivots(File file) throws Exception {
        List<String> out = new ArrayList<String>();
        BufferedReader r = new BufferedReader(new InputStreamReader(new java.io.FileInputStream(file), UTF8));
        try {
            String header = r.readLine();
            assertHeader(header, "pivot");
            String line;
            while ((line = r.readLine()) != null) {
                if (line.trim().length() == 0) continue;
                String[] parts = line.split(",", -1);
                out.add(parts[0]);
            }
        } finally {
            r.close();
        }
        return out;
    }

    private static Map<String, FeeRule> readFeeRules(File file) throws Exception {
        Map<String, FeeRule> out = new HashMap<String, FeeRule>();
        BufferedReader r = new BufferedReader(new InputStreamReader(new java.io.FileInputStream(file), UTF8));
        try {
            String header = r.readLine();
            assertHeader(header, "fee_plan","applies_to","flat_fee","pct_fee","min_fee","max_fee");
            String line;
            while ((line = r.readLine()) != null) {
                if (line.trim().length() == 0) continue;
                String[] parts = line.split(",", -1);
                out.put(parts[0], new FeeRule(
                        parts[1],
                        new BigDecimal(parts[2]),
                        new BigDecimal(parts[3]),
                        new BigDecimal(parts[4]),
                        new BigDecimal(parts[5])
                ));
            }
        } finally {
            r.close();
        }
        return out;
    }

    private static String buildExpectedExceptionsCsv(List<ExceptionRow> exceptions) {
        StringBuilder sb = new StringBuilder();
        sb.append("row_num,tx_id,reason\n");
        for (int i = 0; i < exceptions.size(); i++) {
            ExceptionRow r = exceptions.get(i);
            sb.append(r.rowNum).append(',').append(r.txId).append(',').append(r.reason).append('\n');
        }
        return sb.toString();
    }

    private static BigDecimal computeApr(Account a, BigDecimal eod, java.util.Date biz) {
        BigDecimal apr = a.baseApr;
        if (eod.compareTo(a.tierThreshold) >= 0) apr = apr.add(a.tierApr);
        if (a.promoDays > 0) {
            int days = daysBetween(a.openedAt, biz);
            if (days < a.promoDays) apr = apr.add(a.promoApr);
        }
        return apr;
    }

    private static BigDecimal dailyInterest(BigDecimal eod, BigDecimal apr) {
        BigDecimal principal = eod.compareTo(BigDecimal.ZERO) < 0 ? BigDecimal.ZERO : eod;
        return principal.multiply(apr).divide(DAYS_IN_YEAR, 10, RoundingMode.HALF_EVEN);
    }

    private static int daysBetween(java.util.Date start, java.util.Date end) {
        long ms = end.getTime() - start.getTime();
        return (int) (ms / 86400000L);
    }

    private static long day(java.util.Date d) {
        return d.getTime() / 86400000L;
    }

    private static java.util.Date parseDate(String v) throws Exception {
        return DF.parse(v);
    }

    private static String readFirstLine(File f) throws Exception {
        BufferedReader r = new BufferedReader(new InputStreamReader(new java.io.FileInputStream(f), UTF8));
        try {
            String line = r.readLine();
            return line == null ? "" : line.trim();
        } finally {
            r.close();
        }
    }

    private static void assertHeader(String header, String... expected) {
        if (header == null) die("missing header");
        String[] got = header.split(",", -1);
        if (got.length != expected.length) die("header column count mismatch");
        for (int i = 0; i < expected.length; i++) {
            if (!expected[i].equals(got[i])) {
                die("header mismatch: expected " + expected[i] + " got " + got[i]);
            }
        }
    }

    private static void assertFile(File f, String msg) {
        if (!f.exists()) die(msg);
        if (f.length() == 0) die(msg);
    }

    private static void assertMd5(File f, String expected) throws Exception {
        String got = md5Hex(readAllBytes(f));
        if (!expected.equals(got)) {
            die("md5 mismatch for " + f.getName());
        }
    }

    private static byte[] readAllBytes(File f) throws Exception {
        java.io.FileInputStream in = new java.io.FileInputStream(f);
        try {
            byte[] buf = new byte[(int) f.length()];
            int off = 0;
            while (off < buf.length) {
                int n = in.read(buf, off, buf.length - off);
                if (n <= 0) break;
                off += n;
            }
            return buf;
        } finally {
            in.close();
        }
    }

    private static String md5Hex(byte[] bytes) throws Exception {
        MessageDigest md = MessageDigest.getInstance("MD5");
        md.update(bytes);
        byte[] out = md.digest();
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < out.length; i++) {
            int b = out[i] & 0xff;
            if (b < 16) sb.append('0');
            sb.append(Integer.toHexString(b));
        }
        return sb.toString();
    }

    private static boolean bytesEqual(byte[] a, byte[] b) {
        if (a.length != b.length) return false;
        for (int i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    private static void assertLfOnly(byte[] bytes, String name) {
        for (int i = 0; i < bytes.length; i++) {
            if (bytes[i] == '\r') die(name + " must use LF line endings");
        }
    }

    private static void assertNoNewlines(byte[] bytes, String name) {
        for (int i = 0; i < bytes.length; i++) {
            if (bytes[i] == '\n' || bytes[i] == '\r') die(name + " must be single-line JSON");
        }
    }

    private static void die(String msg) {
        System.err.println(msg);
        System.exit(1);
    }
}
