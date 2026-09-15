# =============================================================================
# A record pointing the FQDN at the Elastic IP.
#
# HTTPS uses the HTTP-01 challenge, so the record must resolve to the instance
# before Traefik can obtain a certificate. If you use Cloudflare, keep it DNS
# only (grey cloud) for the first issuance.
# =============================================================================

resource "aws_route53_record" "app" {
  count = var.route53_zone_id != "" ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.domain
  type    = "A"
  ttl     = 300
  records = [aws_eip.main.public_ip]
}
