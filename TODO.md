# TODO

## Security

- [ ] Move hardcoded Pusher credentials to environment variables (`config/initializers/pusher.rb`). The app_id and key are semi-public (frontend uses them), but the secret must not be in source control.
- [ ] Re-enable Strong Parameters — `permit_all_parameters = true` in `config/application.rb` disables Rails' mass-assignment protection globally. Add explicit `permit` calls to each controller action and remove the global override.
- [ ] Authenticate the resident iCal endpoint (`GET /api/v1/residents/:id/ical`). Currently unauthenticated with sequential integer IDs. Replace with a hard-to-guess token so calendar apps can subscribe without exposing meal schedules to enumeration.
- [ ] Replace `config.hosts.clear` in `config/environments/production.rb` with an explicit hostname allowlist (`comeals.com`, `*.comeals.com`, Heroku app URL). The current setting disables Rails host authorization, enabling DNS rebinding attacks.
