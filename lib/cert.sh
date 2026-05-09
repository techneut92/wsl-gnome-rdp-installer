# lib/cert.sh — TLS certificate for the RDP listener.

prompt_credentials() {
  ui_step "RDP credentials"
  # Skip prompts on re-run: if neither flag/env was passed AND grd already
  # has stored credentials, reuse them. grdctl reports a stored username
  # as "(hidden)" and an empty one as "(empty)".
  REUSE_CREDS=0
  if [ -z "$RDP_USERNAME" ] && [ -z "$RDP_PASSWORD" ]; then
    if grdctl --headless status 2>/dev/null \
         | grep -qE '^[[:space:]]*Username:[[:space:]]*\(hidden\)'; then
      ui_skip "reusing existing credentials (pass -u/-p to change)"
      REUSE_CREDS=1
    fi
  fi
  if [ "$REUSE_CREDS" = "0" ]; then
    if [ -z "$RDP_USERNAME" ]; then
      read -r -p "  RDP username [$USER]: " RDP_USERNAME
      RDP_USERNAME="${RDP_USERNAME:-$USER}"
    fi
    if [ -z "$RDP_PASSWORD" ]; then
      read -r -s -p "  RDP password for $RDP_USERNAME: " RDP_PASSWORD
      echo
      [ -z "$RDP_PASSWORD" ] && die "Password cannot be empty."
    fi
    ui_ok "credentials captured"
  fi
  export RDP_USERNAME RDP_PASSWORD REUSE_CREDS
}

ensure_tls_cert() {
  ui_step "TLS cert"
  mkdir -p "$TLS_DIR"
  if [ -s "$TLS_DIR/rdp.crt" ] && [ -s "$TLS_DIR/rdp.key" ]; then
    ui_skip "already present at $TLS_DIR/"
    return 0
  fi

  rm -f "$TLS_DIR/rdp.crt" "$TLS_DIR/rdp.key"

  if command -v winpr-makecert >/dev/null 2>&1; then
    ui_spin "Generate cert (winpr-makecert)" \
      winpr-makecert -silent -rdp -path "$TLS_DIR" rdp
  else
    ui_spin "Generate cert (openssl, 4096-bit RSA)" \
      openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=NA/L=NA/O=GNOME/CN=gnome-rdp" \
        -out "$TLS_DIR/rdp.crt" -keyout "$TLS_DIR/rdp.key"
  fi
  chmod 600 "$TLS_DIR/rdp.key"

  [ -s "$TLS_DIR/rdp.crt" ] || die "Cert generation produced empty $TLS_DIR/rdp.crt"
  [ -s "$TLS_DIR/rdp.key" ] || die "Cert generation produced empty $TLS_DIR/rdp.key"
  openssl x509 -in "$TLS_DIR/rdp.crt" -noout >/dev/null 2>&1 \
    || die "Generated cert at $TLS_DIR/rdp.crt is not valid PEM"
  ui_detail "$TLS_DIR/rdp.crt + rdp.key"
}
