# TODO

## Security

- [ ] Authenticate the resident iCal endpoint (`GET /api/v1/residents/:id/ical`). Currently unauthenticated with sequential integer IDs. Replace with a hard-to-guess token so calendar apps can subscribe without exposing meal schedules to enumeration.
- [ ] Replace `config.hosts.clear` in `config/environments/production.rb` with an explicit hostname allowlist (`comeals.com`, `*.comeals.com`). The current setting disables Rails host authorization, enabling DNS rebinding attacks.
