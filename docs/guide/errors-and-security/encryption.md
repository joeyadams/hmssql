# Encryption and security

hmssql encrypts by default, and it validates the server's certificate by
default.

## Encryption modes

| `connectEncryption` | What happens |
|---|---|
| `EncryptStrict` | TDS 8.0. TLS on the raw socket, then TDS inside it. Supported by Azure SQL. |
| `EncryptOn` (the default) | TLS negotiated at the start. Refused if the server cannot encrypt. |
| `EncryptReq` | The same as `EncryptOn`. |
| `EncryptOff` | Only the login is encrypted. |
| `EncryptNotSup` | Nothing is encrypted. Refused if the server requires encryption. |

Over networks you do not trust, use `EncryptStrict` or `EncryptOn`.

`EncryptOff` protects against eavesdroppers at most, because an attacker
on the path can rewrite the negotiation and read the login.
`EncryptNotSup` sends the password with trivial obfuscation.

## Certificates

The certificate is checked in every mode that uses TLS.

* It is validated against the system store.
* `tlsCaCertificateFiles` adds CA files.
* `tlsExtraCertificates` adds certificates already in memory.
* `tlsHostNameInCertificate` takes a `Text` name to check, for when the
  name in the certificate is not the host you connect to.

`tlsTrustServerCertificate` turns all of that off. The traffic is still
encrypted, but anyone who can intercept the connection can read it. Use
it for a development server only.

Two checks still apply with `tlsTrustServerCertificate`, because the
`tls` package makes them itself. A certificate that is not meant for
server authentication is refused. With `tls` 2.5 or later, a certificate
with an RSA key shorter than 2048 bits is refused as well. An older SQL
Server that generates its own certificate may present such a key, and
because every connection needs a TLS handshake for its login, even with
`EncryptOff`, such a server cannot be reached until it has a 2048-bit
certificate installed.

A local server with a self-signed certificate can be validated instead:

```haskell
connectTls = defaultTlsSettings
  { tlsCaCertificateFiles = ["/etc/ssl/my-sql-server.crt"]
  , tlsHostNameInCertificate = Just "localhost"
  }
```

## Login redirects

Azure SQL and availability groups can redirect a login to another host.
`connect` follows up to ten redirects, and validates the certificate
against the new host.

Under `EncryptOff`, the redirect arrives in plaintext, so `connect`
throws `LoginRedirected` instead of following it.

## Secrets

`ConnectInfo` has no `Show` instance, and no exception includes the
password or the access token.

Exceptions do include the SQL text that failed, but not the parameter
values. If you log exceptions, pass secrets as parameters rather than in
the SQL text.

## SQL composition

Parameter values never become part of the SQL text. `param`, `namedParam`
and `mkQuery` send them as parameters, and `escapeIdentifier`
bracket-quotes a name. Only `rawSql` and string literals splice text in
as given.

## A malicious server

A malicious server cannot make the client allocate much ahead of the
data, because length prefixes are trusted only as far as bytes arrive.
The one exception is a large value, which gets a buffer of its declared
length, up to `connectValueAllocAhead`, 1 MiB by default.

There are no timeouts. Wrap `connect` and requests in
`System.Timeout.timeout` where that matters.

Text from the server is untrusted, and it may contain control
characters.
