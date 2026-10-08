# Accounts and database setup

CCNexus 0.3 replaces the old single admin-token login with normal accounts and server-side sessions.

## First boot

Open the web dashboard before pairing Minecraft nodes. The first-boot wizard asks for a persistence backend and then creates the first Administrator account.

Supported backends:

- SQLite — easiest single-host deployment. The database file lives under the persistent CCNexus data directory unless an absolute path is supplied.
- MySQL / MariaDB — use the MySQL option and the normal host/port/database/user/password fields.
- PostgreSQL — host/port/database/user/password plus optional TLS.
- MongoDB — either the normal host fields or an explicit MongoDB URI.

The selected backend stores CCNexus application state including accounts, password hashes, sessions, worlds, paired-device credentials, cached telemetry, media queues and system state. `data/config.json` remains local because CCNexus needs the selected driver and connection details before it can open the application database.

`data/config.json` should be treated as secret when it contains remote database credentials. The application attempts to create it with owner-only permissions on Unix-like hosts. Keep the entire `data/` volume private and backed up.

## Existing 0.1 / 0.2 installs

If `data/state.json` exists when first-boot setup is completed, CCNexus seeds an empty selected database from that legacy state before creating the first Administrator. This carries forward Server/World workspaces, paired devices and cached telemetry. The old admin token is not used for the new account system.

## Roles

### User

Users can use normal Minecraft functionality:

- switch/create Server/World workspaces;
- pair and remove their CC:Tweaked nodes;
- manage speakers, media queues, radio and TTS;
- run turtle quarry/farming/tree jobs;
- control redstone and monitor pages;
- inspect inventory/FE/AE2 data and request AE2 crafting.

### Administrator

Administrators receive all User permissions plus:

- create/disable/delete Admin or User accounts;
- reset passwords and change roles;
- inspect the configured database backend (secrets are never returned to the browser);
- schedule fleet updates with a warning grace period;
- cancel scheduled updates;
- reboot selected turtles or all CC nodes immediately.

At least one enabled Administrator is always required.

## Password/session notes

Passwords are hashed with bcrypt before persistence. Browser authentication uses a random server-side session token in an HttpOnly, SameSite cookie. HTTPS deployments also receive the Secure cookie attribute.
