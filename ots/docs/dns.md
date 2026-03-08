# DNS Configuration for TAK Server

## Required DNS Records

These **must** exist before deploying the server:

| Type | Name | Value | TTL | Description |
|------|------|-------|-----|-------------|
| A | `<OTS_DOMAIN>` | `<PRIMARY_IP>` | 300 | Main domain — OTS WebUI |
| A | `<CLOUDTAK_DOMAIN>` | `<PRIMARY_IP>` | 300 | CloudTAK web client |
| A | `<TILES_DOMAIN>` | `<PRIMARY_IP>` | 300 | PMTiles tile server (CloudTAK) |

## Optional DNS Records

| Type | Name | Value | TTL | Description |
|------|------|-------|-----|-------------|
| A | `media.<OTS_DOMAIN>` | `<PRIMARY_IP>` | 300 | If you want to expose MediaMTX directly |
| CAA | `<OTS_DOMAIN>` | `0 issue "letsencrypt.org"` | 3600 | Restrict certificate issuers |

## Verify DNS

```bash
# Check that records resolve correctly
dig +short <OTS_DOMAIN> A
dig +short <CLOUDTAK_DOMAIN> A
dig +short <TILES_DOMAIN> A

# From the server
dig +short @1.1.1.1 <OTS_DOMAIN> A
```

## Notes

- DNS propagation can take up to 48 hours but usually completes in minutes
- Set TTL to 300 (5 min) initially — can be increased later
- If DNS isn't ready at deploy time, you can re-run cloud-init:
  ```bash
  sudo cloud-init clean && sudo cloud-init init
  ```
