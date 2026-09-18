# Database application starter

Four routes, typed SQL, migrations, bounded Eio serving and graceful shutdown.
The same source supports SQLite or PostgreSQL.

Follow [the new-repository guide](../../docs/internal-use.md) to install from
GitHub and copy this application. To run it inside this checkout:

```sh
DATABASE_URL="sqlite3:$PWD/app.db" tools/dune-pkg exec examples/starter/main.exe
```

It binds to `127.0.0.1:8080`. This is an unauthenticated local example; add the
application's authentication and deployment configuration before exposing it.
