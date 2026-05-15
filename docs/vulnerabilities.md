# Security Risks

These are known risks for the server.

- **Internet exposure mistakes:** Only nginx should be reachable from the internet on ports `80/443`. If router forwarding or UFW rules change, you can accidentally expose more than intended.
- **DDNS dependency:** Remote access depends on Dynu DNS being correct. If DNS gets stale or wrong, traffic can fail or be sent to the wrong IP until fixed.
- **Token leaks:** Home Assistant long-lived tokens are stored in `~/secrets/scripts.env`. If those tokens leak, someone can use the API as you until you rotate them.
- **WAF rule drift:** ModSecurity/CRS tuning can break after updates. Re-test auth and API paths after nginx/CRS changes so you catch false blocks or protection gaps.

After image/package updates, rerun Trivy and Lynis and log the results. Treat HIGH/CRITICAL findings as fix-now items.
