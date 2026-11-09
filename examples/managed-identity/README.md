# managed-identity

A login to Azure SQL Database with Entra ID and no password: the program
asks the managed identity endpoint of the Azure host it runs on for an
access token, and hmssql sends the token in the login
(`connectAccessToken`).

```
hmssql-example-managed-identity            # whoami
hmssql-example-managed-identity whoami     # the login, user, database and server the session has
hmssql-example-managed-identity query SQL  # run a query, print its result sets
hmssql-example-managed-identity exec SQL   # run a statement, print the rows affected
```

The connection settings are the examples' `MSSQL_*` variables
([../README.md](../README.md)) without `MSSQL_USER` and `MSSQL_PASSWORD`.
The token comes from `MSSQL_ACCESS_TOKEN` if it is set, which is how to run
it from a developer machine:

```sh
export MSSQL_HOST=myserver.database.windows.net MSSQL_DATABASE=mydb
export MSSQL_TRUST_SERVER_CERT=0
export MSSQL_ACCESS_TOKEN=$(az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)
stack exec hmssql-example-managed-identity
```

Otherwise [ManagedIdentity.hs](src/ManagedIdentity.hs) fetches one: from
the endpoint that `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` name (App
Service, Functions, Container Apps), or from the Instance Metadata Service
at `169.254.169.254` (VMs, Container Instances).  Both are plain HTTP on a
local address, so the program depends on `http-client` and `aeson` and
nothing more; hmssql itself has no HTTP dependency.  `AZURE_CLIENT_ID`
picks a user-assigned identity when the host has several.

The identity needs a user in the database, created by the server's Entra
admin:

```sql
CREATE USER [my-identity] FROM EXTERNAL PROVIDER;   -- the identity's name
ALTER ROLE db_datareader ADD MEMBER [my-identity];
```

The repository's `Dockerfile` builds it for Linux (`docker build
-t hmssql-example .`), and `scripts/azure-managed-identity.sh` does all of it
against the test database of `scripts/azure-sql-test.sh`: builds it for
Linux in Azure Container Instances, creates a user-assigned
identity and its database user (running `exec` here with a CLI token, as
the Entra admin), and runs `whoami` in a container that has the identity.
