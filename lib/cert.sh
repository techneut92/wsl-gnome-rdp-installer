# lib/cert.sh — TLS certificate for the RDP listener.

prompt_credentials() {
  # Skip prompts on re-run: if neither flag/env was passed AND grd already
  # has stored credentials, reuse them. grdctl reports a stored username
  # as "(hidden)" and an empty one as "(empty)".
  REUSE_CREDS=0
  if [ -z "$RDP_USERNAME" ] && [ -z "$RDP_PASSWORD" ]; then
    if grdctl --headless status 2>/dev/null \
         | grep -qE '^[[:space:]]*Username:[[:space:]]*\(hidden\)'; then
      log "Reusing existing RDP credentials (pass -u/-p to change)"
      REUSE_CREDS=1
    fi
  fi
  if [ "$REUSE_CREDS" = "0" ]; then
    if [ -z "$RDP_USERNAME" ]; then
      read -r -p "RDP username [$USER]: " RDP_USERNAME
      RDP_USERNAME="${RDP_USERNAME:-$USER}"
    fi
    if [ -z "$RDP_PASSWORD" ]; then
      read -r -s -p "RDP password for $RDP_USERNAME: " RDP_PASSWORD
      echo
      [ -z "$RDP_PASSWORD" ] && die "Password cannot be empty."
    fi
  fi
  export RDP_USERNAME RDP_PASSWORD REUSE_CREDS
}

ensure_tls_cert() {
  mkdir -p "$TLS_DIR"
  if [ -s "$TLS_DIR/rdp.crt" ] && [ -s "$TLS_DIR/rdp.key" ]; then
    log "TLS cert already present at $TLS_DIR/, reusing"
    return 0
  fi

  log "Generating self-signed TLS certificate at $TLS_DIR/…"
  rm -f "$TLS_DIR/rdp.crt" "$TLS_DIR/rdp.key"

  if command -v winpr-makecert >/dev/null 2>&1; then
    log "  using winpr-makecert"
    winpr-makecert -silent -rdp -path "$TLS_DIR" rdp
  else
    log "  using openssl"
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
      -subj "/C=US/ST=NA/L=NA/O=GNOME/CN=gnome-rdp" \
      -out "$TLS_DIR/rdp.crt" -keyout "$TLS_DIR/rdp.key"
  fi
  chmod 600 "$TLS_DIR/rdp.key"

  [ -s "$TLS_DIR/rdp.crt" ] || die "Cert generation produced empty $TLS_DIR/rdp.crt"
  [ -s "$TLS_DIR/rdp.key" ] || die "Cert generation produced empty $TLS_DIR/rdp.key"
  openssl x509 -in "$TLS_DIR/rdp.crt" -noout >/dev/null 2>&1 \
    || die "Generated cert at $TLS_DIR/rdp.crt is not valid PEM"
}
