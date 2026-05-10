# lib/cert.sh — TLS certificate for the RDP listener.
#
# Credential capture moved to lib/prompt.sh::prompt_all_settings, which
# runs upfront before any heavy work — RDP_USERNAME/RDP_PASSWORD/
# REUSE_CREDS are already exported by the time this file's functions
# are called from install.sh.

ensure_tls_cert() {
  ui_step "TLS cert"
  mkdir -p "$TLS_DIR"
  # Reuse only if the existing cert has a localhost SAN. Older
  # revisions generated with CN=gnome-rdp and no SAN, which makes
  # mstsc warn "the name on the security certificate is from a
  # different site" on every connect even after the user imports the
  # cert into Trusted Root. Detect that and regenerate so users get a
  # clean re-import on next install.sh run.
  if [ -s "$TLS_DIR/rdp.crt" ] && [ -s "$TLS_DIR/rdp.key" ]; then
    if openssl x509 -in "$TLS_DIR/rdp.crt" -noout -ext subjectAltName 2>/dev/null \
         | grep -qiE 'DNS:localhost|IP Address:127\.0\.0\.1'; then
      ui_skip "already present at $TLS_DIR/"
      return 0
    fi
    ui_warn "Existing cert lacks localhost SAN — regenerating"
    ui_detail "Re-import $TLS_DIR/rdp.crt into Windows Trusted Root after this run"
  fi

  rm -f "$TLS_DIR/rdp.crt" "$TLS_DIR/rdp.key"

  # CN=localhost + SAN covering DNS:localhost + IP:127.0.0.1 so mstsc
  # accepts the cert without a name-mismatch dialog when the .rdp
  # uses `full address:s:localhost:<port>`. winpr-makecert doesn't
  # take SAN args on older FreeRDP, so always go through openssl.
  ui_spin "Generate cert (openssl, 4096-bit RSA, SAN=localhost)" \
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
      -subj "/C=US/ST=NA/L=NA/O=GNOME/CN=localhost" \
      -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
      -out "$TLS_DIR/rdp.crt" -keyout "$TLS_DIR/rdp.key"
  chmod 600 "$TLS_DIR/rdp.key"

  [ -s "$TLS_DIR/rdp.crt" ] || die "Cert generation produced empty $TLS_DIR/rdp.crt"
  [ -s "$TLS_DIR/rdp.key" ] || die "Cert generation produced empty $TLS_DIR/rdp.key"
  openssl x509 -in "$TLS_DIR/rdp.crt" -noout >/dev/null 2>&1 \
    || die "Generated cert at $TLS_DIR/rdp.crt is not valid PEM"
  ui_detail "$TLS_DIR/rdp.crt + rdp.key"
}
