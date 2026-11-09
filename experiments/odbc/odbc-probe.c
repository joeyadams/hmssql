/* Direct ODBC experiments. No Haskell, sqlcmd, persistent tables, or passwords
 * in argv/logs. See README.md for scope and interpretation. */
#include <stddef.h>
#include <sql.h>
#include <sqlext.h>
#include <msodbcsql.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <locale.h>
#include <time.h>
#include <pthread.h>
#include <sys/resource.h>

_Static_assert(sizeof(SQLWCHAR) == 2, "requires 16-bit ODBC SQLWCHAR");
_Static_assert(sizeof(uint_least16_t) == sizeof(SQLWCHAR), "UTF-16 literal size");
static SQLHENV env;
static int failures, checks;
static const char *encrypt = "strict";
static int pin_cert;

static const char *setting(const char *key, const char *fallback) {
    const char *v = getenv(key);
    return v && *v ? v : fallback;
}
static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static void delay(double sec) {
    struct timespec t = {(time_t)sec, (long)((sec - (time_t)sec) * 1e9)};
    while (nanosleep(&t, &t)) {}
}
static void diagnostics(SQLSMALLINT kind, SQLHANDLE h) {
    SQLCHAR state[6], message[2048]; SQLINTEGER native; SQLSMALLINT len;
    for (SQLSMALLINT i = 1; SQL_SUCCEEDED(SQLGetDiagRec(kind, h, i, state,
             &native, message, sizeof message, &len)); ++i)
        printf("  DIAG %s native=%d %s\n", state, (int)native, message);
}
static int has_state(SQLHSTMT s, const char *expected) {
    SQLCHAR state[6], message[2048]; SQLINTEGER native; SQLSMALLINT len;
    for (SQLSMALLINT i = 1; SQL_SUCCEEDED(SQLGetDiagRec(SQL_HANDLE_STMT, s,
             i, state, &native, message, sizeof message, &len)); ++i)
        if (!strcmp((char *)state, expected)) return 1;
    return 0;
}
static void require(SQLRETURN rc, SQLSMALLINT kind, SQLHANDLE h, const char *op) {
    if (rc != SQL_SUCCESS) {
        printf("%s rc=%d\n", op, rc); diagnostics(kind, h);
    }
    if (!SQL_SUCCEEDED(rc)) exit(2);
}
#define ST(s, call) require((call), SQL_HANDLE_STMT, (s), #call)
#define DB(c, call) require((call), SQL_HANDLE_DBC, (c), #call)
static void check(int ok, const char *name) {
    ++checks; failures += !ok;
    printf("%s %s\n", ok ? "PASS" : "FAIL", name);
}
/* Brace quoting also escapes semicolons and closing braces in passwords. */
static void attribute(char *dst, size_t cap, const char *key, const char *value) {
    size_t n = strlen(dst);
    if (n + strlen(key) + strlen(value) * 2 + 5 >= cap) exit(2);
    n += (size_t)sprintf(dst + n, "%s={", key);
    for (; *value; ++value) { dst[n++] = *value; if (*value == '}') dst[n++] = '}'; }
    strcpy(dst + n, "};");
}
static SQLHDBC connect_db(int mars, int optional) {
    SQLHDBC c; SQLRETURN rc;
    require(SQLAllocHandle(SQL_HANDLE_DBC, env, &c), SQL_HANDLE_ENV, env, "allocate connection");
    DB(c, SQLSetConnectAttr(c, SQL_ATTR_LOGIN_TIMEOUT, (SQLPOINTER)5, 0));
    char cs[8192] = "", server[512];
    snprintf(server, sizeof server, "tcp:%s,%s", setting("ODBC_TEST_HOST", "localhost"),
             setting("HMSSQL_TEST_PORT", "1433"));
    attribute(cs, sizeof cs, "Driver", "ODBC Driver 18 for SQL Server");
    attribute(cs, sizeof cs, "Server", server);
    attribute(cs, sizeof cs, "Database", setting("HMSSQL_TEST_DATABASE", "master"));
    attribute(cs, sizeof cs, "UID", setting("HMSSQL_TEST_USER", "sa"));
    attribute(cs, sizeof cs, "PWD", setting("HMSSQL_TEST_PASSWORD", ""));
    attribute(cs, sizeof cs, "Encrypt", encrypt);
    attribute(cs, sizeof cs, "TrustServerCertificate", "No");
    attribute(cs, sizeof cs, "MARS_Connection", mars ? "Yes" : "No");
    attribute(cs, sizeof cs, "APP", "hmssql-direct-odbc-experiment");
    attribute(cs, sizeof cs, "LongAsMax", "Yes");
    if (pin_cert) attribute(cs, sizeof cs, "ServerCertificate", setting("HMSSQL_TEST_CERT", ""));
    rc = SQLDriverConnect(c, NULL, (SQLCHAR *)cs, SQL_NTS, NULL, 0, NULL, SQL_DRIVER_NOPROMPT);
    memset(cs, 0, sizeof cs);
    if (!SQL_SUCCEEDED(rc)) {
        diagnostics(SQL_HANDLE_DBC, c); SQLFreeHandle(SQL_HANDLE_DBC, c);
        if (!optional) exit(2);
        return SQL_NULL_HDBC;
    }
    if (rc == SQL_SUCCESS_WITH_INFO && optional) diagnostics(SQL_HANDLE_DBC, c);
    return c;
}
static void disconnect(SQLHDBC c) {
    DB(c, SQLDisconnect(c)); SQLFreeHandle(SQL_HANDLE_DBC, c);
}
static SQLHSTMT statement(SQLHDBC c) {
    SQLHSTMT s;
    DB(c, SQLAllocHandle(SQL_HANDLE_STMT, c, &s));
    return s;
}
static void exec(SQLHSTMT s, const char *sql) {
    ST(s, SQLExecDirect(s, (SQLCHAR *)sql, SQL_NTS));
}
static void close_cursor(SQLHSTMT s) { ST(s, SQLFreeStmt(s, SQL_CLOSE)); }
static void command(SQLHDBC c, const char *sql) {
    SQLHSTMT s = statement(c); exec(s, sql);
    SQLRETURN rc;
    while ((rc = SQLMoreResults(s)) != SQL_NO_DATA) ST(s, rc);
    SQLFreeHandle(SQL_HANDLE_STMT, s);
}
static int integer(SQLHDBC c, const char *sql) {
    SQLHSTMT s = statement(c); SQLINTEGER v = -999; SQLLEN len;
    exec(s, sql); ST(s, SQLFetch(s));
    ST(s, SQLGetData(s, 1, SQL_C_SLONG, &v, sizeof v, &len));
    SQLFreeHandle(SQL_HANDLE_STMT, s); return v;
}
static void info(SQLHDBC c) {
    SQLUSMALLINT codes[] = {SQL_DRIVER_NAME, SQL_DRIVER_VER, SQL_DM_VER, SQL_DBMS_VER};
    const char *names[] = {"driver", "driver_version", "manager_version", "server_version"};
    for (size_t i = 0; i < 4; ++i) {
        char value[512]; SQLSMALLINT len;
        DB(c, SQLGetInfo(c, codes[i], value, sizeof value, &len));
        printf("ENV %s=%s\n", names[i], value);
    }
    SQLHSTMT s = statement(c);
    exec(s, "SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(128)), "
            "CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS nvarchar(128)), "
            "encrypt_option, net_transport FROM sys.dm_exec_connections WHERE session_id=@@SPID");
    ST(s, SQLFetch(s));
    for (int i = 1; i <= 4; ++i) {
        char v[512]; SQLLEN len;
        ST(s, SQLGetData(s, (SQLUSMALLINT)i, SQL_C_CHAR, v, sizeof v, &len));
        printf("ENV %s=%s\n", (const char *[]) {"edition", "database_collation", "encrypted", "transport"}[i-1], v);
    }
    SQLFreeHandle(SQL_HANDLE_STMT, s);
}

static int same_dto(const SQL_SS_TIMESTAMPOFFSET_STRUCT *a, const SQL_SS_TIMESTAMPOFFSET_STRUCT *b) {
    return a->year == b->year && a->month == b->month && a->day == b->day &&
        a->hour == b->hour && a->minute == b->minute && a->second == b->second &&
        a->fraction == b->fraction && a->timezone_hour == b->timezone_hour &&
        a->timezone_minute == b->timezone_minute;
}
static void datetime_tests(SQLHDBC c) {
    command(c, "CREATE TABLE #dates (d datetimeoffset(7) NULL)");
    SQL_SS_TIMESTAMPOFFSET_STRUCT cases[] = {
        {2026,10,29,14,35,42,123456700,-4,0},
        {2026,7,1,9,12,33,765432100,5,30},
        {2026,1,15,8,0,0,0,-3,-30},
        {2026,3,8,1,59,59,999999900,-5,0},
        {2026,10,29,18,35,42,100,0,0}
    };
    SQLHSTMT s = statement(c);
    for (size_t i = 0; i < sizeof cases / sizeof *cases; ++i) {
        SQLLEN len = sizeof cases[i];
        ST(s, SQLBindParameter(s, 1, SQL_PARAM_INPUT, SQL_C_SS_TIMESTAMPOFFSET,
            SQL_SS_TIMESTAMPOFFSET, 34, 7, &cases[i], sizeof cases[i], &len));
        exec(s, "INSERT INTO #dates VALUES (?)"); close_cursor(s);
        ST(s, SQLFreeStmt(s, SQL_RESET_PARAMS));
        exec(s, "SELECT d FROM #dates"); ST(s, SQLFetch(s));
        SQL_SS_TIMESTAMPOFFSET_STRUCT out = {0}; SQLLEN n;
        ST(s, SQLGetData(s, 1, SQL_C_SS_TIMESTAMPOFFSET, &out, sizeof out, &n));
        char name[160];
        snprintf(name, sizeof name, "datetimeoffset native struct round trip case=%zu offset=%d:%d fraction=%u",
            i, cases[i].timezone_hour, cases[i].timezone_minute, (unsigned)cases[i].fraction);
        check(n == sizeof out && same_dto(&out, &cases[i]), name);
        close_cursor(s);
        exec(s, "SELECT d FROM #dates"); ST(s, SQLFetch(s));
        char rendered[96], expected[96];
        ST(s, SQLGetData(s, 1, SQL_C_CHAR, rendered, sizeof rendered, &n));
        snprintf(expected, sizeof expected, "%04d-%02d-%02d %02d:%02d:%02d.%07u %c%02d:%02d",
            cases[i].year, cases[i].month, cases[i].day, cases[i].hour, cases[i].minute,
            cases[i].second, (unsigned)cases[i].fraction / 100,
            cases[i].timezone_hour < 0 || cases[i].timezone_minute < 0 ? '-' : '+',
            abs(cases[i].timezone_hour), abs(cases[i].timezone_minute));
        printf("OBS datetimeoffset text=%s\n", rendered);
        check(!strcmp(rendered, expected), "datetimeoffset string representation independently matches input");
        close_cursor(s);
        exec(s, "SELECT d FROM #dates");
        SQLCHAR col[32]; SQLSMALLINT namelen, type, scale, nullable; SQLULEN size;
        ST(s, SQLDescribeCol(s, 1, col, sizeof col, &namelen, &type, &size, &scale, &nullable));
        check(type == SQL_SS_TIMESTAMPOFFSET && scale == 7, "datetimeoffset metadata exposes type -155 and scale 7");
        ST(s, SQLFetch(s));
        SQL_TIMESTAMP_STRUCT plain = {0};
        SQLRETURN rc = SQLGetData(s, 1, SQL_C_TYPE_TIMESTAMP, &plain, sizeof plain, &n);
        printf("OBS datetimeoffset -> generic timestamp rc=%d local=%04d-%02d-%02d %02d:%02d:%02d.%09u (no offset field)\n",
            rc, plain.year, plain.month, plain.day, plain.hour, plain.minute, plain.second, (unsigned)plain.fraction);
        if (rc != SQL_SUCCESS) diagnostics(SQL_HANDLE_STMT, s);
        close_cursor(s); command(c, "DELETE FROM #dates");
    }
    SQLLEN null_len = SQL_NULL_DATA;
    ST(s, SQLBindParameter(s, 1, SQL_PARAM_INPUT, SQL_C_SS_TIMESTAMPOFFSET,
        SQL_SS_TIMESTAMPOFFSET, 34, 7, &cases[0], sizeof cases[0], &null_len));
    exec(s, "INSERT INTO #dates VALUES (?)"); close_cursor(s);
    ST(s, SQLFreeStmt(s, SQL_RESET_PARAMS));
    exec(s, "SELECT d FROM #dates"); ST(s, SQLFetch(s));
    SQLLEN n; SQL_SS_TIMESTAMPOFFSET_STRUCT out;
    ST(s, SQLGetData(s, 1, SQL_C_SS_TIMESTAMPOFFSET, &out, sizeof out, &n));
    check(n == SQL_NULL_DATA, "datetimeoffset NULL preserved"); close_cursor(s);
    SQL_TIMESTAMP_STRUCT dt = {2026,10,29,14,35,42,123456700}, dt_out = {0};
    SQLLEN dt_len = sizeof dt;
    ST(s, SQLBindParameter(s, 1, SQL_PARAM_INPUT, SQL_C_TYPE_TIMESTAMP,
        SQL_TYPE_TIMESTAMP, 27, 7, &dt, sizeof dt, &dt_len));
    exec(s, "SELECT CAST(? AS datetime2(7))"); ST(s, SQLFetch(s));
    ST(s, SQLGetData(s, 1, SQL_C_TYPE_TIMESTAMP, &dt_out, sizeof dt_out, &n));
    check(dt_out.year == dt.year && dt_out.month == dt.month && dt_out.day == dt.day &&
          dt_out.hour == dt.hour && dt_out.minute == dt.minute && dt_out.second == dt.second &&
          dt_out.fraction == dt.fraction, "datetime2 native struct preserves 100ns precision");
    SQLFreeHandle(SQL_HANDLE_STMT, s);
}

/* Decimal magnitude is 16 little-endian bytes. All arithmetic here is exact
 * base-256 integer arithmetic; no double, long double, or locale parsing. */
static SQL_NUMERIC_STRUCT decimal_value(const char *text, int precision, int scale) {
    SQL_NUMERIC_STRUCT n = {0}; n.precision = (SQLCHAR)precision;
    n.scale = (SQLSCHAR)scale; n.sign = *text == '-' ? 0 : 1;
    if (*text == '-') ++text;
    for (; *text; ++text) {
        if (*text == '.') continue;
        if (*text < '0' || *text > '9') exit(2);
        unsigned carry = (unsigned)(*text - '0');
        for (size_t i = 0; i < SQL_MAX_NUMERIC_LEN; ++i) {
            unsigned value = n.val[i] * 10u + carry;
            n.val[i] = (SQLCHAR)(value & 255); carry = value >> 8;
        }
        if (carry) exit(2);
    }
    return n;
}
static int same_decimal(const SQL_NUMERIC_STRUCT *a, const SQL_NUMERIC_STRUCT *b) {
    return a->sign == b->sign && a->scale == b->scale && !memcmp(a->val, b->val, SQL_MAX_NUMERIC_LEN);
}
static void numeric_descriptor(SQLHSTMT s, SQLINTEGER which, int precision, int scale, SQLPOINTER ptr) {
    SQLHDESC d;
    ST(s, SQLGetStmtAttr(s, which, &d, 0, NULL));
    require(SQLSetDescField(d, 1, SQL_DESC_TYPE, (SQLPOINTER)SQL_C_NUMERIC, 0), SQL_HANDLE_DESC, d, "numeric descriptor type");
    require(SQLSetDescField(d, 1, SQL_DESC_PRECISION, (SQLPOINTER)(uintptr_t)precision, 0), SQL_HANDLE_DESC, d, "numeric descriptor precision");
    require(SQLSetDescField(d, 1, SQL_DESC_SCALE, (SQLPOINTER)(uintptr_t)scale, 0), SQL_HANDLE_DESC, d, "numeric descriptor scale");
    if (ptr) require(SQLSetDescField(d, 1, SQL_DESC_DATA_PTR, ptr, 0), SQL_HANDLE_DESC, d, "numeric descriptor buffer");
}
static void decimal_tests(SQLHDBC c) {
    struct { int p, s; const char *text; } cases[] = {
        {9,2,"1234.56"}, {9,2,"-19.95"}, {9,2,"0.00"}, {9,2,"0.01"},
        {18,4,"12345678901234.5678"}, {18,4,"42.5000"},
        {19,6,"1.234567"}, {28,10,"987654321012345678.1234567890"},
        {38,18,"12345678901234567890.123456789012345678"},
        {38,0,"12345678901234567890123456789012345678"}
    };
    for (size_t i = 0; i < sizeof cases / sizeof *cases; ++i) {
        int p = cases[i].p, scale = cases[i].s;
        char sql[200], label[200];
        snprintf(sql, sizeof sql, "CREATE TABLE #decimal (v decimal(%d,%d))", p, scale);
        command(c, sql);
        SQLHSTMT s = statement(c);
        SQL_NUMERIC_STRUCT input = decimal_value(cases[i].text, p, scale), output = {0};
        SQLLEN len = sizeof input, out_len;
        ST(s, SQLBindParameter(s, 1, SQL_PARAM_INPUT, SQL_C_NUMERIC, SQL_DECIMAL,
            (SQLULEN)p, (SQLSMALLINT)scale, &input, sizeof input, &len));
        numeric_descriptor(s, SQL_ATTR_APP_PARAM_DESC, p, scale, &input);
        exec(s, "INSERT INTO #decimal VALUES (?)"); close_cursor(s);
        ST(s, SQLFreeStmt(s, SQL_RESET_PARAMS));
        exec(s, "SELECT v FROM #decimal");
        SQLCHAR name[32]; SQLSMALLINT namelen, type, digits, nullable; SQLULEN precision;
        ST(s, SQLDescribeCol(s, 1, name, sizeof name, &namelen, &type, &precision, &digits, &nullable));
        check((type == SQL_DECIMAL || type == SQL_NUMERIC) && precision == (SQLULEN)p && digits == scale,
            "decimal metadata preserves precision and scale");
        numeric_descriptor(s, SQL_ATTR_APP_ROW_DESC, p, scale, NULL);
        ST(s, SQLFetch(s));
        ST(s, SQLGetData(s, 1, SQL_ARD_TYPE, &output, sizeof output, &out_len));
        snprintf(label, sizeof label, "decimal(%d,%d) native struct exact: %s", p, scale, cases[i].text);
        check(out_len == sizeof output && output.precision == p && same_decimal(&input, &output), label);
        close_cursor(s);
        exec(s, "SELECT v FROM #decimal"); ST(s, SQLFetch(s));
        char text[128];
        ST(s, SQLGetData(s, 1, SQL_C_CHAR, text, sizeof text, &out_len));
        const char *dot = strchr(text, '.');
        int text_scale = dot ? (int)strlen(dot + 1) : 0;
        SQL_NUMERIC_STRUCT from_text = decimal_value(text, p, text_scale);
        printf("OBS decimal(%d,%d) text=%s\n", p, scale, text);
        check(same_decimal(&input, &from_text), "decimal string independently preserves magnitude and trailing scale");
        close_cursor(s);
        exec(s, "SELECT v FROM #decimal");
        memset(&output, 0, sizeof output);
        ST(s, SQLBindCol(s, 1, SQL_C_NUMERIC, &output, sizeof output, &out_len));
        numeric_descriptor(s, SQL_ATTR_APP_ROW_DESC, p, scale, &output);
        ST(s, SQLFetch(s));
        check(same_decimal(&input, &output), "decimal SQLBindCol exact with descriptor scale");
        SQLFreeHandle(SQL_HANDLE_STMT, s); command(c, "DROP TABLE #decimal");
    }
    SQLHSTMT s = statement(c); SQL_NUMERIC_STRUCT output = {0}; SQLLEN len;
    exec(s, "SELECT CAST(1234.56 AS decimal(9,2))"); ST(s, SQLFetch(s));
    SQLRETURN rc = SQLGetData(s, 1, SQL_C_NUMERIC, &output, sizeof output, &len);
    printf("OBS decimal SQL_C_NUMERIC without descriptor rc=%d precision=%d scale=%d magnitude_low_bytes=%02x%02x\n",
        rc, output.precision, output.scale, output.val[1], output.val[0]);
    diagnostics(SQL_HANDLE_STMT, s);
    check(rc == SQL_SUCCESS_WITH_INFO && has_state(s, "01S07") && output.scale == 0,
        "unconfigured numeric retrieval truncates fractional part with 01S07 warning");
    close_cursor(s);
    SQL_NUMERIC_STRUCT input = decimal_value("0.00", 18, 2); SQLLEN null_len = SQL_NULL_DATA;
    ST(s, SQLBindParameter(s, 1, SQL_PARAM_INPUT, SQL_C_NUMERIC, SQL_DECIMAL, 18, 2, &input, sizeof input, &null_len));
    numeric_descriptor(s, SQL_ATTR_APP_PARAM_DESC, 18, 2, &input);
    exec(s, "SELECT CAST(? AS decimal(18,2))"); ST(s, SQLFetch(s));
    numeric_descriptor(s, SQL_ATTR_APP_ROW_DESC, 18, 2, NULL);
    ST(s, SQLGetData(s, 1, SQL_ARD_TYPE, &output, sizeof output, &len));
    check(len == SQL_NULL_DATA, "decimal NULL preserved");
    SQLFreeHandle(SQL_HANDLE_STMT, s);
}

static const char utf8[] = "Renée / Łódź / 東京 / مرحبا / 😀 / café";
static const uint_least16_t utf16[] = u"Renée / Łódź / 東京 / مرحبا / 😀 / café";

static void long_text(SQLHSTMT s, SQLUSMALLINT col, int wide,
                      const void *expected, size_t bytes) {
    unsigned char *received = malloc(bytes + 4096);
    if (!received) exit(2);
    size_t used = 0; int chunks = 0, truncations = 0; SQLRETURN rc;
    do {
        SQLWCHAR chunk[513] = {0}; SQLLEN n;
        rc = SQLGetData(s, col, wide ? SQL_C_WCHAR : SQL_C_CHAR, chunk, sizeof chunk, &n);
        if (rc == SQL_NO_DATA) break;
        if (rc == SQL_SUCCESS_WITH_INFO && has_state(s, "01004")) ++truncations;
        else ST(s, rc);
        size_t count = 0;
        if (wide) { while (count < 512 && chunk[count]) ++count; count *= 2; }
        else count = strnlen((char *)chunk, sizeof chunk - 1);
        if (used + count > bytes + 4096) exit(2);
        memcpy(received + used, chunk, count); used += count; ++chunks;
    } while (rc == SQL_SUCCESS_WITH_INFO);
    printf("OBS long_text column=%s encoding=%s bytes=%zu chunks=%d truncation_warnings=%d\n",
        col == 1 ? "nvarchar(max)" : "UTF8 varchar(max)", wide ? "UTF16" : "UTF8", used, chunks, truncations);
    check(used == bytes && !memcmp(expected, received, bytes), "large multilingual text exact after chunked SQLGetData");
    free(received);
}

/* Input includes names, non-Latin scripts, an emoji and a decomposed accent.
 * Compare exact bytes/code units: no SQL collation equality or normalization. */
static void unicode_tests(SQLHDBC c) {
    command(c, "CREATE TABLE #text (n nvarchar(max), v varchar(max) COLLATE Latin1_General_100_CI_AS_SC_UTF8)");
    SQLHSTMT s = statement(c);
    for (int wide = 0; wide < 2; ++wide) {
        SQLLEN len = wide ? sizeof utf16 - 2 : sizeof utf8 - 1;
        SQLPOINTER p = wide ? (SQLPOINTER)utf16 : (SQLPOINTER)utf8;
        for (int i = 1; i <= 2; ++i)
            ST(s, SQLBindParameter(s, (SQLUSMALLINT)i, SQL_PARAM_INPUT,
                wide ? SQL_C_WCHAR : SQL_C_CHAR, SQL_WVARCHAR, 200, 0, p, len, &len));
        exec(s, "INSERT INTO #text VALUES (?, ?)"); close_cursor(s);
        ST(s, SQLFreeStmt(s, SQL_RESET_PARAMS));
        for (int read_wide = 0; read_wide < 2; ++read_wide) {
            exec(s, "SELECT n, v FROM #text"); ST(s, SQLFetch(s));
            for (int col = 1; col <= 2; ++col) {
                SQLWCHAR buf[512] = {0}; SQLLEN n;
                ST(s, SQLGetData(s, (SQLUSMALLINT)col, read_wide ? SQL_C_WCHAR : SQL_C_CHAR, buf, sizeof buf, &n));
                size_t expected_len = read_wide ? sizeof utf16 - 2 : sizeof utf8 - 1;
                const void *expected = read_wide ? (const void *)utf16 : (const void *)utf8;
                char label[160];
                snprintf(label, sizeof label, "Unicode %s -> SQL_WVARCHAR -> %s -> %s exact",
                    wide ? "UTF16" : "UTF8", col == 1 ? "nvarchar" : "UTF8 varchar", read_wide ? "UTF16" : "UTF8");
                check(n == (SQLLEN)expected_len && !memcmp(buf, expected, expected_len), label);
            }
            close_cursor(s);
        }
        command(c, "DELETE FROM #text");
    }
    /* Realistic pitfall: a binding that always declares narrow SQL parameters.
     * Observe, don't assume, whether the DB collation loses input on the way to
     * an explicitly UTF-8 column. The safe tests above use SQL_WVARCHAR. */
    SQLLEN input_len = sizeof utf8 - 1;
    ST(s, SQLBindParameter(s, 1, SQL_PARAM_INPUT, SQL_C_CHAR, SQL_VARCHAR, 200, 0,
        (SQLPOINTER)utf8, sizeof utf8, &input_len));
    exec(s, "INSERT INTO #text(v) VALUES (?)"); close_cursor(s);
    ST(s, SQLFreeStmt(s, SQL_RESET_PARAMS));
    exec(s, "SELECT v FROM #text"); ST(s, SQLFetch(s));
    char small[512]; SQLLEN n;
    SQLRETURN rc = SQLGetData(s, 1, SQL_C_CHAR, small, sizeof small, &n);
    ST(s, rc);
    printf("OBS SQL_VARCHAR parameter -> UTF8 varchar exact=%d output=%s rc=%d\n",
        n == sizeof utf8 - 1 && !memcmp(small, utf8, sizeof utf8 - 1), small, rc);
    close_cursor(s); command(c, "DELETE FROM #text");

    const size_t repetitions = 4096;
    size_t bytes = repetitions * (sizeof utf16 - 2);
    size_t narrow_bytes = repetitions * (sizeof utf8 - 1);
    char *large = malloc(bytes + 2), *narrow = malloc(narrow_bytes);
    if (!large || !narrow) exit(2);
    for (size_t i = 0; i < repetitions; ++i) {
        memcpy(large + i * (sizeof utf16 - 2), utf16, sizeof utf16 - 2);
        memcpy(narrow + i * (sizeof utf8 - 1), utf8, sizeof utf8 - 1);
    }
    memset(large + bytes, 0, 2); SQLLEN large_len = (SQLLEN)bytes;
    ST(s, SQLBindParameter(s, 1, SQL_PARAM_INPUT, SQL_C_WCHAR, SQL_WLONGVARCHAR,
        bytes / 2, 0, large, (SQLLEN)bytes, &large_len));
    ST(s, SQLBindParameter(s, 2, SQL_PARAM_INPUT, SQL_C_WCHAR, SQL_WLONGVARCHAR,
        bytes / 2, 0, large, (SQLLEN)bytes, &large_len));
    exec(s, "INSERT INTO #text(n,v) VALUES (?,?)"); close_cursor(s);
    ST(s, SQLFreeStmt(s, SQL_RESET_PARAMS));
    for (int wide = 0; wide < 2; ++wide) {
        exec(s, "SELECT n, v FROM #text"); ST(s, SQLFetch(s));
        for (SQLUSMALLINT col = 1; col <= 2; ++col)
            long_text(s, col, wide, wide ? large : narrow, wide ? bytes : narrow_bytes);
        close_cursor(s);
    }
    free(large); free(narrow);
    command(c, "DELETE FROM #text; INSERT INTO #text VALUES (NULL,NULL), (N'', '')");
    exec(s, "SELECT n, v FROM #text ORDER BY CASE WHEN n IS NULL THEN 0 ELSE 1 END");
    for (int row = 0; row < 2; ++row) {
        ST(s, SQLFetch(s));
        for (int col = 1; col <= 2; ++col) {
            ST(s, SQLGetData(s, (SQLUSMALLINT)col, SQL_C_CHAR, small, sizeof small, &n));
            check(n == (row == 0 ? SQL_NULL_DATA : 0), row == 0 ? "Unicode NULL preserved" : "Unicode empty distinct from NULL");
        }
    }
    SQLFreeHandle(SQL_HANDLE_STMT, s);
}

struct pending { SQLHSTMT s; SQLRETURN rc; const char *sql; };
static void *execute_pending(void *arg) {
    struct pending *p = arg;
    p->rc = SQLExecDirect(p->s, (SQLCHAR *)p->sql, SQL_NTS);
    return NULL;
}
static void reuse(SQLHDBC c, SQLHSTMT s, int spid, const char *label) {
    close_cursor(s);
    exec(s, "SELECT 42"); ST(s, SQLFetch(s));
    SQLINTEGER v; SQLLEN n;
    ST(s, SQLGetData(s, 1, SQL_C_SLONG, &v, sizeof v, &n));
    check(v == 42, label); close_cursor(s);
    check(integer(c, "SELECT @@SPID") == spid, "reuse keeps original server session (no reconnect)");
}
static void cancellation_tests(SQLHDBC c, int mars) {
    printf("SECTION cancellation mars=%d\n", mars);
    SQLHSTMT s = statement(c); int spid = integer(c, "SELECT @@SPID");
    ST(s, SQLSetStmtAttr(s, SQL_ATTR_QUERY_TIMEOUT, (SQLPOINTER)1, 0));
    double start = now();
    SQLRETURN rc = SQLExecDirect(s, (SQLCHAR *)"WAITFOR DELAY '00:00:10'; SELECT 99", SQL_NTS);
    double elapsed = now() - start;
    printf("OBS query_timeout elapsed=%.6f rc=%d\n", elapsed, rc); diagnostics(SQL_HANDLE_STMT, s);
    check(rc == SQL_ERROR && has_state(s, "HYT00") && elapsed >= .8 && elapsed < 5,
          "1s query timeout interrupts 10s WAITFOR with HYT00");
    reuse(c, s, spid, "statement reusable after query timeout");
    ST(s, SQLSetStmtAttr(s, SQL_ATTR_QUERY_TIMEOUT, (SQLPOINTER)0, 0));
    SQLHDBC observer = connect_db(0, 0);
    for (int trial = 0; trial < 3; ++trial) {
        struct pending p = {s, 0, "WAITFOR DELAY '00:00:10'; SELECT 99"};
        pthread_t thread;
        if (pthread_create(&thread, NULL, execute_pending, &p)) exit(2);
        char sql[256];
        snprintf(sql, sizeof sql, "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE session_id=%d AND wait_type='WAITFOR'", spid);
        start = now(); int running = 0;
        do { running = integer(observer, sql); if (!running) delay(.01); } while (!running && now() - start < 3);
        check(running > 0, "observer confirms query executing before cross-thread cancel");
        start = now(); SQLRETURN cancel_rc = SQLCancelHandle(SQL_HANDLE_STMT, s);
        double call_time = now() - start;
        pthread_join(thread, NULL); elapsed = now() - start;
        printf("OBS cross_thread_cancel trial=%d call_ms=%.3f completion_ms=%.3f cancel_rc=%d query_rc=%d\n",
            trial, call_time * 1000, elapsed * 1000, cancel_rc, p.rc);
        diagnostics(SQL_HANDLE_STMT, s);
        check(SQL_SUCCEEDED(cancel_rc) && p.rc == SQL_ERROR && has_state(s, "HY008") && elapsed < 3,
            "SQLCancelHandle cancels running query with HY008 promptly");
        reuse(c, s, spid, "statement reusable after cross-thread cancel");
        check(integer(observer, sql) == 0, "canceled WAITFOR no longer executing on server");
    }
    disconnect(observer);
    /* Timeout after the first result set, during a subsequent blocking call. */
    ST(s, SQLSetStmtAttr(s, SQL_ATTR_QUERY_TIMEOUT, (SQLPOINTER)1, 0));
    exec(s, "SELECT 1; RAISERROR(N'flush first result',0,1) WITH NOWAIT; WAITFOR DELAY '00:00:10'; SELECT 2"); ST(s, SQLFetch(s));
    check(SQLFetch(s) == SQL_NO_DATA, "first result consumed before delayed second result");
    start = now();
    do { rc = SQLMoreResults(s); } while (SQL_SUCCEEDED(rc));
    elapsed = now() - start;
    printf("OBS more_results_timeout elapsed=%.6f rc=%d\n", elapsed, rc); diagnostics(SQL_HANDLE_STMT, s);
    check(rc == SQL_ERROR && has_state(s, "HYT00") && elapsed < 5, "query timeout applies to SQLMoreResults");
    reuse(c, s, spid, "statement reusable after SQLMoreResults timeout");
    ST(s, SQLSetStmtAttr(s, SQL_ATTR_QUERY_TIMEOUT, (SQLPOINTER)0, 0));

    exec(s, "SELECT TOP (100000) a.object_id, REPLICATE('x',1000) FROM sys.all_objects a CROSS JOIN sys.all_objects b");
    for (int i = 0; i < 10; ++i) ST(s, SQLFetch(s));
    start = now(); close_cursor(s); elapsed = now() - start;
    printf("OBS abandon_stream close_ms=%.3f\n", elapsed * 1000);
    check(elapsed < 5, "close cursor abandons partially consumed ~100MB result promptly");
    reuse(c, s, spid, "statement reusable after abandoning partial result");

    command(c, "CREATE TABLE #cancel_transaction (id int)");
    DB(c, SQLSetConnectAttr(c, SQL_ATTR_AUTOCOMMIT, (SQLPOINTER)SQL_AUTOCOMMIT_OFF, 0));
    command(c, "INSERT INTO #cancel_transaction VALUES (1)");
    ST(s, SQLSetStmtAttr(s, SQL_ATTR_QUERY_TIMEOUT, (SQLPOINTER)1, 0));
    rc = SQLExecDirect(s, (SQLCHAR *)"WAITFOR DELAY '00:00:10'", SQL_NTS);
    check(rc == SQL_ERROR && has_state(s, "HYT00"), "timeout inside transaction"); close_cursor(s);
    int state = integer(c, "SELECT XACT_STATE()"), count = integer(c, "SELECT @@TRANCOUNT");
    printf("OBS timeout_transaction xact_state=%d trancount=%d\n", state, count);
    check(state == 1 && count > 0, "timeout leaves explicit transaction open (caller must roll back)");
    DB(c, SQLEndTran(SQL_HANDLE_DBC, c, SQL_ROLLBACK));
    DB(c, SQLSetConnectAttr(c, SQL_ATTR_AUTOCOMMIT, (SQLPOINTER)SQL_AUTOCOMMIT_ON, 0));
    check(integer(c, "SELECT COUNT(*) FROM #cancel_transaction") == 0, "explicit rollback undoes pre-timeout write");
    reuse(c, s, spid, "statement reusable after rollback");
    command(c, "DROP TABLE #cancel_transaction");
    SQLFreeHandle(SQL_HANDLE_STMT, s);
}

static void mars_tests(void) {
    for (int mars = 0; mars <= 1; ++mars) {
        SQLHDBC c = connect_db(mars, 0);
        command(c, "SELECT TOP (10000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS id INTO #mars FROM sys.all_objects a CROSS JOIN sys.all_objects b");
        SQLHSTMT a = statement(c), b = statement(c);
        exec(a, "SELECT id FROM #mars ORDER BY id"); ST(a, SQLFetch(a));
        SQLRETURN rc = SQLExecDirect(b, (SQLCHAR *)"SELECT id*10 FROM #mars ORDER BY id", SQL_NTS);
        if (!mars) {
            printf("OBS second active statement mars=0 rc=%d\n", rc); diagnostics(SQL_HANDLE_STMT, b);
            check(rc == SQL_ERROR && has_state(b, "HY000"), "without MARS second active result is rejected");
        } else {
            ST(b, rc); int ok = 1;
            for (int i = 1; i <= 10000; ++i) {
                SQLBIGINT av = 0, bv = 0; SQLLEN n;
                if (i > 1) ST(a, SQLFetch(a));
                ST(a, SQLGetData(a, 1, SQL_C_SBIGINT, &av, sizeof av, &n));
                ST(b, SQLFetch(b));
                ST(b, SQLGetData(b, 1, SQL_C_SBIGINT, &bv, sizeof bv, &n));
                ok &= av == i && bv == i * 10;
            }
            check(ok && SQLFetch(a) == SQL_NO_DATA && SQLFetch(b) == SQL_NO_DATA,
                "MARS interleaves two 10000-row results exactly on one connection");
            close_cursor(a); close_cursor(b);
            exec(a, "SELECT id FROM #mars ORDER BY id"); ST(a, SQLFetch(a));
            ST(b, SQLSetStmtAttr(b, SQL_ATTR_QUERY_TIMEOUT, (SQLPOINTER)1, 0));
            rc = SQLExecDirect(b, (SQLCHAR *)"WAITFOR DELAY '00:00:10'", SQL_NTS);
            check(rc == SQL_ERROR && has_state(b, "HYT00"), "MARS second statement times out while first result is open");
            close_cursor(b);
            int count = 1, exact = 1;
            while ((rc = SQLFetch(a)) != SQL_NO_DATA) {
                ST(a, rc); ++count; SQLBIGINT id; SQLLEN n;
                ST(a, SQLGetData(a, 1, SQL_C_SBIGINT, &id, sizeof id, &n));
                exact &= id == count;
            }
            check(count == 10000 && exact, "MARS first result survives cancellation of second statement");
        }
        SQLFreeHandle(SQL_HANDLE_STMT, a); SQLFreeHandle(SQL_HANDLE_STMT, b);
        if (mars) cancellation_tests(c, 1);
        disconnect(c);
    }
}

struct perf_row {
    SQLBIGINT id;
    SQLWCHAR text[128]; /* Also holds UTF-8 when bound as SQL_C_CHAR. */
    SQL_SS_TIMESTAMPOFFSET_STRUCT dto;
    SQLLEN id_len, text_len, dto_len;
};
static void bench_fetch(SQLHDBC c, int mars, int wide, int batch, int round) {
    SQLHSTMT s = statement(c);
    struct perf_row *rows = calloc((size_t)batch, sizeof *rows);
    SQLUSMALLINT *status = calloc((size_t)batch, sizeof *status);
    if (!rows || !status) exit(2);
    SQLULEN fetched = 0;
    ST(s, SQLSetStmtAttr(s, SQL_ATTR_ROW_BIND_TYPE, (SQLPOINTER)sizeof *rows, 0));
    ST(s, SQLSetStmtAttr(s, SQL_ATTR_ROW_ARRAY_SIZE, (SQLPOINTER)(uintptr_t)batch, 0));
    ST(s, SQLSetStmtAttr(s, SQL_ATTR_ROWS_FETCHED_PTR, &fetched, 0));
    ST(s, SQLSetStmtAttr(s, SQL_ATTR_ROW_STATUS_PTR, status, 0));
    ST(s, SQLBindCol(s, 1, SQL_C_SBIGINT, &rows[0].id, sizeof rows[0].id, &rows[0].id_len));
    ST(s, SQLBindCol(s, 2, wide ? SQL_C_WCHAR : SQL_C_CHAR, rows[0].text, sizeof rows[0].text, &rows[0].text_len));
    ST(s, SQLBindCol(s, 3, SQL_C_SS_TIMESTAMPOFFSET, &rows[0].dto, sizeof rows[0].dto, &rows[0].dto_len));
    double start = now();
    exec(s, "SELECT id, txt, dto FROM #perf");
    SQLRETURN rc; SQLBIGINT sum = 0; size_t count = 0; int valid = 1;
    while ((rc = SQLFetch(s)) != SQL_NO_DATA) {
        ST(s, rc);
        for (SQLULEN i = 0; i < fetched; ++i) {
            sum += rows[i].id; ++count;
            valid &= status[i] == SQL_ROW_SUCCESS && rows[i].id_len == sizeof(SQLBIGINT) &&
                rows[i].text_len == (SQLLEN)(wide ? sizeof utf16 - 2 : sizeof utf8 - 1) &&
                !memcmp(rows[i].text, wide ? (const void *)utf16 : (const void *)utf8,
                    wide ? sizeof utf16 - 2 : sizeof utf8 - 1) &&
                rows[i].dto.year == 2026 && rows[i].dto.timezone_hour == 5 &&
                rows[i].dto.timezone_minute == 30 && rows[i].dto.fraction == 123456700;
        }
    }
    double elapsed = now() - start;
    check(valid && count == 100000 && sum == INT64_C(5000050000), "benchmark fetched all values exactly");
    if (round >= 0) printf("BENCH fetch mars=%d encoding=%s rowset=%d round=%d rows=%zu seconds=%.6f rows_per_sec=%.0f\n",
        mars, wide ? "UTF16" : "UTF8", batch, round, count, elapsed, count / elapsed);
    SQLFreeHandle(SQL_HANDLE_STMT, s); free(rows); free(status);
}
static void bench_blob(SQLHDBC c, int mars) {
    const size_t bytes = 4 * 1024 * 1024;
    unsigned char *input = malloc(bytes), *output = malloc(bytes);
    if (!input || !output) exit(2);
    for (size_t i = 0; i < bytes; ++i) input[i] = (unsigned char)(i * 37 + i / 256);
    command(c, "CREATE TABLE #blob (v varbinary(max))");
    SQLHSTMT s = statement(c);
    for (int round = -1; round < 5; ++round) {
        command(c, "DELETE FROM #blob");
        SQLLEN len = (SQLLEN)bytes;
        ST(s, SQLPrepare(s, (SQLCHAR *)"INSERT INTO #blob VALUES (?)", SQL_NTS));
        ST(s, SQLBindParameter(s, 1, SQL_PARAM_INPUT, SQL_C_BINARY, SQL_LONGVARBINARY,
            bytes, 0, input, (SQLLEN)bytes, &len));
        double start = now(); ST(s, SQLExecute(s)); close_cursor(s);
        double upload = now() - start;
        ST(s, SQLFreeStmt(s, SQL_RESET_PARAMS));
        start = now(); exec(s, "SELECT v FROM #blob"); ST(s, SQLFetch(s));
        size_t used = 0; SQLRETURN rc;
        do {
            unsigned char chunk[65536];
            rc = SQLGetData(s, 1, SQL_C_BINARY, chunk, sizeof chunk, &len);
            if (rc == SQL_SUCCESS_WITH_INFO && has_state(s, "01004")) {}
            else ST(s, rc);
            size_t n = rc == SQL_SUCCESS_WITH_INFO ? sizeof chunk : (size_t)len;
            if (n > sizeof chunk || used + n > bytes) exit(2);
            memcpy(output + used, chunk, n); used += n;
        } while (rc == SQL_SUCCESS_WITH_INFO);
        close_cursor(s); double download = now() - start;
        check(used == bytes && !memcmp(input, output, bytes), "4MiB binary upload/download byte exact");
        if (round >= 0) printf("BENCH blob mars=%d round=%d bytes=%zu upload_MiB_per_sec=%.3f download_MiB_per_sec=%.3f\n",
            mars, round, bytes, 4 / upload, 4 / download);
    }
    SQLFreeHandle(SQL_HANDLE_STMT, s); free(input); free(output);
}
static void bench_insert(SQLHDBC c, int mars) {
    command(c, "CREATE TABLE #insert (id int NOT NULL)");
    for (int round = -1; round < 5; ++round) {
        for (int array = 0; array < 2; ++array) {
            command(c, "TRUNCATE TABLE #insert");
            SQLHSTMT s = statement(c);
            SQLINTEGER values[1000]; SQLLEN lengths[1000];
            SQLUSMALLINT status[1000] = {0}; SQLULEN processed = 0;
            for (int i = 0; i < 1000; ++i) { values[i] = i + 1; lengths[i] = sizeof *values; }
            ST(s, SQLPrepare(s, (SQLCHAR *)"INSERT INTO #insert VALUES (?)", SQL_NTS));
            if (array) {
                ST(s, SQLSetStmtAttr(s, SQL_ATTR_PARAMSET_SIZE, (SQLPOINTER)1000, 0));
                ST(s, SQLSetStmtAttr(s, SQL_ATTR_PARAMS_PROCESSED_PTR, &processed, 0));
                ST(s, SQLSetStmtAttr(s, SQL_ATTR_PARAM_STATUS_PTR, status, 0));
            }
            ST(s, SQLBindParameter(s, 1, SQL_PARAM_INPUT, SQL_C_SLONG, SQL_INTEGER, 10, 0, values, sizeof *values, lengths));
            DB(c, SQLSetConnectAttr(c, SQL_ATTR_AUTOCOMMIT, (SQLPOINTER)SQL_AUTOCOMMIT_OFF, 0));
            double start = now();
            if (array) { ST(s, SQLExecute(s)); close_cursor(s); }
            else for (int i = 0; i < 1000; ++i) { values[0] = i + 1; ST(s, SQLExecute(s)); close_cursor(s); }
            DB(c, SQLEndTran(SQL_HANDLE_DBC, c, SQL_COMMIT));
            double elapsed = now() - start;
            DB(c, SQLSetConnectAttr(c, SQL_ATTR_AUTOCOMMIT, (SQLPOINTER)SQL_AUTOCOMMIT_ON, 0));
            int valid = 1;
            if (array) {
                valid = processed == 1000;
                for (int i = 0; i < 1000; ++i) valid &= status[i] == SQL_PARAM_SUCCESS;
            }
            check(valid && integer(c, "SELECT COUNT(*) FROM #insert") == 1000 &&
                integer(c, "SELECT SUM(id) FROM #insert") == 500500, "1000 parameterized inserts verified");
            if (round >= 0) printf("BENCH insert mars=%d parameter_array=%d round=%d rows=1000 ms=%.3f\n",
                mars, array, round, elapsed * 1000);
            SQLFreeHandle(SQL_HANDLE_STMT, s);
        }
    }
}
static void benchmark(int mars) {
    SQLHDBC c = connect_db(mars, 0);
    command(c, "SET NOCOUNT ON; CREATE TABLE #perf (id bigint NOT NULL, txt nvarchar(100) NOT NULL, dto datetimeoffset(7) NOT NULL)");
    SQLHSTMT s = statement(c); SQLLEN len = sizeof utf16 - 2;
    ST(s, SQLBindParameter(s, 1, SQL_PARAM_INPUT, SQL_C_WCHAR, SQL_WVARCHAR, 100, 0, (SQLPOINTER)utf16, len, &len));
    exec(s, "INSERT INTO #perf SELECT TOP (100000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), ?, "
        "CAST('2026-10-29T12:34:56.1234567+05:30' AS datetimeoffset(7)) FROM sys.all_objects a CROSS JOIN sys.all_objects b");
    close_cursor(s); ST(s, SQLFreeStmt(s, SQL_RESET_PARAMS));
    for (int wide = 0; wide < 2; ++wide)
        for (int batch = 1; batch <= 256; batch *= 256) bench_fetch(c, mars, wide, batch, -1);
    for (int round = 0; round < 5; ++round) {
        /* Reverse order on alternate rounds to reduce systematic warmup bias. */
        for (int j = 0; j < 4; ++j) {
            int k = round % 2 ? 3-j : j;
            bench_fetch(c, mars, k / 2, k % 2 ? 256 : 1, round);
        }
        double start = now(); int valid = 1;
        for (int i = 0; i < 200; ++i) {
            exec(s, "SELECT 1"); ST(s, SQLFetch(s)); SQLINTEGER v; SQLLEN n;
            ST(s, SQLGetData(s, 1, SQL_C_SLONG, &v, sizeof v, &n));
            valid &= v == 1; close_cursor(s);
        }
        printf("BENCH select1 mars=%d round=%d iterations=200 us_per_query=%.3f\n", mars, round, (now()-start)*1e6/200);
        check(valid, "benchmark SELECT 1 values");
        SQLINTEGER input = 123; SQLLEN ilen = sizeof input;
        ST(s, SQLPrepare(s, (SQLCHAR *)"SELECT CAST(? AS int)", SQL_NTS));
        ST(s, SQLBindParameter(s, 1, SQL_PARAM_INPUT, SQL_C_SLONG, SQL_INTEGER, 10, 0, &input, sizeof input, &ilen));
        /* Warm up prepared execution outside the timed section. */
        ST(s, SQLExecute(s)); close_cursor(s);
        start = now();
        for (int i = 0; i < 200; ++i) {
            ST(s, SQLExecute(s)); ST(s, SQLFetch(s)); SQLINTEGER v; SQLLEN n;
            ST(s, SQLGetData(s, 1, SQL_C_SLONG, &v, sizeof v, &n));
            valid &= v == input; close_cursor(s);
        }
        printf("BENCH prepared_select mars=%d round=%d iterations=200 us_per_query=%.3f\n", mars, round, (now()-start)*1e6/200);
        check(valid, "benchmark prepared parameter values");
        ST(s, SQLFreeStmt(s, SQL_RESET_PARAMS));
        start = now();
        for (int i = 0; i < 10; ++i) { SQLHDBC fresh = connect_db(mars, 0); disconnect(fresh); }
        printf("BENCH connect_close mars=%d round=%d iterations=10 ms_per_connection=%.3f\n", mars, round, (now()-start)*1000/10);
    }
    SQLFreeHandle(SQL_HANDLE_STMT, s);
    bench_blob(c, mars); bench_insert(c, mars);
    disconnect(c);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc > 2 || (argc == 2 && strcmp(argv[1], "--connect-only") &&
        strcmp(argv[1], "--tests-only") && strcmp(argv[1], "--types-only") && strcmp(argv[1], "--bench-only"))) {
        fprintf(stderr, "Usage: %s [--connect-only|--tests-only|--types-only|--bench-only]\n", argv[0]); return 2;
    }
    setlocale(LC_ALL, "C"); /* Driver 18 uses UTF-8 for SQLCHAR in C locale. */
    time_t wall = time(NULL); struct tm local;
    localtime_r(&wall, &local); char tz[80]; strftime(tz, sizeof tz, "%Z %z", &local);
    printf("ENV local_timezone=%s compiler=%s\n", tz, __VERSION__);
    if (!*setting("HMSSQL_TEST_PASSWORD", "")) {
        fprintf(stderr, "Set HMSSQL_TEST_PASSWORD (run.sh sources ~/.hmssql-test-env).\n"); return 2;
    }
    encrypt = setting("ODBC_TEST_ENCRYPT", "strict");
    pin_cert = !strcmp(setting("ODBC_TEST_PIN_CERT", "1"), "1");
    printf("ENV encrypt=%s pin_certificate=%d locale=%s sizeof_SQLWCHAR=%zu\n",
           encrypt, pin_cert, setlocale(LC_ALL, NULL), sizeof(SQLWCHAR));
    if (!SQL_SUCCEEDED(SQLSetEnvAttr(SQL_NULL_HANDLE, SQL_ATTR_CONNECTION_POOLING, (SQLPOINTER)SQL_CP_OFF, 0))) {
        fprintf(stderr, "Could not disable ODBC connection pooling\n"); return 2;
    }
    require(SQLAllocHandle(SQL_HANDLE_ENV, SQL_NULL_HANDLE, &env), SQL_HANDLE_ENV, env, "allocate environment");
    require(SQLSetEnvAttr(env, SQL_ATTR_ODBC_VERSION, (SQLPOINTER)SQL_OV_ODBC3_80, 0), SQL_HANDLE_ENV, env, "ODBC 3.8");
    SQLHDBC c = connect_db(0, 1);
    if (!c) { SQLFreeHandle(SQL_HANDLE_ENV, env); return 2; }
    info(c);
    if (argc > 1 && !strcmp(argv[1], "--connect-only")) {
        check(integer(c, "SELECT 42") == 42, "connect and SELECT 42");
    } else if (argc > 1 && !strcmp(argv[1], "--types-only")) {
        datetime_tests(c); decimal_tests(c); unicode_tests(c);
    } else if (argc > 1 && !strcmp(argv[1], "--bench-only")) {
        benchmark(0); benchmark(1);
    } else {
        check(integer(c, "SELECT 42") == 42, "baseline");
        datetime_tests(c);
        decimal_tests(c);
        unicode_tests(c);
        cancellation_tests(c, 0);
        mars_tests();
        if (!(argc > 1 && !strcmp(argv[1], "--tests-only"))) { benchmark(0); benchmark(1); }
    }
    disconnect(c); SQLFreeHandle(SQL_HANDLE_ENV, env);
    struct rusage usage; getrusage(RUSAGE_SELF, &usage);
    printf("ENV peak_rss_native_units=%ld (bytes on macOS, KiB on Linux)\n", usage.ru_maxrss);
    printf("SUMMARY checks=%d failures=%d\n", checks, failures);
    return failures ? 1 : 0;
}
