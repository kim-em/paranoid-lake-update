# Examples

- `systemd/`: a user timer that audits new commits on Tau Ceti's `main` every hour.
  Install with

  ```
  ln -s ~/paranoid-lake-update/examples/systemd/paranoid-watch-tauceti.{service,timer} ~/.config/systemd/user/
  systemctl --user daemon-reload
  systemctl --user enable --now paranoid-watch-tauceti.timer
  systemctl --user start paranoid-watch-tauceti.service   # first run only records the head
  ```

- `mathlib-update_dependencies.patch`: the steps added to Mathlib's hourly
  `update_dependencies.yml` (see the corresponding Mathlib PR).
