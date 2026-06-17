# Security Risks

These are known risks for the server.

- **Internet exposure mistakes:** Only nginx should be reachable from the internet on ports `80/443`. If router forwarding or UFW rules change, you can accidentally expose more than intended.
- **Direct LAN HA access:** Port `8123` is published for LAN fallback. It is plain HTTP and bypasses nginx TLS, Host checks, rate limits, and WAF, so do not forward it publicly.
- **DDNS dependency:** Remote access depends on Dynu DNS being correct. If DNS gets stale or wrong, traffic can fail or be sent to the wrong IP until fixed.
- **DDNS hairpin bans:** Using the public hostname from inside the LAN can hairpin through the router; failed logins may ban the translated router/public address instead of one client.
- **Token leaks:** Home Assistant long-lived tokens are stored in `~/secrets/scripts.env`. If those tokens leak, someone can use the API as you until you rotate them.
- **WAF rule drift:** ModSecurity/CRS tuning can break after updates. Re-test auth and API paths after nginx/CRS changes so you catch false blocks or protection gaps.

After image/package updates, rerun Trivy and Lynis and log the results. Treat HIGH/CRITICAL findings as fix-now items.
